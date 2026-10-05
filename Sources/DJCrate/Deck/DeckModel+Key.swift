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

    /// 덱 제안 줄의 키 제안에 쓸 추정. 덱에 올린 곡의 것일 때만 돌려준다(앞 곡의 추정이 뒤 곡에 비치지 않게).
    func estimatedKey(for uuid: String) -> String? {
        guard let keyEstimate, keyEstimate.uuid == uuid, row?.track.uuid == uuid else { return nil }
        return keyEstimate.key
    }

    /// 크로마·그리드가 바뀌면 다시 계산한다(마디 창, 벌점 5, 최소 16마디).
    func refreshKeySegments() {
        guard let chroma = keyChroma, !chroma.frames.isEmpty else {
            keySegments = []
            if keyEstimate != nil { keyEstimate = nil }
            return
        }
        let offset = timelineOffset
        let rekordbox = row.flatMap { KeyAnalyzer.signature(camelot: $0.track.key ?? "") }
        // 창은 rekordbox 시간축(그리드 기준) → 크로마(음원 시간축)로 옮겨 계산하고 되돌린다.
        let windows = KeyAnalyzer.windows(grid: grid, duration: duration).map { ($0.0 - offset, $0.1 - offset) }
        let result = KeyAnalyzer.segments(chroma: chroma, windows: windows, switchPenalty: 5, minWindows: 16)
        // 장·단은 rekordbox 키를 따른다. 키가 없으면 주 조표 구간의 크로마로 정한다(조표 흐름은 장·단을 가리지 않는다).
        keyMinor = rekordbox?.minor
            ?? result.main.map { KeyAnalyzer.isMinor(chroma: chroma, signature: $0, segments: result.segments) } ?? false
        var segments = result.segments.map { KeyAnalyzer.Segment(start: $0.start + offset, end: $0.end + offset, signature: $0.signature) }
        // 주 조표를 rekordbox 키에 맞춘다(전조는 같은 간격으로 옮긴다).
        if let main = result.main, let rekordbox, main != rekordbox.signature {
            let shift = rekordbox.signature - main
            segments = segments.map { var s = $0; s.signature = (($0.signature + shift) % 12 + 12) % 12; return s }
        }
        if let first = segments.first, first.start > 0 { segments[0].start = 0 }
        keySegments = segments
        // rekordbox 키가 빈 곡(추가한 곡 제외)만 주 조성을 키 제안으로 내놓는다. 헤더에 보이는 조성과 같은 계산이다.
        // 크로마는 덱이 지금 곡에서 구한 것만 들어온다(디코딩 결과는 곡이 바뀌면 버린다).
        var estimate: KeyEstimate?
        if let row, !row.isStaged, (row.track.key ?? "").isEmpty, let main = result.main {
            estimate = KeyEstimate(uuid: row.track.uuid, key: KeyAnalyzer.camelot(signature: main, minor: keyMinor))
        }
        if keyEstimate != estimate { keyEstimate = estimate }
    }
}

/// 덱이 구한 곡의 주 조성(Camelot)과 그 곡
struct KeyEstimate: Equatable {
    var uuid: String
    var key: String
}
