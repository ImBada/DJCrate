import DJCDomain
import Foundation
import SQLCipher

/// SQLCipher C API를 감싼 연결. 기본은 읽기 전용이고 스냅샷 사본을 연다.
/// 쓰기 연결(`writable`)은 `RekordboxWriter`만 쓴다.
public final class CipherDatabase {
    private var handle: OpaquePointer?

    /// SQLCipher는 `sqlite3_initialize` 안에서 자기 전역 초기화(정적 뮤텍스·암호 제공자)를 마치는데, 그 초기화가 끝나기 전에
    /// 다른 스레드의 `sqlite3_initialize`가 "이미 됨"으로 돌아온다. 프로세스에서 처음 여는 순간 스레드가 겹치면 뒤늦게 들어온 스레드가
    /// `PRAGMA key`에서 "sqlcipher not initialized"로 실패했다(#154). `static let`은 처음 부른 스레드가 끝낼 때까지 다른 스레드를
    /// 기다리게 하므로, 여는 곳마다 먼저 거치면 초기화가 끝난 뒤에만 열린다.
    private static let sqlcipherReady: Void = { _ = sqlite3_initialize() }()

    public init(path: String, key: String?, writable: Bool = false) throws {
        Self.sqlcipherReady
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
            throw DJCError.databaseOpenFailed(path: path, message: String(ui: "키가 맞지 않거나 DB가 손상됐습니다"))
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// 개발용 조사도 인증값은 읽지 않는다. 뷰·하위 질의도 SQLite가 실제 참조하는 표·칸에서 막는다.
    public static func diagnostic(path: String, key: String?) throws -> CipherDatabase {
        let db = try CipherDatabase(path: path, key: key)
        sqlite3_set_authorizer(db.handle, { _, action, table, column, _, _ in
            guard action == SQLITE_READ else { return SQLITE_OK }
            let table = table.map { String(cString: $0) } ?? ""
            let column = column.map { String(cString: $0) } ?? ""
            return CipherDatabase.isCredentialIdentifier(table) || CipherDatabase.isCredentialIdentifier(column) ? SQLITE_DENY : SQLITE_OK
        }, nil)
        return db
    }

    public static func isCredentialIdentifier(_ name: String) -> Bool {
        let name = name.lowercased()
        return ["agentregistry", "cloudagent", "credential", "token", "password", "secret", "auth", "session"].contains(where: name.contains)
    }

    /// 연결을 바로 닫는다(쓰기 뒤 파일을 다시 열어 검사하기 전에 쓴다).
    public func close() {
        sqlite3_close_v2(handle)
        handle = nil
    }

    /// 스냅샷 **사본**에 딸린 WAL을 사본 안으로 합친다(원본 rekordbox DB에는 절대 쓰지 않는다).
    /// rekordbox가 켜져 있으면 최근 변경(예: 방금 가져온 XML)이 아직 WAL에만 있어서 이게 필요하다.
    public static func mergeWriteAheadLog(ofCopyAt path: String, key: String) throws {
        Self.sqlcipherReady
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
        case real(Double)
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
            case let .real(number): sqlite3_bind_double(statement, position, number)
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

        public func double(_ column: Int32) -> Double? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            return sqlite3_column_double(statement, column)
        }
    }
}
