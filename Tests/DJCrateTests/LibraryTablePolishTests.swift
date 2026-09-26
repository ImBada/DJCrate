@testable import DJCrate
import AppKit
import DJCDomain
import Testing

@Suite("목록·태그 시트 표")
@MainActor
struct LibraryTablePolishTests {
    @Test func 앨범_아트_머리글은_표가_그리는_텍스트_첨부_이미지를_쓴다() throws {
        let header = TrackColumn.artworkHeader
        let attachment = try #require(header.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.image != nil)
        #expect(header.string == "\u{fffc}")
    }

    @Test func 번호_칸은_네_자리와_여백을_확보한다() throws {
        let spec = try #require(TrackColumn.all.first { $0.id == "index" })
        #expect(spec.minWidth >= 48)
        #expect(spec.width >= spec.minWidth)
    }

    @Test func 시트_칸은_평소_말줄임표와_전체_값_도움말을_쓴다() {
        let cell = SheetCell()
        let value = "열 너비보다 긴 제목을 끝까지 보여 주는 도움말"
        cell.configure(text: value, edited: false, readOnly: false, selected: true, active: true)
        #expect(cell.label.cell?.isScrollable == false)
        #expect(cell.label.lineBreakMode == .byTruncatingTail)
        #expect(cell.toolTip == value)
        cell.beginEditing(text: value)
        #expect(cell.label.cell?.isScrollable == true)
        cell.endEditing()
        #expect(cell.label.cell?.isScrollable == false)
        #expect(cell.label.lineBreakMode == .byTruncatingTail)
    }

    @Test func 저장된_좁은_번호_칸도_다시_넓히고_배율을_따른다() throws {
        let store = LibraryStore(saveTagDrafts: { _ in })
        let coordinator = TrackListCoordinator(store: store)
        let table = NSTableView()
        let column = NSTableColumn(identifier: .init("index"))
        column.minWidth = 30
        column.width = 38
        table.addTableColumn(column)
        coordinator.table = table
        let rows = (0..<10000).map { TrackListTagEditTests.row(String($0)) }
        coordinator.update(rows: rows, edited: [], selection: [], sortOrder: [], snapshotURL: nil, previewRevision: 0)
        #expect(column.width >= 48)
        coordinator.updateTextScale(1.5)
        let width = ("10000" as NSString).size(withAttributes: [.font: TrackTextCell.Fonts(scale: 1.5).digits]).width
        #expect(column.width >= width + 12)
        let cell = try #require(coordinator.tableView(table, viewFor: column, row: 9999) as? TrackTextCell)
        #expect(cell.label.alignment == .right)
        #expect(cell.label.stringValue == "10000")
    }

    @Test func 시트_머리글_정렬은_스토어에_전달된다() throws {
        let store = LibraryStore(saveTagDrafts: { _ in })
        let coordinator = SheetCoordinator(store: store)
        let table = SheetTableView()
        coordinator.table = table
        table.delegate = coordinator
        table.dataSource = coordinator
        for key in TagFields.Key.allCases {
            table.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: false)]
            let sort = try #require(store.sortOrder.first)
            #expect(TrackColumn.sortKey(of: sort.keyPath) == key.rawValue)
            #expect(sort.order == .reverse)
        }
    }

    @Test func 다른_표의_정렬이_시트_머리글로_돌아오고_선택한_곡은_유지된다() {
        let store = LibraryStore(saveTagDrafts: { _ in })
        let coordinator = SheetCoordinator(store: store)
        let table = SheetTableView()
        coordinator.table = table
        table.delegate = coordinator
        table.dataSource = coordinator
        let a = TrackListTagEditTests.row("1", title: "A")
        let b = TrackListTagEditTests.row("2", title: "B")
        coordinator.update(rows: [a, b], revision: 0)
        coordinator.select(CellPosition(row: 0, column: 1), extend: false)
        store.sortOrder = [KeyPathComparator(\TrackRow.title, order: .reverse)]
        coordinator.update(rows: [b, a], revision: 0)
        #expect(coordinator.cursor.row == 1)
        #expect(table.sortDescriptors.first?.key == "title")
        #expect(table.sortDescriptors.first?.ascending == false)
        // 시트에 없는 칸의 정렬도 유지하되 다른 칸에 화살표를 표시하지 않는다.
        store.sortOrder = [KeyPathComparator(\TrackRow.bpmValue)]
        coordinator.update(rows: [a, b], revision: 0)
        #expect(table.sortDescriptors.isEmpty)
        #expect(store.sortOrder.first?.keyPath == \TrackRow.bpmValue)
    }
}
