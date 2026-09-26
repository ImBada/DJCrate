import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// FLAC을 분석까지 붙여 넣을 때의 음원 정보와 탐색표(PVB2). 규칙은 라이브러리 FLAC 1,083곡 중 1,081곡과 바이트까지 확인(2026-09-26).
@Suite("FLAC 분석 음원 정보")
struct FlacAnalysisTests {
    @Test func STREAMINFO를_읽는다() throws {
        let fixture = try RekordboxFixture()
        let url = try AudioFixture.flac(seconds: 1.5, in: fixture.audio)
        let info = try #require(SeekInfo.flacStreamInfo(url: url))
        #expect(info.sampleRate == 44_100 && info.channels == 2 && info.bitsPerSample == 24, "macOS 인코더는 float 입력을 24비트로 적는다: \(info)")
        let frames = try #require(SeekInfo.flacFrames(url: url)?.frames)
        #expect(info.totalSamples == frames.last!.startSample + frames.last!.blockSize)
    }

    @Test func 탐색표는_k_곱하기_floor_전체의_400분의_1이_든_프레임() throws {
        let fixture = try RekordboxFixture()
        let url = try AudioFixture.flac(seconds: 3, in: fixture.audio)
        let frames = try #require(SeekInfo.flacFrames(url: url)?.frames)
        let total = frames.last!.startSample + frames.last!.blockSize
        let facts = AudioFacts.read(url: url)
        #expect(facts.unsupported == nil && facts.bitRate == 0 && facts.bitDepth == 24 && facts.pvbrTotalSamples == 0)
        #expect(facts.flacTotalSamples == UInt64(total) && facts.flacEntries.count == 400)
        let step = total / 400
        for (k, entry) in facts.flacEntries.enumerated() {
            let frame = try #require(frames.last { $0.startSample <= k * step })
            #expect(entry.startSample == frame.startSample && entry.blockSize == frame.blockSize)
            #expect(entry.offset == frame.offset - frames[0].offset, "첫 프레임 기준 바이트 위치")
        }
        // 바이트: 머리 12 + (u32 0 · u64 전체 · u32 400 · u32 20) + 400칸 × 20
        let tag = try #require(TrackAnalysisFiles.pvb2(facts))
        #expect(tag.count == 32 + 400 * 20)
        #expect(Array(tag.prefix(12)) == Array("PVB2".utf8) + [0, 0, 0, 0x20, 0, 0, 0x1F, 0x60])
        #expect(tag.subdata(in: 16..<24).reduce(0) { $0 << 8 | UInt64($1) } == UInt64(total))
        #expect(Array(tag.subdata(in: 24..<32)) == [0, 0, 1, 0x90, 0, 0, 0, 20])
    }

    @Test func FLAC이_아니면_PVB2가_없다() throws {
        #expect(TrackAnalysisFiles.pvb2(AudioFacts.read(url: try TestResources.url("mp3-lame-cbr.mp3"))) == nil)
    }
}
