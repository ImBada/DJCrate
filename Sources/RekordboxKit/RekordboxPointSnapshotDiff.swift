import DJCDomain
import Foundation

/// 시점 스냅샷과 지금 라이브러리의 차이 요약(#225). 복원하면 무엇이 어떻게 바뀌는지를 곡·큐·그리드·태그·재생 목록·파일 수준으로 센다.
/// 두 DB는 임시 폴더에 복사한 사본으로 읽는다(라이브 DB·스냅샷 폴더에 읽기 곁 파일을 남기지 않게). 분석·앨범아트 파일은
/// 경로·크기·수정 시각만 견준다(클론은 수정 시각을 그대로 둔다). 내용은 출력하지 않는다.
/// `djc lab db-diff`(모든 표·칸 비교)는 규칙을 알아낼 때 쓰는 실험 도구라 옮기지 않고, 사용자가 알아볼 수준만 센다.
public struct RekordboxPointSnapshotDiff: Sendable, Equatable {
    /// 지금 있고 스냅샷에 없는 곡(복원하면 컬렉션에서 빠진다)
    public var tracksRemoved: [String] = []
    /// 스냅샷에만 있는 곡(복원하면 돌아온다)
    public var tracksRestored: [String] = []
    public var cuesChanged: [String] = []
    /// BPM이나 분석 파일이 다른 곡
    public var gridsChanged: [String] = []
    /// 제목·아티스트·앨범·장르·코멘트·키·평점·곡 색 등 곡 정보가 다른 곡
    public var tagsChanged: [String] = []
    /// 지금만 있는 재생 목록(복원하면 사라진다)
    public var playlistsRemoved: [String] = []
    /// 스냅샷에만 있는 재생 목록(복원하면 돌아온다)
    public var playlistsRestored: [String] = []
    /// 이름·곡·순서가 다른 재생 목록
    public var playlistsChanged: [String] = []
    /// 다른·지금만·스냅샷에만 있는 분석 파일 수
    public var analysisFiles = FileCounts()
    public var artworkFiles = FileCounts()
    /// 복원하면 다시 읽어야 할 곡(덱이 새 값을 읽게)
    public var changedTrackUUIDs: Set<String> = []
    /// 지금 DB의 클라우드 동기화 카운터(`lastUpdateCount`, 정수 칸만)
    public var currentCloudUpdateCount: Int?
    /// 그리드·분석이 바뀌는 곡(같은 곡을 두 번 세지 않게)·빠지거나 돌아오는 곡
    var gridUUIDs: Set<String> = []
    var addedOrGoneUUIDs: Set<String> = []

    public struct FileCounts: Sendable, Equatable {
        public var changed = 0
        /// 지금만 있음(복원하면 지운다)
        public var removed = 0
        /// 스냅샷에만 있음(복원하면 되살린다)
        public var restored = 0
        public var total: Int { changed + removed + restored }
    }

    public init() {}

    public var isEmpty: Bool {
        tracksRemoved.isEmpty && tracksRestored.isEmpty && cuesChanged.isEmpty && gridsChanged.isEmpty && tagsChanged.isEmpty
            && playlistsRemoved.isEmpty && playlistsRestored.isEmpty && playlistsChanged.isEmpty
            && analysisFiles.total == 0 && artworkFiles.total == 0
    }

    /// 스냅샷 뒤 클라우드 동기화가 더 진행됐는지(#229 확인 전: 막지 않고 확인 창에 알린다)
    public func cloudSyncedSince(_ entry: RekordboxPointSnapshot.Entry) -> Bool {
        guard let current = currentCloudUpdateCount, current > 0 else { return false }
        return current > (entry.metadata.cloudUpdateCount ?? 0)
    }

    /// 클라우드 동기화가 스냅샷 뒤에 진행된 라이브러리에 붙이는 한 줄(#229 확인 전이라 막지 않고 알린다)
    public static var cloudSyncNote: String {
        String(ui: "이 스냅샷 뒤에 클라우드 동기화가 있었습니다. rekordbox를 켜면 동기화가 복원한 내용 일부를 다시 바꿀 수 있습니다.")
    }

    /// 요약 줄(복원하면 일어나는 일로). 바뀐 것이 없으면 빈 배열
    public var summary: [String] {
        var lines: [String] = []
        if !tracksRemoved.isEmpty { lines.append(String(ui: "컬렉션에서 빠지는 곡 \(tracksRemoved.count)")) }
        if !tracksRestored.isEmpty { lines.append(String(ui: "컬렉션에 돌아오는 곡 \(tracksRestored.count)")) }
        if !cuesChanged.isEmpty { lines.append(String(ui: "큐가 바뀌는 곡 \(cuesChanged.count)")) }
        if !gridsChanged.isEmpty { lines.append(String(ui: "그리드·분석이 바뀌는 곡 \(gridsChanged.count)")) }
        if !tagsChanged.isEmpty { lines.append(String(ui: "곡 정보가 바뀌는 곡 \(tagsChanged.count)")) }
        let playlists = playlistsRemoved.count + playlistsRestored.count + playlistsChanged.count
        if playlists > 0 { lines.append(String(ui: "바뀌는 재생 목록 \(playlists)")) }
        if analysisFiles.total > 0 { lines.append(String(ui: "바뀌는 분석 파일 \(analysisFiles.total)")) }
        if artworkFiles.total > 0 { lines.append(String(ui: "바뀌는 앨범아트 파일 \(artworkFiles.total)")) }
        return lines
    }

    /// 펼쳐 보기: 묶음마다 제목 줄과 이름(묶음마다 `limit`개까지)
    public func details(limit: Int = 30) -> [(title: String, items: [String])] {
        func group(_ title: String, _ items: [String]) -> (title: String, items: [String])? {
            guard !items.isEmpty else { return nil }
            let shown = Array(items.prefix(limit))
            return (title, items.count > limit ? shown + [String(ui: "외 \(items.count - limit)개")] : shown)
        }
        return [
            group(String(ui: "컬렉션에서 빠지는 곡"), tracksRemoved),
            group(String(ui: "컬렉션에 돌아오는 곡"), tracksRestored),
            group(String(ui: "큐가 바뀌는 곡"), cuesChanged),
            group(String(ui: "그리드·분석이 바뀌는 곡"), gridsChanged),
            group(String(ui: "곡 정보가 바뀌는 곡"), tagsChanged),
            group(String(ui: "사라지는 재생 목록"), playlistsRemoved),
            group(String(ui: "돌아오는 재생 목록"), playlistsRestored),
            group(String(ui: "바뀌는 재생 목록"), playlistsChanged),
        ].compactMap { $0 }
    }

    // MARK: - 비교

    /// 스냅샷과 지금 라이브러리(`database`·share)를 견준다. 대상은 부르는 쪽이 적는다. 읽기만 한다.
    public static func compare(_ entry: RekordboxPointSnapshot.Entry, database: URL, shareRoot: URL?,
                               guard writeGuard: RekordboxWriteGuard = .system) throws -> RekordboxPointSnapshotDiff {
        let share = try RekordboxPointSnapshot.resolvedShare(database, shareRoot: shareRoot, guard: writeGuard)
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "djc-point-diff-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let then = scratch.appending(path: "then.db"), now = scratch.appending(path: "now.db")
        try fm.copyItem(at: entry.url.appending(path: "master.db"), to: then)
        try fm.copyItem(at: database, to: now)
        let old = try RekordboxLibrary.load(snapshot: then), current = try RekordboxLibrary.load(snapshot: now)
        var diff = RekordboxPointSnapshotDiff()
        diff.compareTracks(old: old, current: current)
        diff.comparePlaylists(old: old.playlists, current: current.playlists)
        diff.compareFiles(snapshotShare: entry.url.appending(path: "share"), currentShare: share, old: old, current: current)
        if let db = try? CipherDatabase(path: now.path, key: RekordboxKey.derive()) {
            defer { db.close() }
            diff.currentCloudUpdateCount = (try? RekordboxCompatibility.updateCounters(db))?.cloud
        }
        return diff
    }

    mutating func compareTracks(old: RekordboxLibrary, current: RekordboxLibrary) {
        let before = Dictionary(old.tracks.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(current.tracks.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        tracksRemoved = current.tracks.filter { before[$0.uuid] == nil }.map(\.title)
        tracksRestored = old.tracks.filter { after[$0.uuid] == nil }.map(\.title)
        addedOrGoneUUIDs = Set(current.tracks.filter { before[$0.uuid] == nil }.map(\.uuid))
            .union(old.tracks.filter { after[$0.uuid] == nil }.map(\.uuid))
        changedTrackUUIDs.formUnion(addedOrGoneUUIDs)
        func cues(_ library: RekordboxLibrary, _ track: Track) -> [String] {
            library.cues(for: track).map { "\($0.kind)|\($0.inMsec)|\($0.outMsec)|\($0.name)|\($0.color ?? -1)|\($0.activeLoop)" }.sorted()
        }
        func tags(_ track: Track) -> [String?] {
            [track.title, track.artist, track.album, track.albumArtist, track.genre, track.composer, track.releaseYear.map(String.init),
             track.trackNumber.map(String.init), track.key, track.comment, String(track.rating), track.colorID, track.imagePath]
        }
        for track in current.tracks {
            guard let then = before[track.uuid] else { continue }
            var changed = false
            if cues(old, then) != cues(current, track) { cuesChanged.append(track.title); changed = true }
            if then.bpm != track.bpm { gridsChanged.append(track.title); gridUUIDs.insert(track.uuid); changed = true }
            if tags(then) != tags(track) { tagsChanged.append(track.title); changed = true }
            if changed { changedTrackUUIDs.insert(track.uuid) }
        }
    }

    mutating func comparePlaylists(old: [RekordboxPlaylist], current: [RekordboxPlaylist]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        playlistsRemoved = current.filter { before[$0.id] == nil }.map(\.name)
        playlistsRestored = old.filter { after[$0.id] == nil }.map(\.name)
        playlistsChanged = current.compactMap { playlist in
            guard let then = before[playlist.id] else { return nil }
            let same = then.name == playlist.name && then.parentID == playlist.parentID && then.seq == playlist.seq
                && then.trackIDs == playlist.trackIDs && then.isFolder == playlist.isFolder
            return same ? nil : playlist.name
        }
    }

    /// 분석·앨범아트 파일을 경로·크기·수정 시각으로 견준다. 분석 파일이 다른 곡은 그리드·분석이 바뀌는 곡에 더한다.
    mutating func compareFiles(snapshotShare: URL, currentShare: URL, old: RekordboxLibrary, current: RekordboxLibrary) {
        // 분석 파일 폴더(`/PIONEER/USBANLZ/…/`) → 곡
        var owners: [String: Track] = [:]
        // 지금 곡의 제목을 먼저(바뀐 제목으로 보인다)
        for track in current.tracks + old.tracks {
            guard let path = track.analysisDataPath, !path.isEmpty else { continue }
            let folder = String(path.drop { $0 == "/" }).split(separator: "/").dropLast().joined(separator: "/")
            owners[folder] = owners[folder] ?? track
        }
        for (folder, keyPath) in [("PIONEER/USBANLZ", \RekordboxPointSnapshotDiff.analysisFiles), ("PIONEER/Artwork", \.artworkFiles)] {
            let then = RekordboxPointSnapshot.fileStamps(snapshotShare.appending(path: folder))
            let now = RekordboxPointSnapshot.fileStamps(currentShare.appending(path: folder))
            var counts = FileCounts()
            var touched: [String] = []
            for (path, stamp) in now {
                if let old = then[path] { if old != stamp { counts.changed += 1; touched.append(path) } } else { counts.removed += 1; touched.append(path) }
            }
            for path in then.keys where now[path] == nil { counts.restored += 1; touched.append(path) }
            self[keyPath: keyPath] = counts
            guard folder == "PIONEER/USBANLZ" else { continue }
            for path in touched {
                let owner = (folder + "/" + path).split(separator: "/").dropLast().joined(separator: "/")
                guard let track = owners[owner] else { continue }
                changedTrackUUIDs.insert(track.uuid)
                // 빠지거나 돌아오는 곡은 그 묶음에 이미 있다
                if !addedOrGoneUUIDs.contains(track.uuid), gridUUIDs.insert(track.uuid).inserted { gridsChanged.append(track.title) }
            }
        }
    }
}
