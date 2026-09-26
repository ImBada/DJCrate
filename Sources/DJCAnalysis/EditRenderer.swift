import AVFoundation
import DJCDomain
import Foundation

/// 편집 시간표(`TrackEdit`)대로 원본 음원의 프레임을 이어 PCM 파일(WAV·AIFF)로 쓴다.
///
/// 무엇을 어디에 쓸지는 `TrackEdit.frames`(순수, 테스트됨)가 정하고 여기서는 그대로 읽고 쓴다.
/// 원본은 읽기만 하고, 이미 있는 파일은 덮지 않는다. 옆에 임시 파일로 다 쓴 뒤 이름을 바꿔 반쯤 쓴 파일을 남기지 않는다.
public enum EditRenderer {
    public struct Result: Sendable, Equatable {
        public var frames: Int64
        public var sampleRate: Double
        public var channels: Int
        /// 섞은 이음새 수
        public var seams: Int
        public var duration: Double { Double(frames) / sampleRate }
    }

    public static let outputExtensions: Set<String> = ["wav", "aif", "aiff"]

    /// - Parameter sourceOffset: 원본의 rekordbox 시간축 − 음원 시간축(초, `RekordboxTimeline.predictedOffset`)
    public static func render(_ edit: TrackEdit, source: URL, sourceOffset: Double, to output: URL, bitDepth: Int = 16) throws -> Result {
        let rate = try AVAudioFile(forReading: source).processingFormat.sampleRate
        return try render(edit.frames(sampleRate: rate, sourceOffset: sourceOffset), source: source, to: output, bitDepth: bitDepth)
    }

    public static func render(_ spans: [EditFrameSpan], source: URL, to output: URL, bitDepth: Int = 16) throws -> Result {
        let ext = output.pathExtension.lowercased()
        guard outputExtensions.contains(ext) else {
            throw DJCError.editRefused("\(output.lastPathComponent): WAV·AIFF로만 렌더합니다. 확장자를 .wav나 .aiff로 주세요")
        }
        guard bitDepth == 16 || bitDepth == 24 else { throw DJCError.editRefused("비트 수는 16이나 24로 주세요") }
        func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
        guard canonical(output) != canonical(source) else {
            throw DJCError.editRefused("원본 음원에는 쓰지 않습니다. 다른 출력 파일 이름을 주세요")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw DJCError.editRefused("\(output.lastPathComponent)은 이미 있는 파일입니다. 덮지 않으니 다른 이름을 주세요")
        }
        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat
        guard format.channelCount <= 2 else { throw DJCError.editRefused("모노·스테레오 음원만 편집합니다") }

        let partial = output.deletingLastPathComponent().appending(path: ".\(output.deletingPathExtension().lastPathComponent).djc-partial.\(ext)")
        try? FileManager.default.removeItem(at: partial)
        do {
            let result = try write(spans, from: file, to: partial, bitDepth: bitDepth, bigEndian: ext != "wav")
            try FileManager.default.moveItem(at: partial, to: output)
            return result
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    static let chunk: AVAudioFrameCount = 1 << 16

    static func write(_ spans: [EditFrameSpan], from file: AVAudioFile, to url: URL, bitDepth: Int, bigEndian: Bool) throws -> Result {
        let format = file.processingFormat
        let out = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: bitDepth, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: bigEndian,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { out.close() }
        guard let body = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw DJCError.editRefused("렌더 버퍼를 만들지 못했습니다")
        }
        let channels = Int(format.channelCount)
        var written: Int64 = 0
        // 앞 조각 끝(다음 이음새에서 섞을 만큼)을 쓰지 않고 들고 있다.
        var tail: AVAudioPCMBuffer?
        for (index, span) in spans.enumerated() {
            guard span.outputFrame == written + Int64(tail?.frameLength ?? 0) else {
                throw DJCError.editRefused("편집 시간표가 이어지지 않습니다(프레임 \(span.outputFrame))")
            }
            if let held = tail {
                if span.crossfadeFrames > 0 {
                    // 앞 조각 끝은 줄이고 이 조각 바로 앞 원본은 키운다. 이음새(이 조각 첫 프레임)에서 끝난다.
                    let fade = Int(span.crossfadeFrames)
                    try read(file, from: span.sourceFrame - Int64(fade), count: fade, into: body, scratch: scratch)
                    for c in 0..<channels {
                        let a = held.floatChannelData![c], b = body.floatChannelData![c]
                        for k in 0..<fade {
                            let g = (Float(k) + 0.5) / Float(fade)
                            a[k] = a[k] * (1 - g) + b[k] * g
                        }
                    }
                }
                try out.write(from: held)
                written += Int64(held.frameLength)
                tail = nil
            }
            let hold = index + 1 < spans.count ? spans[index + 1].crossfadeFrames : 0
            var position = span.sourceFrame
            var remaining = span.frameCount - hold
            while remaining > 0 {
                let n = Int(min(Int64(chunk), remaining))
                try read(file, from: position, count: n, into: body, scratch: scratch)
                try out.write(from: body)
                written += Int64(n)
                position += Int64(n)
                remaining -= Int64(n)
            }
            if hold > 0 {
                guard let held = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(hold)) else {
                    throw DJCError.editRefused("렌더 버퍼를 만들지 못했습니다")
                }
                try read(file, from: position, count: Int(hold), into: held, scratch: scratch)
                tail = held
            }
        }
        if let held = tail {
            try out.write(from: held)
            written += Int64(held.frameLength)
        }
        return Result(frames: written, sampleRate: format.sampleRate, channels: channels,
                      seams: spans.filter { $0.crossfadeFrames > 0 }.count)
    }

    /// 원본 [from, from + count) 프레임을 `buffer` 앞에 채운다. 음수·길이 밖은 무음이다(곡 머리의 인코더 지연·곡 끝 너머).
    static func read(_ file: AVAudioFile, from: Int64, count: Int, into buffer: AVAudioPCMBuffer, scratch: AVAudioPCMBuffer) throws {
        precondition(count <= Int(buffer.frameCapacity))
        buffer.frameLength = AVAudioFrameCount(count)
        let channels = Int(buffer.format.channelCount)
        for c in 0..<channels { buffer.floatChannelData![c].update(repeating: 0, count: count) }
        var position = max(from, 0)
        let end = min(from + Int64(count), file.length)
        while position < end {
            // 이어 읽을 때는 다시 찾지 않는다(압축 음원은 찾기가 비싸다).
            if file.framePosition != position { file.framePosition = position }
            let want = AVAudioFrameCount(min(Int64(scratch.frameCapacity), end - position))
            do {
                try file.read(into: scratch, frameCount: want)
            } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == eofErr {
                // MP3 길이는 추정값이라 끝 몇 프레임이 모자랄 수 있다. 모자란 만큼은 무음이다.
                break
            }
            let got = Int(scratch.frameLength)
            guard got > 0 else { break }
            let offset = Int(position - from)
            for c in 0..<channels {
                (buffer.floatChannelData![c] + offset).update(from: scratch.floatChannelData![c], count: got)
            }
            position += Int64(got)
        }
    }
}
