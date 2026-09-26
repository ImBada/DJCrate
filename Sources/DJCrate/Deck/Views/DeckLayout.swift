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

    /// 핸들 조절(VoiceOver)·메뉴 '파형 크게·작게' 한 번에 바뀌는 높이
    static let waveformHeightStep = 20.0

    /// 지금 보이는 높이에서 한 칸 키우거나(+1) 줄인다(−1). 저장한 높이가 창보다 커도 보이는 높이에서 움직인다.
    static func steppedWaveformHeight(displayed: Double, direction: Int, maximum: Double) -> Double {
        min(max(displayed + Double(direction) * waveformHeightStep, minimumWaveformHeight), max(maximum, minimumWaveformHeight))
    }

    static func deckViewportHeight(contentHeight: Double, detailHeight: Double,
                                   otherHeight: Double) -> Double {
        min(contentHeight, max(0, detailHeight - otherHeight - minimumLibraryHeight))
    }
}

/// 메뉴 '파형 크게·작게'가 쓰는 파형 높이(보이는 높이·창에 들어가는 최대). 핸들과 같은 규칙으로 바꾼다.
struct WaveformHeightControl {
    var displayed: Double
    var maximum: Double
    var set: (Double) -> Void

    var canGrow: Bool { displayed < maximum - 0.5 }
    var canShrink: Bool { displayed > DeckLayout.minimumWaveformHeight + 0.5 }

    func grow() { set(DeckLayout.steppedWaveformHeight(displayed: displayed, direction: 1, maximum: maximum)) }
    func shrink() { set(DeckLayout.steppedWaveformHeight(displayed: displayed, direction: -1, maximum: maximum)) }
}
