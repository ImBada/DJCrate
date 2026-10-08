import DJCDomain
import Foundation
import RekordboxKit

/// 로컬 곡 하나의 갱신 횟수(djmdContent의 TrackInfoUpdated·AnalysisUpdated·CueUpdated 문자열 그대로, NULL은 nil)
struct LocalTrackCounters: Sendable, Hashable {
    var information: String?
    var analysis: String?
    var cue: String?
}

/// 로컬 라이브러리(스냅샷 사본)의 짝짓기 키. `UsbTrackMatch`·`UsbSyncStatus` 입력.
struct LocalLibraryKeys: Sendable {
    /// djmdProperty.DBID
    var localDBID: Int64
    /// ContentID·MasterSongID·FileNameL·FolderPath
    var tracks: [UsbLocalTrackKey]
    /// 로컬 ContentID → 갱신 횟수
    var counters: [String: LocalTrackCounters]

    /// 로컬 스냅샷 **사본**(읽기 전용으로 연 연결)에서 읽는다. 백그라운드 작업에서 부른다. 지운 곡은 뺀다
    static func load(database: CipherDatabase) throws -> LocalLibraryKeys {
        var dbid: Int64?
        try database.query("SELECT DBID FROM djmdProperty") { row in
            if dbid == nil { dbid = row.string(0).flatMap { Int64($0) } }
        }
        guard let dbid else { throw DJCError.databaseOpenFailed(path: "djmdProperty", message: "DBID") }
        var tracks: [UsbLocalTrackKey] = []
        var counters: [String: LocalTrackCounters] = [:]
        try database.query("""
            SELECT ID, MasterSongID, FileNameL, TrackInfoUpdated, AnalysisUpdated, CueUpdated, FolderPath FROM djmdContent WHERE rb_local_deleted = 0
            """) { row in
            guard let id = row.string(0) else { return }
            tracks.append(UsbLocalTrackKey(contentID: id, masterSongID: row.string(1) ?? "", fileNameL: row.string(2) ?? "",
                                           folderPath: row.string(6)))
            counters[id] = LocalTrackCounters(information: row.string(3), analysis: row.string(4), cue: row.string(5))
        }
        return LocalLibraryKeys(localDBID: dbid, tracks: tracks, counters: counters)
    }

    /// 스냅샷 사본 파일을 읽기 전용으로 열어 읽는다
    static func load(snapshot: URL) throws -> LocalLibraryKeys {
        let database = try CipherDatabase(path: snapshot.path, key: .hex(RekordboxKey.derive()), mode: .readOnly)
        defer { database.close() }
        return try load(database: database)
    }
}

/// 앱이 연 스냅샷에서 읽은 짝짓기 키(백그라운드에서 채우고 어디서나 읽는다)
final class LocalLibraryKeysCache: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: LocalLibraryKeys?

    var current: LocalLibraryKeys? { lock.withLock { keys } }

    func set(_ keys: LocalLibraryKeys?) {
        lock.withLock { self.keys = keys }
    }
}
