@testable import DJCrate
import Observation
import Synchronization
import Testing

@MainActor
@Suite("라이브러리 높이 측정과 적용")
struct LibraryLayoutMetricsTests {
    @Test func 들어맞는_창의_원시_높이는_덱과_파형에_알리지_않는다() {
        let layout = LibraryLayoutMetrics()
        layout.measureDetail(height: 900, deckHeight: 390, waveformHeight: 150, hasTrack: true)
        let changed = Mutex(false)
        withObservationTracking {
            _ = layout.waveformHeight
            _ = layout.viewportHeight
        } onChange: { changed.withLock { $0 = true } }
        for height in stride(from: 900.0, through: 748, by: -8) {
            layout.measureDetail(height: height, deckHeight: 390, waveformHeight: 150, hasTrack: true)
        }
        #expect(!changed.withLock { $0 })
        #expect(layout.waveformHeight == 150)
        #expect(layout.viewportHeight == 390)
        #expect(layout.maximumWaveformHeight == 311)
    }

    @Test func 낮아진_창과_알림과_머리글은_기존_최소_높이_규칙을_쓴다() {
        let layout = LibraryLayoutMetrics()
        layout.request(480)
        layout.measureDetail(height: 650, deckHeight: 390, waveformHeight: 150, hasTrack: true)
        layout.measureNotice(30)
        layout.measureListHeader(60)
        #expect(layout.waveformHeight == DeckLayout.waveformHeight(requested: 480, detailHeight: 650,
                                                                  deckChromeHeight: 240, otherHeight: 97))
        #expect(layout.viewportHeight == 403)
        #expect(650 - layout.viewportHeight - 97 == DeckLayout.minimumLibraryHeight)
        layout.measureDetail(height: 100, deckHeight: 500, waveformHeight: 80, hasTrack: true)
        #expect(layout.viewportHeight == 403)
    }

    @Test func 곡_내용만_늘면_파형을_보존하고_창을_줄였다_키우면_요청값을_복원한다() {
        let layout = LibraryLayoutMetrics()
        layout.measureDetail(height: 1000, deckHeight: 390, waveformHeight: 150, hasTrack: true)
        layout.request(480)
        #expect(layout.waveformHeight == 480)
        layout.measureDetail(height: 1000, deckHeight: 880, waveformHeight: 480, hasTrack: true)
        #expect(layout.waveformHeight == 480)
        layout.measureDetail(height: 650, deckHeight: 880, waveformHeight: 480, hasTrack: true)
        #expect(layout.waveformHeight == 80)
        #expect(layout.viewportHeight == 453)
        layout.measureDetail(height: 1200, deckHeight: 480, waveformHeight: 80, hasTrack: true)
        #expect(layout.waveformHeight == 480)
        #expect(layout.viewportHeight == 880)
    }

    @Test func 같은_값을_반복해도_적용값을_알리지_않는다() {
        let layout = LibraryLayoutMetrics()
        let changed = Mutex(false)
        withObservationTracking {
            _ = layout.waveformHeight
            _ = layout.maximumWaveformHeight
            _ = layout.viewportHeight
        } onChange: { changed.withLock { $0 = true } }
        layout.request(150)
        layout.measureNotice(0)
        layout.measureListHeader(40)
        layout.measureDetail(height: 650, deckHeight: 390, waveformHeight: 150, hasTrack: true)
        #expect(!changed.withLock { $0 })
    }
}
