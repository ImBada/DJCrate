import Foundation
import SQLCipher

/// SQLCipher C API를 감싼 읽기 전용 연결.
/// rekordbox의 라이브 DB가 아니라 항상 스냅샷 사본을 연다.
public final class CipherDatabase {
    private var handle: OpaquePointer?

    public init(path: String, key: String?) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            handle = nil  // deinit이 한 번 더 닫지 않도록
            throw AnicueError.databaseOpenFailed(path: path, message: message)
        }
        if let key {
            // 키는 16진수 문자열만 허용하므로 SQL 문자열에 넣어도 안전하다.
            guard key.allSatisfy(\.isHexDigit) else { throw AnicueError.keyDerivationFailed }
            try execute("PRAGMA key = '\(key)'")
        }
        try execute("PRAGMA query_only = ON")
        try? execute("PRAGMA cache_size = -65536")
        try? execute("PRAGMA temp_store = MEMORY")
        do {
            _ = try scalarInt("SELECT count(*) FROM sqlite_master")
        } catch {
            throw AnicueError.databaseOpenFailed(path: path, message: "키가 맞지 않거나 DB가 손상됐습니다")
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw AnicueError.queryFailed(sql: sql, message: message)
        }
    }

    public func query(_ sql: String, _ each: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AnicueError.queryFailed(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try each(Row(statement: statement))
            case SQLITE_DONE:
                return
            default:
                throw AnicueError.queryFailed(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
            }
        }
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

        public func int(_ column: Int32) -> Int? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(statement, column))
        }
    }
}
