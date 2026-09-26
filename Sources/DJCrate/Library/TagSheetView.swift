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
/// - ⌘C·⌘V: 탭 구분 텍스트(엑셀·구글 시트 호환) / ⌘D: 아래로 채우기 / Delete: 지우기
/// - ⌘Z·⇧⌘Z: 되돌리기·다시 실행 / ⌘A: 전체 선택
struct TagSheetView: NSViewRepresentable {
    @Bindable var store: LibraryStore

    func makeCoordinator() -> SheetCoordinator { SheetCoordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = SheetTableView()
        table.coordinator = context.coordinator
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.selectionHighlightStyle = .none
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
            table.addTableColumn(tableColumn)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
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
        SheetColumn(id: "title", title: "제목", width: 220, key: .title),
        SheetColumn(id: "artist", title: "아티스트", width: 170, key: .artist),
        SheetColumn(id: "album", title: "앨범", width: 170, key: .album),
        SheetColumn(id: "albumArtist", title: "앨범 아티스트", width: 120, key: .albumArtist),
        SheetColumn(id: "genre", title: "장르", width: 90, key: .genre),
        SheetColumn(id: "composer", title: "작곡가", width: 110, key: .composer),
        SheetColumn(id: "year", title: "연도", width: 52, key: .year),
        SheetColumn(id: "trackNumber", title: "트랙", width: 44, key: .trackNumber),
        SheetColumn(id: "comment", title: "코멘트", width: 300, key: .comment),
        SheetColumn(id: "file", title: "파일", width: 220, key: nil),
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

    init(store: LibraryStore) {
        self.store = store
    }

    // MARK: - 데이터

    func update(rows: [TrackRow], revision: Int) {
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
        } else if revision != self.revision {
            self.rows = rows
            self.revision = revision
            reloadVisible()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

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
        cell.configure(text: text(row: row, column: column),
                       edited: spec.key.map { store.isTagEdited(rows[row], $0) } ?? false,
                       readOnly: editableKey(row: row, column: column) == nil,
                       selected: isSelected(position),
                       active: position == cursor)
        cell.label.delegate = self
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
        guard !rows.isEmpty else { return }
        let clamped = CellPosition(row: min(max(position.row, 0), rows.count - 1),
                                   column: min(max(position.column, 0), SheetColumn.all.count - 1))
        cursor = clamped
        if !extend { anchor = clamped }
        table?.scrollRowToVisible(clamped.row)
        table?.scrollColumnToVisible(clamped.column)
        reloadVisible()
        // 커서 줄을 덱에 올린다.
        store.selection = [rows[clamped.row].id]
    }

    func move(rows dRow: Int, columns dColumn: Int, extend: Bool) {
        select(CellPosition(row: cursor.row + dRow, column: cursor.column + dColumn), extend: extend)
    }

    func selectAll() {
        guard !rows.isEmpty else { return }
        anchor = CellPosition(row: 0, column: 0)
        cursor = CellPosition(row: rows.count - 1, column: SheetColumn.all.count - 1)
        reloadVisible()
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
        store.applyTagEdits(editableCells(in: selectionRect).map { ($0.row, $0.key, "") })
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
        store.applyTagEdits(changes)
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
        store.applyTagEdits(changes)
    }
}

/// 셀 선택·키보드·마우스를 엑셀처럼 다루는 NSTableView.
final class SheetTableView: NSTableView {
    weak var coordinator: SheetCoordinator?

    override var acceptsFirstResponder: Bool { true }

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

    override func mouseDragged(with event: NSEvent) {
        guard let coordinator, let position = position(for: event) else { return }
        autoscroll(with: event)
        if position != coordinator.cursor { coordinator.select(position, extend: true) }
    }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else { return super.keyDown(with: event) }
        let shift = event.modifierFlags.contains(.shift)
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let coordinator, window?.firstResponder === self,
              event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": coordinator.copySelection(); return true
        case "x": coordinator.copySelection(); coordinator.clearSelection(); return true
        case "v": coordinator.paste(); return true
        case "d": coordinator.fillDown(); return true
        case "a": coordinator.selectAll(); return true
        case "z":
            if shift { coordinator.store.redoTags() } else { coordinator.store.undoTags() }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// 시트 셀: 평소에는 라벨, 편집할 때만 같은 텍스트 필드를 편집 가능으로 바꾼다.
final class SheetCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    private var edited = false
    private var readOnly = false
    private var selected = false
    private var active = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)
        label.cell?.usesSingleLineMode = true
        label.cell?.isScrollable = true
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, edited: Bool, readOnly: Bool, selected: Bool, active: Bool) {
        if label.currentEditor() == nil { label.stringValue = text }
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
        let emphasized = window?.isKeyWindow == true && (window?.firstResponder is SheetTableView || label.currentEditor() != nil)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            label.textColor = selected && label.currentEditor() == nil
                ? .labelColor
                : (edited ? UIColors.draft.nsColor : (readOnly ? .secondaryLabelColor : .labelColor))
            let selection: NSColor = emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
            layer?.backgroundColor = selected ? selection.withAlphaComponent(0.28).cgColor : nil
            layer?.borderWidth = active ? 2 : 0
            layer?.borderColor = UIColors.info.nsColor.cgColor
        }
    }

    func beginEditing(text: String) {
        label.isEditable = true
        label.isSelectable = true
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.stringValue = text
    }

    func endEditing() {
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
    }
}
