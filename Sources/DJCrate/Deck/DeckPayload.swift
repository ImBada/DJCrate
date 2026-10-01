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

    static func load(track: Track, cues: [Cue], duration: Double, storage: DeckStorage, analysisRoot: URL? = nil) -> DeckPayload {
        // 덱의 시각은 모두 rekordbox 시간축이다(초안·rekordbox 큐·그리드를 그대로 쓴다).
        // 자동 큐를 빼고 만든 옛 초안에는 곡의 자동 큐를 채운다(#145, 목록에 메모리 큐로 보인다).
        let draft = storage.loadCueDraft(track.uuid)?.includingAutoCues(from: cues) ?? CueDraft(trackUUID: track.uuid, rekordboxCues: cues)
        var payload = DeckPayload(draft: draft)
        payload.artwork = ArtworkCache.downsampled(imagePath: track.imagePath, maxPixels: 360)

        guard let url = RekordboxShare.analysisURL(track.analysisDataPath, root: analysisRoot),
              let rekordboxGrid = try? BeatGrid.load(anlz: url), !rekordboxGrid.beats.isEmpty
        else {
            // 그리드가 없는 곡: 앞서 적용해 둔 추정 그리드 초안이 있으면 그것을 쓴다.
            payload.gridDraft = storage.loadGridDraft(track.uuid)
            if payload.gridDraft?.replacementSource != nil {
                payload.gridBlockedReason = String(ui: "rekordbox 분석 파일이 없습니다. rekordbox에서 트랙 분석을 먼저 하세요")
            }
            return payload
        }
        let original = rekordboxGrid
        payload.originalGrid = original
        let fresh = GridDraft(trackUUID: track.uuid, grid: original)
        // 재생성 오차 확인: 편집하지 않은 상태에서 2ms 넘게 다르면 편집을 막는다.
        let rebuilt = fresh.grid(duration: max(duration + 1, original.beats.last!.time + 0.01))
        let worst = GridEditEligibility.reconstructionErrorMilliseconds(original: original, rebuilt: rebuilt)
        let saved = storage.loadGridDraft(track.uuid)
        let replacement = saved.map { $0.trackUUID == track.uuid && $0.isVerifiedReplacement(of: original, duration: duration) } ?? false
        if saved?.replacementSource != nil, !replacement {
            payload.gridBlockedReason = String(ui: "초안을 만든 뒤 rekordbox에서 그리드가 바뀌었습니다. DJCrate에서 다시 불러와 확인하세요")
        } else if worst > 2, !replacement {
            payload.gridBlockedReason = String(ui: "이 곡의 그리드는 템포 구간 \(fresh.segments.count)개로 복잡해 정확히 재현되지 않습니다(최대 \(worst, specifier: "%.0f")ms). 편집을 막았습니다.")
        }
        payload.gridDraft = saved ?? fresh
        return payload
    }
}
