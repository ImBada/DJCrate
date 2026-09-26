import DJCDomain
import Accelerate
import AVFoundation
import Foundation

/// rekordbox식 3밴드 파형. 저음(~200Hz)·중음(200~2,500Hz)·고음(2,500Hz~)의 RMS를
/// 초당 `rate`칸으로 계산해 0~255로 양자화한다.
public struct Waveform: Codable, Sendable {
    public var rate: Double
    public var duration: Double
    public var low: [UInt8]
    public var mid: [UInt8]
    public var high: [UInt8]

    public var count: Int { low.count }

    public var colorColumns: [WaveformColumn] {
        (0..<count).map { WaveformColumn(low: Double(low[$0]) / 255,
                                        mid: Double(mid[$0]) / 255, high: Double(high[$0]) / 255) }
    }

    /// 개요 파형용 다운샘플(구간 최대값).
    public func downsampled(to points: Int) -> Waveform {
        guard count > points, points > 0 else { return self }
        func reduce(_ band: [UInt8]) -> [UInt8] {
            (0..<points).map { i in
                let start = i * band.count / points, end = max(start + 1, (i + 1) * band.count / points)
                return band[start..<end].max() ?? 0
            }
        }
        return Waveform(rate: Double(points) / duration, duration: duration,
                        low: reduce(low), mid: reduce(mid), high: reduce(high))
    }

    /// `[start, end)` 초 구간만 잘라낸다.
    public func slice(from start: Double, to end: Double) -> Waveform {
        let a = max(0, Int(start * rate)), b = min(count, Int(end * rate))
        guard a < b else { return Waveform(rate: rate, duration: 0, low: [], mid: [], high: []) }
        return Waveform(rate: rate, duration: Double(b - a) / rate,
                        low: Array(low[a..<b]), mid: Array(mid[a..<b]), high: Array(high[a..<b]))
    }
}

public enum WaveformAnalyzer {
    /// 파일을 약 1.5초 조각으로 읽으며 계산한다. 곡 전체를 메모리에 올리지 않고(이전: 곡당 최고 약 291MB),
    /// 조각마다 취소를 확인해 곡을 빨리 넘기면 바로 멈춘다.
    public static func analyze(fileAt url: URL, rate: Double = 150) throws -> Waveform {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        let hop = max(1, Int(sampleRate / rate))
        let chunkFrames = AVAudioFrameCount(hop * 220)
        guard channels > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw DJCError.queryFailed(sql: url.path, message: String(ui: "오디오 버퍼를 만들지 못했습니다"))
        }

        // 필터 상태는 조각 사이에 이어진다(vDSP.Biquad가 상태를 들고 있다).
        var filters = [
            makeBiquad([.lowPass(200, sampleRate), .lowPass(200, sampleRate)]),
            makeBiquad([.highPass(200, sampleRate), .lowPass(2500, sampleRate)]),
            makeBiquad([.highPass(2500, sampleRate), .highPass(2500, sampleRate)]),
        ]
        var envelopes: [[Float]] = [[], [], []]
        var pending: [[Float]] = [[], [], []]   // hop보다 짧게 남은 필터 출력
        var totalFrames = 0
        var mono = [Float](repeating: 0, count: Int(chunkFrames))

        while true {
            if Task.isCancelled { throw CancellationError() }
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                // 파일 끝에서 eofErr(-39)를 돌려주는 디코더가 있다(MP3 길이 추정). 읽은 만큼은 쓴다.
                guard totalFrames > 0 else { throw error }
                break
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            totalFrames += frames

            mono.withUnsafeMutableBufferPointer { out in
                for i in 0..<frames { out[i] = 0 }
                for ch in 0..<channels {
                    let input = UnsafeBufferPointer(start: data[ch], count: frames)
                    for i in 0..<frames { out[i] += input[i] }
                }
            }
            let chunk = Array(mono[0..<frames]).map { $0 / Float(channels) }
            for band in 0..<3 {
                let filtered = filters[band]?.apply(input: chunk) ?? chunk
                pending[band].append(contentsOf: filtered)
                let whole = pending[band].count / hop
                if whole > 0 {
                    pending[band].withUnsafeBufferPointer { pointer in
                        for i in 0..<whole {
                            envelopes[band].append(vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: pointer[(i * hop)..<((i + 1) * hop)])))
                        }
                    }
                    pending[band].removeFirst(whole * hop)
                }
            }
            if frames < Int(chunkFrames) { break }
        }

        // 밴드마다 99.5 백분위수를 최대로 잡아 양자화한다(드문 피크가 전체를 납작하게 만들지 않도록).
        func quantize(_ values: [Float]) -> [UInt8] {
            guard !values.isEmpty else { return [] }
            let sorted = values.sorted()
            let ceiling = max(sorted[Int(Double(sorted.count - 1) * 0.995)], 1e-6)
            return values.map { UInt8(min(255, $0 / ceiling * 255)) }
        }
        return Waveform(rate: sampleRate / Double(hop), duration: Double(totalFrames) / sampleRate,
                        low: quantize(envelopes[0]), mid: quantize(envelopes[1]), high: quantize(envelopes[2]))
    }

    private static func makeBiquad(_ sections: [Biquad]) -> vDSP.Biquad<Float>? {
        vDSP.Biquad(coefficients: sections.flatMap(\.coefficients), channelCount: 1,
                    sectionCount: vDSP_Length(sections.count), ofType: Float.self)
    }

    /// RBJ 쿡북 2차 필터를 직렬로 적용한다.
    static func filter(_ signal: [Float], sections: [Biquad]) -> [Float] {
        let coefficients = sections.flatMap(\.coefficients)
        guard var biquad = vDSP.Biquad(coefficients: coefficients, channelCount: 1,
                                       sectionCount: vDSP_Length(sections.count), ofType: Float.self)
        else { return signal }
        return biquad.apply(input: signal)
    }

    struct Biquad {
        let coefficients: [Double]

        static func lowPass(_ frequency: Double, _ sampleRate: Double, q: Double = 0.7071) -> Biquad {
            let w0 = 2 * .pi * frequency / sampleRate, alpha = sin(w0) / (2 * q), c = cos(w0)
            return normalized(b: [(1 - c) / 2, 1 - c, (1 - c) / 2], a: [1 + alpha, -2 * c, 1 - alpha])
        }

        static func highPass(_ frequency: Double, _ sampleRate: Double, q: Double = 0.7071) -> Biquad {
            let w0 = 2 * .pi * frequency / sampleRate, alpha = sin(w0) / (2 * q), c = cos(w0)
            return normalized(b: [(1 + c) / 2, -(1 + c), (1 + c) / 2], a: [1 + alpha, -2 * c, 1 - alpha])
        }

        /// vDSP 순서: b0, b1, b2, a1, a2 (a0로 정규화)
        static func normalized(b: [Double], a: [Double]) -> Biquad {
            Biquad(coefficients: [b[0] / a[0], b[1] / a[0], b[2] / a[0], a[1] / a[0], a[2] / a[0]])
        }
    }
}

/// 파형은 파일 크기·수정 시각 단위로 디스크에 캐시한다(곡당 약 1초 절약).
public enum WaveformCache {
    public static var directory: URL {
        DJCIdentity.supportDirectory.appending(path: "waveforms")
    }

    public static func load(fileAt url: URL, key: String) throws -> Waveform {
        let cacheURL = directory.appending(path: "\(key)-\(PartAnalyzer.fileStamp(url)).json")
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode(Waveform.self, from: data) {
            return cached
        }
        let waveform = try WaveformAnalyzer.analyze(fileAt: url)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(waveform).write(to: cacheURL, options: .atomic)
        return waveform
    }
}
