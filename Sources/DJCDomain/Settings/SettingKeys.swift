/// 앱 설정 목록(이름·기본값·범위). 이름은 설정 창 전부터 쓰던 UserDefaults 키 그대로라 쓰던 값이 이어진다.
public enum SettingKeys {
    public static let commentPreset = SettingKey("library.commentPreset", CommentPreset.none.rawValue) {
        CommentPreset(rawValue: $0)?.rawValue
    }

    // MARK: 덱

    public static let waveformColorMode = SettingKey("waveform.colorMode", WaveformColorMode.threeBand.rawValue) {
        WaveformColorMode(rawValue: $0)?.rawValue
    }

    /// 파형 확대(화면에 보이는 초)
    public static let zoomSeconds = SettingKey<Double>("deck.zoomSeconds", 16, in: 2...64)
    public static let quantize = SettingKey("deck.quantize", true)
    /// 그리드를 고칠 때 큐도 같은 박을 따라 옮긴다.
    public static let carryCues = SettingKey("deck.carryCues", true)
    /// 메모리 큐 제안 표시
    public static let showSuggestions = SettingKey("deck.showSuggestions", true)
    public static let volume = SettingKey<Double>("deck.volume", 0.9, in: 0...1)
    public static let keyLock = SettingKey("deck.keyLock", true)
    public static let metronomeVolume = SettingKey<Double>("deck.metronomeVolume", 0.8, in: 0...1)
    /// 재생을 멈춘 뒤 오디오 엔진을 끄기까지(초). 짧으면 CPU를 덜 쓰고, 길면 멈춘 뒤 바로 다시 소리가 난다.
    public static let idleSeconds = SettingKey<Double>("deck.idleSeconds", 20, in: 5...300)
    public static let idleSecondsChoices: [Double] = [5, 10, 20, 30, 60, 120, 300]

    // MARK: 게인

    public static let autoGain = SettingKey("deck.autoGain", true)
    /// 오토게인 목표(LUFS)
    public static let gainTarget = SettingKey<Double>("deck.gainTarget", -10, in: -14...(-8))
    public static let gainTargetChoices: [Double] = [-14, -12, -11, -10, -9, -8]
    public static let peakProtection = SettingKey("deck.peakProtection", true)
    /// 수동 트림(dB)
    public static let gainTrim = SettingKey<Double>("deck.gainTrim", 0, in: -12...12)
    public static let useRekordboxGain = SettingKey("deck.useRekordboxGain", true)

    // MARK: 화면 상태(창에서 바로 바꾸는 값)

    public static let waveformHeight = SettingKey<Double>("waveformHeight", 150, in: nil)
    public static let sheetMode = SettingKey("sheetMode", false)
    public static let sidebarPlaylistsExpanded = SettingKey("sidebar.playlistsExpanded", true)
    public static let sidebarSummaryExpanded = SettingKey("sidebar.summaryExpanded", true)
    /// 재생 기록은 날짜마다 한 줄이라 길어서 접어 두고 시작한다.
    public static let sidebarHistoriesExpanded = SettingKey("sidebar.historiesExpanded", false)

    // MARK: 목록·표

    public static let commentClassColumnHidden = SettingKey("library.commentClassColumnHidden", false)

    /// 곡 UUID 모음: 무시한 게인·그리드 제안
    public static let dismissedGainSuggestions = "deck.dismissedGainSuggestions"
    public static let dismissedGridSuggestions = "deck.dismissedGridSuggestions"
    /// 덱 단축키 중 바꾼 동작만(`DeckShortcuts.overrides`)
    public static let deckShortcuts = "shortcuts.deck"

    /// 모든 이름(겹치지 않는지 확인용)
    public static var all: [String] {
        [zoomSeconds.name, volume.name, metronomeVolume.name, idleSeconds.name, gainTarget.name, gainTrim.name,
         waveformHeight.name]
            + [quantize, carryCues, showSuggestions, keyLock, autoGain, peakProtection, useRekordboxGain,
               sheetMode, sidebarPlaylistsExpanded, sidebarSummaryExpanded, sidebarHistoriesExpanded,
               commentClassColumnHidden].map(\.name)
            + [dismissedGainSuggestions, dismissedGridSuggestions, deckShortcuts, waveformColorMode.name, commentPreset.name]
    }
}
