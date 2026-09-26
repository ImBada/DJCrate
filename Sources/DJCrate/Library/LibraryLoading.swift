import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation
import Observation

/// 백그라운드에서 만드는 로드 결과.
struct LoadedLibrary: Sendable {
    var rows: [TrackRow]
    var report: LibraryReport
    var filterCounts: [LibraryFilter: Int]
    var tagDrafts: [String: TagDraft]
    var cueDraftUUIDs: Set<String>
    var gridDraftUUIDs: Set<String>
    var tree: [PlaylistNode]
    var histories: [RekordboxHistory]
    var draftCueCounts: [String: CueCounts] = [:]
    var draftPreviewCues: [String: [PreviewCueMark]] = [:]

    static func load(snapshot: URL) throws -> LoadedLibrary {
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        let tracks = library.tracks
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
                     tempoChanges: tempo.values[i], autoGain: library.autoGains[track.id])
        }
        var counts: [LibraryFilter: Int] = [:]
        for filter in LibraryFilter.allCases { counts[filter] = rows.lazy.filter(filter.includes).count }
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
        return LoadedLibrary(rows: rows, report: LibraryReport(library: library), filterCounts: counts,
                             tagDrafts: tagDrafts, cueDraftUUIDs: cueUUIDs,
                             gridDraftUUIDs: GridDraftStore.uuids(), tree: PlaylistNode.tree(library.playlists),
                             histories: library.histories,
                             draftCueCounts: draftCueCounts, draftPreviewCues: draftPreviewCues)
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
