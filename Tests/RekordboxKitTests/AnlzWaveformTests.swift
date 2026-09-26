import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

/// 파형 태그 생성기(RekordboxWaveforms). 규칙 자체는 실제 라이브러리와 `djc lab waveform-eval`로 맞춘다.
@Suite("파형 태그 만들기")
struct AnlzWaveformTests {
    func tone(seconds: Double, hz: Double, amplitude: Float, rate: Double = 44_100) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    @Test func 칸_수와_태그_크기는_rekordbox_모양() throws {
        let w = RekordboxWaveforms.analyze(mono: tone(seconds: 2, hz: 440, amplitude: 0.5), sampleRate: 44_100)
        #expect(w.columns == 300 && w.pwv5.count == 300 && w.pwv7.count == 900)
        #expect((w.pwav.count, w.pwv2.count, w.pwv6.count, w.pwv4.count) == (400, 100, 3600, 7200))
        #expect((w.pwavTag.count, w.pwv2Tag.count, w.pwv3Tag.count, w.pwv5Tag.count) == (420, 120, 24 + 300, 24 + 600))
        #expect((w.pwv4Tag.count, w.pwv7Tag.count, w.pwv6Tag.count, w.pwvcTag.count) == (7224, 24 + 900, 3620, 20))
        #expect(RekordboxWaveforms.body(of: w.pwv3Tag) == w.pwv3)
    }

    @Test func 센_고음은_희고_저음은_어둡고_무음은_0() {
        let high = RekordboxWaveforms.analyze(mono: tone(seconds: 1, hz: 8000, amplitude: 0.8), sampleRate: 48_000)
        #expect(high.pwv3.dropFirst(10).allSatisfy { $0 >> 5 == 7 && $0 & 31 >= 29 })
        let bass = RekordboxWaveforms.analyze(mono: tone(seconds: 1, hz: 60, amplitude: 0.8), sampleRate: 48_000)
        #expect(bass.pwv3.dropFirst(10).allSatisfy { $0 >> 5 <= 1 })
        #expect(bass.pwv7[20 * 3] > bass.pwv7[20 * 3 + 2], "저음은 저역 밴드가 크다")
        let silence = RekordboxWaveforms.analyze(mono: [Float](repeating: 0, count: 44_100), sampleRate: 44_100)
        #expect(silence.pwv3.allSatisfy { $0 == 0xE0 } && silence.gains == [80, 80, 95])
    }

    @Test func DAT를_바탕으로_rekordbox_순서의_EXT와_2EX() throws {
        // .DAT: 경로·큐 목록 태그만 있으면 된다
        let ppth = RekordboxWaveforms.section("PPTH", headerLength: 0x10, RekordboxWaveforms.be32(4) + [0, 0x3F, 0, 0x2F])
        let pcob = { (kind: UInt32) in RekordboxWaveforms.section("PCOB", headerLength: 0x18, RekordboxWaveforms.be32(kind) + [0, 0, 0xFF, 0xFF, 0xFF, 0xFF].map { $0 }) }
        let header = Data([0x50, 0x4D, 0x41, 0x49] + RekordboxWaveforms.be32(0x1C) + RekordboxWaveforms.be32(0) + [0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        let dat = AnlzFile(header: header, tags: [ppth, pcob(1), pcob(0)])
        let w = RekordboxWaveforms.analyze(mono: tone(seconds: 1, hz: 440, amplitude: 0.5), sampleRate: 44_100)
        let (extData, twoData) = try w.files(dat: dat)
        let ext = try AnlzFile(data: extData), two = try AnlzFile(data: twoData)
        #expect(ext.tags.map(\.fourcc) == ["PPTH", "PWV3", "PCOB", "PCOB", "PCO2", "PCO2", "PQT2", "PWV5", "PWV4"])
        #expect(two.tags.map(\.fourcc) == ["PPTH", "PWV7", "PWV6", "PWVC"])
        #expect(ext.tag("PWV3")?.bytes == w.pwv3Tag && ext.header.prefix(8) == header.prefix(8))
        // 빈 PCO2는 rekordbox 7.2 파일과 바이트까지 같다
        #expect(ext.tags.filter { $0.fourcc == "PCO2" }.map { [UInt8]($0.bytes) }
            == [[0x50, 0x43, 0x4F, 0x32, 0, 0, 0, 0x14, 0, 0, 0, 0x14, 0, 0, 0, 1, 0, 0, 0, 0],
                [0x50, 0x43, 0x4F, 0x32, 0, 0, 0, 0x14, 0, 0, 0, 0x14, 0, 0, 0, 0, 0, 0, 0, 0]])
    }
}
