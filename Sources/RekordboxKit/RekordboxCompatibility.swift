import AnicueDomain
import Foundation

/// 쓰기를 확인한 rekordbox·DB 구조에서만 쓴다.
///
/// rekordbox가 업데이트로 DB 구조를 바꾸면 anicue가 넣는 행이 rekordbox가 기대하는 모양과 달라질 수 있다.
/// 그래서 새 행을 넣는 표는 칸이 정확히 같아야 하고, 고치거나 읽는 칸은 모두 있어야 한다.
/// 설치된 rekordbox는 확인한 주.부 버전(7.2.x)일 때만 라이브 DB에 쓴다. 설치를 못 찾으면 DB 구조 검사에 맡긴다.
public enum RekordboxCompatibility {
    /// 쓰기를 확인한 rekordbox 주.부 버전
    public static let verifiedAppVersions: Set<String> = ["7.2"]
    /// `djmdProperty.DBVersion`
    public static let databaseVersion = "6000"

    /// 행을 새로 넣는 표: 칸이 정확히 같아야 한다(rekordbox 7.2.18)
    static let exactColumns: [String: Set<String>] = [
        "djmdCue": ["ID", "ContentID", "InMsec", "InFrame", "InMpegFrame", "InMpegAbs", "OutMsec", "OutFrame", "OutMpegFrame",
                    "OutMpegAbs", "Kind", "Color", "ColorTableIndex", "ActiveLoop", "Comment", "BeatLoopSize", "CueMicrosec",
                    "InPointSeekInfo", "OutPointSeekInfo", "ContentUUID", "UUID", "rb_data_status", "rb_local_data_status",
                    "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
        "contentCue": ["ID", "ContentID", "Cues", "rb_cue_count", "UUID", "rb_data_status", "rb_local_data_status",
                       "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
    ]

    /// 고치거나 읽는 칸: 있어야 한다
    static let requiredColumns: [String: Set<String>] = [
        "djmdContent": ["ID", "UUID", "Title", "FileType", "BitRate", "Length", "FolderPath", "AnalysisDataPath", "BPM",
                        "CueUpdated", "AnalysisUpdated", "TrackInfoUpdated", "rb_data_status", "rb_local_deleted",
                        "rb_local_usn", "updated_at"],
        "contentFile": ["ContentID", "Path", "Hash", "Size", "rb_data_status", "rb_local_usn", "updated_at"],
        "djmdMixerParam": ["ID", "ContentID", "GainHigh", "GainLow", "rb_data_status", "rb_local_deleted", "rb_local_usn", "updated_at"],
        "agentRegistry": ["registry_id", "int_1"],
        "djmdProperty": ["DBVersion"],
    ]

    /// DB 구조와 DB 버전을 확인한다. 다르면 `writeRefused`.
    public static func checkSchema(_ db: CipherDatabase) throws {
        var problems: [String] = []
        for (table, expected) in exactColumns.sorted(by: { $0.key < $1.key }) {
            let columns = try self.columns(of: table, in: db)
            let extra = columns.subtracting(expected).sorted(), missing = expected.subtracting(columns).sorted()
            if !extra.isEmpty { problems.append("\(table)에 모르는 칸(\(extra.joined(separator: ", ")))") }
            if !missing.isEmpty { problems.append("\(table)에 없는 칸(\(missing.joined(separator: ", ")))") }
        }
        for (table, expected) in requiredColumns.sorted(by: { $0.key < $1.key }) {
            let missing = expected.subtracting(try columns(of: table, in: db)).sorted()
            if !missing.isEmpty { problems.append("없는 칸 " + missing.map { "\(table).\($0)" }.joined(separator: ", ")) }
        }
        if problems.isEmpty {
            var versions: [String] = []
            try db.query("SELECT DBVersion FROM djmdProperty") { versions.append($0.string(0) ?? "?") }
            if versions != [databaseVersion] {
                problems.append("DB 버전 \(versions.joined(separator: ", "))(확인한 버전 \(databaseVersion))")
            }
        }
        guard problems.isEmpty else {
            throw AnicueError.writeRefused("rekordbox DB 구조가 anicue가 확인한 모양과 다릅니다: \(problems.joined(separator: "; ")). rekordbox가 업데이트됐다면 anicue도 확인이 필요합니다")
        }
    }

    /// 설치된 rekordbox 버전을 확인한다. 못 찾으면(nil) 통과.
    public static func checkApp(version: String?) throws {
        guard let version else { return }
        let parts = version.split(separator: ".")
        let majorMinor = parts.prefix(2).joined(separator: ".")
        guard parts.count >= 2, verifiedAppVersions.contains(majorMinor) else {
            let verified = verifiedAppVersions.sorted().map { "\($0).x" }.joined(separator: ", ")
            throw AnicueError.writeRefused("rekordbox \(version)는 anicue가 쓰기를 확인하지 않은 버전입니다(확인: \(verified))")
        }
    }

    /// `/Applications/rekordbox N/rekordbox.app` 중 가장 높은 판의 버전
    public static func installedAppVersion() -> String? {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        return apps.filter { $0.hasPrefix("rekordbox") }.sorted().reversed().lazy.compactMap { folder -> String? in
            let info = URL(filePath: "/Applications").appending(path: folder).appending(path: "rekordbox.app/Contents/Info.plist")
            guard let plist = NSDictionary(contentsOf: info) else { return nil }
            return plist["CFBundleShortVersionString"] as? String
        }.first
    }

    static func columns(of table: String, in db: CipherDatabase) throws -> Set<String> {
        var names: Set<String> = []
        try db.query("PRAGMA table_info(\(table))") { names.insert($0.string(1) ?? "") }
        return names
    }
}

/// 라이브 rekordbox DB에 쓰기 전에 보는 환경. 시험에서는 가짜로 바꾼다.
public struct RekordboxWriteGuard: Sendable {
    public var isLive: @Sendable (URL) -> Bool
    public var isRekordboxRunning: @Sendable () -> Bool
    public var appVersion: @Sendable () -> String?

    public init(isLive: @escaping @Sendable (URL) -> Bool, isRekordboxRunning: @escaping @Sendable () -> Bool,
                appVersion: @escaping @Sendable () -> String?) {
        self.isLive = isLive
        self.isRekordboxRunning = isRekordboxRunning
        self.appVersion = appVersion
    }

    public static let system = RekordboxWriteGuard(isLive: RekordboxWriter.isLive,
                                                   isRekordboxRunning: LibrarySnapshot.isRekordboxRunning,
                                                   appVersion: RekordboxCompatibility.installedAppVersion)

    /// 라이브 DB면 rekordbox가 꺼져 있고 WAL이 비었고 확인한 버전이어야 한다.
    func checkLive(_ database: URL, dryRun: Bool) throws {
        guard !dryRun else { throw AnicueError.writeRefused("미리 보기는 스냅샷 사본으로만 합니다") }
        guard !isRekordboxRunning() else {
            throw AnicueError.writeRefused("rekordbox가 켜져 있습니다. rekordbox를 완전히 종료한 뒤 다시 시도하세요")
        }
        let wal = URL(filePath: database.path + "-wal")
        if let size = (try? FileManager.default.attributesOfItem(atPath: wal.path))?[.size] as? Int, size > 0 {
            throw AnicueError.writeRefused("rekordbox가 정상적으로 종료되지 않은 것 같습니다(WAL 파일이 남아 있음). rekordbox를 한 번 켰다가 종료한 뒤 다시 시도하세요")
        }
        try RekordboxCompatibility.checkApp(version: appVersion())
    }
}
