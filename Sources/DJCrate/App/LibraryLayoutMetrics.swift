import Observation

/// 원시 측정값은 관찰하지 않고, 실제 적용 높이가 바뀔 때만 작은 뷰에 알린다.
@MainActor
@Observable
final class LibraryLayoutMetrics {
    @ObservationIgnored private var requested = DeckLayout.defaultWaveformHeight
    @ObservationIgnored private var detailHeight = 650.0
    @ObservationIgnored private var deckChromeHeight = 240.0
    @ObservationIgnored private var fittedChromeHeight = 240.0
    @ObservationIgnored private var noticeHeight = 0.0
    @ObservationIgnored private var listHeaderHeight = 40.0

    private(set) var waveformHeight = 150.0
    private(set) var maximumWaveformHeight = 213.0
    private(set) var viewportHeight = 390.0

    func request(_ height: Double) { requested = height; update() }
    func measureNotice(_ height: Double) { noticeHeight = height; update() }
    func measureListHeader(_ height: Double) { listHeaderHeight = height; update() }

    func measureDetail(height: Double, deckHeight: Double, waveformHeight: Double, hasTrack: Bool) {
        guard DeckLayout.isDetailMeasurement(height: height) else { return }
        // 곡 로드로 내용이 늘어날 때는 파형을 줄이지 않고, 창 높이가 바뀔 때만 맞춘다(PR #151).
        if hasTrack, abs(detailHeight - height) > 1 { fittedChromeHeight = deckChromeHeight }
        detailHeight = height
        deckChromeHeight = max(0, deckHeight - waveformHeight)
        update()
    }

    private func update() {
        let other = noticeHeight + listHeaderHeight + DeckLayout.splitHandleHeight
        let waveform = DeckLayout.waveformHeight(requested: requested, detailHeight: detailHeight,
                                                 deckChromeHeight: fittedChromeHeight, otherHeight: other)
        let maximum = DeckLayout.waveformHeight(requested: DeckLayout.maximumWaveformHeight, detailHeight: detailHeight,
                                                deckChromeHeight: fittedChromeHeight, otherHeight: other)
        let viewport = DeckLayout.deckViewportHeight(contentHeight: deckChromeHeight + waveform,
                                                     detailHeight: detailHeight, otherHeight: other)
        if waveformHeight != waveform { waveformHeight = waveform }
        if maximumWaveformHeight != maximum { maximumWaveformHeight = maximum }
        if viewportHeight != viewport { viewportHeight = viewport }
    }
}
