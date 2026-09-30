@testable import DJCrate
import AppKit
import Testing

@MainActor
struct TrackTableResizeTests {
    private func harness(width: CGFloat = 900) -> ListHarness {
        let h = ListHarness(rows: TrackListReloadTests.rows(1...200), selection: ["5"])
        h.store.selection = ["5"]
        h.table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        h.table.autoresizingMask = [.width]
        for column in h.table.tableColumns {
            column.minWidth = 30
            column.resizingMask = column.identifier.rawValue == "index" ? [.userResizingMask] : [.autoresizingMask, .userResizingMask]
        }
        h.table.enclosingScrollView?.autoresizingMask = [.width, .height]
        resize(h, width: width)
        return h
    }

    private func resize(_ h: ListHarness, width: CGFloat) {
        h.window.setContentSize(NSSize(width: width, height: 300))
        h.window.layoutIfNeeded()
        h.table.enclosingScrollView?.tile()
        h.table.layoutSubtreeIfNeeded()
    }

    private func widths(_ h: ListHarness) -> [CGFloat] { h.table.tableColumns.map(\.width) }

    @Test func 연속_창_조절_중에는_열_너비를_유지한다() throws {
        let h = harness()
        defer { h.close() }
        let original = widths(h)
        h.table.viewWillStartLiveResize()
        for width in [800.0, 700.0, 600.0] {
            resize(h, width: width)
            #expect(widths(h) == original)
        }
        h.table.viewDidEndLiveResize()
    }

    @Test func 놓은_뒤에는_최종_폭의_자동_배치로_돌아온다() {
        let h = harness(), reference = harness()
        defer { h.close(); reference.close() }
        resize(reference, width: 600)
        h.table.viewWillStartLiveResize()
        resize(h, width: 800)
        resize(h, width: 600)
        h.table.viewDidEndLiveResize()
        #expect(h.table.columnAutoresizingStyle == .uniformColumnAutoresizingStyle)
        for (actual, expected) in zip(widths(h), widths(reference)) { #expect(abs(actual - expected) < 1, "열 너비 \(widths(h)) / 기준 \(widths(reference))") }
        #expect(abs(h.table.frame.width - reference.table.frame.width) < 1, "표 폭 \(h.table.frame.width) / 기준 \(reference.table.frame.width)")
        #expect(h.table.selectedRowIndexes == IndexSet(integer: 4))
        #expect(h.store.selection == ["5"])
    }

    @Test func 최소_열_너비보다_창이_좁아져도_끝_열까지_스크롤할_수_있다() {
        let h = harness(), reference = harness()
        defer { h.close(); reference.close() }
        for table in [h.table, reference.table] {
            for column in table.tableColumns where column.identifier.rawValue != "index" { column.minWidth = 120 }
        }
        resize(h, width: 900)
        resize(reference, width: 900)
        resize(reference, width: 500)
        h.table.viewWillStartLiveResize()
        resize(h, width: 500)
        h.table.viewDidEndLiveResize()
        for (actual, expected) in zip(widths(h), widths(reference)) { #expect(abs(actual - expected) < 1, "열 너비 \(widths(h)) / 기준 \(widths(reference))") }
        #expect(abs(h.table.frame.width - reference.table.frame.width) < 1, "표 폭 \(h.table.frame.width) / 기준 \(reference.table.frame.width)")
        #expect(h.table.frame.width >= h.table.rect(ofColumn: h.table.numberOfColumns - 1).maxX)
    }

    @Test func 기본_자동_크기_마스크에서도_최종_열_배치를_복원한다() {
        let h = harness(), reference = harness()
        defer { h.close(); reference.close() }
        h.table.autoresizingMask = []
        reference.table.autoresizingMask = []
        resize(reference, width: 600)
        h.table.viewWillStartLiveResize()
        resize(h, width: 600)
        h.table.viewDidEndLiveResize()
        for (actual, expected) in zip(widths(h), widths(reference)) { #expect(abs(actual - expected) < 1) }
        #expect(abs(h.table.frame.width - reference.table.frame.width) < 1)
    }

    @Test func 원래_고정_열이면_조절_뒤에도_너비와_정책을_유지한다() {
        let h = harness()
        defer { h.close() }
        h.table.columnAutoresizingStyle = .noColumnAutoresizing
        let original = widths(h)
        h.table.viewWillStartLiveResize()
        resize(h, width: 600)
        h.table.viewDidEndLiveResize()
        #expect(widths(h) == original)
        #expect(h.table.columnAutoresizingStyle == .noColumnAutoresizing)
    }

    @Test func 태그_편집과_열_순서는_창_조절_뒤에도_유지한다() {
        let h = harness()
        defer { h.close() }
        h.table.moveColumn(2, toColumn: 1)
        let columns = h.table.tableColumns.map(\.identifier)
        #expect(h.coordinator.beginEditing(row: 4, column: "title"))
        h.type("입력 중인 합성 제목")
        let editor = h.window.firstResponder
        h.table.viewWillStartLiveResize()
        resize(h, width: 600)
        h.table.viewDidEndLiveResize()
        #expect(h.coordinator.isEditing)
        #expect(h.window.firstResponder === editor)
        #expect(h.editor?.string == "입력 중인 합성 제목")
        #expect(h.table.tableColumns.map(\.identifier) == columns)
    }
}

@MainActor
struct TrackTextHeightTests {
    @Test func 같은_글자와_글꼴은_한_번만_측정한다() {
        var height = TrackTextHeight(), calls = 0
        let font = NSFont.systemFont(ofSize: 13)
        for _ in 0..<10 {
            let result = height.value(text: "합성 곡", font: font) { calls += 1; return 18 }
            #expect(result == 18)
        }
        #expect(calls == 1)
    }

    @Test func 글자와_글꼴이_바뀌거나_무효화하면_다시_측정한다() {
        var height = TrackTextHeight(), calls = 0
        let font = NSFont.systemFont(ofSize: 13), larger = NSFont.systemFont(ofSize: 18)
        _ = height.value(text: "합성 곡", font: font) { calls += 1; return 18 }
        #expect(height.value(text: "合成 🎵", font: font) { calls += 1; return 19 } == 19)
        #expect(height.value(text: "合成 🎵", font: larger) { calls += 1; return 24 } == 24)
        height.invalidate()
        #expect(height.value(text: "合成 🎵", font: larger) { calls += 1; return 25 } == 25)
        #expect(calls == 4)
    }
}
