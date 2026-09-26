import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import Foundation
import RekordboxKit

/// 덱에 올릴 곡의 무거운 부분(초안·그리드·아트워크). 백그라운드에서 만든다.
struct DeckPayload: Sendable {
    var draft: CueDraft
    var originalGrid: BeatGrid?
    var gridDraft: GridDraft?
    var gridBlockedReason: String?
    var artwork: Thumbnails.Box?

    static func load(track: Track, cues: [Cue], duration: Double, storage: DeckStorage) -> DeckPayload {
        // 덱의 시각은 모두 rekordbox 시간축이다(초안·rekordbox 큐·그리드를 그대로 쓴다).
        let draft = storage.loadCueDraft(track.uuid) ?? CueDraft(trackUUID: track.uuid, rekordboxCues: cues)
        var payload = DeckPayload(draft: draft)
        payload.artwork = ArtworkCache.downsampled(imagePath: track.imagePath, maxPixels: 360)

        guard let url = RekordboxShare.analysisURL(track.analysisDataPath),
              let rekordboxGrid = try? BeatGrid.load(anlz: url), !rekordboxGrid.beats.isEmpty
        else {
            // 그리드가 없는 곡: 앞서 적용해 둔 추정 그리드 초안이 있으면 그것을 쓴다.
            payload.gridDraft = storage.loadGridDraft(track.uuid)
            return payload
        }
        let original = rekordboxGrid
        payload.originalGrid = original
        let fresh = GridDraft(trackUUID: track.uuid, grid: original)
        // 재생성 오차 확인: 편집하지 않은 상태에서 2ms 넘게 다르면 편집을 막는다.
        let rebuilt = fresh.grid(duration: max(duration + 1, original.beats.last!.time + 0.01))
        let worst = original.beats.map { abs(rebuilt.snap($0.time) - $0.time) }.max() ?? 0
        if worst > 0.002 {
            payload.gridBlockedReason = String(ui: "이 곡의 그리드는 템포 구간 \(fresh.segments.count)개로 복잡해 정확히 재현되지 않습니다(최대 \(worst * 1000, specifier: "%.0f")ms). 편집을 막았습니다.")
        }
        payload.gridDraft = storage.loadGridDraft(track.uuid) ?? fresh
        return payload
    }
}
