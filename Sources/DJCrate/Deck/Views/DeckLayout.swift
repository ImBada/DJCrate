/// 저장한 파형 높이와 창에 실제로 들어가는 높이를 분리한다.
enum DeckLayout {
    static let defaultWaveformHeight = 150.0
    static let minimumWaveformHeight = 80.0
    static let maximumWaveformHeight = 480.0
    static let minimumLibraryHeight = 150.0
    static let splitHandleHeight = 7.0
    static let minimumDetailWidth = 620.0

    static func waveformHeight(requested: Double, detailHeight: Double,
                               deckChromeHeight: Double, otherHeight: Double) -> Double {
        let available = detailHeight - deckChromeHeight - otherHeight - minimumLibraryHeight
        let upperBound = max(minimumWaveformHeight, min(available, maximumWaveformHeight))
        return min(max(requested, minimumWaveformHeight), upperBound)
    }

    static func deckViewportHeight(contentHeight: Double, detailHeight: Double,
                                   otherHeight: Double) -> Double {
        min(contentHeight, max(0, detailHeight - otherHeight - minimumLibraryHeight))
    }
}
