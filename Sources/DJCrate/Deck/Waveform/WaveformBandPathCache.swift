import DJCAnalysis
import SwiftUI

/// 같은 Canvas 크기를 여러 번 배치할 때 3밴드의 구간 최대값과 경로를 다시 만들지 않는다.
@MainActor
final class WaveformBandPathCache {
    private struct Key: Equatable {
        var start: Double
        var end: Double
        var rect: CGRect
    }
    private struct Source: Equatable {
        var rate: Double
        var buffers: [UInt]
        var counts: [Int]

        init(_ waveform: Waveform) {
            rate = waveform.rate
            counts = [waveform.low.count, waveform.mid.count, waveform.high.count]
            buffers = [waveform.low, waveform.mid, waveform.high].map { band in
                band.withUnsafeBufferPointer { $0.baseAddress.map { UInt(bitPattern: $0) } ?? 0 }
            }
        }
    }
    private var source: Source?
    // 원본 배열을 보관해 주소 재사용을 막고 수정 시 COW로 다른 원본임을 확인한다.
    private var retainedWaveform: Waveform?
    private var entries: [(key: Key, paths: [Path])] = []

    func paths(waveform: Waveform, from start: Double, to end: Double, in rect: CGRect) -> [Path] {
        let nextSource = Source(waveform)
        if source != nextSource {
            entries.removeAll(keepingCapacity: true)
            source = nextSource
            retainedWaveform = waveform
        }
        let key = Key(start: start, end: end, rect: rect)
        if let entry = entries.first(where: { $0.key == key }) { return entry.paths }
        PerfProbe.count("WaveformBandPath.build")
        let paths = Self.makePaths(waveform: waveform, from: start, to: end, in: rect)
        // 예측 배치에서 번갈아 쓰는 크기만 보관해 메모리가 계속 늘지 않게 한다.
        if entries.count == 4 { entries.removeFirst() }
        entries.append((key, paths))
        return paths
    }

    nonisolated static func makePaths(waveform: Waveform, from start: Double, to end: Double, in rect: CGRect,
                                     scales: (Double, Double, Double) = (1, 0.78, 0.5)) -> [Path] {
        let columns = max(1, Int(rect.width))
        let span = end - start
        guard span > 0, waveform.count > 0 else { return [] }
        let binDuration = span / Double(columns)
        let firstBin = Int((start / binDuration).rounded(.down))
        let cy = rect.midY, half = rect.height / 2
        return [(waveform.low, scales.0), (waveform.mid, scales.1), (waveform.high, scales.2)].map { band, scale in
            var top: [CGPoint] = [], bottom: [CGPoint] = []
            top.reserveCapacity(columns + 2); bottom.reserveCapacity(columns + 2)
            for k in 0...(columns + 1) {
                let t0 = Double(firstBin + k) * binDuration
                let a = Int((t0 * waveform.rate).rounded(.down))
                let b = max(a + 1, Int(((t0 + binDuration) * waveform.rate).rounded(.down)))
                var peak: UInt8 = 0
                if a < band.count, b > 0 {
                    for i in max(0, a)..<min(band.count, b) where band[i] > peak { peak = band[i] }
                }
                let amplitude = Double(peak) / 255 * half * scale
                let x = rect.minX + CGFloat((t0 - start) / span) * rect.width
                top.append(CGPoint(x: x, y: cy - amplitude))
                bottom.append(CGPoint(x: x, y: cy + amplitude))
            }
            var path = Path()
            path.addLines(top + bottom.reversed())
            path.closeSubpath()
            return path
        }
    }
}
