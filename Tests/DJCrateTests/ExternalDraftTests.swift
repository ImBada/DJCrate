@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import Testing

@Suite("외부 초안 다시 읽기")
@MainActor
struct ExternalDraftTests {
    @Test func 저장하지_않은_드래그는_외부_초안이_덮지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let initial = try #require(h.deck.draft)
        h.deck.mutate(save: false) { $0.place(EditableCue(kind: .hot(3), time: 35)) }
        h.deck.reloadExternalCueDraft(initial)
        #expect(h.deck.hotCue(slot: 3)?.time == 35)
    }

    @Test func 파일_생성_수정_삭제가_목록과_덱에_반영된다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let fixture = try RekordboxFixture(), home = fixture.root.appending(path: "home")
        let row = try #require(h.deck.row)
        let store = LibraryStore()
        store.phase = .loaded
        store.rowsByUUID[row.track.uuid] = row
        store.onCueDraftsReloaded = { drafts in h.deck.reloadExternalCueDraft(drafts[row.track.uuid]) }
        store.refreshExternalDrafts(home: home)
        h.deck.seek(20)
        let original = try #require(h.deck.draft)
        var draft = original
        draft.place(EditableCue(kind: .hot(3), time: 30))
        let cueDirectory = home.appending(path: "cue-drafts")
        try CueDraftStore.save(draft, directory: cueDirectory)
        var tag = TagDraft(track: row.track)
        tag.fields.title = "외부 제목"
        try TagDraftStore.save(tag, directory: home.appending(path: "tag-drafts"))
        store.refreshExternalDrafts(home: home)
        #expect(store.pendingUUIDs.contains(row.track.uuid))
        #expect(store.tagDrafts[row.track.uuid]?.fields.title == "외부 제목")
        #expect(h.deck.hotCue(slot: 3)?.time == 30 && h.deck.playhead == 20)
        draft.place(EditableCue(kind: .hot(3), time: 40))
        try CueDraftStore.save(draft, directory: cueDirectory)
        store.refreshExternalDrafts(home: home)
        #expect(h.deck.hotCue(slot: 3)?.time == 40)
        try CueDraftStore.remove(trackUUID: row.track.uuid, directory: cueDirectory)
        try TagDraftStore.remove(trackUUID: row.track.uuid, directory: home.appending(path: "tag-drafts"))
        store.refreshExternalDrafts(home: home)
        #expect(store.pendingUUIDs.isEmpty && store.tagDrafts.isEmpty)
        #expect(h.deck.draft?.hasChanges == false && h.deck.playhead == 20)
    }
}
