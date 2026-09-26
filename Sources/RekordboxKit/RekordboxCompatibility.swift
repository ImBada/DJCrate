import DJCDomain
import Foundation

/// 쓰기를 확인한 rekordbox·DB 구조에서만 쓴다.
///
/// rekordbox가 업데이트로 DB 구조를 바꾸면 DJCrate가 넣는 행이 rekordbox가 기대하는 모양과 달라질 수 있다.
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
        // 곡 추가(RekordboxTrackWriter)
        "djmdContent": ["ID", "FolderPath", "FileNameL", "FileNameS", "Title", "ArtistID", "AlbumID", "GenreID", "BPM", "Length", "TrackNo",
                        "BitRate", "BitDepth", "Commnt", "FileType", "Rating", "ReleaseYear", "RemixerID", "LabelID", "OrgArtistID", "KeyID",
                        "StockDate", "ColorID", "DJPlayCount", "ImagePath", "MasterDBID", "MasterSongID", "AnalysisDataPath", "SearchStr",
                        "FileSize", "DiscNo", "ComposerID", "Subtitle", "SampleRate", "DisableQuantize", "Analysed", "ReleaseDate",
                        "DateCreated", "ContentLink", "Tag", "ModifiedByRBM", "HotCueAutoLoad", "DeliveryControl", "DeliveryComment",
                        "CueUpdated", "AnalysisUpdated", "TrackInfoUpdated", "Lyricist", "ISRC", "SamplerTrackInfo", "SamplerPlayOffset",
                        "SamplerGain", "VideoAssociate", "LyricStatus", "ServiceID", "OrgFolderPath", "Reserved1", "Reserved2", "Reserved3",
                        "Reserved4", "ExtInfo", "rb_file_id", "DeviceID", "rb_LocalFolderPath", "SrcID", "SrcTitle", "SrcArtistName",
                        "SrcAlbumName", "SrcLength", "UUID", "rb_data_status", "rb_local_data_status", "rb_local_deleted", "rb_local_synced",
                        "usn", "rb_local_usn", "created_at", "updated_at"],
        "djmdArtist": ["ID", "Name", "SearchStr", "UUID", "rb_data_status", "rb_local_data_status", "rb_local_deleted", "rb_local_synced",
                       "usn", "rb_local_usn", "created_at", "updated_at"],
        "djmdAlbum": ["ID", "Name", "AlbumArtistID", "ImagePath", "Compilation", "SearchStr", "UUID", "rb_data_status",
                      "rb_local_data_status", "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
        "djmdGenre": ["ID", "Name", "UUID", "rb_data_status", "rb_local_data_status", "rb_local_deleted", "rb_local_synced", "usn",
                      "rb_local_usn", "created_at", "updated_at"],
        // 분석까지 붙인 곡 추가·분석 붙이기(파일 행·오토게인 행을 새로 넣는다)
        "contentFile": ["ID", "ContentID", "Path", "Hash", "Size", "rb_local_path", "rb_insync_hash", "rb_insync_local_usn",
                        "rb_file_hash_dirty", "rb_local_file_status", "rb_in_progress", "rb_process_type", "rb_temp_path", "rb_priority",
                        "rb_file_size_dirty", "UUID", "rb_data_status", "rb_local_data_status", "rb_local_deleted", "rb_local_synced",
                        "usn", "rb_local_usn", "created_at", "updated_at"],
        "djmdMixerParam": ["ID", "ContentID", "GainHigh", "GainLow", "PeakHigh", "PeakLow", "UUID", "rb_data_status",
                           "rb_local_data_status", "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
        // 재생 목록 쓰기(목록·곡 항목·클라우드 거울 행을 새로 넣는다). 곡 삭제도 곡 항목을 지우고 번호를 당긴다.
        "djmdPlaylist": ["ID", "Seq", "Name", "ImagePath", "Attribute", "ParentID", "SmartList", "UUID", "rb_data_status",
                         "rb_local_data_status", "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
        "djmdSongPlaylist": ["ID", "PlaylistID", "ContentID", "TrackNo", "UUID", "rb_data_status", "rb_local_data_status",
                             "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
        "djmdCloudFilterPlaylist": ["ID", "PlaylistUUID", "Seq", "ParentID", "UUID", "rb_data_status", "rb_local_data_status",
                                    "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
    ]

    /// 고치거나 읽는 칸: 있어야 한다
    static let requiredColumns: [String: Set<String>] = [
        "agentRegistry": ["registry_id", "int_1"],
        "djmdProperty": ["DBVersion"],
        // 곡 삭제 때 지우거나 번호를 당기는 표(곡 항목 djmdSongPlaylist는 위에서 칸 전체를 본다)
        "djmdSongHistory": ["ID", "HistoryID", "ContentID", "TrackNo", "rb_local_usn", "updated_at"],
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
            throw DJCError.writeRefused("rekordbox DB 구조가 DJCrate가 확인한 모양과 다릅니다: \(problems.joined(separator: "; ")). rekordbox가 업데이트됐다면 DJCrate도 확인이 필요합니다")
        }
    }

    /// 변경 카운터 두 개(`agentRegistry`의 정수 칸만 읽는다. 인증값이 든 칸은 읽지 않는다).
    /// - local: 이 컴퓨터에서 나눠 준 마지막 번호(`localUpdateCount`)
    /// - cloud: 클라우드 동기화가 본 가장 큰 번호(`lastUpdateCount`, 동기화를 안 쓰면 없거나 0)
    public static func updateCounters(_ db: CipherDatabase) throws -> (local: Int?, cloud: Int?) {
        var local: Int?, cloud: Int?
        try db.query("SELECT registry_id, int_1 FROM agentRegistry WHERE registry_id IN ('localUpdateCount', 'lastUpdateCount')") { row in
            if row.string(0) == "localUpdateCount" { local = row.int(1) } else { cloud = row.int(1) }
        }
        return (local, cloud)
    }

    /// 로컬 카운터가 클라우드 동기화 카운터보다 작으면 쓰지 않는다. rekordbox가 동기화하며 그 번호 밑의 변경을
    /// 되돌렸다는 사례가 있다(조사 2026-09-26). 동기화를 안 쓰면(값 없음·0) 통과.
    public static func checkCounters(local: Int, cloud: Int?) throws {
        guard let cloud, cloud > 0, local < cloud else { return }
        throw DJCError.writeRefused("rekordbox 변경 카운터(\(local))가 클라우드 동기화 카운터(\(cloud))보다 작습니다. rekordbox를 한 번 켜서 동기화를 끝낸 뒤 종료하고 다시 시도하세요")
    }

    /// 설치된 rekordbox 버전을 확인한다. 못 찾으면(nil) 통과.
    public static func checkApp(version: String?) throws {
        guard let version else { return }
        let parts = version.split(separator: ".")
        let majorMinor = parts.prefix(2).joined(separator: ".")
        guard parts.count >= 2, verifiedAppVersions.contains(majorMinor) else {
            let verified = verifiedAppVersions.sorted().map { "\($0).x" }.joined(separator: ", ")
            throw DJCError.writeRefused("rekordbox \(version)는 DJCrate가 쓰기를 확인하지 않은 버전입니다(확인: \(verified))")
        }
    }

    /// `/Applications/rekordbox N/rekordbox.app` 중 가장 높은 판의 버전
    public static func installedAppVersion(applications: URL = URL(filePath: "/Applications")) -> String? {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []
        return apps.filter { $0.hasPrefix("rekordbox") }.sorted().reversed().lazy.compactMap { folder -> String? in
            let info = applications.appending(path: folder).appending(path: "rekordbox.app/Contents/Info.plist")
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
                                                   appVersion: { RekordboxCompatibility.installedAppVersion() })

    /// 라이브 DB면 rekordbox가 꺼져 있고 WAL이 비었고 확인한 버전이어야 한다.
    func checkLive(_ database: URL, dryRun: Bool) throws {
        guard !dryRun else { throw DJCError.writeRefused("미리 보기는 스냅샷 사본으로만 합니다") }
        guard !isRekordboxRunning() else {
            throw DJCError.writeRefused("rekordbox가 켜져 있습니다. rekordbox를 완전히 종료한 뒤 다시 시도하세요")
        }
        let wal = URL(filePath: database.path + "-wal")
        if let size = (try? FileManager.default.attributesOfItem(atPath: wal.path))?[.size] as? Int, size > 0 {
            throw DJCError.writeRefused("rekordbox가 정상적으로 종료되지 않은 것 같습니다(WAL 파일이 남아 있음). rekordbox를 한 번 켰다가 종료한 뒤 다시 시도하세요")
        }
        try RekordboxCompatibility.checkApp(version: appVersion())
    }
}
