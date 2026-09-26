import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import Foundation
import RekordboxKit

/// 조성 흐름(추정): 크로마 + 그리드 마디 창
extension DeckModel {
    // MARK: 조성 흐름(추정)


    func keyName(for segment: KeyAnalyzer.Segment) -> String { KeyAnalyzer.camelot(signature: segment.signature, minor: keyMinor) }

    /// 재생 위치의 조성(Camelot)
    func key(at time: Double) -> String? {
        guard let segment = keySegments.first(where: { time >= $0.start && time < $0.end }) ?? keySegments.last(where: { time >= $0.start })
        else { return row?.track.key }
        return keyName(for: segment)
    }

    /// 크로마·그리드가 바뀌면 다시 계산한다(마디 창, 벌점 5, 최소 16마디).
    func refreshKeySegments() {
        guard let chroma = keyChroma, !chroma.frames.isEmpty else { keySegments = []; return }
        let offset = timelineOffset
        let rekordbox = row.flatMap { KeyAnalyzer.signature(camelot: $0.track.key ?? "") }
        keyMinor = rekordbox?.minor ?? false
        // 창은 rekordbox 시간축(그리드 기준) → 크로마(음원 시간축)로 옮겨 계산하고 되돌린다.
        let windows = KeyAnalyzer.windows(grid: grid, duration: duration).map { ($0.0 - offset, $0.1 - offset) }
        let result = KeyAnalyzer.segments(chroma: chroma, windows: windows, switchPenalty: 5, minWindows: 16)
        var segments = result.segments.map { KeyAnalyzer.Segment(start: $0.start + offset, end: $0.end + offset, signature: $0.signature) }
        // 주 조표를 rekordbox 키에 맞춘다(전조는 같은 간격으로 옮긴다).
        if let main = result.main, let rekordbox, main != rekordbox.signature {
            let shift = rekordbox.signature - main
            segments = segments.map { var s = $0; s.signature = (($0.signature + shift) % 12 + 12) % 12; return s }
        }
        if let first = segments.first, first.start > 0 { segments[0].start = 0 }
        keySegments = segments
    }
}
