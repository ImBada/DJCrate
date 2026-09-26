@testable import DJCrate
import DJCDomain
import Foundation
import Testing

@Suite("설정 저장소")
@MainActor
struct SettingsStoreTests {
    static func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "djc-test-\(UUID().uuidString)")! }

    @Test func 설정을_안_건드린_덱은_예전_기본값으로_시작한다() {
        let audio = FakeDeckAudio()
        let deck = DeckModel(audio: audio, storage: .memory(MemoryDrafts()), runsAnalysis: false)
        #expect(deck.zoomSeconds == 16)
        #expect(deck.waveformColorMode == .threeBand)
        #expect(deck.quantize)
        #expect(deck.carryCues)
        #expect(deck.showSuggestions)
        #expect(deck.volume == 0.9)
        #expect(deck.keyLock)
        #expect(deck.autoGain)
        #expect(deck.gainTarget == -10)
        #expect(deck.peakProtection)
        #expect(deck.gainTrim == 0)
        #expect(deck.useRekordboxGain)
        #expect(!deck.metronome)
        #expect(deck.metronomeVolume == 0.8)
        #expect(deck.idleSeconds == 20)
        #expect(deck.shortcuts == .standard)
        // 오디오 엔진도 예전 상수 그대로 받는다
        #expect(audio.volume == 0.9)
        #expect(audio.keyLock)
        #expect(audio.metronomeVolume == 0.8)
        #expect(audio.idleSeconds == 20)
    }

    @Test func 예전에_저장한_값을_같은_이름으로_읽는다() {
        let defaults = Self.freshDefaults()
        defaults.set(false, forKey: "deck.quantize")
        defaults.set(0.5, forKey: "deck.volume")
        defaults.set(-12.0, forKey: "deck.gainTarget")
        defaults.set(["a", "b"], forKey: "deck.dismissedGainSuggestions")
        let storage = DeckStorage.memory(MemoryDrafts(), settings: SettingsStore(defaults: defaults, persist: true))
        let deck = DeckModel(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)
        #expect(!deck.quantize)
        #expect(deck.volume == 0.5)
        #expect(deck.gainTarget == -12)
        #expect(deck.dismissedGainSuggestions == ["a", "b"])
    }

    @Test func 바꾼_값은_다시_켜도_남는다() throws {
        let defaults = Self.freshDefaults()
        let storage = DeckStorage.memory(MemoryDrafts(), settings: SettingsStore(defaults: defaults, persist: true))
        let deck = DeckModel(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)
        deck.metronomeVolume = 0.3
        deck.idleSeconds = 60
        deck.carryCues = false
        deck.waveformColorMode = .rgb
        var shortcuts = deck.shortcuts
        try shortcuts.replace(8, with: 7, in: .cue)
        deck.shortcuts = shortcuts

        let audio = FakeDeckAudio()
        let again = DeckModel(audio: audio, storage: storage, runsAnalysis: false)
        #expect(again.metronomeVolume == 0.3)
        #expect(again.idleSeconds == 60)
        #expect(!again.carryCues)
        #expect(again.waveformColorMode == .rgb)
        #expect(again.shortcuts.keys(for: .cue) == [7])
        #expect(audio.metronomeVolume == 0.3)
        #expect(audio.idleSeconds == 60)
    }

    @Test func 설정_창_컨트롤이_같은_값을_다시_넣으면_저장하지_않는다() {
        // 저장해 두면 나중에 기본값이 바뀌어도 옛 기본값에 묶인다.
        let defaults = Self.freshDefaults()
        let storage = DeckStorage.memory(MemoryDrafts(), settings: SettingsStore(defaults: defaults, persist: true))
        let deck = DeckModel(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)
        deck.metronomeVolume = SettingKeys.metronomeVolume.defaultValue
        deck.idleSeconds = SettingKeys.idleSeconds.defaultValue
        #expect(defaults.object(forKey: SettingKeys.metronomeVolume.name) == nil)
        #expect(defaults.object(forKey: SettingKeys.idleSeconds.name) == nil)
    }

    @Test func 덱_설정을_기본값으로_되돌린다() throws {
        let storage = DeckStorage.memory(MemoryDrafts())
        let audio = FakeDeckAudio()
        let deck = DeckModel(audio: audio, storage: storage, runsAnalysis: false)
        deck.quantize = false
        deck.keyLock = false
        deck.metronomeVolume = 0.1
        deck.gainTarget = -14
        deck.volume = 0.5
        deck.resetDeckSettings()
        #expect(deck.quantize)
        #expect(deck.keyLock)
        #expect(deck.metronomeVolume == 0.8)
        #expect(deck.gainTarget == -10)
        #expect(deck.volume == 0.5, "덱에서 바로 만지는 볼륨은 그대로")
        #expect(audio.metronomeVolume == 0.8)
        #expect(audio.keyLock)
        #expect(storage.settings.value(SettingKeys.quantize))
    }

    @Test func 단축키는_바꾼_것만_저장하고_기본으로_돌리면_지운다() throws {
        let defaults = Self.freshDefaults()
        let store = SettingsStore(defaults: defaults, persist: true)
        #expect(store.shortcuts == .standard)
        var shortcuts = DeckShortcuts.standard
        try shortcuts.replace(8, with: 7, in: .cue)
        store.shortcuts = shortcuts
        #expect(defaults.dictionary(forKey: SettingKeys.deckShortcuts) as? [String: [Int]] == ["cue": [7]])
        #expect(SettingsStore(defaults: defaults, persist: true).shortcuts == shortcuts)
        store.shortcuts = .standard
        #expect(defaults.object(forKey: SettingKeys.deckShortcuts) == nil)
    }

    @Test func 자가_테스트는_설정을_읽지도_쓰지도_않는다() throws {
        let defaults = Self.freshDefaults()
        defaults.set(false, forKey: "deck.quantize")
        defaults.set(["cue": [7]], forKey: SettingKeys.deckShortcuts)
        let store = SettingsStore(defaults: defaults, persist: false)
        #expect(store.value(SettingKeys.quantize))
        #expect(store.shortcuts == .standard)
        store.set(SettingKeys.volume, 0.1)
        store.shortcuts = DeckShortcuts(overrides: ["loop": [1]])
        #expect(defaults.object(forKey: "deck.volume") == nil)
        #expect(defaults.dictionary(forKey: SettingKeys.deckShortcuts) as? [String: [Int]] == ["cue": [7]])
    }
}
