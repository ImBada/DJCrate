@testable import DJCrate
import Testing

@Suite("덱 — 창 크기에 따른 배치")
struct DeckLayoutTests {
    @Test func 낮은_창에서_목록_최소_높이를_남긴다() {
        let height = DeckLayout.waveformHeight(requested: 480, detailHeight: 650,
                                               deckChromeHeight: 190, otherHeight: 40)
        #expect(height == 270)
        #expect(650 - height - 190 - 40 == DeckLayout.minimumLibraryHeight)
    }

    @Test func 창을_다시_키우면_저장한_파형_높이로_돌아온다() {
        let requested = 480.0
        #expect(DeckLayout.waveformHeight(requested: requested, detailHeight: 650,
                                         deckChromeHeight: 190, otherHeight: 40) < requested)
        #expect(DeckLayout.waveformHeight(requested: requested, detailHeight: 900,
                                         deckChromeHeight: 190, otherHeight: 40) == requested)
    }

    @Test(arguments: [-10.0, 80, 150, 480, 700])
    func 파형_높이는_기존_범위_안에_둔다(_ requested: Double) {
        let height = DeckLayout.waveformHeight(requested: requested, detailHeight: 1200,
                                               deckChromeHeight: 190, otherHeight: 40)
        #expect(height == min(max(requested, 80), 480))
    }

    @Test func 컨트롤이_늘어나면_파형을_먼저_줄인다() {
        #expect(DeckLayout.waveformHeight(requested: 480, detailHeight: 650,
                                         deckChromeHeight: 320, otherHeight: 60) == 120)
    }

    @Test func 덱이_최소_파형보다_커도_목록과_핸들은_남긴다() {
        let waveform = DeckLayout.waveformHeight(requested: 480, detailHeight: 650,
                                                 deckChromeHeight: 480, otherHeight: 60)
        #expect(waveform == 80)
        let viewport = DeckLayout.deckViewportHeight(contentHeight: waveform + 480,
                                                     detailHeight: 650, otherHeight: 60)
        #expect(viewport == 440)
        #expect(viewport < waveform + 480)
        #expect(650 - viewport - 60 == DeckLayout.minimumLibraryHeight)
    }
}
