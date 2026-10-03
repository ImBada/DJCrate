#if DEBUG
@testable import DJCrate
import DJCDomain
import DJCTestSupport
import Foundation
import Testing

@MainActor
@Suite("키 전달 진단 준비")
struct KeyRoutingPreparationTests {
    @Test func 설정_저장을_끄는_자가_테스트에서도_태그_보기는_전환된다() throws {
        let domain = "djc-key-preparation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, persist: false)
        DevSelfTests.setKeyRoutingSheetMode(true, settings: settings)
        #expect(defaults.bool(forKey: SettingKeys.sheetMode.name))
        DevSelfTests.setKeyRoutingSheetMode(false, settings: settings)
        #expect(!defaults.bool(forKey: SettingKeys.sheetMode.name))
        #expect(!settings.persist)
    }

    @Test func 합성_정상_곡으로_편집_창의_확대를_준비할_수_있다() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-key-preparation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try AsyncGuidanceFixtureCapture.make(in: home)
        let root = home.appending(path: "rekordbox")
        let store = LibraryStore(draftHome: home.appending(path: "drafts"))
        store.rekordboxDatabase = root.appending(path: "master.db")
        store.rekordboxShareRoot = root.appending(path: "share")
        await store.load(snapshot: store.rekordboxDatabase)
        let row = try #require(store.rowsByID["1"])
        let audio = FakeDeckAudio()
        audio.trackLength = 20
        let deck = DeckModel(audio: audio, storage: .memory(MemoryDrafts()), runsAnalysis: false)
        deck.load(row)
        await deck.loadTask?.value
        deck.apply(DeckPayload.load(track: row.track, cues: row.cues, duration: 20,
                                   storage: deck.storage, analysisRoot: root.appending(path: "share")))
        let model = try #require(TrackEditModel(deck: deck, audio: FakeEditAudio(), home: home))
        defer { model.close() }
        #expect(deck.hasRekordboxGrid)
        #expect(model.blockedReason == nil)
        let before = model.sourceView
        #expect(TrackEditCommand.zoom(in: true).perform(on: model))
        #expect(model.sourceView != before)
    }
}
#endif
