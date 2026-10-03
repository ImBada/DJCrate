@testable import DJCrate
@testable import DJCAnalysis
import SwiftUI
import Testing

@MainActor
@Suite("전체 파형 반복 배치 경로", .serialized)
struct WaveformBandPathCacheTests {
    private let rect = CGRect(x: 3, y: 2, width: 2, height: 20)
    private var waveform: Waveform { Waveform(rate: 1, duration: 4, low: [0, 255, 128, 64], mid: [255, 0, 0, 0], high: [0, 0, 255, 0]) }

    @Test func 같은_파형과_크기의_반복_배치는_경로를_한_번만_만든다() {
        let previous = PerfProbe.countsBodies
        defer { PerfProbe.countsBodies = previous; PerfProbe.resetBodyCounts() }
        PerfProbe.countsBodies = true
        PerfProbe.resetBodyCounts()
        let cache = WaveformBandPathCache(), wave = waveform
        let first = cache.paths(waveform: wave, from: 0, to: 4, in: rect)
        for _ in 0..<4 { #expect(cache.paths(waveform: wave, from: 0, to: 4, in: rect) == first) }
        #expect(PerfProbe.bodyCount("WaveformBandPath.build") == 1)
    }

    @Test func 경로는_구간_최댓값과_양끝_빈_구간을_보존한다() {
        let paths = WaveformBandPathCache().paths(waveform: waveform, from: 0, to: 4, in: rect)
        var expected = Path()
        let second = Double(128) / 255 * 10
        expected.addLines([CGPoint(x: 3, y: 2), CGPoint(x: 4, y: 12 - second), CGPoint(x: 5, y: 12), CGPoint(x: 6, y: 12),
                           CGPoint(x: 6, y: 12), CGPoint(x: 5, y: 12), CGPoint(x: 4, y: 12 + second), CGPoint(x: 3, y: 22)])
        expected.closeSubpath()
        #expect(paths.count == 3)
        #expect(paths.first == expected)
    }

    @Test func 크기와_시간축과_원본_변경은_캐시를_잘못_재사용하지_않는다() {
        let cache = WaveformBandPathCache()
        var wave = waveform
        let original = cache.paths(waveform: wave, from: 0, to: 4, in: rect)
        #expect(cache.paths(waveform: wave, from: -1, to: 3, in: rect) != original)
        #expect(cache.paths(waveform: wave, from: 0, to: 4, in: rect.offsetBy(dx: 1, dy: 1)) != original)
        #expect(cache.paths(waveform: wave, from: 0, to: 4, in: CGRect(x: 3, y: 2, width: 3, height: 20)) != original)
        wave.low[1] = 0
        #expect(cache.paths(waveform: wave, from: 0, to: 4, in: rect) != original)
        wave.rate = 2
        #expect(cache.paths(waveform: wave, from: 0, to: 4, in: rect) == WaveformBandPathCache().paths(waveform: wave, from: 0, to: 4, in: rect))
    }

    @Test func 배열_길이만_줄여도_새_경로를_만든다() {
        let cache = WaveformBandPathCache()
        var wave = waveform
        let original = cache.paths(waveform: wave, from: 0, to: 4, in: rect)
        wave.low.removeLast(2)
        #expect(cache.paths(waveform: wave, from: 0, to: 4, in: rect) != original)
        wave.mid.removeLast(3)
        wave.high.removeLast(3)
        #expect(cache.paths(waveform: wave, from: 0, to: 4, in: rect) == WaveformBandPathCache.makePaths(waveform: wave, from: 0, to: 4, in: rect))
    }

    @Test func 중음과_고음_변경과_빈_원본도_반영한다() {
        let cache = WaveformBandPathCache()
        var wave = waveform
        var previous = cache.paths(waveform: wave, from: 0, to: 4, in: rect)
        wave.mid[0] = 0
        var next = cache.paths(waveform: wave, from: 0, to: 4, in: rect)
        #expect(previous != next)
        previous = next
        wave.high[2] = 0
        next = cache.paths(waveform: wave, from: 0, to: 4, in: rect)
        #expect(previous != next)
        wave.low = []
        #expect(cache.paths(waveform: wave, from: 0, to: 4, in: rect).isEmpty)
        #expect(cache.paths(waveform: waveform, from: 4, to: 0, in: rect).isEmpty)
    }

    @Test func 여러_크기를_오가도_보관_범위는_네_개다() {
        let previous = PerfProbe.countsBodies
        defer { PerfProbe.countsBodies = previous; PerfProbe.resetBodyCounts() }
        PerfProbe.countsBodies = true
        PerfProbe.resetBodyCounts()
        let cache = WaveformBandPathCache(), wave = waveform
        for width in 2...5 {
            _ = cache.paths(waveform: wave, from: 0, to: 4, in: CGRect(x: 0, y: 0, width: width, height: 20))
        }
        for width in 2...5 {
            _ = cache.paths(waveform: wave, from: 0, to: 4, in: CGRect(x: 0, y: 0, width: width, height: 20))
        }
        #expect(PerfProbe.bodyCount("WaveformBandPath.build") == 4)
        _ = cache.paths(waveform: wave, from: 0, to: 4, in: CGRect(x: 0, y: 0, width: 6, height: 20))
        _ = cache.paths(waveform: wave, from: 0, to: 4, in: CGRect(x: 0, y: 0, width: 2, height: 20))
        #expect(PerfProbe.bodyCount("WaveformBandPath.build") == 6)
    }
}
