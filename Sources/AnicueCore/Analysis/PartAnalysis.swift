import Foundation

/// Music Understanding 결과를 초 단위로 옮긴 캐시 가능한 모델.
public struct PartAnalysis: Codable, Sendable {
    public struct Span: Codable, Sendable, Hashable {
        public var start: Double
        public var end: Double
        public var duration: Double { end - start }
    }

    public struct KeySpan: Codable, Sendable, Hashable {
        public var span: Span
        public var tonic: String
        public var mode: String
        public var name: String { "\(tonic) \(mode)" }
    }

    public struct Sample: Codable, Sendable, Hashable {
        public var time: Double
        public var value: Double
    }

    public var duration: Double
    public var bpm: Double?
    public var beats: [Double]
    public var bars: [Double]
    public var sections: [Span]
    public var segments: [Span]
    public var phrases: [Span]
    public var keys: [KeySpan]
    public var pace: [Sample]
    public var vocal: [Sample]
    public var drum: [Sample]
    public var loudness: [Sample]
    public var integratedLoudness: Double?

    /// 구간 안 샘플의 평균. 무음 구간의 `-inf` LUFS 같은 비유한 값은 `floor`로 바꾼다.
    public static func mean(_ samples: [Sample], in span: Span, floor: Double = -70) -> Double {
        let values = samples
            .filter { $0.time >= span.start && $0.time < span.end }
            .map { $0.value.isFinite ? max($0.value, floor) : floor }
        return values.isEmpty ? floor : values.reduce(0, +) / Double(values.count)
    }

    /// 가장 가까운 박으로 스냅. 다운비트(마디 시작)가 반 박 안에 있으면 그쪽을 택한다.
    public func snap(_ time: Double) -> Double {
        guard let beat = beats.min(by: { abs($0 - time) < abs($1 - time) }) else { return time }
        let beatLength = bpm.map { 60 / $0 } ?? 0.5
        if let bar = bars.min(by: { abs($0 - beat) < abs($1 - beat) }), abs(bar - time) <= beatLength / 2 {
            return bar
        }
        return beat
    }

    /// 몇 번째 마디인지 (1부터).
    public func barNumber(at time: Double) -> Int? {
        guard !bars.isEmpty else { return nil }
        return bars.lastIndex(where: { $0 <= time + 0.05 }).map { $0 + 1 }
    }
}
