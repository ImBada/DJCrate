import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation
import Observation

/// 백그라운드에서 만드는 로드 결과.
struct LoadedLibrary: Sendable {
    struct ITunesFallback: Sendable {
        let source: URL
        let contents: ITunesLibrarySnapshot
    }
    var rows: [TrackRow]
    var report: LibraryReport
    var filterCounts: [LibraryFilter: Int]
    var tagDrafts: [String: TagDraft]
    var cueDraftUUIDs: Set<String>
    var gridDraftUUIDs: Set<String>
    var playlists: PlaylistLayout
    var playlistDraft: PlaylistDraft
    var histories: [RekordboxHistory]
    var draftCueCounts: [String: CueCounts] = [:]
    var draftPreviewCues: [String: [PreviewCueMark]] = [:]
    var duplicateGroups: [LibraryRead.DuplicateGroup] = []
    var iTunesLibrary = SyncedITunesLibrary()
    var iTunesSnapshot = ITunesLibrarySnapshot(status: .notCaptured)

    static func load(snapshot: URL, commentPreset: CommentPreset = .none, refreshITunes: Bool = false,
                     previousITunesSnapshot: ITunesFallback? = nil,
                     fallbackDirectory: URL = LibrarySnapshot.defaultDirectory,
                     refreshTicket: ITunesRefreshCoordinator.Ticket? = nil,
                     captureITunes: () -> ITunesLibrarySnapshot = { RekordboxITunesReader.capture() }) throws -> LoadedLibrary {
        let refreshTicket = refreshITunes ? (refreshTicket ?? ITunesRefreshCoordinator.shared.begin(snapshot: snapshot)) : nil
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        let tracks = library.tracks
        var iTunes = ITunesLibrarySnapshot.load(for: snapshot)
        // 명시한 사본에 동기화 파일도 있으면 그 파일을 기준으로 고른다. 라이브 폴더로 되돌아가지 않는다.
        let syncURL = snapshot.deletingLastPathComponent().appending(path: "playlists3.sync")
        if !refreshITunes, iTunes.status == .ready, FileManager.default.fileExists(atPath: syncURL.path) {
            do { iTunes = try iTunes.applyingRekordboxSelection(Data(contentsOf: syncURL)) }
            catch { iTunes.status = .stale }
        }
        if let refreshTicket {
            let captured = captureITunes()
            iTunes = ITunesRefreshCoordinator.shared.commit(refreshTicket, snapshot: snapshot) {
                let current = ITunesLibrarySnapshot.load(for: snapshot)
                if captured.status == .ready {
                    do {
                        try captured.save(for: snapshot)
                        return captured
                    } catch {
                        return staleITunesSnapshot(current: current, snapshot: snapshot,
                                                    previous: previousITunesSnapshot, fallbackDirectory: fallbackDirectory)
                    }
                }
                return staleITunesSnapshot(current: current, snapshot: snapshot,
                                            previous: previousITunesSnapshot, fallbackDirectory: fallbackDirectory)
            }
        }
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
        for uuid in cueUUIDs {
            if let draft = CueDraftStore.load(trackUUID: uuid) {
                draftCueCounts[uuid] = CueCounts(draft)
                if draft.hasChanges { draftPreviewCues[uuid] = draft.cues.map(PreviewCueMark.init) }
            }
        }
        return LoadedLibrary(rows: rows, report: LibraryReport(library: library, commentRule: commentPreset.rule), filterCounts: counts,
                             tagDrafts: tagDrafts, cueDraftUUIDs: cueUUIDs,
                             gridDraftUUIDs: GridDraftStore.uuids(), playlists: PlaylistLayout(rekordbox: library.playlists),
                             playlistDraft: PlaylistDraftStore.load(),
                             histories: library.histories,
                             draftCueCounts: draftCueCounts, draftPreviewCues: draftPreviewCues,
                             duplicateGroups: LibraryRead.duplicates(in: library).groups,
                             iTunesLibrary: SyncedITunesLibrary(snapshot: iTunes, tracks: tracks), iTunesSnapshot: iTunes)
    }

    private static func staleITunesSnapshot(current: ITunesLibrarySnapshot, snapshot: URL,
                                            previous: ITunesFallback?, fallbackDirectory: URL) -> ITunesLibrarySnapshot {
        var fallback = current
        if fallback.status != .ready && fallback.status != .stale {
            // 명시한 이전 사본은 같은 스냅샷 폴더일 때만 쓴다. 서로 다른 DB 출처를 섞지 않는다.
            if let previous, LibrarySnapshot.sameDirectory(previous.source.deletingLastPathComponent(),
                                                           snapshot.deletingLastPathComponent()),
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
        if current.status == .notCaptured { try? fallback.save(for: snapshot) }
        return fallback
    }
}

/// 캡처는 병렬로 읽되, 같은 DB sidecar의 채택·저장은 요청 순서 확인과 한 잠금 안에서 끝낸다.
final class ITunesRefreshCoordinator: @unchecked Sendable {
    struct Ticket: Sendable {
        let path: String
        let sequence: UInt64
    }

    static let shared = ITunesRefreshCoordinator()
    private let lock = NSLock()
    private var nextSequence: UInt64 = 0
    private var latestByPath: [String: UInt64] = [:]

    func begin(snapshot: URL) -> Ticket {
        lock.lock()
        defer { lock.unlock() }
        nextSequence &+= 1
        let path = snapshot.standardizedFileURL.path
        latestByPath[path] = nextSequence
        return Ticket(path: path, sequence: nextSequence)
    }

    func commit(_ ticket: Ticket, snapshot: URL, latest: () -> ITunesLibrarySnapshot) -> ITunesLibrarySnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard latestByPath[ticket.path] == ticket.sequence else { return ITunesLibrarySnapshot.load(for: snapshot) }
        return latest()
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

    init(_ draft: CueDraft) {
        hot = draft.cues.filter { if case .hot = $0.kind { true } else { false } }.count
        memory = draft.cues.count - hot
    }
}
