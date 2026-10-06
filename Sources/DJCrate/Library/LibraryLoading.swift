import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation
import Observation

/// 백그라운드에서 만드는 로드 결과.
struct LoadedLibrary: Sendable {
    enum Stage: String, Sendable {
        case database, music, iTunes, tracks

        var message: String {
            switch self {
            case .database: String(ui: "rekordbox 라이브러리를 읽는 중…")
            case .music: String(ui: "Music 보관함을 읽는 중…")
            case .iTunes: String(ui: "iTunes 목록 사본을 읽는 중…")
            case .tracks: String(ui: "곡 목록을 준비하는 중…")
            }
        }

        func measure<Value>(progress: (Stage) -> Void, _ operation: () throws -> Value) rethrows -> Value {
            progress(self)
            let started = ContinuousClock.now
            defer { logElapsed(since: started) }
            return try operation()
        }

        func logElapsed(since started: ContinuousClock.Instant) {
            // 개인 경로·곡·목록 정보 없이 DB와 Music 대기 시간을 구분한다.
            FileHandle.standardError.write(Data("라이브러리 단계 \(rawValue) · \(ContinuousClock.now - started)\n".utf8))
        }
    }

    struct ITunesFallback: Sendable {
        let source: URL
        let contents: ITunesLibrarySnapshot
        var preferOverCurrent = false
        var sourceDatabase: URL? = nil
    }
    var rows: [TrackRow]
    var report: LibraryReport
    var filterCounts: [LibraryFilter: Int]
    var tagDrafts: [String: TagDraft]
    var cueDraftUUIDs: Set<String>
    var gridDraftUUIDs: Set<String>
    var gainDraftUUIDs: Set<String> = []
    var playlists: PlaylistLayout
    /// 인텔리전트 재생 목록 ID → 읽은 조건 칸(#68). 보이는 것은 실험실 설정이 켜 있을 때뿐이다.
    var smartPlaylists: [String: SmartPlaylistSource] = [:]
    var playlistDraft: PlaylistDraft
    var histories: [RekordboxHistory]
    var draftCueCounts: [String: CueCounts] = [:]
    var draftPreviewCues: [String: [PreviewCueMark]] = [:]
    var duplicateGroups: [LibraryRead.DuplicateGroup] = []
    var iTunesLibrary = SyncedITunesLibrary()
    var iTunesSnapshot = ITunesLibrarySnapshot(status: .notCaptured)
    /// 그림 초안(그림 바이트 없이)과 곡의 살아 있는 그림 파일 행(ContentID별, 초안 base)
    var artworkDrafts: [String: ArtworkDraft] = [:]
    var artworkFiles: [String: [ArtworkFileRow]] = [:]

    static func load(snapshot: URL, commentPreset: CommentPreset = .none, refreshITunes: Bool = false,
                     previousITunesSnapshot: ITunesFallback? = nil,
                     fallbackDirectory: URL = LibrarySnapshot.defaultDirectory,
                     refreshTicket: ITunesRefreshCoordinator.Ticket? = nil,
                     sourceDatabase: URL? = nil,
                     artworkDirectory: URL = ArtworkDraftStore.directory,
                     progress: @Sendable (Stage) -> Void = { _ in },
                     captureITunes: () -> ITunesLibrarySnapshot = { RekordboxITunesReader.capture() }) throws -> LoadedLibrary {
        let refreshTicket = refreshTicket ?? ITunesRefreshCoordinator.shared.begin(snapshot: snapshot, sourceDatabase: sourceDatabase)
        let library = try Stage.database.measure(progress: progress) { try RekordboxLibrary.load(snapshot: snapshot) }
        let tracks = library.tracks
        let iTunes = loadITunes(snapshot: snapshot, refreshITunes: refreshITunes,
                                previousITunesSnapshot: previousITunesSnapshot, fallbackDirectory: fallbackDirectory,
                                refreshTicket: refreshTicket, sourceDatabase: sourceDatabase,
                                progress: progress, captureITunes: captureITunes)
        progress(.tracks)
        let tracksStarted = ContinuousClock.now
        defer { Stage.tracks.logElapsed(since: tracksStarted) }
        // 변속 흐름: 분석 파일의 그리드를 병렬로 훑는다(7천 곡 약 0.2~0.7초).
        let tempo = TempoScan(count: tracks.count)
        DispatchQueue.concurrentPerform(iterations: tracks.count) { i in
            let track = tracks[i]
            guard !track.isStreaming, let url = RekordboxShare.analysisURL(track.analysisDataPath),
                  let grid = try? BeatGrid.load(anlz: url) else { return }
            tempo.set(i, grid.tempoChanges)
        }
        let rows = tracks.enumerated().map { i, track in
            TrackRow(track: track, cues: library.cues(for: track), playCount: library.playCounts[track.id, default: 0],
                     tempoChanges: tempo.values[i], autoGain: library.autoGains[track.id], commentRule: commentPreset.rule)
        }
        var counts: [LibraryFilter: Int] = [:]
        for filter in LibraryFilter.visible(commentPreset: commentPreset) { counts[filter] = rows.lazy.filter(filter.includes).count }
        var tagDrafts: [String: TagDraft] = [:]
        for uuid in TagDraftStore.uuids() { tagDrafts[uuid] = TagDraftStore.load(trackUUID: uuid) }
        let cueUUIDs = CueDraftStore.uuids()
        var draftCueCounts: [String: CueCounts] = [:]
        var draftPreviewCues: [String: [PreviewCueMark]] = [:]
        let cuesByUUID = Dictionary(rows.map { ($0.track.uuid, $0.cues) }, uniquingKeysWith: { a, _ in a })
        for uuid in cueUUIDs {
            // 자동 큐를 빼고 만든 옛 초안에는 곡의 자동 큐를 채워 덱과 같은 수로 센다(#145).
            if let draft = CueDraftStore.load(trackUUID: uuid)?.includingAutoCues(from: cuesByUUID[uuid] ?? []) {
                draftCueCounts[uuid] = CueCounts(draft)
                if draft.hasChanges { draftPreviewCues[uuid] = draft.cues.map(PreviewCueMark.init) }
            }
        }
        var loaded = LoadedLibrary(rows: rows, report: LibraryReport(library: library, commentRule: commentPreset.rule), filterCounts: counts,
                             tagDrafts: tagDrafts, cueDraftUUIDs: cueUUIDs,
                             gridDraftUUIDs: GridDraftStore.uuids(), gainDraftUUIDs: GainDraftStore.uuids(),
                             playlists: PlaylistLayout(rekordbox: library.playlists),
                             playlistDraft: PlaylistDraftStore.load(),
                             histories: library.histories,
                             draftCueCounts: draftCueCounts, draftPreviewCues: draftPreviewCues,
                             duplicateGroups: LibraryRead.duplicates(in: library).groups,
                             iTunesLibrary: SyncedITunesLibrary(snapshot: iTunes, tracks: tracks), iTunesSnapshot: iTunes)
        loaded.artworkDrafts = ArtworkDraftStore.all(directory: artworkDirectory)
        loaded.artworkFiles = library.artworkFiles
        loaded.smartPlaylists = Dictionary(library.playlists.compactMap { playlist in playlist.smartSource.map { (playlist.id, $0) } },
                                           uniquingKeysWith: { first, _ in first })
        return loaded
    }

    /// DB를 다시 읽지 않고 Music 결과만 채택한다. 캡처 전 발급한 요청 순서로 늦은 결과를 거른다.
    /// - Parameter alreadyCaptured: 따로 끝낸 Music 조회 결과. 있으면 여기서 다시 조회하지 않는다.
    static func loadITunes(snapshot: URL, refreshITunes: Bool = false,
                           captured alreadyCaptured: ITunesLibrarySnapshot? = nil,
                           previousITunesSnapshot: ITunesFallback? = nil,
                           fallbackDirectory: URL = LibrarySnapshot.defaultDirectory,
                           refreshTicket: ITunesRefreshCoordinator.Ticket? = nil,
                           sourceDatabase: URL? = nil,
                           progress: @Sendable (Stage) -> Void = { _ in },
                           captureITunes: () -> ITunesLibrarySnapshot = { RekordboxITunesReader.capture() }) -> ITunesLibrarySnapshot {
        let refreshTicket = refreshTicket ?? ITunesRefreshCoordinator.shared.begin(snapshot: snapshot, sourceDatabase: sourceDatabase)
        let captured = refreshITunes ? alreadyCaptured ?? Stage.music.measure(progress: progress, captureITunes) : nil
        progress(.iTunes)
        let iTunesStarted = ContinuousClock.now
        let iTunes = ITunesRefreshCoordinator.shared.commit(refreshTicket, snapshot: snapshot, current: {
            let current = Self.currentITunesSnapshot(snapshot: snapshot, sourceDatabase: sourceDatabase)
            return Self.recoverCurrentSelection(current, snapshot: snapshot, sourceDatabase: sourceDatabase,
                                                previous: previousITunesSnapshot)
        }) {
            let local = ITunesLibrarySnapshot.load(for: snapshot)
            let rawCurrent = Self.currentITunesSnapshot(snapshot: snapshot, sourceDatabase: sourceDatabase)
            let current = captured == nil
                ? Self.recoverCurrentSelection(rawCurrent, snapshot: snapshot, sourceDatabase: sourceDatabase,
                                               previous: previousITunesSnapshot) : rawCurrent
            var result: ITunesLibrarySnapshot
            if let captured {
                result = captured.status == .ready ? captured : staleITunesSnapshot(current: current, snapshot: snapshot,
                    previous: previousITunesSnapshot, fallbackDirectory: fallbackDirectory,
                    sourceDatabase: sourceDatabase)
            } else {
                result = current
                // 쓰기 후 Music을 다시 읽지 않아도, 앞서 Music을 조회해 실패했으면 그 실패를 이어 간다(사본 파일은 미캡처로 남는다).
                // 조회한 적 없는 사본(`DJC_REKORDBOX_DIR`·`--db`)의 미캡처는 그대로 둔다: 읽는 중은 `.loading`이 따로 있어
                // 미캡처는 "캡처한 목록이 없다"만 뜻하고, 접근 권한 안내로 바꾸면 조회하지도 않은 Music 탓이 된다(#197).
                if result.status == .notCaptured, let previous = previousITunesSnapshot,
                   previous.preferOverCurrent,
                   sameSource(previous, snapshot: snapshot, sourceDatabase: sourceDatabase),
                   previous.contents.status == .unavailable {
                    result.status = .unavailable
                }
            }
            if let syncURL = Self.syncURL(snapshot: snapshot, sourceDatabase: sourceDatabase), result.status == .ready {
                do { result = try result.applyingRekordboxSelection(Data(contentsOf: syncURL)) }
                catch { result.status = .stale }
            }
            let shouldSave = captured != nil || (sourceDatabase != nil && result.syncData != local.syncData)
            // 새 DB 사본에도 재사용한 목록을 남긴다. 같은 초에 교체되거나 정상 자료가 낡음 상태여도 보존한다.
            let reusedSnapshot = captured == nil && previousITunesSnapshot.map {
                sameSource($0, snapshot: snapshot, sourceDatabase: sourceDatabase)
            } == true && result != local && (result.status == .ready || result.status == .stale)
            if (result.status == .ready && shouldSave) || reusedSnapshot {
                do { try result.save(for: snapshot) }
                catch {
                    if captured != nil {
                        result = staleITunesSnapshot(current: current, snapshot: snapshot,
                                                     previous: previousITunesSnapshot, fallbackDirectory: fallbackDirectory,
                                                     sourceDatabase: sourceDatabase)
                    }
                }
            }
            return result
        }
        Stage.iTunes.logElapsed(since: iTunesStarted)
        return iTunes
    }

    private static func currentITunesSnapshot(snapshot: URL, sourceDatabase: URL?) -> ITunesLibrarySnapshot {
        let local = ITunesLibrarySnapshot.load(for: snapshot)
        guard let sourceDatabase else { return applyingCurrentSelection(local, snapshot: snapshot, sourceDatabase: nil) }
        let source = ITunesLibrarySnapshot.load(for: sourceDatabase)
        let currentSync = syncURL(snapshot: snapshot, sourceDatabase: sourceDatabase).flatMap { try? Data(contentsOf: $0) }
        let base: ITunesLibrarySnapshot
        if local.status == .ready, currentSync != nil, local.syncData == currentSync {
            base = local
        } else if source.status == .ready {
            base = source
        } else if local.status == .ready {
            base = local
        } else {
            base = source.status == .stale ? source : local
        }
        return applyingCurrentSelection(base, snapshot: snapshot, sourceDatabase: sourceDatabase)
    }

    private static func recoverCurrentSelection(_ value: ITunesLibrarySnapshot, snapshot: URL,
                                                sourceDatabase: URL?, previous: ITunesFallback?) -> ITunesLibrarySnapshot {
        let current = applyingCurrentSelection(value, snapshot: snapshot, sourceDatabase: sourceDatabase)
        guard let previous, sameSource(previous, snapshot: snapshot, sourceDatabase: sourceDatabase),
              previous.contents.status == .ready || previous.contents.status == .stale else { return current }
        let syncData = syncURL(snapshot: snapshot, sourceDatabase: sourceDatabase).flatMap { try? Data(contentsOf: $0) }
        let previousMatchesSync = syncData != nil && previous.contents.syncData == syncData
        let diskMatchesSync = readySnapshotMatchesSync(snapshot: snapshot, sourceDatabase: sourceDatabase,
                                                       syncData: syncData)
        // 현재 선택과 맞는 정상 사본이 있으면 이전 메모리 선택의 강제 우선권도 적용하지 않는다.
        if current.status == .ready && diskMatchesSync { return current }
        guard previous.preferOverCurrent || current.status != .ready
                || (previousMatchesSync && !diskMatchesSync) else { return current }
        return applyingCurrentSelection(previous.contents, snapshot: snapshot, sourceDatabase: sourceDatabase)
    }

    private static func sameSource(_ previous: ITunesFallback, snapshot: URL, sourceDatabase: URL?) -> Bool {
        guard LibrarySnapshot.sameDirectory(previous.source.deletingLastPathComponent(),
                                            snapshot.deletingLastPathComponent()) else { return false }
        guard let expected = previous.sourceDatabase else { return true }
        return sourceDatabase?.standardizedFileURL.path == expected.standardizedFileURL.path
    }

    private static func syncURL(snapshot: URL, sourceDatabase: URL?) -> URL? {
        let directory = (sourceDatabase ?? snapshot).deletingLastPathComponent()
        let url = directory.appending(path: "playlists3.sync")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func readySnapshotMatchesSync(snapshot: URL, sourceDatabase: URL?, syncData: Data?) -> Bool {
        guard let syncData else { return false }
        let local = ITunesLibrarySnapshot.load(for: snapshot)
        let source = sourceDatabase.map { ITunesLibrarySnapshot.load(for: $0) }
        return ([local, source].compactMap { $0 }).contains { $0.status == .ready && $0.syncData == syncData }
    }

    private static func applyingCurrentSelection(_ value: ITunesLibrarySnapshot, snapshot: URL,
                                                 sourceDatabase: URL?) -> ITunesLibrarySnapshot {
        guard value.status == .ready, let sync = syncURL(snapshot: snapshot, sourceDatabase: sourceDatabase) else { return value }
        do { return try value.applyingRekordboxSelection(Data(contentsOf: sync)) }
        catch { var stale = value; stale.status = .stale; return stale }
    }

    private static func staleITunesSnapshot(current: ITunesLibrarySnapshot, snapshot: URL,
                                            previous: ITunesFallback?, fallbackDirectory: URL,
                                            sourceDatabase: URL?) -> ITunesLibrarySnapshot {
        var fallback = current
        let syncData = syncURL(snapshot: snapshot, sourceDatabase: sourceDatabase).flatMap { try? Data(contentsOf: $0) }
        let hasCurrentReadySnapshot = current.status == .ready
            && readySnapshotMatchesSync(snapshot: snapshot, sourceDatabase: sourceDatabase, syncData: syncData)
        var usedPreferredPrevious = false
        if let previous, previous.preferOverCurrent, !hasCurrentReadySnapshot,
           sameSource(previous, snapshot: snapshot, sourceDatabase: sourceDatabase),
           previous.contents.status == .ready || previous.contents.status == .stale {
            fallback = previous.contents
            usedPreferredPrevious = true
        }
        if fallback.status != .ready && fallback.status != .stale {
            // 명시한 이전 사본은 같은 스냅샷 폴더일 때만 쓴다. 서로 다른 DB 출처를 섞지 않는다.
            if let previous, sameSource(previous, snapshot: snapshot, sourceDatabase: sourceDatabase),
               previous.contents.status == .ready || previous.contents.status == .stale {
                fallback = previous.contents
            }
            if fallback.status != .ready && fallback.status != .stale,
               LibrarySnapshot.sameDirectory(snapshot.deletingLastPathComponent(), fallbackDirectory) {
                let files = ((try? FileManager.default.contentsOfDirectory(at: fallbackDirectory, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "db" && $0.lastPathComponent.hasPrefix("master-")
                        && $0.lastPathComponent < snapshot.lastPathComponent }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
                fallback = files.lazy.map { ITunesLibrarySnapshot.load(for: $0) }
                    .first { $0.status == .ready || $0.status == .stale } ?? fallback
            }
        }
        guard fallback.status == .ready || fallback.status == .stale else { return ITunesLibrarySnapshot(status: .unavailable) }
        fallback.status = .stale
        // 새 DB 사본에만 낡음 표시를 저장한다. 기존 정상/손상 sidecar는 실패로 덮어쓰지 않는다.
        if current.status == .notCaptured || usedPreferredPrevious { try? fallback.save(for: snapshot) }
        return fallback
    }
}

/// 캡처는 병렬로 읽되, 같은 DB sidecar의 채택·저장은 요청 순서 확인과 한 잠금 안에서 끝낸다.
final class ITunesRefreshCoordinator: @unchecked Sendable {
    struct Ticket: Sendable {
        let snapshotPath: String
        let sequence: UInt64
        let sourcePath: String
        let writeEpoch: UInt64
    }

    static let shared = ITunesRefreshCoordinator()
    private let lock = NSLock()
    private var nextSequence: UInt64 = 0
    private var latestBySnapshot: [String: UInt64] = [:]
    private var writeEpochBySource: [String: UInt64] = [:]

    func begin(snapshot: URL, sourceDatabase: URL? = nil) -> Ticket {
        lock.lock()
        defer { lock.unlock() }
        nextSequence &+= 1
        let snapshotPath = snapshot.standardizedFileURL.path
        let sourcePath = (sourceDatabase ?? snapshot).standardizedFileURL.path
        latestBySnapshot[snapshotPath] = nextSequence
        return Ticket(snapshotPath: snapshotPath, sequence: nextSequence, sourcePath: sourcePath,
                      writeEpoch: writeEpochBySource[sourcePath, default: 0])
    }

    func commit(_ ticket: Ticket, snapshot: URL, current: () -> ITunesLibrarySnapshot,
                latest: () -> ITunesLibrarySnapshot) -> ITunesLibrarySnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard latestBySnapshot[ticket.snapshotPath] == ticket.sequence,
              writeEpochBySource[ticket.sourcePath, default: 0] == ticket.writeEpoch else { return current() }
        return latest()
    }

    func publish(sources: [URL], update: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        invalidateSourcesLocked(sources)
        update()
    }

    func invalidateSnapshots(_ snapshots: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        for snapshot in snapshots {
            nextSequence &+= 1
            latestBySnapshot[snapshot.standardizedFileURL.path] = nextSequence
        }
    }

    private func invalidateSourcesLocked(_ sources: [URL]) {
        for source in sources {
            let path = source.standardizedFileURL.path
            writeEpochBySource[path, default: 0] &+= 1
            nextSequence &+= 1
            latestBySnapshot[path] = nextSequence
        }
    }
}

/// 병렬로 채우는 변속 결과(칸마다 한 스레드만 쓴다).
final class TempoScan: @unchecked Sendable {
    private(set) var values: [[Double]]
    private let lock = NSLock()
    init(count: Int) { values = Array(repeating: [], count: count) }
    func set(_ index: Int, _ value: [Double]) {
        guard !value.isEmpty else { return }
        lock.lock(); values[index] = value; lock.unlock()
    }
}

/// 핫큐·메모리 큐 개수(초안 기준).
struct CueCounts: Hashable, Sendable {
    var hot: Int
    var memory: Int
    /// 메모리 큐 가운데 아직 고치지 않은 rekordbox 자동 큐(#145)
    var autoMemory: Int

    init(_ draft: CueDraft) {
        hot = draft.cues.filter { if case .hot = $0.kind { true } else { false } }.count
        memory = draft.cues.count - hot
        autoMemory = draft.cues.filter { $0.kind == .memory && $0.isAutoGenerated }.count
    }
}
