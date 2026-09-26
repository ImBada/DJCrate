import DJCDomain
import Foundation
import RekordboxKit

/// 사본 컬렉션과 초안을 조회한다. SQL 연결·음원·초안에는 쓰지 않는다.
public struct LibraryRead {
    private let library: RekordboxLibrary
    private let tracks: [Track]
    private let byID: [String: Track]
    private let home: URL
    private let shareRoot: URL
    private let gains: [String: Double]

    public init(snapshot: URL, home: URL = DJCPaths.userData, shareRoot: URL? = nil) throws {
        let snapshot = try Self.resolve(database: snapshot)
        library = try RekordboxLibrary.load(snapshot: snapshot)
        tracks = library.tracks.sorted { $0.id < $1.id }
        byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.home = home
        self.shareRoot = shareRoot ?? snapshot.deletingLastPathComponent().appending(path: "share")
        gains = GainDraftStore.all(url: home.appending(path: "gain-drafts.json"))
    }

    /// 명시한 사본 또는 기존 최신 스냅샷만 사용한다. 라이브 경로·링크를 DB로 열지 않는다.
    public static func resolve(database: URL?, snapshots: URL = LibrarySnapshot.defaultDirectory) throws -> URL {
        let candidate = try database ?? LibrarySnapshot.latest(in: snapshots)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let live = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer/rekordbox/master.db")
            .resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        let source = try? fm.attributesOfItem(atPath: live.path)
        let target = try? fm.attributesOfItem(atPath: resolved.path)
        let sameFile = source?[.systemNumber] as? UInt64 == target?[.systemNumber] as? UInt64
            && source?[.systemFileNumber] as? UInt64 == target?[.systemFileNumber] as? UInt64 && source != nil && target != nil
        guard resolved != live, !sameFile else {
            throw ReadFailure("live_database", "라이브 master.db는 열 수 없습니다. djc snapshot으로 사본을 만든 뒤 읽으세요")
        }
        return candidate
    }

    public func search(query: String, bpm: ClosedRange<Double>? = nil, key: String? = nil,
                       playlistID: String? = nil, filter: LibraryFilter = .all) throws -> TrackList {
        let allowed = try playlistID.map { Set(try playlistTracks(id: $0).map(\.id)) }
        let needle = query.lowercased()
        let result = tracks.filter { track in
            let encrypted = track.title.hasPrefix("$A7:")
            let haystack = [encrypted ? "" : track.title, encrypted ? "" : (track.artist ?? ""), track.comment, track.genre ?? ""]
                .joined(separator: "\u{1F}").lowercased()
            guard needle.isEmpty || haystack.contains(needle),
                  bpm.map({ range in track.bpm.map(range.contains) ?? false }) ?? true,
                  key.map({ track.key?.caseInsensitiveCompare($0) == .orderedSame }) ?? true,
                  allowed?.contains(track.id) ?? true else { return false }
            return filter.includes(track: track, commentClass: CommentClassifier.classify(track.comment),
                                   hasCues: !library.cues(for: track).isEmpty, playCount: library.playCounts[track.id, default: 0],
                                   tempoChanges: filter == .tempoChange ? grid(for: track).tempoChanges : [])
        }
        return TrackList(tracks: result.map(TrackRecord.init))
    }

    /// 초안을 시작할 때 쓰는 원본. 이미 열린 스냅샷에서만 읽는다.
    public func draftSource(id: String) throws -> (track: Track, cues: [Cue]) {
        guard let track = byID[id] else { throw ReadFailure("not_found", "곡을 찾지 못했습니다. search로 ContentID를 확인하세요") }
        return (track, library.cues(for: track))
    }

    public func track(id: String) throws -> TrackInfo {
        guard let track = byID[id] else { throw ReadFailure("not_found", "곡을 찾지 못했습니다. search로 ContentID를 확인하세요") }
        let gain = library.autoGains[id].map {
            GainRecord(linear: $0.gain, decibels: $0.gainDB, peak: $0.peak.isFinite ? $0.peak : nil)
        }
        return TrackInfo(track: TrackRecord(track), cues: library.cues(for: track).sorted {
            ($0.inMsec, $0.id) < ($1.inMsec, $1.id)
        }.map(CueRecord.init), grid: grid(for: track), gain: gain,
        playlists: sortedPlaylists.filter { !$0.isFolder && $0.trackIDs.contains(id) }.map { record($0, tree: false) },
        drafts: draftState(uuid: track.uuid))
    }

    public func playlists(tree: Bool) -> PlaylistList {
        PlaylistList(playlists: sortedPlaylists.filter { !tree || $0.parentID == "root" }.map { record($0, tree: tree) })
    }

    public func playlist(id: String) throws -> PlaylistContents {
        guard let playlist = library.playlists.first(where: { $0.id == id }) else { throw missingPlaylist() }
        return PlaylistContents(playlist: record(playlist, tree: false), tracks: try playlistTracks(id: id).map(TrackRecord.init))
    }

    public func drafts() -> DraftList {
        let uuids = CueDraftStore.uuids(directory: home.appending(path: "cue-drafts"))
            .union(GridDraftStore.uuids(directory: home.appending(path: "grid-drafts")))
            .union(TagDraftStore.uuids(directory: home.appending(path: "tag-drafts"))).union(gains.keys)
        let byUUID = Dictionary(tracks.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        return DraftList(drafts: uuids.sorted().compactMap { uuid in
            let state = draftState(uuid: uuid)
            guard !state.kinds.isEmpty else { return nil }
            return DraftRecord(trackUUID: uuid, contentID: byUUID[uuid]?.id, title: byUUID[uuid]?.title, kinds: state.kinds)
        })
    }

    public func paths(query: String) -> PathList {
        PathList(paths: tracks.filter { $0.title.contains(query) && !$0.isStreaming }.map(\.folderPath))
    }

    public func report(checkFiles: Bool) -> Report {
        let report = LibraryReport(library: library, checkFiles: checkFiles)
        return Report(totalRows: report.totalRows, deletedRows: report.deletedRows, liveTracks: report.liveTracks,
                      streamingTracks: report.streamingTracks, extensions: report.extensions,
                      commentClasses: Dictionary(uniqueKeysWithValues: report.commentClasses.map { ($0.key.rawValue, $0.value) }),
                      prefixes: Dictionary(uniqueKeysWithValues: report.prefixes.map { ($0.key.rawValue, $0.value) }),
                      usages: report.usages, emptyByImportYear: report.emptyByImportYear,
                      tracksWithCues: report.tracksWithCues, tracksWithManualCues: report.tracksWithManualCues,
                      tracksWithOnlyAutoCues: report.tracksWithOnlyAutoCues, tracksWithoutCues: report.tracksWithoutCues,
                      hotCueSlots: Dictionary(uniqueKeysWithValues: report.hotCueSlots.map { (String($0.key), $0.value) }),
                      playedTracks: report.playedTracks, emptyCommentPlayed: report.emptyCommentPlayed, missingFiles: report.missingFiles)
    }

    public static func parse(comment: String) -> ParsedComment {
        let parsed = ConventionParser.parse(comment).map { value in
            ParsedComment.Parsed(prefix: value.prefix.rawValue, workRef: value.workRef, workName: value.workName,
                                 season: value.season, seasonStyle: value.seasonStyle.map {
                switch $0 { case .parenthesized: "parenthesized"; case .plain: "plain"; case .season: "season" }
            }, abbreviations: value.abbreviations, usages: value.usages.map { .init(kind: $0.kind.rawValue, numbers: $0.numbers) },
                                 episodes: value.episodes, isCharacterSong: value.isCharacterSong, isTVSize: value.isTVSize,
                                 variants: value.variants, isFormerAffiliation: value.isFormerAffiliation,
                                 airingYear: value.tail.airingYear, airingQuarter: value.tail.airingQuarter,
                                 movieYear: value.tail.movieYear, boomboxVolumes: value.tail.boomboxVolumes)
        }
        return ParsedComment(classification: CommentClassifier.classify(comment).rawValue, parsed: parsed)
    }

    public static func compatibility(snapshot: URL, version: String?) throws -> Compatibility {
        let snapshot = try resolve(database: snapshot)
        try RekordboxCompatibility.checkApp(version: version)
        let db = try CipherDatabase(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        try RekordboxCompatibility.checkSchema(db)
        let counters = try RekordboxCompatibility.updateCounters(db)
        if let local = counters.local { try RekordboxCompatibility.checkCounters(local: local, cloud: counters.cloud) }
        return Compatibility(appVersion: version, verifiedAppVersions: RekordboxCompatibility.verifiedAppVersions.sorted(),
                             databaseVersion: RekordboxCompatibility.databaseVersion,
                             localUpdateCount: counters.local, cloudUpdateCount: counters.cloud)
    }

    private func grid(for track: Track) -> GridRecord {
        guard let url = RekordboxShare.analysisURL(track.analysisDataPath, root: shareRoot),
              let grid = try? BeatGrid.load(anlz: url), !grid.beats.isEmpty else {
            return GridRecord(status: "unavailable", beatCount: 0, segments: [], tempoChanges: [])
        }
        return GridRecord(status: "available", beatCount: grid.beats.count,
                          segments: GridDraft.segments(from: grid), tempoChanges: grid.tempoChanges)
    }

    private func draftState(uuid: String) -> DraftState {
        // 외부 DB의 UUID를 경로 조각으로 쓸 때 초안 폴더 밖을 읽지 않는다.
        guard !uuid.isEmpty, !uuid.contains("/"), uuid != ".", uuid != ".." else {
            return DraftState(cue: false, grid: false, gain: gains[uuid] != nil, tag: false)
        }
        return DraftState(cue: CueDraftStore.load(trackUUID: uuid, directory: home.appending(path: "cue-drafts"))?.hasChanges == true,
                          grid: GridDraftStore.load(trackUUID: uuid, directory: home.appending(path: "grid-drafts"))?.hasChanges == true,
                          gain: gains[uuid] != nil,
                          tag: TagDraftStore.load(trackUUID: uuid, directory: home.appending(path: "tag-drafts"))?.hasChanges == true)
    }

    private var sortedPlaylists: [RekordboxPlaylist] {
        library.playlists.sorted { ($0.seq, $0.id) < ($1.seq, $1.id) }
    }

    private func missingPlaylist() -> ReadFailure {
        ReadFailure("not_found", "재생 목록을 찾지 못했습니다. playlists로 ID를 확인하세요")
    }

    private func playlistTracks(id: String, visited: Set<String> = []) throws -> [Track] {
        guard let playlist = library.playlists.first(where: { $0.id == id }) else { throw missingPlaylist() }
        guard !visited.contains(id) else { return [] }
        if !playlist.isFolder { return playlist.trackIDs.compactMap { byID[$0] } }
        var seen = Set<String>()
        return try sortedPlaylists.filter { $0.parentID == id }.flatMap {
            try playlistTracks(id: $0.id, visited: visited.union([id]))
        }.filter { seen.insert($0.id).inserted }
    }

    private func record(_ playlist: RekordboxPlaylist, tree: Bool, visited: Set<String> = []) -> PlaylistRecord {
        let children = tree && playlist.isFolder && !visited.contains(playlist.id)
            ? sortedPlaylists.filter { $0.parentID == playlist.id }.map { record($0, tree: true, visited: visited.union([playlist.id])) } : nil
        return PlaylistRecord(id: playlist.id, name: playlist.name, parentID: playlist.parentID, sequence: playlist.seq,
                              isFolder: playlist.isFolder, trackCount: (try? playlistTracks(id: playlist.id).count) ?? 0, children: children)
    }
}
