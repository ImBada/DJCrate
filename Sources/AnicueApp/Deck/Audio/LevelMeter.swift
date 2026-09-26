import Accelerate
import AVFoundation
import Foundation

/// 게인 뒤·볼륨 앞 레벨. 오디오 탭 스레드가 쓰고 화면이 읽는다(잠금으로 보호).
final class LevelMeter: @unchecked Sendable {
    struct Reading {
        var peak: (left: Float, right: Float) = (0, 0)
        var rms: (left: Float, right: Float) = (0, 0)
        /// 마지막으로 받은 시각(재생이 멈추면 더 오지 않는다)
        var time: Double = 0
        /// 마지막으로 0dBFS 이상이 나온 시각
        var clipTime: Double = -.infinity
        /// 곡을 불러온 뒤 가장 큰 피크와 0dBFS를 넘은 횟수(버퍼 단위)
        var maxPeak: Float = 0
        var clipCount = 0
    }

    private let lock = NSLock()
    private var reading = Reading()

    func update(peak: (Float, Float), rms: (Float, Float)) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        reading.peak = peak
        reading.rms = rms
        reading.time = now
        let top = max(peak.0, peak.1)
        reading.maxPeak = max(reading.maxPeak, top)
        if top >= 1 {
            reading.clipTime = now
            reading.clipCount += 1
        }
        lock.unlock()
    }

    func read() -> Reading {
        lock.lock()
        defer { lock.unlock() }
        return reading
    }

    func reset() {
        lock.lock()
        reading = Reading()
        lock.unlock()
    }

    /// 최고 피크·CLIP 기록만 지운다.
    func resetPeaks() {
        lock.lock()
        reading.maxPeak = 0
        reading.clipCount = 0
        reading.clipTime = -.infinity
        lock.unlock()
    }
}
