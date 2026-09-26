import AnicueDomain
import Foundation

/// rekordbox가 큐 행에 적는 파일 탐색 위치.
///
/// - FLAC: `InPointSeekInfo = "<프레임 시작 샘플>,<프레임 바이트 위치>,<블록 크기>"`(큐 지점이 든 FLAC 프레임)
/// - VBR MP3: `InMpegFrame`(1/75초 단위)·`InMpegAbs`(큐 지점이 든 MPEG 프레임의 바이트 위치)
/// 규칙은 라이브러리에 이미 있는 rekordbox 큐와 전수 대조해 확인한다(`anicue seekinfo-check`).
public enum SeekInfo {
    // MARK: - FLAC

    public struct FlacFrame: Hashable, Sendable {
        public var startSample: Int
        public var offset: Int
        public var blockSize: Int
    }

    /// FLAC 파일의 오디오 프레임 표(시작 샘플·바이트 위치·블록 크기). 형식이 아니면 nil.
    public static func flacFrames(url: URL) -> (sampleRate: Int, frames: [FlacFrame])? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { raw -> (Int, [FlacFrame])? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var p = id3v2Length(bytes)
            guard p + 4 <= n, bytes[p] == 0x66, bytes[p + 1] == 0x4C, bytes[p + 2] == 0x61, bytes[p + 3] == 0x43 else { return nil }
            p += 4
            // 메타데이터 블록
            var sampleRate = 0, minBlock = 0, maxBlock = 0
            while p + 4 <= n {
                let last = bytes[p] & 0x80 != 0
                let type = bytes[p] & 0x7F
                let length = Int(bytes[p + 1]) << 16 | Int(bytes[p + 2]) << 8 | Int(bytes[p + 3])
                if type == 0, p + 4 + 18 <= n {
                    let s = p + 4
                    minBlock = Int(bytes[s]) << 8 | Int(bytes[s + 1])
                    maxBlock = Int(bytes[s + 2]) << 8 | Int(bytes[s + 3])
                    sampleRate = Int(bytes[s + 10]) << 12 | Int(bytes[s + 11]) << 4 | Int(bytes[s + 12]) >> 4
                }
                p += 4 + length
                if last { break }
            }
            guard sampleRate > 0, maxBlock > 0 else { return nil }
            // 오디오 프레임: 싱크(0xFFF8/0xFFF9) + 헤더 CRC-8이 맞고, 번호가 이어지는 것만 받는다.
            var frames: [FlacFrame] = []
            var expected = 0
            var q = p
            while q + 6 <= n {
                if bytes[q] == 0xFF, bytes[q + 1] & 0xFE == 0xF8,
                   let header = parseFlacHeader(bytes, at: q, fixedBlock: minBlock == maxBlock ? maxBlock : nil),
                   header.startSample == expected || frames.isEmpty {
                    frames.append(FlacFrame(startSample: header.startSample, offset: q, blockSize: header.blockSize))
                    expected = header.startSample + header.blockSize
                    q += header.length + 1
                } else {
                    q += 1
                }
            }
            return frames.isEmpty ? nil : (sampleRate, frames)
        }
    }

    /// `sample`이 든 프레임의 SeekInfo 문자열
    public static func flacSeekInfo(frames: [FlacFrame], sample: Int) -> String? {
        var lo = 0, hi = frames.count - 1
        guard hi >= 0, sample >= 0 else { return nil }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if frames[mid].startSample <= sample { lo = mid } else { hi = mid - 1 }
        }
        let frame = frames[lo]
        guard sample < frame.startSample + frame.blockSize else { return nil }
        // 바이트 위치는 첫 오디오 프레임부터 센다(메타데이터·앨범 아트 제외).
        return "\(frame.startSample),\(frame.offset - frames[0].offset),\(frame.blockSize)"
    }

    struct FlacHeader {
        var startSample: Int
        var blockSize: Int
        var length: Int
    }

    static func parseFlacHeader(_ b: UnsafeBufferPointer<UInt8>, at start: Int, fixedBlock: Int?) -> FlacHeader? {
        let n = b.count
        let variable = b[start + 1] & 0x01 == 1
        let blockCode = Int(b[start + 2] >> 4)
        let rateCode = Int(b[start + 2] & 0x0F)
        let channels = Int(b[start + 3] >> 4)
        let sizeCode = Int((b[start + 3] >> 1) & 0x07)
        guard blockCode != 0, rateCode != 15, channels < 11, sizeCode != 3, b[start + 3] & 0x01 == 0 else { return nil }
        var p = start + 4
        // UTF-8처럼 부호화한 프레임 번호(고정 블록) 또는 샘플 번호(가변 블록)
        guard p < n else { return nil }
        let first = b[p]
        var extra = 0
        var value: Int
        if first & 0x80 == 0 { value = Int(first) }
        else if first & 0xE0 == 0xC0 { extra = 1; value = Int(first & 0x1F) }
        else if first & 0xF0 == 0xE0 { extra = 2; value = Int(first & 0x0F) }
        else if first & 0xF8 == 0xF0 { extra = 3; value = Int(first & 0x07) }
        else if first & 0xFC == 0xF8 { extra = 4; value = Int(first & 0x03) }
        else if first & 0xFE == 0xFC { extra = 5; value = Int(first & 0x01) }
        else if first == 0xFE { extra = 6; value = 0 }
        else { return nil }
        guard p + extra < n else { return nil }
        for i in 1...max(extra, 1) where extra > 0 {
            let c = b[p + i]
            guard c & 0xC0 == 0x80 else { return nil }
            value = value << 6 | Int(c & 0x3F)
        }
        p += 1 + extra
        var blockSize: Int
        switch blockCode {
        case 1: blockSize = 192
        case 2...5: blockSize = 576 << (blockCode - 2)
        case 6: guard p < n else { return nil }; blockSize = Int(b[p]) + 1; p += 1
        case 7: guard p + 1 < n else { return nil }; blockSize = (Int(b[p]) << 8 | Int(b[p + 1])) + 1; p += 2
        default: blockSize = 256 << (blockCode - 8)
        }
        switch rateCode {
        case 12: p += 1
        case 13, 14: p += 2
        default: break
        }
        guard p < n else { return nil }
        var crc: UInt8 = 0
        for i in start..<p {
            crc ^= b[i]
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        guard crc == b[p] else { return nil }
        let startSample = variable ? value : value * (fixedBlock ?? blockSize)
        return FlacHeader(startSample: startSample, blockSize: blockSize, length: p + 1 - start)
    }

    // MARK: - MP3

    public struct Mp3Frames: Sendable {
        public var sampleRate: Int
        public var samplesPerFrame: Int
        /// 오디오 프레임 바이트 위치(Xing/Info 머리 프레임 포함 여부는 `hasInfoFrame`)
        public var offsets: [Int]
        public var hasInfoFrame: Bool
        /// Xing/Info 머리: 프레임 수·바이트 수·목차(100칸)
        public var xingFrames: Int?
        public var xingBytes: Int?
        public var toc: [UInt8]?
        /// 첫 프레임 머리 표시("Xing" = VBR, "Info" = CBR, "VBRI" = VBR)
        public var headerTag: String?

        /// 가변 비트레이트인지: Xing·VBRI 머리가 있거나, 프레임 길이가 패딩(1바이트)보다 크게 달라진다.
        /// rekordbox는 VBR을 BitRate 0으로도, 첫 프레임 비트레이트(예: 32)로도 적어서 DB 값만으로는 가릴 수 없다.
        public var isVariableBitRate: Bool {
            if headerTag == "Xing" || headerTag == "VBRI" { return true }
            let audio = hasInfoFrame ? Array(offsets.dropFirst()) : offsets
            let lengths = zip(audio.dropFirst(), audio).map { $0 - $1 }
            guard let low = lengths.min(), let high = lengths.max() else { return false }
            return high - low > 1
        }
    }

    /// MPEG 오디오 프레임 표(ID3v2 뒤부터, 헤더가 이어지는 프레임만).
    public static func mp3Frames(url: URL) -> Mp3Frames? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { raw -> Mp3Frames? in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            var p = id3v2Length(b)
            var offsets: [Int] = []
            var sampleRate = 0, samplesPerFrame = 0
            var hasInfo = false
            var xingFrames: Int?, xingBytes: Int?, toc: [UInt8]?
            var headerTag: String?
            while p + 4 <= n {
                guard let frame = mpegFrame(b, at: p) else {
                    // 첫 프레임을 찾을 때만 한 바이트씩 넘긴다. 도중에 끊기면 끝(뒤쪽 태그 등)
                    if offsets.isEmpty { p += 1; continue }
                    break
                }
                if offsets.isEmpty {
                    // 다음 프레임도 맞아야 진짜 시작으로 본다.
                    guard p + frame.length + 4 <= n, mpegFrame(b, at: p + frame.length) != nil else { p += 1; continue }
                    sampleRate = frame.sampleRate
                    samplesPerFrame = frame.samplesPerFrame
                    let side = frame.sideInfo
                    let tag = p + 4 + side
                    if tag + 4 <= n {
                        let word = String(bytes: [b[tag], b[tag + 1], b[tag + 2], b[tag + 3]], encoding: .ascii)
                        hasInfo = word == "Xing" || word == "Info"
                        if hasInfo { headerTag = word }
                        if hasInfo, tag + 8 <= n {
                            func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
                            let flags = u32(tag + 4)
                            var q = tag + 8
                            if flags & 1 != 0, q + 4 <= n { xingFrames = u32(q); q += 4 }
                            if flags & 2 != 0, q + 4 <= n { xingBytes = u32(q); q += 4 }
                            if flags & 4 != 0, q + 100 <= n { toc = (0..<100).map { b[q + $0] }; q += 100 }
                        }
                    }
                    // Fraunhofer VBRI 머리는 프레임 머리 뒤 32바이트에 있다.
                    let vbri = p + 4 + 32
                    if !hasInfo, vbri + 4 <= n, [b[vbri], b[vbri + 1], b[vbri + 2], b[vbri + 3]] == [0x56, 0x42, 0x52, 0x49] {
                        headerTag = "VBRI"
                    }
                }
                offsets.append(p)
                p += frame.length
            }
            return offsets.isEmpty ? nil : Mp3Frames(sampleRate: sampleRate, samplesPerFrame: samplesPerFrame,
                                                     offsets: offsets, hasInfoFrame: hasInfo,
                                                     xingFrames: xingFrames, xingBytes: xingBytes, toc: toc, headerTag: headerTag)
        }
    }

    struct MpegFrame {
        var length: Int
        var sampleRate: Int
        var samplesPerFrame: Int
        var sideInfo: Int
    }

    static func mpegFrame(_ b: UnsafeBufferPointer<UInt8>, at p: Int) -> MpegFrame? {
        guard p + 4 <= b.count, b[p] == 0xFF, b[p + 1] & 0xE0 == 0xE0 else { return nil }
        let version = Int((b[p + 1] >> 3) & 0x03)   // 0: 2.5, 2: 2, 3: 1
        let layer = Int((b[p + 1] >> 1) & 0x03)     // 1: III
        let bitrateIndex = Int(b[p + 2] >> 4)
        let rateIndex = Int((b[p + 2] >> 2) & 0x03)
        let padding = Int((b[p + 2] >> 1) & 0x01)
        let mono = (b[p + 3] >> 6) == 3
        guard version != 1, layer == 1, bitrateIndex != 0, bitrateIndex != 15, rateIndex != 3 else { return nil }
        let mpeg1 = version == 3
        let bitrates1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        let bitrates2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let bitrate = (mpeg1 ? bitrates1 : bitrates2)[bitrateIndex] * 1000
        let rates = [44_100, 48_000, 32_000][rateIndex]
        let sampleRate = mpeg1 ? rates : version == 2 ? rates / 2 : rates / 4
        let samples = mpeg1 ? 1152 : 576
        let length = samples / 8 * bitrate / sampleRate + padding
        let side = mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
        guard length > 4 else { return nil }
        return MpegFrame(length: length, sampleRate: sampleRate, samplesPerFrame: samples, sideInfo: side)
    }

    /// ID3v2 태그 길이(없으면 0)
    static func id3v2Length(_ b: UnsafeBufferPointer<UInt8>) -> Int {
        guard b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return 0 }
        let size = Int(b[6] & 0x7F) << 21 | Int(b[7] & 0x7F) << 14 | Int(b[8] & 0x7F) << 7 | Int(b[9] & 0x7F)
        let footer = b[5] & 0x10 != 0 ? 10 : 0
        return 10 + size + footer
    }
}
