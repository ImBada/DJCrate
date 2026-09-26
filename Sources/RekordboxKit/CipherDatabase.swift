import DJCDomain
import Foundation
import SQLCipher

/// SQLCipher C API를 감싼 연결. 기본은 읽기 전용이고 스냅샷 사본을 연다.
/// 쓰기 연결(`writable`)은 `RekordboxWriter`만 쓴다.
public final class CipherDatabase {
    private var handle: OpaquePointer?

    public init(path: String, key: String?, writable: Bool = false) throws {
        guard sqlite3_open_v2(path, &handle, writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            handle = nil  // deinit이 한 번 더 닫지 않도록
            throw DJCError.databaseOpenFailed(path: path, message: message)
        }
        if let key {
            // 키는 16진수 문자열만 허용하므로 SQL 문자열에 넣어도 안전하다.
            guard key.allSatisfy(\.isHexDigit) else { throw DJCError.keyDerivationFailed }
            try execute("PRAGMA key = '\(key)'")
        }
        if writable {
            sqlite3_busy_timeout(handle, 2000)
        } else {
            try execute("PRAGMA query_only = ON")
        }
        try? execute("PRAGMA cache_size = -65536")
        try? execute("PRAGMA temp_store = MEMORY")
        do {
            _ = try scalarInt("SELECT count(*) FROM sqlite_master")
        } catch {
            throw DJCError.databaseOpenFailed(path: path, message: "키가 맞지 않거나 DB가 손상됐습니다")
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// 연결을 바로 닫는다(쓰기 뒤 파일을 다시 열어 검사하기 전에 쓴다).
    public func close() {
        sqlite3_close_v2(handle)
        handle = nil
    }

    /// 스냅샷 **사본**에 딸린 WAL을 사본 안으로 합친다(원본 rekordbox DB에는 절대 쓰지 않는다).
    /// rekordbox가 켜져 있으면 최근 변경(예: 방금 가져온 XML)이 아직 WAL에만 있어서 이게 필요하다.
    public static func mergeWriteAheadLog(ofCopyAt path: String, key: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw DJCError.databaseOpenFailed(path: path, message: message)
        }
        defer { sqlite3_close_v2(handle) }
        guard key.allSatisfy(\.isHexDigit) else { throw DJCError.keyDerivationFailed }
        for sql in ["PRAGMA key = '\(key)'", "PRAGMA wal_checkpoint(TRUNCATE)"] {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(error)
                throw DJCError.queryFailed(sql: "wal_checkpoint", message: message)
            }
        }
    }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw DJCError.queryFailed(sql: sql, message: message)
        }
    }

    /// 자리표시자(`?`)에 넣을 값
    public enum Value: Sendable, Equatable {
        case text(String)
        case int(Int)
        case null
    }

    public func query(_ sql: String, _ values: [Value] = [], _ each: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DJCError.queryFailed(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result = switch value {
            case let .text(text): sqlite3_bind_text(statement, position, text, -1, transient)
            case let .int(number): sqlite3_bind_int64(statement, position, Int64(number))
            case .null: sqlite3_bind_null(statement, position)
            }
            guard result == SQLITE_OK else {
                throw DJCError.queryFailed(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try each(Row(statement: statement))
            case SQLITE_DONE:
                return
            default:
                throw DJCError.queryFailed(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    /// 값을 넣어 한 문장을 실행하고 바뀐 행 수를 돌려준다.
    @discardableResult
    public func run(_ sql: String, _ values: [Value]) throws -> Int {
        try query(sql, values) { _ in }
        return Int(sqlite3_changes(handle))
    }

    public func scalarInt(_ sql: String) throws -> Int {
        var value = 0
        try query(sql) { value = $0.int(0) ?? 0 }
        return value
    }

    public struct Row {
        let statement: OpaquePointer?

        public func string(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                  let text = sqlite3_column_text(statement, column)
            else { return nil }
            return String(cString: text)
        }

        public var count: Int { Int(sqlite3_column_count(statement)) }

        /// 칸 이름
        public func name(_ column: Int32) -> String {
            sqlite3_column_name(statement, column).map { String(cString: $0) } ?? ""
        }

        public func int(_ column: Int32) -> Int? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(statement, column))
        }
    }
}
