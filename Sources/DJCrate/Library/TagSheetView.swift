import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import SwiftUI

/// 엑셀처럼 셀 단위로 편집하는 태그 시트. 편집은 DJCrate 초안에만 저장된다.
///
/// - 클릭: 셀 선택 / Shift+클릭·드래그: 범위 / 방향키·Tab: 이동(Shift로 범위 확장)
/// - 더블클릭·Return·타이핑: 편집 시작 / Return: 확정 후 아래로 / Tab: 확정 후 오른쪽 / Esc: 취소
/// - 커서 줄은 고른 곡일 뿐 덱은 그대로다. ⌘→·오른쪽 클릭 '덱에 불러오기'로 덱에 올린다(#93)
/// - ⌘C·⌘V: 탭 구분 텍스트(엑셀·구글 시트 호환) / ⌘D: 아래로 채우기 / Delete: 지우기
/// - ⌘Z·⇧⌘Z: 실행 취소·실행 복귀 / ⌘A: 전체 선택
struct TagSheetView: NSViewRepresentable {
    @Bindable var store: LibraryStore

    func makeCoordinator() -> SheetCoordinator { SheetCoordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = SheetTableView()
        table.coordinator = context.coordinator
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.gridColor = .separatorColor
        for column in SheetColumn.all {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 30
            if column.key != nil {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
            }
            table.addTableColumn(tableColumn)
        }
        table.autosaveName = "djc.tagSheet.v1"
        table.autosaveTableColumns = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        context.coordinator.updateTextScale(context.environment.textScale)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.updateTextScale(context.environment.textScale)
        context.coordinator.update(rows: store.displayRows, revision: store.tagRevision)
    }
}

struct SheetColumn {
    let id: String
    let title: String
    let width: CGFloat
    /// nil이면 읽기 전용(복사만 된다).
    let key: TagFields.Key?

    static let all: [SheetColumn] = [
        SheetColumn(id: "index", title: "#", width: 44, key: nil),
        SheetColumn(id: "title", title: String(ui: "제목"), width: 220, key: .title),
        SheetColumn(id: "artist", title: String(ui: "아티스트"), width: 170, key: .artist),
        SheetColumn(id: "album", title: String(ui: "앨범"), width: 170, key: .album),
        SheetColumn(id: "albumArtist", title: String(ui: "앨범 아티스트"), width: 120, key: .albumArtist),
        SheetColumn(id: "genre", title: String(ui: "장르"), width: 90, key: .genre),
        SheetColumn(id: "composer", title: String(ui: "작곡가"), width: 110, key: .composer),
        SheetColumn(id: "year", title: String(ui: "연도"), width: 52, key: .year),
        SheetColumn(id: "trackNumber", title: String(ui: "트랙"), width: 44, key: .trackNumber),
        SheetColumn(id: "comment", title: String(ui: "코멘트"), width: 300, key: .comment),
        SheetColumn(id: "file", title: String(ui: "파일"), width: 220, key: nil),
    ]
}

struct CellPosition: Equatable {
    var row: Int
    var column: Int
}

@MainActor
final class SheetCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let store: LibraryStore
    weak var table: SheetTableView?
    private(set) var rows: [TrackRow] = []
    private var rowIDs: [TrackRow.ID] = []
    private var revision = -1

    var anchor = CellPosition(row: 0, column: 1)
    var cursor = CellPosition(row: 0, column: 1)
    private var editing: CellPosition?
    private var editingOriginal = ""
    private var textScale = 1.0
    private var font = SheetCell.font(scale: 1)
    private var syncingSort = false
    var announce: (String) -> Void = { message in
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    init(store: LibraryStore) {
        self.store = store
    }

    // MARK: - 데이터

    /// 글자 배율(보기 › 글자 크게·작게)이 바뀌면 글자 크기와 줄 높이를 함께 바꾼다.
    func updateTextScale(_ scale: Double) {
        guard scale != textScale, let table else { return }
        textScale = scale
        font = SheetCell.font(scale: scale)
        table.rowHeight = TextScale.length(22, scale: scale)
        reloadVisible()
    }

    func update(rows: [TrackRow], revision: Int) {
        defer { table?.updateFillDownCommand() }
        applySortIndicator()
        let ids = rows.map(\.id)
        if ids != rowIDs {
            // 줄이 바뀌면(필터·정렬·검색) 편집 중인 셀을 먼저 취소한다. 편집 위치가 인덱스라
            // 그대로 확정하면 다른 곡에 들어갈 수 있다.
            if editing != nil { cancelEditing() }
            let anchorID = self.rows.indices.contains(anchor.row) ? self.rows[anchor.row].id : nil
            let cursorID = self.rows.indices.contains(cursor.row) ? self.rows[cursor.row].id : nil
            self.rows = rows
            rowIDs = ids
            self.revision = revision
            // 선택은 곡 ID로 다시 찾는다(없으면 범위 안으로).
            if let cursorID, let index = ids.firstIndex(of: cursorID) { cursor.row = index }
            if let anchorID, let index = ids.firstIndex(of: anchorID) { anchor.row = index } else { anchor = cursor }
            clampSelection()
            table?.reloadData()
            syncAccessibilitySelection(announceFocus: false)
        } else if revision != self.revision {
            self.rows = rows
            self.revision = revision
            reloadVisible()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !syncingSort, let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key, SheetColumn.all.contains(where: { $0.id == key && $0.key != nil }),
              let comparator = TrackColumn.comparator(key: key, ascending: descriptor.ascending) else { return }
        finishEditing(commit: true, then: nil)
        store.sortOrder = [comparator]
    }

    private func applySortIndicator() {
        guard let table else { return }
        let wanted: [NSSortDescriptor] = store.sortOrder.first.flatMap { comparator in
            guard let key = TrackColumn.sortKey(of: comparator.keyPath),
                  SheetColumn.all.contains(where: { $0.id == key && $0.key != nil }) else { return nil }
            return [NSSortDescriptor(key: key, ascending: comparator.order == .forward)]
        } ?? []
        guard table.sortDescriptors != wanted else { return }
        syncingSort = true
        table.sortDescriptors = wanted
        syncingSort = false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = tableView.tableColumns.firstIndex(of: tableColumn) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? SheetCell) ?? {
            let cell = SheetCell()
            cell.identifier = identifier
            return cell
        }()
        let spec = SheetColumn.all[column]
        let position = CellPosition(row: row, column: column)
        if cell.label.font != font { cell.label.font = font }
        cell.configure(text: text(row: row, column: column),
                       edited: spec.key.map { store.isTagEdited(rows[row], $0) } ?? false,
                       readOnly: editableKey(row: row, column: column) == nil,
                       selected: isSelected(position),
                       active: position == cursor)
        cell.label.delegate = self
        cell.label.setAccessibilityLabel(spec.title)
        return cell
    }

    /// 편집 가능한 칸인가. 스트리밍 곡은 파일 태그가 없어 편집하지 않는다.
    func editableKey(row: Int, column: Int) -> TagFields.Key? {
        guard rows.indices.contains(row), !rows[row].track.isStreaming else { return nil }
        return SheetColumn.all[column].key
    }

    func text(row: Int, column: Int) -> String {
        guard rows.indices.contains(row) else { return "" }
        let spec = SheetColumn.all[column]
        if spec.key == .title, rows[row].isEncrypted { return rows[row].title }
        if let key = spec.key { return store.tagCell(rows[row], key) }
        switch spec.id {
        case "index": return "\(row + 1)"
        case "file": return (rows[row].track.folderPath as NSString).lastPathComponent
        default: return ""
        }
    }

    // MARK: - 선택

    var selectionRect: (rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
        (min(anchor.row, cursor.row)...max(anchor.row, cursor.row),
         min(anchor.column, cursor.column)...max(anchor.column, cursor.column))
    }

    func isSelected(_ p: CellPosition) -> Bool {
        let rect = selectionRect
        return rect.rows.contains(p.row) && rect.columns.contains(p.column)
    }

    func select(_ position: CellPosition, extend: Bool) {
        defer { table?.updateFillDownCommand() }
        guard !rows.isEmpty else { return }
        let clamped = CellPosition(row: min(max(position.row, 0), rows.count - 1),
                                   column: min(max(position.column, 0), SheetColumn.all.count - 1))
        cursor = clamped
        if !extend { anchor = clamped }
        table?.scrollRowToVisible(clamped.row)
        table?.scrollColumnToVisible(clamped.column)
        reloadVisible()
        // 커서 줄을 고른 곡으로 둔다(태그 편집 창 등이 따라온다). 덱은 불러오기 명령으로만 바꾼다.
        store.selection = [rows[clamped.row].id]
        syncAccessibilitySelection()
    }

    // MARK: - 덱에 불러오기(#93)

    /// ⌘→: 커서 줄의 곡을 덱에 올린다.
    func loadCursorRow() {
        loadRow(cursor.row)
    }

    /// 오른쪽 클릭 메뉴: 누른 줄의 곡을 덱에 올린다.
    func contextMenu(forRow row: Int) -> NSMenu {
        let menu = NSMenu()
        let load = NSMenuItem(title: String(ui: "덱에 불러오기"), action: rows.indices.contains(row) ? #selector(loadMenuRow(_:)) : nil,
                              keyEquivalent: TrackListCoordinator.loadKey)
        load.keyEquivalentModifierMask = .command
        load.target = self
        load.tag = row
        menu.addItem(load)
        return menu
    }

    @objc private func loadMenuRow(_ sender: NSMenuItem) {
        loadRow(sender.tag)
    }

    private func loadRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        store.loadToDeck(rows[index])
    }

    func move(rows dRow: Int, columns dColumn: Int, extend: Bool) {
        select(CellPosition(row: cursor.row + dRow, column: cursor.column + dColumn), extend: extend)
    }

    func selectAll() {
        defer { table?.updateFillDownCommand() }
        guard !rows.isEmpty else { return }
        anchor = CellPosition(row: 0, column: 0)
        cursor = CellPosition(row: rows.count - 1, column: SheetColumn.all.count - 1)
        reloadVisible()
        syncAccessibilitySelection()
    }

    private func syncAccessibilitySelection(announceFocus: Bool = true) {
        guard let table else { return }
        let indexes = rows.isEmpty ? IndexSet() : IndexSet(integersIn: selectionRect.rows)
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        NSAccessibility.post(element: table, notification: .selectedCellsChanged)
        if announceFocus, !rows.isEmpty,
           let cell = table.accessibilityCell(forColumn: cursor.column, row: cursor.row) {
            NSAccessibility.post(element: cell, notification: .focusedUIElementChanged)
        }
    }

    private func clampSelection() {
        let maxRow = max(rows.count - 1, 0)
        anchor.row = min(anchor.row, maxRow)
        cursor.row = min(cursor.row, maxRow)
    }

    func reloadVisible() {
        guard let table else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                         columnIndexes: IndexSet(integersIn: 0..<SheetColumn.all.count))
    }

    // MARK: - 편집

    func beginEditing(initialText: String? = nil) {
        guard editing == nil, let table, rows.indices.contains(cursor.row),
              editableKey(row: cursor.row, column: cursor.column) != nil,
              let cell = table.view(atColumn: cursor.column, row: cursor.row, makeIfNecessary: true) as? SheetCell
        else { return }
        anchor = cursor
        syncAccessibilitySelection(announceFocus: false)
        editing = cursor
        editingOriginal = text(row: cursor.row, column: cursor.column)
        cell.beginEditing(text: initialText ?? editingOriginal)
        table.window?.makeFirstResponder(cell.label)
        if let editor = cell.label.currentEditor() {
            let length = (cell.label.stringValue as NSString).length
            editor.selectedRange = initialText == nil ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
        }
    }

    func cancelEditing() {
        finishEditing(commit: false, then: nil)
    }

    var isEditing: Bool { editing != nil }

    private func finishEditing(commit: Bool, then move: (rows: Int, columns: Int)?) {
        guard let position = editing, let table else { return }
        editing = nil
        let cell = table.view(atColumn: position.column, row: position.row, makeIfNecessary: false) as? SheetCell
        let value = cell?.label.stringValue ?? editingOriginal
        cell?.endEditing()
        table.window?.makeFirstResponder(table)
        if commit, value != editingOriginal, let key = editableKey(row: position.row, column: position.column) {
            store.applyTagEdits([(row: rows[position.row], key: key, value: value)])
        } else {
            reloadVisible()
        }
        if let move { self.move(rows: move.rows, columns: move.columns, extend: false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finishEditing(commit: true, then: (1, 0)); return true
        case #selector(NSResponder.insertTab(_:)):
            finishEditing(commit: true, then: (0, 1)); return true
        case #selector(NSResponder.insertBacktab(_:)):
            finishEditing(commit: true, then: (0, -1)); return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishEditing(commit: false, then: nil); return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // 다른 곳을 클릭해 포커스를 잃으면 확정한다.
        if editing != nil { finishEditing(commit: true, then: nil) }
    }

    // MARK: - 일괄 작업

    private func editableCells(in rect: (rows: ClosedRange<Int>, columns: ClosedRange<Int>)) -> [(row: TrackRow, key: TagFields.Key)] {
        rect.rows.filter { rows.indices.contains($0) }.flatMap { r in
            rect.columns.compactMap { c in editableKey(row: r, column: c).map { (row: rows[r], key: $0) } }
        }
    }

    func clearSelection() {
        guard !rows.isEmpty else { return }
        applyChanges(editableCells(in: selectionRect).map { ($0.row, $0.key, "") })
    }

    func copySelection() {
        guard !rows.isEmpty else { return }
        let rect = selectionRect
        let tsv = rect.rows.filter { rows.indices.contains($0) }
            .map { r in rect.columns.map { TSV.quote(text(row: r, column: $0)) }.joined(separator: "\t") }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tsv, forType: .string)
    }

    func paste() {
        defer { table?.updateFillDownCommand() }
        guard let string = NSPasteboard.general.string(forType: .string), !rows.isEmpty else { return }
        let block = TSV.parse(string)
        guard !block.isEmpty else { return }
        let rect = selectionRect
        var changes: [(row: TrackRow, key: TagFields.Key, value: String)] = []
        if block.count == 1, block[0].count == 1 {
            // 값 하나 → 선택 범위 전체를 채운다.
            changes = editableCells(in: rect).map { ($0.row, $0.key, block[0][0]) }
        } else {
            for (i, line) in block.enumerated() {
                let r = rect.rows.lowerBound + i
                guard rows.indices.contains(r) else { break }
                for (j, value) in line.enumerated() {
                    let c = rect.columns.lowerBound + j
                    guard SheetColumn.all.indices.contains(c), let key = editableKey(row: r, column: c) else { continue }
                    changes.append((rows[r], key, value))
                }
            }
            cursor = CellPosition(row: min(rect.rows.lowerBound + block.count - 1, rows.count - 1),
                                  column: min(rect.columns.lowerBound + (block.map(\.count).max() ?? 1) - 1, SheetColumn.all.count - 1))
            anchor = CellPosition(row: rect.rows.lowerBound, column: rect.columns.lowerBound)
        }
        applyChanges(changes)
    }

    /// 선택 범위 맨 윗줄 값으로 아래 줄들을 채운다.
    func fillDown() {
        let rect = selectionRect
        guard rect.rows.count > 1, rows.indices.contains(rect.rows.lowerBound) else { return }
        var changes: [(row: TrackRow, key: TagFields.Key, value: String)] = []
        for c in rect.columns {
            guard let key = SheetColumn.all[c].key else { continue }
            let value = store.tagCell(rows[rect.rows.lowerBound], key)
            for r in rect.rows.dropFirst() where editableKey(row: r, column: c) != nil {
                changes.append((rows[r], key, value))
            }
        }
        applyChanges(changes)
    }

    private func applyChanges(_ changes: [(row: TrackRow, key: TagFields.Key, value: String)]) {
        let before = changes.map { store.tagCell($0.row, $0.key) }
        store.applyTagEdits(changes)
        let changed = zip(changes, before).filter { store.tagCell($0.0.row, $0.0.key) != $0.1 }.count
        reloadVisible()
        syncAccessibilitySelection(announceFocus: false)
        if changed > 0 { announce(String(ui: "\(changed)칸 바뀜")) }
    }
}

/// 셀 선택·키보드·마우스를 엑셀처럼 다루는 NSTableView.
final class SheetTableView: NSTableView {
    weak var coordinator: SheetCoordinator?

    override var acceptsFirstResponder: Bool { true }

    override func accessibilitySelectedCells() -> [Any]? {
        guard let coordinator, !coordinator.rows.isEmpty else { return [] }
        let rect = coordinator.selectionRect
        return rect.rows.flatMap { row in
            rect.columns.compactMap { accessibilityCell(forColumn: $0, row: row) }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { updateFillDownCommand(focused: true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { coordinator?.store.canFillDownTags = false }
        return accepted
    }

    func updateFillDownCommand(focused: Bool? = nil) {
        let enabled = (focused ?? (window?.firstResponder === self))
            && canEditSelection && (coordinator?.selectionRect.rows.count ?? 0) > 1
        if coordinator?.store.canFillDownTags != enabled { coordinator?.store.canFillDownTags = enabled }
    }

    private func position(for event: NSEvent) -> CellPosition? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), column = column(at: point)
        guard row >= 0, column >= 0 else { return nil }
        return CellPosition(row: row, column: column)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let coordinator, let position = position(for: event) else { return }
        coordinator.select(position, extend: event.modifierFlags.contains(.shift))
        if event.clickCount == 2 { coordinator.beginEditing() }
    }

    /// 오른쪽 클릭: 고른 범위 밖이면 그 칸으로 커서를 옮기고(엑셀처럼) 덱에 불러오기 메뉴를 띄운다.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinator, let position = position(for: event) else { return nil }
        if !coordinator.isSelected(position) { coordinator.select(position, extend: false) }
        return coordinator.contextMenu(forRow: position.row)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let coordinator, let position = position(for: event) else { return }
        autoscroll(with: event)
        if position != coordinator.cursor { coordinator.select(position, extend: true) }
    }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else { return super.keyDown(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        // ⌘→: 커서 줄을 덱에 올린다(곡 목록과 같다). ⌘ 없는 →는 옆 칸으로.
        if event.specialKey == .rightArrow, event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            coordinator.loadCursorRow()
            return
        }
        if event.modifierFlags.contains(.control), event.specialKey == .tab || event.specialKey == .backTab {
            if shift || event.specialKey == .backTab { window?.selectPreviousKeyView(nil) }
            else { window?.selectNextKeyView(nil) }
            return
        }
        switch event.specialKey {
        case .upArrow: coordinator.move(rows: -1, columns: 0, extend: shift)
        case .downArrow: coordinator.move(rows: 1, columns: 0, extend: shift)
        case .leftArrow: coordinator.move(rows: 0, columns: -1, extend: shift)
        case .rightArrow: coordinator.move(rows: 0, columns: 1, extend: shift)
        case .tab: coordinator.move(rows: 0, columns: 1, extend: false)
        case .backTab: coordinator.move(rows: 0, columns: -1, extend: false)
        case .carriageReturn, .enter: coordinator.beginEditing()
        case .delete, .deleteForward, .backspace: coordinator.clearSelection()
        case .pageUp: coordinator.move(rows: -20, columns: 0, extend: shift)
        case .pageDown: coordinator.move(rows: 20, columns: 0, extend: shift)
        default:
            // 글자를 치면 그 글자로 편집을 시작한다(엑셀과 같다).
            if let characters = event.characters, !characters.isEmpty,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                // 글자를 직접 넣으면 한글 입력기가 조합하지 못한다(ㅎ+ㅏ가 따로 들어감).
                // 빈 칸으로 편집을 시작하고 같은 키 이벤트를 편집기에 넘겨 입력기가 처리하게 한다.
                coordinator.beginEditing(initialText: "")
                if coordinator.isEditing, let editor = window?.firstResponder as? NSTextView {
                    editor.keyDown(with: event)
                }
            } else {
                super.keyDown(with: event)
            }
        }
    }

    @objc func copy(_ sender: Any?) { coordinator?.copySelection() }
    @objc func cut(_ sender: Any?) {
        guard canEditSelection else { return }
        coordinator?.copySelection()
        coordinator?.clearSelection()
    }
    @objc func paste(_ sender: Any?) {
        guard canEditSelection else { return }
        coordinator?.paste()
    }
    @objc func delete(_ sender: Any?) {
        guard canEditSelection else { return }
        coordinator?.clearSelection()
    }
    override func selectAll(_ sender: Any?) { coordinator?.selectAll() }
    @objc func fillDown(_ sender: Any?) {
        guard canEditSelection else { return }
        coordinator?.fillDown()
    }

    var canEditSelection: Bool {
        guard let coordinator, !coordinator.store.isWritingRekordbox else { return false }
        let rect = coordinator.selectionRect
        return rect.rows.contains { row in
            rect.columns.contains { coordinator.editableKey(row: row, column: $0) != nil }
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(selectAll(_:)):
            return coordinator?.rows.isEmpty == false
        case #selector(cut(_:)), #selector(delete(_:)):
            return canEditSelection
        case #selector(paste(_:)):
            return canEditSelection && NSPasteboard.general.canReadItem(withDataConformingToTypes: ["public.utf8-plain-text"])
        case #selector(fillDown(_:)):
            return canEditSelection && (coordinator?.selectionRect.rows.count ?? 0) > 1
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

/// 시트 칸의 초안 표시. 글자색(초안 색)만이 아니라 왼쪽 위 모서리 삼각형과 VoiceOver 값("…, 초안")으로도 알린다.
struct SheetCellAppearance: Equatable {
    enum Tone { case primary, secondary, draft }

    var tone: Tone
    /// 선택해도 남긴다(선택하면 글자색이 기본색으로 바뀌어 색으로는 알 수 없다).
    var showsDraftMark: Bool
    private var speaksDraft: Bool

    init(edited: Bool, readOnly: Bool, selected: Bool, editing: Bool) {
        // 선택한 칸은 선택 배경 위에서 읽히게 기본색으로 쓴다.
        tone = selected && !editing ? .primary : edited ? .draft : readOnly ? .secondary : .primary
        showsDraftMark = edited
        // 입력 중에는 칸 값을 덮지 않는다(입력한 글자를 VoiceOver가 그대로 읽게).
        speaksDraft = edited && !editing
    }

    /// VoiceOver가 읽을 칸 값. nil이면 칸 글자 그대로 읽힌다.
    func accessibilityValue(for text: String) -> String? {
        speaksDraft ? "\(text), \(DraftMark.spoken)" : nil
    }
}

/// 초안 칸 왼쪽 위 모서리의 작은 삼각형(엑셀의 칸 표식처럼 글자 자리를 빼앗지 않는다). 태그 시트와 곡 목록 칸이 같이 쓴다.
final class DraftCornerView: NSView {
    /// 곡 목록의 강조된 선택 줄에서는 선택 글자색으로 바꿔 보이게 한다.
    var color = UIColors.draft.nsColor {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: .zero)
        path.line(to: NSPoint(x: bounds.width, y: 0))
        path.line(to: NSPoint(x: 0, y: bounds.height))
        path.close()
        color.setFill()
        path.fill()
    }
}

/// 범례용 칸 모양: 시트 칸처럼 테두리 안 왼쪽 위에 초안 삼각형
struct DraftCornerSwatch: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().strokeBorder(Color(nsColor: .separatorColor))
            Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: 7, y: 0))
                path.addLine(to: CGPoint(x: 0, y: 7))
                path.closeSubpath()
            }
            .fill(UIColors.draft.color)
        }
        .frame(width: 16, height: 12)
    }
}

/// 시트 셀: 평소에는 라벨, 편집할 때만 같은 텍스트 필드를 편집 가능으로 바꾼다.
final class SheetCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    private let draftMark = DraftCornerView()
    private var edited = false
    private var readOnly = false
    private var selected = false
    private var active = false

    /// 초안 모서리 표식이 보이는지(시험용)
    var showsDraftMark: Bool { !draftMark.isHidden }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = Self.font(scale: 1)
        label.cell?.usesSingleLineMode = true
        label.cell?.isScrollable = false
        addSubview(label)
        textField = label
        draftMark.translatesAutoresizingMaskIntoConstraints = false
        draftMark.isHidden = true
        addSubview(draftMark)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            draftMark.leadingAnchor.constraint(equalTo: leadingAnchor),
            draftMark.topAnchor.constraint(equalTo: topAnchor),
            draftMark.widthAnchor.constraint(equalToConstant: 7),
            draftMark.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 시트 글자(12pt × 글자 배율)
    static func font(scale: Double) -> NSFont {
        .systemFont(ofSize: TextScale.pointSize(12, scale: scale))
    }

    func configure(text: String, edited: Bool, readOnly: Bool, selected: Bool, active: Bool) {
        if label.currentEditor() == nil { label.stringValue = text }
        toolTip = text
        self.edited = edited
        self.readOnly = readOnly
        self.selected = selected
        self.active = active
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewWillDraw() {
        updateColors()
        super.viewWillDraw()
    }

    private func updateColors() {
        // AppKit이 창·표 포커스가 바뀔 때 다시 그리므로 선택색도 그때 풀어 쓴다.
        let editing = label.currentEditor() != nil
        let emphasized = window?.isKeyWindow == true && (window?.firstResponder is SheetTableView || editing)
        let appearance = SheetCellAppearance(edited: edited, readOnly: readOnly, selected: selected, editing: editing)
        if draftMark.isHidden == appearance.showsDraftMark { draftMark.isHidden = !appearance.showsDraftMark }
        // 글자 칸의 접근성 요소는 셀(NSTextFieldCell)이라 값도 셀에 둔다. 셀에 nil을 넣으면 기본값으로 돌아가지 않고
        // 값이 비므로(재사용한 칸을 VoiceOver가 못 읽는다) 초안이 아니어도 글자를 그대로 넣는다.
        label.cell?.setAccessibilityValue(appearance.accessibilityValue(for: label.stringValue) ?? label.stringValue)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            label.textColor = switch appearance.tone {
            case .primary: .labelColor
            case .secondary: .secondaryLabelColor
            case .draft: UIColors.draft.nsColor
            }
            let selection: NSColor = emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
            layer?.backgroundColor = selected ? selection.withAlphaComponent(0.28).cgColor : nil
            layer?.borderWidth = active ? 2 : 0
            layer?.borderColor = UIColors.info.nsColor.cgColor
        }
    }

    func beginEditing(text: String) {
        label.cell?.isScrollable = true
        label.isEditable = true
        label.isSelectable = true
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.stringValue = text
        // 입력하는 동안은 VoiceOver가 칸 값을 그대로 읽는다.
        label.cell?.setAccessibilityValue(text)
    }

    func endEditing() {
        label.cell?.isScrollable = false
        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        updateColors()
    }
}
