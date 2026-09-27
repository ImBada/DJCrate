import DJCDomain
import Foundation

/// 읽거나 고치기 전에 OneLibrary가 확인한 모양(rekordbox 7.2.18)인지 본다.
/// 모르는 모양은 추측해서 읽지 않는다 — 새 rekordbox가 칸을 바꿨을 수 있다.
public enum OneLibraryCompatibility {
    /// rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    public static let databaseVersion = "1000"

    /// 표 22·인덱스 4·표마다 칸 이름·선언 자료형·순서·기본 키가 정확히 같고 property.dbVersion = "1000"이어야 한다.
    /// 아니면 `UsbError.formatUnsupported`
    public static func check(_ db: CipherDatabase) throws {
        var tables: Set<String> = [], indexes: [String: String] = [:], others: [String] = []
        try db.query("SELECT type, name, tbl_name FROM sqlite_master") { row in
            let type = row.string(0) ?? "", name = row.string(1) ?? "", table = row.string(2) ?? ""
            // SQLite가 스스로 만드는 표·인덱스(sqlite_sequence·sqlite_autoindex_…)는 보지 않는다.
            if name.hasPrefix("sqlite_") { return }
            switch type {
            case "table": tables.insert(name)
            case "index": indexes[name] = table
            default: others.append(name)
            }
        }
        guard others.isEmpty else {
            throw UsbError.formatUnsupported(detail: String(ui: "OneLibrary에 확인하지 않은 뷰나 트리거가 있습니다(\(others.sorted().joined(separator: ", ")))"))
        }
        let expected = Set(OneLibrarySchema.tables.map(\.name))
        guard tables == expected else {
            let missing = expected.subtracting(tables).sorted().joined(separator: ", ")
            let unknown = tables.subtracting(expected).sorted().joined(separator: ", ")
            throw UsbError.formatUnsupported(detail: String(ui: "OneLibrary 표 구성이 확인한 모양과 다릅니다(없는 표: \(missing), 모르는 표: \(unknown))"))
        }
        for table in OneLibrarySchema.tables {
            var columns: [OneLibrarySchema.Column] = []
            // SQLite는 표준 자료형 이름(integer 등)을 대문자로 돌려준다. 대소문자만 빼고 선언 그대로 비교한다.
            try db.query("PRAGMA table_info(\(table.name))") { row in
                columns.append(OneLibrarySchema.Column(name: row.string(1) ?? "", type: (row.string(2) ?? "").lowercased(),
                                                       primaryKey: (row.int(5) ?? 0) != 0))
            }
            guard columns == table.columns else {
                throw UsbError.formatUnsupported(detail: String(ui: "OneLibrary \(table.name) 표의 칸이 확인한 모양과 다릅니다"))
            }
        }
        guard Set(indexes.keys) == Set(OneLibrarySchema.indexes.map(\.name)) else {
            throw UsbError.formatUnsupported(detail: String(ui: "OneLibrary 인덱스가 확인한 모양과 다릅니다"))
        }
        for index in OneLibrarySchema.indexes {
            var columns: [String] = []
            try db.query("PRAGMA index_info(\(index.name))") { columns.append($0.string(2) ?? "") }
            guard indexes[index.name] == index.table, columns == [index.column] else {
                throw UsbError.formatUnsupported(detail: String(ui: "OneLibrary 인덱스가 확인한 모양과 다릅니다"))
            }
        }
        var versions: [String] = []
        try db.query("SELECT dbVersion FROM property") { versions.append($0.string(0) ?? "") }
        guard versions.count == 1 else {
            throw UsbError.formatUnsupported(detail: String(ui: "OneLibrary property 행이 1개가 아닙니다(\(versions.count)개)"))
        }
        guard versions[0] == databaseVersion else {
            throw UsbError.formatUnsupported(detail: String(ui: "rekordbox 새 버전이 만든 USB라 아직 읽거나 고칠 수 없습니다(dbVersion \(versions[0]))"))
        }
    }
}
