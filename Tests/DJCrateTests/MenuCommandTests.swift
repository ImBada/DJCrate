@testable import DJCrate
import DJCDomain
import Foundation
import SwiftUI
import Testing

@MainActor
@Suite("메뉴 — 구성·단축키·덱 동작")
struct MenuCommandTests {
    @Test func 덱_메뉴는_단축키_표의_모든_동작을_한번씩_포함한다() {
        let actions = DeckAction.Group.allCases.flatMap { DeckMenuCommand.actions(in: $0) }
        #expect(actions == DeckAction.allCases)
        #expect(Set(actions).count == actions.count)
    }

    @Test func 메뉴의_키_안내는_바꾼_키와_삭제한_키를_따른다() throws {
        var shortcuts = DeckShortcuts.standard
        #expect(DeckMenuCommand.action(.playPause).keyLabel(shortcuts: shortcuts) == "Space")
        try shortcuts.replace(49, with: 35, in: .playPause)
        #expect(DeckMenuCommand.action(.playPause).keyLabel(shortcuts: shortcuts) == "P")
        shortcuts.remove(35, from: .playPause)
        #expect(DeckMenuCommand.action(.playPause).keyLabel(shortcuts: shortcuts).isEmpty)
        try shortcuts.replace(18, with: 7, in: .hotCueA)
        #expect(DeckMenuCommand.deleteHotCue(0).keyLabel(shortcuts: shortcuts) == "⇧X · ⇧숫자패드 1")
        #expect(DeckMenuCommand.moveHotCue(0).keyLabel(shortcuts: shortcuts).isEmpty)
    }

    @Test func 키가_없거나_겹쳐도_메뉴는_고른_동작을_한번만_실행한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.shortcuts.remove(49, from: .playPause)
        let play = DeckMenuCommand.action(.playPause)
        play.perform(on: h.deck)
        #expect(h.deck.isPlaying)
        play.perform(on: h.deck)
        #expect(!h.deck.isPlaying)
        try h.deck.shortcuts.add(46, to: .tapTempo)
        DeckMenuCommand.action(.tapTempo).perform(on: h.deck)
        #expect(h.deck.taps.count == 1)
        #expect(h.deck.draft?.cues.isEmpty == true)
    }

    @Test func 메뉴_CUE는_누르기와_떼기를_마쳐_미리듣기가_남지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(10.5)
        let cue = DeckMenuCommand.action(.cue)
        cue.perform(on: h.deck)
        #expect(h.deck.cuePoint == 10.5)
        cue.perform(on: h.deck)
        #expect(!h.deck.isCuePreviewing)
        #expect(!h.deck.isPlaying)
        h.deck.togglePlay()
        cue.perform(on: h.deck)
        #expect(!h.deck.isPlaying)
    }

    @Test func 핫큐_메뉴는_찍기_옮기기_지우기를_제공한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let move = DeckMenuCommand.moveHotCue(0), delete = DeckMenuCommand.deleteHotCue(0)
        #expect(!move.isEnabled(on: h.deck))
        #expect(!delete.isEnabled(on: h.deck))
        h.deck.seek(10.5)
        DeckMenuCommand.action(.hotCueA).perform(on: h.deck)
        #expect(move.isEnabled(on: h.deck))
        h.deck.seek(20.5)
        move.perform(on: h.deck)
        #expect(h.deck.hotCue(slot: 0)?.time == 20.5)
        delete.perform(on: h.deck)
        #expect(h.deck.hotCue(slot: 0) == nil)
    }

    @Test func 쓰기_중에는_메뉴로_재생하거나_편집할_수_없다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.isWriteLocked = true
        for action in DeckAction.allCases {
            let command = DeckMenuCommand.action(action)
            #expect(!command.isEnabled(on: h.deck))
            command.perform(on: h.deck)
        }
        #expect(!h.deck.isPlaying)
        #expect(h.deck.draft?.cues.isEmpty == true)
        #expect(h.deck.taps.isEmpty)
    }

    @Test func 앱_명령은_파일과_rekordbox_메뉴로_나뉜다() {
        #expect(LibraryMenuAction.fileActions == [.addFiles, .snapshot, .exportXML])
        #expect(LibraryMenuAction.rekordboxActions == [.reflect, .pending, .writeResult, .restore, .removeTracks])
        #expect(LibraryMenuAction.fileActions + LibraryMenuAction.rekordboxActions == LibraryMenuAction.allCases)
    }

    @Test func 앱_명령의_조합_단축키는_서로_겹치지_않는다() {
        #expect(LibraryMenuAction.addFiles.shortcut == KeyboardShortcut("o", modifiers: .command))
        #expect(LibraryMenuAction.snapshot.shortcut == KeyboardShortcut("r", modifiers: .command))
        #expect(LibraryMenuAction.reflect.shortcut == KeyboardShortcut("e", modifiers: [.command, .shift]))
        #expect(LibraryMenuAction.allCases.filter { $0.shortcut != nil } == [.addFiles, .snapshot, .reflect])
    }

    @Test func 빈_라이브러리와_쓰기_잠금에서_명령의_활성_조건을_지킨다() {
        let store = LibraryStore(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in })
        #expect(LibraryMenuAction.snapshot.isEnabled(in: store))
        #expect(!LibraryMenuAction.addFiles.isEnabled(in: store))
        #expect(!LibraryMenuAction.reflect.isEnabled(in: store))
        #expect(!LibraryMenuAction.restore.isEnabled(in: store))
        #expect(!LibraryMenuAction.removeTracks.isEnabled(in: store))
        #expect(!LibraryMenuAction.exportXML.isEnabled(in: store))
        store.phase = .loading("시험")
        #expect(!LibraryMenuAction.snapshot.isEnabled(in: store))
        store.phase = .loaded
        store.isWritingRekordbox = true
        for action in LibraryMenuAction.allCases { #expect(!action.isEnabled(in: store)) }
    }
}
