import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// 합성 MP3(1초, 44.1kHz, lame 3.100·ffmpeg)로 rekordbox 시간축 보정과 MP3 프레임 읽기를 고정한다.
/// 규칙(150곡 실측, 2026-09-25): LAME 정보 태그 = 프라이밍 + 529 + 1152, ffmpeg 태그 = 프라이밍 + 529, 태그 없음 = 529.
@Suite("MP3 시간축·프레임")
struct Mp3TimelineTests {
    @Test func LAME_태그는_정보_프레임까지_센다() throws {
        let offset = RekordboxTimeline.predictedOffset(url: try TestResources.url("mp3-lame-cbr.mp3"))
        #expect(abs(offset - Double(576 + 529 + 1152) / 44_100) < 1e-9, "\(offset * 1000)ms, 실측 규칙 51.2ms")
    }

    @Test func ffmpeg_태그는_정보_프레임을_세지_않는다() throws {
        let offset = RekordboxTimeline.predictedOffset(url: try TestResources.url("mp3-ffmpeg-cbr.mp3"))
        let priming = try #require(RekordboxTimeline.packetInfo(url: try TestResources.url("mp3-ffmpeg-cbr.mp3"))?.primingFrames)
        #expect(abs(offset - Double(priming + 529) / 44_100) < 1e-9)
        #expect(offset > 0.015 && offset < 0.027, "실측 +16~26ms")
    }

    @Test func 태그_없는_MP3는_디코더_지연만() throws {
        #expect(abs(RekordboxTimeline.predictedOffset(url: try TestResources.url("mp3-notag-cbr.mp3")) - 529.0 / 44_100) < 1e-9)
    }

    @Test func VBR_MP3는_Xing_TOC를_읽는다() throws {
        let vbr = try #require(SeekInfo.mp3Frames(url: try TestResources.url("mp3-lame-vbr.mp3")))
        #expect(vbr.sampleRate == 44_100 && vbr.samplesPerFrame == 1152)
        #expect(vbr.hasInfoFrame && vbr.toc?.count == 100)
        // offsets 첫 칸은 정보(Xing) 프레임 자신이다. Xing이 적은 오디오 프레임 수 = 나머지
        #expect(vbr.xingFrames == vbr.offsets.count - 1)
        #expect(vbr.headerTag == "Xing" && vbr.isVariableBitRate)
        let cbr = try #require(SeekInfo.mp3Frames(url: try TestResources.url("mp3-lame-cbr.mp3")))
        #expect(cbr.hasInfoFrame && cbr.offsets.count > 30)
        #expect(cbr.headerTag == "Info" && !cbr.isVariableBitRate)
        let notag = try #require(SeekInfo.mp3Frames(url: try TestResources.url("mp3-notag-cbr.mp3")))
        #expect(notag.headerTag == nil && !notag.isVariableBitRate, "머리가 없는 CBR은 프레임 길이가 일정하다")
        // CBR은 프레임 간격이 일정하다(128kbps: 417 또는 418바이트)
        let gaps = Set(zip(cbr.offsets.dropFirst(), cbr.offsets).map { $0 - $1 })
        #expect(gaps.isSubset(of: [417, 418]))
    }
}
