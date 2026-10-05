@testable import DJCrate
import AppKit
import DJCDomain
import Foundation
import Testing

/// 곡 목록의 키 칸(#204): 키 초안을 다른 태그 칸처럼 보이고, 태그 시트처럼 없음·Camelot 24개 메뉴로만 고친다.
@Suite("곡 목록 키 초안·고르기")
@MainActor
struct TrackListKeyEditTests {
    @Test func 키_초안은_목록에_값과_표식으로_보이고_되돌리면_원래_값이다() throws {
        let row = MusicalKeyEditingTests.row("1", key: "5A")
        let h = ListHarness(rows: [row], selection: [row.id], showKey: true)
        defer { h.close() }
        let cell = try #require(h.cell(row: 0, column: "key"))
        #expect(cell.text == "5A" && !cell.showsDraftMark)
        h.store.setTag(.musicalKey, "8A", rows: [row])
        h.coordinator.updateTagRevision(h.store.tagRevision)
        #expect(cell.text == "8A" && cell.showsDraftMark)
        #expect(cell.label.accessibilityValue() == "8A, 초안")
        h.undo.undo()
        h.coordinator.updateTagRevision(h.store.tagRevision)
        #expect(cell.text == "5A" && !cell.showsDraftMark)
        h.store.setTag(.musicalKey, "", rows: [row])
        h.coordinator.updateTagRevision(h.store.tagRevision)
        #expect(cell.text.isEmpty && cell.showsDraftMark)
    }

    @Test func 추가한_곡은_키를_고르기_전까지_다른_초안이_있어도_추정_표시를_유지한다() throws {
        var row = MusicalKeyEditingTests.row("1", key: "8A", staged: true)
        row.keyEstimated = true
        let h = ListHarness(rows: [row], selection: [row.id], showKey: true)
        defer { h.close() }
        h.store.setTag(.title, "새 제목", rows: [row])
        h.coordinator.updateTagRevision(h.store.tagRevision)
        let cell = try #require(h.cell(row: 0, column: "key"))
        #expect(cell.text == "8A" && !cell.showsDraftMark)
        #expect(cell.label.accessibilityValue() == "8A, 추정")
        // 추가한 곡의 기준 키는 빈칸이라 메뉴는 "없음"에 체크한다(제안은 고른 값이 아니다, #5)
        let menu = try #require(h.coordinator.keyMenu(row: 0))
        #expect(menu.items.first { $0.state == .on }?.title == "없음")
        try choose("8A", menu: menu)
        #expect(h.store.confirmedStagedKey(uuid: row.track.uuid) == "8A")
        #expect(cell.text == "8A" && cell.showsDraftMark)
        #expect(cell.label.accessibilityValue() == "8A, 초안")
    }

    /// 덱 제안 줄의 [적용]으로 생긴 키 초안도 목록 칸에 초안으로 보인다.
    @Test func 덱_제안_적용으로_생긴_키_초안도_목록에_보인다() throws {
        let suite = "djc.test.list-key-suggestion.\(UUID())"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LibraryStore(settings: SettingsStore(defaults: try #require(UserDefaults(suiteName: suite))), saveTagDrafts: { _ in })
        let row = MusicalKeyEditingTests.row("1")
        let h = ListHarness(rows: [row], selection: [row.id], store: store, showKey: true)
        defer { h.close() }
        let cell = try #require(h.cell(row: 0, column: "key"))
        #expect(cell.text.isEmpty && !cell.showsDraftMark)
        store.applyKeySuggestion(estimate: "8B", rows: [row])
        h.coordinator.updateTagRevision(store.tagRevision)
        #expect(cell.text == "8B" && cell.showsDraftMark)
    }

    // MARK: - 여는 길

    @Test func Return은_키_칸을_누른_뒤에만_키_메뉴를_열고_취소는_초안을_만들지_않는다() throws {
        let row = MusicalKeyEditingTests.row("1", key: "Em")
        let h = ListHarness(rows: [row], selection: [row.id], showKey: true)
        defer { h.close() }
        var opened: NSMenu?
        h.coordinator.presentKeyMenu = { menu, _, _ in opened = menu }
        // 키 칸을 누르지 않았으면 Return은 지금처럼 보이는 첫 글자 칸(제목)을 고친다(#88)
        h.pressReturn()
        #expect(opened == nil && h.coordinator.editingColumn == "title")
        h.command(#selector(NSResponder.cancelOperation(_:)))
        h.coordinator.clickedColumnID = "key"
        h.pressReturn()
        let menu = try #require(opened)
        #expect(h.editor == nil && !h.coordinator.isEditing)
        #expect(h.store.tagDrafts.isEmpty && !h.undo.canUndo)
        #expect(menu.items.filter(\.isEnabled).map(\.title) == ["없음"] + KeyNotation.camelotNames)
        // 옛 표기는 지금 값으로 보이기만 하고 고를 수 없다(태그 시트와 같다)
        #expect(menu.items.first?.title == "Em" && menu.items.first?.isEnabled == false && menu.items.first?.state == .on)
        h.coordinator.cancelEditing()
        #expect(h.store.tagDrafts.isEmpty && h.window.firstResponder === h.table)
        try choose("8A", menu: menu)
        #expect(h.store.tagCell(row, .musicalKey) == "8A")
        // 다른 칸을 누르면 Return은 다시 제목부터다
        opened = nil
        h.coordinator.clickedColumnID = "artist"
        h.pressReturn()
        #expect(opened == nil && h.coordinator.editingColumn == "title")
        h.command(#selector(NSResponder.cancelOperation(_:)))
    }

    @Test func Return과_Tab의_글자_칸_흐름은_키_칸을_건너뛴다() {
        let order = ["index", "title", "artist", "key", "comment"]
        #expect(TrackListTagEditing.firstColumn(in: ["index", "key", "title"]) == "title")
        #expect(TrackListTagEditing.firstColumn(in: order, clicked: "key") == "key")
        #expect(TrackListTagEditing.firstColumn(in: order, clicked: "artist") == "title")
        #expect(TrackListTagEditing.firstColumn(in: ["title"], clicked: "key") == "title")
        // 글자 칸이 하나도 보이지 않으면 키 칸이라도 고친다
        #expect(TrackListTagEditing.firstColumn(in: ["index", "bpm", "key"]) == "key")
        #expect(TrackListTagEditing.column(after: "artist", forward: true, in: order) == "comment")
        #expect(TrackListTagEditing.column(after: "comment", forward: false, in: order) == "artist")
        #expect(TrackListTagEditing.column(after: "key", forward: true, in: order) == nil)
    }

    @Test func Tab은_키_칸에서_메뉴를_열지_않고_다음_글자_칸으로_간다() {
        let row = MusicalKeyEditingTests.row("1", key: "5A")
        let h = ListHarness(rows: [row], selection: [row.id], showKey: true)
        defer { h.close() }
        var opened = 0
        h.coordinator.presentKeyMenu = { _, _, _ in opened += 1 }
        #expect(h.coordinator.beginEditing(row: 0, column: "artist"))
        h.command(#selector(NSResponder.insertTab(_:)))
        #expect(opened == 0 && h.coordinator.editingColumn == "comment")
        h.command(#selector(NSResponder.insertBacktab(_:)))
        #expect(opened == 0 && h.coordinator.editingColumn == "artist")
        h.command(#selector(NSResponder.cancelOperation(_:)))
        #expect(h.store.tagDrafts.isEmpty)
    }

    /// 고른 줄을 다시 눌러 고치기(#88)는 글자 칸만이다. 키 칸은 메뉴라 클릭 한 번에 저절로 열지 않는다.
    @Test func 다시_누르기는_키_칸에서_메뉴를_예약하지_않는다() {
        let row = MusicalKeyEditingTests.row("1")
        let h = ListHarness(rows: [row], selection: [row.id], showKey: true)
        defer { h.close() }
        h.coordinator.scheduleEdit(row: 0, column: "key", after: .milliseconds(20))
        #expect(!h.coordinator.hasPendingEdit)
        h.coordinator.scheduleEdit(row: 0, column: "title", after: .seconds(60))
        #expect(h.coordinator.hasPendingEdit)
        h.coordinator.cancelPendingEdit()
    }

    @Test func 키_더블클릭은_메뉴를_열고_다른_칸과_고칠_수_없는_곡은_덱에_올린다() {
        let row = MusicalKeyEditingTests.row("1")
        let s = MusicalKeyEditingTests.row("s", streaming: true)
        let h = ListHarness(rows: [row, s], selection: [row.id], showKey: true)
        defer { h.close() }
        var opened = 0
        var loaded: [String?] = []
        h.coordinator.presentKeyMenu = { _, _, _ in opened += 1 }
        h.store.onLoadToDeck = { loaded.append($0?.track.id) }
        h.coordinator.doubleClicked(row: 0, column: "key")
        #expect(opened == 1 && loaded.isEmpty && h.store.tagDrafts.isEmpty)
        h.coordinator.doubleClicked(row: 0, column: "title")
        #expect(opened == 1 && loaded == [row.track.id])
        // 키를 고칠 수 없는 곡(스트리밍·USB)은 경고 대신 다른 칸처럼 덱에 올린다
        h.coordinator.doubleClicked(row: 1, column: "key")
        #expect(opened == 1 && loaded == [row.track.id, s.track.id] && h.store.stagingMessage == nil)
    }

    // MARK: - 고르기 규칙

    @Test func 여러_곡의_키는_선택할_때만_한번에_바꾸고_실행_취소와_복귀를_지원한다() throws {
        let a = MusicalKeyEditingTests.row("1", key: "5A")
        let b = MusicalKeyEditingTests.row("2", key: "8A")
        let s = MusicalKeyEditingTests.row("s", streaming: true)
        let usb = MusicalKeyEditingTests.row(UsbLibraryRows.idPrefix + "u", key: "6A")
        let h = ListHarness(rows: [a, b, s, usb], selection: [a.id, b.id, s.id, usb.id], showKey: true)
        defer { h.close() }
        let menu = try #require(h.coordinator.keyMenu(row: 0))
        // 값이 서로 다르면 어느 항목에도 체크하지 않는다
        #expect(menu.items.allSatisfy { $0.state == .off })
        #expect(h.store.tagDrafts.isEmpty)
        try choose("없음", menu: menu)
        #expect(h.store.tagCell(a, .musicalKey).isEmpty && h.store.tagCell(b, .musicalKey).isEmpty)
        #expect(h.store.tagDrafts.count == 2)
        #expect(h.store.tagDrafts[s.track.uuid] == nil && h.store.tagDrafts[usb.track.uuid] == nil)
        h.undo.undo()
        #expect(h.store.tagDrafts.isEmpty && !h.undo.canUndo)
        h.undo.redo()
        #expect(h.store.tagDrafts.count == 2)
        let single = try #require(h.coordinator.keyMenu(row: 1))
        try choose("12B", menu: single)
        #expect(h.store.tagCell(a, .musicalKey) == "12B" && h.store.tagCell(b, .musicalKey) == "12B")
        // 고른 줄 밖을 누르면 그 곡 하나만
        h.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let outside = try #require(h.coordinator.keyMenu(row: 1))
        try choose("3A", menu: outside)
        #expect(h.store.tagCell(a, .musicalKey) == "12B" && h.store.tagCell(b, .musicalKey) == "3A")
    }

    @Test func 읽기_전용_곡과_쓰기_중에는_메뉴와_선택을_막는다() throws {
        let a = MusicalKeyEditingTests.row("1")
        let s = MusicalKeyEditingTests.row("s", streaming: true)
        let usb = MusicalKeyEditingTests.row(UsbLibraryRows.idPrefix + "u")
        let h = ListHarness(rows: [a, s, usb], selection: [a.id], showKey: true)
        defer { h.close() }
        var opened = 0
        h.coordinator.presentKeyMenu = { _, _, _ in opened += 1 }
        let rows = [a, s, usb]
        for index in [1, 2] {
            #expect(h.coordinator.keyMenu(row: index) == nil)
            h.store.stagingMessage = nil
            #expect(!h.coordinator.beginEditing(row: index, column: "key"))
            #expect(h.store.stagingMessage?.text == KeyPicker.unavailableReason(rows[index]))
        }
        let menu = try #require(h.coordinator.keyMenu(row: 0))
        h.store.isWritingRekordbox = true
        #expect(h.coordinator.keyMenu(row: 0) == nil)
        #expect(!h.coordinator.beginEditing(row: 0, column: "key"))
        try choose("8A", menu: menu)
        #expect(h.store.tagDrafts.isEmpty && opened == 0)
    }

    @Test func 메뉴는_Camelot만_고를_수_있고_같은_값은_초안을_만들지_않는다() throws {
        let row = MusicalKeyEditingTests.row("1", key: "5A")
        let h = ListHarness(rows: [row], selection: [row.id], showKey: true)
        defer { h.close() }
        let menu = try #require(h.coordinator.keyMenu(row: 0))
        #expect(menu.items.filter(\.isEnabled).count == 25)
        for item in menu.items where item.isEnabled {
            #expect(item.title == "없음" || KeyNotation.camelotNames.contains(item.title))
        }
        #expect(menu.items.first { $0.state == .on }?.title == "5A")
        try choose("5A", menu: menu)
        #expect(h.store.tagDrafts.isEmpty && !h.undo.canUndo)
        // 목록에는 글자 입력 칸이 열리지 않는다
        h.coordinator.presentKeyMenu = { _, _, _ in }
        #expect(h.coordinator.beginEditing(row: 0, column: "key"))
        #expect(h.editor == nil && h.coordinator.editingColumn == nil)
    }

    // MARK: - 다른 입력

    /// 메뉴 추적은 AppKit의 별도 루프라 덱 단축키 모니터에 키가 오지 않는다. 그래서 키 전달 규칙은 바꾸지 않는다:
    /// 메뉴를 여는 동안·닫은 뒤 모두 목록이 첫 응답자이고 포커스는 곡 목록 그대로다.
    @Test func 키_메뉴는_키_전달_규칙을_바꾸지_않고_닫으면_목록이_포커스를_가진다() throws {
        let row = MusicalKeyEditingTests.row("1")
        let h = ListHarness(rows: [row], selection: [row.id], showKey: true)
        defer { h.close() }
        var during: (KeyRoutingPolicy.Focus, Bool)?
        h.coordinator.presentKeyMenu = { [unowned h] _, _, _ in
            during = (KeyRouter.focus(in: h.window), h.coordinator.isEditing)
        }
        #expect(h.coordinator.beginEditing(row: 0, column: "key"))
        #expect(during?.0 == .trackList && during?.1 == true)
        #expect(!h.coordinator.isEditing && h.window.firstResponder === h.table)
        #expect(KeyRouter.focus(in: h.window) == .trackList)
        for key in KeyRoutingTests.deckKeys {
            #expect(KeyRoutingPolicy.accepts(key, in: .init(focus: .trackList)))
        }
        // 고른 뒤에도 같다
        let menu = try #require(h.coordinator.keyMenu(row: 0))
        try choose("1B", menu: menu)
        #expect(h.window.firstResponder === h.table && KeyRouter.focus(in: h.window) == .trackList)
    }

    @Test func 키_정렬은_다른_태그_칸처럼_초안_전_값을_쓴다() throws {
        let a = MusicalKeyEditingTests.row("1", key: "1A"), b = MusicalKeyEditingTests.row("2", key: "8A")
        let h = ListHarness(rows: [a, b], selection: [a.id], showKey: true)
        defer { h.close() }
        h.store.setTag(.musicalKey, "12B", rows: [a])
        let sort = try #require(TrackColumn.comparator(key: "key", ascending: true))
        #expect([b, a].sorted(using: sort).map(\.id) == [a.id, b.id])
        #expect(TrackColumn.sortKey(of: sort.keyPath) == "key")
        // 제목도 초안 전 값으로 정렬한다(같은 규칙)
        h.store.setTag(.title, "가", rows: [b])
        let title = try #require(TrackColumn.comparator(key: "title", ascending: true))
        #expect([b, a].sorted(using: title).map(\.id) == [a.id, b.id])
    }

    private func choose(_ title: String, menu: NSMenu) throws {
        let item = try #require(menu.items.first { $0.title == title && $0.isEnabled })
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    }
}
