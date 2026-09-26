import AudioToolbox
import DJCDomain
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// rekordbox 7.2.18, 2026-09-27: DJC 실험 ALAC 16/24bit 44100/48000Hz·VBR ffmpeg q2/q8/q5.
/// 실험 음원은 저장소 밖에 두고 합성 파일로 확인한 칸 규칙을 고정한다.
@Suite("ALAC·ffmpeg VBR 분석 골든")
struct AnalysisFormatGoldenTests {
    @Test(arguments: [16, 24], [44_100.0, 48_000.0])
    func ALAC은_코덱으로_형식_6을_고르고_압축_비트레이트를_적는다(bits: Int, rate: Double) async throws {
        let fixture = try RekordboxFixture()
        let url = try AudioFixture.alac(seconds: 2.375, sampleRate: rate, bitDepth: bits, in: fixture.audio)
        let tags = try await AudioTags.read(url: url)
        let plan = try TrackAddPlan.make(url: url, tags: tags)
        let facts = AudioFacts.read(url: url)
        #expect(plan.fileType == 6, "같은 m4a 확장자의 AAC(4)와 구분")
        #expect(facts.unsupported?.contains("카운터") == true)
        #expect(facts.bitDepth == bits && facts.sampleRate == Int(rate))

        var fileID: AudioFileID?
        #expect(AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr)
        let file = try #require(fileID)
        defer { AudioFileClose(file) }
        var bytes: UInt64 = 0, packets: UInt64 = 0
        var size: UInt32 = 8
        #expect(AudioFileGetProperty(file, kAudioFilePropertyAudioDataByteCount, &size, &bytes) == noErr)
        size = 8
        #expect(AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &packets) == noErr)
        // 실험 4개: 195046·234701·901640·984708 bps → 195·234·901·984 kbps.
        // 이 afconvert/macOS ALAC 표본은 패딩까지 포함한 4096샘플 패킷의 평균이다.
        let expected = Int(Double(bytes) * 8 * rate / Double(packets * 4096)) / 1000
        #expect(facts.bitRate == expected)
        #expect(TrackAnalysisFiles.pvbr(facts).dropFirst(12).allSatisfy { $0 == 0 })
        #expect(TrackAnalysisFiles.pvb2(facts) == nil)
        #expect(RekordboxTimeline.predictedOffset(url: url) == 0)
        #expect(RekordboxTimeline.predictedTrailingFrames(url: url) == 0)
        let waves = try RekordboxWaveforms.analyze(url: url)
        #expect(waves.columns == 357, "유효 샘플 길이만 사용하며 ALAC 끝 패딩을 붙이지 않는다")
    }

    @Test func AAC의_m4a_형식_4는_유지한다() async throws {
        let fixture = try RekordboxFixture()
        let url = try AudioFixture.aac(seconds: 1, in: fixture.audio)
        #expect(try await TrackAddPlan.make(url: url, tags: AudioTags.read(url: url)).fileType == 4)
    }

    @Test(arguments: [(44_100, 256), (44_100, 192), (48_000, 224)])
    func ffmpeg_Xing은_정보_프레임을_빼고_첫_음성_비트레이트를_쓴다(sample: (Int, Int)) throws {
        let fixture = try RekordboxFixture()
        let url = try mp3(in: fixture.audio, rate: sample.0, firstBitRate: sample.1, encoder: "Lavc62.28")
        let facts = AudioFacts.read(url: url)
        #expect(facts.unsupported?.contains("카운터") == true && facts.bitRate == sample.1)
        #expect(facts.bitDepth == 16 && facts.sampleRate == sample.0)
        #expect(facts.pvbrTotalSamples == 40 * 1152, "Xing 프레임은 제외")
        #expect(facts.pvbrEntries.count == 400)
        #expect(facts.pvbrEntries.first == 0)
        let counted = try #require(SeekInfo.mp3Frames(url: url)).offsets.dropFirst()
        let last = Array(counted)[32] - counted.first!
        #expect(facts.pvbrEntries.last == UInt32(last), "마지막 탐색 칸은 끝에서 8프레임 앞")
    }

    @Test func Lavf도_첫_음성_프레임_규칙을_쓴다() throws {
        let fixture = try RekordboxFixture()
        let url = try mp3(in: fixture.audio, rate: 44_100, firstBitRate: 160, encoder: "Lavf56.4.")
        let facts = AudioFacts.read(url: url)
        #expect(facts.unsupported?.contains("카운터") == true && facts.bitRate == 160 && facts.pvbrEntries.count == 400)
    }

    @Test func L3_99와_알_수_없는_인코더는_계속_막는다() throws {
        let fixture = try RekordboxFixture()
        for encoder in ["L3.99r1", "unknown"] {
            let url = try mp3(in: fixture.audio, rate: 44_100, firstBitRate: 32, encoder: encoder)
            #expect(AudioFacts.read(url: url).unsupported != nil)
        }
    }

    @Test func 분석_카운터_사본_불일치가_남은_새_형식은_쓰지_않는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let alac = try AudioFixture.alac(seconds: 1, in: fixture.audio)
        let vbr = try mp3(in: fixture.audio, rate: 44_100, firstBitRate: 256, encoder: "Lavc62.28")
        for url in [alac, vbr] {
            let plan = try TrackAddPlan.make(url: url, tags: try await AudioTags.read(url: url))
            let input = RekordboxTrackWriter.Analysis(segments: [.init(start: 0, bpm: 120, firstBeatNumber: 1)], loudness: -10, peak: 1)
            let report = try RekordboxTrackWriter.add([plan], analyses: [plan.path: input], to: fixture.database,
                                                     shareRoot: fixture.shareRoot, dryRun: false, now: .now, backups: fixture.backups)
            #expect(report.added.first?.written == false)
            #expect(report.added.first?.reason?.contains("카운터") == true)
        }
        #expect(try fixture.rows("SELECT ID FROM djmdContent").count == 1)
    }

    @Test func 분석_전_곡에_붙이기도_카운터_검증_전까지_막는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let alac = try AudioFixture.alac(seconds: 1, in: fixture.audio)
        let vbr = try mp3(in: fixture.audio, rate: 48_000, firstBitRate: 224, encoder: "Lavc62.28")
        for url in [alac, vbr] {
            let plan = try TrackAddPlan.make(url: url, tags: try await AudioTags.read(url: url))
            let bare = try RekordboxTrackWriter.add([plan], to: fixture.database, dryRun: false, now: .now, backups: fixture.backups)
            let uuid = try #require(bare.added.first?.uuid)
            let grid = GridDraft(trackUUID: uuid, base: [], segments: [.init(start: 0, bpm: 120, firstBeatNumber: 1)])
            let report = try RekordboxWriter.write(drafts: [], grids: [grid], gains: [:],
                analysisInputs: [uuid: .init(duration: plan.duration, loudness: -10, peak: 1)], to: fixture.database,
                dryRun: false, now: .now, backups: fixture.backups, shareRoot: fixture.shareRoot, attachesAnalysis: true)
            #expect(report.analysisWritten.isEmpty)
            #expect(report.analysisBlocked.first?.reason?.contains("카운터") == true)
            #expect((report.createdFiles ?? []).isEmpty)
            #expect(try fixture.rows("SELECT Analysed FROM djmdContent WHERE UUID = ?", [.text(uuid)]).first?["Analysed"] == "0")
        }
    }

    /// 정보 프레임·서로 다른 길이의 MPEG1 프레임을 칸 단위로 만든다(음원 바이트를 옮기지 않는다).
    private func mp3(in directory: URL, rate: Int, firstBitRate: Int, encoder: String) throws -> URL {
        let bitrates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        let rates = [64, firstBitRate] + (0..<39).map { $0.isMultiple(of: 2) ? 32 : 320 }
        var bytes = Data()
        for (index, bitrate) in rates.enumerated() {
            var frame = [UInt8](repeating: 0, count: 144 * bitrate * 1000 / rate)
            frame[0] = 0xFF; frame[1] = 0xFB
            frame[2] = UInt8(bitrates.firstIndex(of: bitrate)! << 4 | (rate == 48_000 ? 4 : 0))
            if index == 0 {
                frame.replaceSubrange(36..<40, with: "Xing".utf8)
                frame[43] = 15
                frame[47] = 40
                frame.replaceSubrange(156..<156 + encoder.utf8.count, with: encoder.utf8)
            }
            bytes.append(contentsOf: frame)
        }
        let total = UInt32(bytes.count)
        for i in 0..<4 { bytes[48 + i] = UInt8(truncatingIfNeeded: total >> (24 - 8 * i)) }
        let url = directory.appending(path: "ffmpeg-vbr.mp3")
        try bytes.write(to: url)
        return url
    }
}
