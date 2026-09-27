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
        let undo = UndoManager()
        h.deck.undoManager = undo
        let initial = try #require(h.deck.draft)
        h.deck.mutate(save: false) { $0.place(EditableCue(kind: .hot(3), time: 35)) }
        h.deck.reloadExternalCueDraft(initial)
        #expect(h.deck.hotCue(slot: 3)?.time == 35)
        #expect(h.deck.hasUncommittedCueEdits && h.deck.pendingDraftUndo != nil)
        h.deck.commitDraft()
        undo.undo()
        #expect(h.deck.draft == initial && !h.deck.hasUncommittedCueEdits)
    }

    @Test(arguments: [false, true], [false, true])
    func 외부_태그_변경은_태그_이력만_비운다(undoFirst: Bool, delete: Bool) async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let undo = UndoManager()
        h.deck.undoManager = undo
        var saved: [TagDraft] = []
        let store = LibraryStore(saveTagDrafts: { saved += $0 })
        store.undoManager = undo
        store.phase = .loaded
        let row = try #require(h.deck.row)
        store.rowsByUUID[row.track.uuid] = row
        let home = h.root.appending(path: "home")
        let directory = home.appending(path: "tag-drafts")
        h.deck.pressHotCue(slot: 0)
        store.setTag(.title, "첫 제목", rows: [row])
        store.setTag(.title, "둘째 제목", rows: [row])
        if undoFirst { undo.undo() }
        var external = try #require(store.tagDrafts[row.track.uuid])
        try TagDraftStore.save(external, directory: directory)
        store.refreshExternalDrafts(home: home)
        #expect(undo.undoActionName == "태그 편집" && undo.canRedo == undoFirst)
        let savedCount = saved.count

        if delete {
            try TagDraftStore.remove(trackUUID: row.track.uuid, directory: directory)
        } else {
            external.fields.title = "외부에서 고친 제목"
            try TagDraftStore.save(external, directory: directory)
        }
        store.refreshExternalDrafts(home: home)
        let expected: TagDraft? = delete ? nil : external
        #expect(store.tagDrafts[row.track.uuid] == expected)
        #expect(undo.canUndo && !undo.canRedo)
        undo.undo()
        #expect(h.deck.hotCue(slot: 0) == nil && !undo.canUndo)
        #expect(store.tagDrafts[row.track.uuid] == expected)
        undo.redo()
        #expect(h.deck.hotCue(slot: 0) != nil)
        #expect(store.tagDrafts[row.track.uuid] == expected && saved.count == savedCount)
    }

    @Test(arguments: [false, true], [false, true])
    func 외부_큐_변경은_덱_이력만_비운다(undoFirst: Bool, delete: Bool) async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let undo = UndoManager()
        h.deck.undoManager = undo
        let store = LibraryStore(saveTagDrafts: { _ in })
        store.undoManager = undo
        store.phase = .loaded
        let row = try #require(h.deck.row)
        store.rowsByUUID[row.track.uuid] = row
        store.onCueDraftsReloaded = { drafts in h.deck.reloadExternalCueDraft(drafts[row.track.uuid]) }
        let home = h.root.appending(path: "home")
        let directory = home.appending(path: "cue-drafts")
        store.setTag(.title, "앱에서 고친 제목", rows: [row])
        let tag = try #require(store.tagDrafts[row.track.uuid])
        try TagDraftStore.save(tag, directory: home.appending(path: "tag-drafts"))
        h.deck.pressHotCue(slot: 0)
        h.deck.pressHotCue(slot: 1)
        if undoFirst { undo.undo() }
        var external = try #require(h.deck.draft)
        try CueDraftStore.save(external, directory: directory)
        store.refreshExternalDrafts(home: home)
        #expect(undo.undoActionName == "핫큐 찍기" && undo.canRedo == undoFirst)
        let persisted = h.drafts.cue(row.track.uuid)

        if delete {
            try CueDraftStore.remove(trackUUID: row.track.uuid, directory: directory)
        } else {
            external.place(EditableCue(kind: .hot(3), time: 30))
            try CueDraftStore.save(external, directory: directory)
        }
        store.refreshExternalDrafts(home: home)
        let expected = delete ? CueDraft(trackUUID: row.track.uuid, rekordboxCues: row.cues) : external
        #expect(h.deck.draft == expected)
        #expect(undo.canUndo && !undo.canRedo)
        undo.undo()
        #expect(store.tagDrafts.isEmpty && !undo.canUndo)
        #expect(h.deck.draft == expected)
        undo.redo()
        #expect(store.tagDrafts[row.track.uuid] == tag)
        #expect(h.deck.draft == expected && h.drafts.cue(row.track.uuid) == persisted)
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
