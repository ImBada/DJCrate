import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import SwiftUI

/// 곡 목록.
///
/// SwiftUI `Table`은 7천 줄 배열이 바뀔 때마다(필터·검색·정렬·선택) 행 비교와 레이아웃 비용이 커서
/// 스크롤·선택이 무거웠다. AppKit `NSTableView`(데이터 소스 + 셀 재사용)로 그리고,
/// 선택·정렬은 스토어와 양방향으로 맞춘다. 열 너비·순서는 자동 저장된다.
struct TrackTable: View {
    @Bindable var store: LibraryStore
    let deck: DeckModel

    var body: some View {
        TrackListView(store: store, mode: deck.waveformColorMode)
            .navigationTitle(store.sidebarTitle)
            .navigationSubtitle("\(store.displayRows.count)곡" + (store.selection.count > 1 ? " · \(store.selection.count)곡 선택" : ""))
    }
}

private struct TrackListView: NSViewRepresentable {
    let store: LibraryStore
    let mode: WaveformColorMode

    func makeCoordinator() -> TrackListCoordinator { TrackListCoordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.identifier = KeyRouter.trackListID
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.style = .inset
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        // 한 글자 키는 덱 단축키로 쓰므로 제목 타이핑 선택과 겹치지 않게 한다.
        table.allowsTypeSelect = false
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for spec in TrackColumn.all {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.minWidth
            column.resizingMask = spec.flexible ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            if let key = spec.sortKey {
                column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: spec.ascendingFirst)
            }
            if !spec.help.isEmpty { column.headerToolTip = spec.help }
            if spec.id == "edited" {
                column.headerCell.attributedStringValue = TrackColumn.draftHeader
                column.headerCell.setAccessibilityLabel(spec.title)
            }
            column.isHidden = spec.id == "preview"
            table.addTableColumn(column)
        }
        table.menu = context.coordinator.makeMenu()
        table.autosaveName = "djc.trackList.v2"
        table.autosaveTableColumns = !PerfProbe.enabled
        // 머리글을 오른쪽 클릭하면 보일 칸을 고른다(숨김 상태도 자동 저장된다).
        table.headerView?.menu = context.coordinator.makeColumnMenu(table)
        // 저장된 칸 배치에는 새 "형식" 칸이 없어서 끝으로 밀린다. 한 번만 BPM 옆으로 옮긴다(그 뒤로는 사용자가 옮긴 대로).
        let indexKey = "djc.trackList.indexColumnPlaced"
        if !UserDefaults.standard.bool(forKey: indexKey),
           let from = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "index" }) {
            table.moveColumn(from, toColumn: 0)
            UserDefaults.standard.set(true, forKey: indexKey)
        }
        let albumKey = "djc.trackList.albumColumnPlaced"
        if !UserDefaults.standard.bool(forKey: albumKey),
           let from = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "album" }),
           let artist = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "artist" }) {
            table.moveColumn(from, toColumn: from > artist ? artist + 1 : artist)
            UserDefaults.standard.set(true, forKey: albumKey)
        }
        let tempoKey = "djc.trackList.tempoColumnPlaced"
        if !UserDefaults.standard.bool(forKey: tempoKey),
           let from = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "tempo" }),
           let bpm = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "bpm" }) {
            table.moveColumn(from, toColumn: from > bpm ? bpm + 1 : bpm)
            UserDefaults.standard.set(true, forKey: tempoKey)
        }
        let placedKey = "djc.trackList.formatColumnPlaced"
        if !UserDefaults.standard.bool(forKey: placedKey),
           let from = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "format" }),
           let bpm = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "bpm" }) {
            table.moveColumn(from, toColumn: from > bpm ? bpm + 1 : bpm)
            UserDefaults.standard.set(true, forKey: placedKey)
        }
        let previewKey = "djc.trackList.previewColumnPlaced"
        if !UserDefaults.standard.bool(forKey: previewKey),
           let from = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "preview" }),
           let title = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "title" }) {
            table.moveColumn(from, toColumn: from > title ? title + 1 : title)
            if !PerfProbe.enabled { UserDefaults.standard.set(true, forKey: previewKey) }
        }
        if let show = PerfProbe.previewColumnVisible {
            table.tableColumns.first(where: { $0.identifier.rawValue == "preview" })?.isHidden = !show
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        context.coordinator.updateCommentPreset(store.commentPreset)
        context.coordinator.updateTextScale(context.environment.textScale)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.updateTextScale(context.environment.textScale)
        context.coordinator.updateCommentPreset(store.commentPreset)
        context.coordinator.update(rows: store.displayRows, edited: store.editedUUIDs,
                                   selection: store.selection, sortOrder: store.sortOrder, snapshotURL: store.snapshotURL,
                                   previewRevision: store.previewRevision)
        context.coordinator.updateCueCounts(store.draftCueCounts)
        context.coordinator.updatePreviewCues(store.draftPreviewCues)
        context.coordinator.updateWaveformMode(mode)
    }
}

private struct TrackColumn {
    let id: String
    let title: String
    let width: CGFloat
    var minWidth: CGFloat = 18
    var flexible = false
    /// nil이면 정렬하지 않는다.
    var sortKey: String?
    /// 머리글을 처음 눌렀을 때 오름차순인지(숫자·날짜는 큰 값부터가 쓸모 있다).
    var ascendingFirst = true
    var help = ""

    static let all: [TrackColumn] = [
        TrackColumn(id: "index", title: "#", width: 38, minWidth: 30, help: "지금 목록에서 몇 번째 곡인지"),
        TrackColumn(id: "thumb", title: "", width: 26, minWidth: 26),
        TrackColumn(id: "edited", title: "초안", width: 18, minWidth: 18, help: "DJCrate 초안이 있는 곡 (rekordbox·파일에는 아직 반영 안 됨)"),
        TrackColumn(id: "title", title: "제목", width: 220, minWidth: 140, flexible: true, sortKey: "title"),
        TrackColumn(id: "preview", title: "미리 보기", width: 160, minWidth: 80,
                    help: "곡 전체 파형과 핫큐·메모리 큐·루프 위치"),
        TrackColumn(id: "artist", title: "아티스트", width: 140, minWidth: 80, flexible: true, sortKey: "artist"),
        TrackColumn(id: "album", title: "앨범", width: 150, minWidth: 60, flexible: true, sortKey: "album"),
        TrackColumn(id: "genre", title: "장르", width: 90, minWidth: 50, flexible: true, sortKey: "genre"),
        TrackColumn(id: "comment", title: "코멘트", width: 250, minWidth: 140, flexible: true, sortKey: "comment"),
        TrackColumn(id: "class", title: "분류", width: 52, minWidth: 40, sortKey: "class", help: "코멘트 분류: 규칙·구형·잔재·크레딧·빈 값·기타"),
        TrackColumn(id: "bpm", title: "BPM", width: 44, minWidth: 34, sortKey: "bpm", ascendingFirst: false),
        TrackColumn(id: "key", title: "키", width: 36, minWidth: 30, sortKey: "key"),
        TrackColumn(id: "length", title: "길이", width: 46, minWidth: 38, sortKey: "length", ascendingFirst: false, help: "곡 전체 재생 시간"),
        TrackColumn(id: "format", title: "형식", width: 44, minWidth: 36, sortKey: "format", help: "파일 확장자(MP3·M4A·FLAC·WAV 등)"),
        TrackColumn(id: "tempo", title: "변속", width: 90, minWidth: 44, sortKey: "tempo", ascendingFirst: false,
                    help: "rekordbox 그리드에서 BPM이 바뀌는 곡의 흐름(예: 175→128→175)"),
        TrackColumn(id: "imported", title: "임포트", width: 86, minWidth: 70, sortKey: "imported", ascendingFirst: false),
        TrackColumn(id: "plays", title: "재생", width: 42, minWidth: 34, sortKey: "plays", ascendingFirst: false),
        TrackColumn(id: "hotCues", title: "핫큐", width: 42, minWidth: 34, sortKey: "hotCues", ascendingFirst: false,
                    help: "직접 찍은 핫큐 수(초록)"),
        TrackColumn(id: "memoryCues", title: "메모리", width: 50, minWidth: 40, sortKey: "memoryCues", ascendingFirst: false,
                    help: "직접 찍은 메모리 큐 수(빨강). 큐가 없으면 주황 '없음', rekordbox 자동 큐만 있으면 '자동'"),
    ]

    /// 초안 칸 머리글: 글자 '✎' 대신 pencil 심볼을 머리글 글자색·크기로 넣는다(칸이 좁아 '초안'이 들어가지 않는다).
    /// 제목 '초안'은 칸 메뉴와 VoiceOver에 쓴다.
    @MainActor static var draftHeader: NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "초안")?
            .withSymbolConfiguration(.init(pointSize: NSFont.smallSystemFontSize, weight: .regular))
        let text = NSMutableAttributedString(attachment: attachment)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.addAttributes([.foregroundColor: NSColor.headerTextColor, .paragraphStyle: paragraph],
                           range: NSRange(location: 0, length: text.length))
        return text
    }

    static func comparator(key: String, ascending: Bool) -> KeyPathComparator<TrackRow>? {
        let order: SortOrder = ascending ? .forward : .reverse
        switch key {
        case "title": return KeyPathComparator(\TrackRow.title, order: order)
        case "artist": return KeyPathComparator(\TrackRow.artist, order: order)
        case "genre": return KeyPathComparator(\TrackRow.genre, order: order)
        case "album": return KeyPathComparator(\TrackRow.album, order: order)
        case "comment": return KeyPathComparator(\TrackRow.comment, order: order)
        case "class": return KeyPathComparator(\TrackRow.commentClassName, order: order)
        case "bpm": return KeyPathComparator(\TrackRow.bpmValue, order: order)
        case "key": return KeyPathComparator(\TrackRow.keyName, order: order)
        case "length": return KeyPathComparator(\TrackRow.lengthSeconds, order: order)
        case "format": return KeyPathComparator(\TrackRow.formatName, order: order)
        case "tempo": return KeyPathComparator(\TrackRow.tempoChangeCount, order: order)
        case "imported": return KeyPathComparator(\TrackRow.importedOn, order: order)
        case "plays": return KeyPathComparator(\TrackRow.playCount, order: order)
        case "hotCues": return KeyPathComparator(\TrackRow.hotCueCount, order: order)
        case "memoryCues": return KeyPathComparator(\TrackRow.memoryCueCount, order: order)
        default: return nil
        }
    }

    /// 스토어의 정렬을 머리글 표시로 되돌린다.
    static func sortKey(of keyPath: PartialKeyPath<TrackRow>) -> String? {
        switch keyPath {
        case \TrackRow.title: "title"
        case \TrackRow.artist: "artist"
        case \TrackRow.genre: "genre"
        case \TrackRow.album: "album"
        case \TrackRow.comment: "comment"
        case \TrackRow.commentClassName: "class"
        case \TrackRow.bpmValue: "bpm"
        case \TrackRow.keyName: "key"
        case \TrackRow.lengthSeconds: "length"
        case \TrackRow.formatName: "format"
        case \TrackRow.tempoChangeCount: "tempo"
        case \TrackRow.importedOn: "imported"
        case \TrackRow.playCount: "plays"
        case \TrackRow.hotCueCount: "hotCues"
        case \TrackRow.memoryCueCount: "memoryCues"
        default: nil
        }
    }
}

@MainActor
final class TrackListCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let store: LibraryStore
    weak var table: NSTableView?
    private var rows: [TrackRow] = []
    private var rowIDs: [TrackRow.ID] = []
    private var edited: Set<String> = []
    private var snapshotURL: URL?
    private var previewRevision = 0
    private var commentPreset: CommentPreset?
    private var classHiddenWhenEnabled = false
    private var waveformMode = WaveformColorMode.threeBand
    private var previewCues: [String: [PreviewCueMark]] = [:]
    private var textScale = 1.0
    private var fonts = TextCell.Fonts(scale: 1)
    /// 표 → 스토어로 선택·정렬을 넘기는 중에는 스토어 → 표 동기화를 건너뛴다(되먹임 방지).
    private var syncing = false

    init(store: LibraryStore) {
        self.store = store
    }

    // MARK: - 스토어 → 표

    func updateCommentPreset(_ preset: CommentPreset) {
        guard commentPreset != preset, let table,
              let column = table.tableColumns.first(where: { $0.identifier.rawValue == "class" }) else { return }
        // 강제로 숨긴 상태가 사용자가 고른 열 숨김 설정을 덮지 않게 따로 기억한다.
        if commentPreset == nil {
            classHiddenWhenEnabled = store.settings.defaults.object(forKey: SettingKeys.commentClassColumnHidden.name) as? Bool ?? column.isHidden
        } else if commentPreset?.rule != nil {
            classHiddenWhenEnabled = column.isHidden
        }
        store.settings.set(SettingKeys.commentClassColumnHidden, classHiddenWhenEnabled)
        commentPreset = preset
        column.isHidden = preset.rule == nil || classHiddenWhenEnabled
        reloadVisible(table)
    }

    /// 글자 배율(보기 › 글자 크게·작게)이 바뀌면 글자 크기와 줄 높이를 함께 바꾼다. 보이지 않는 줄은 나타날 때 새 글자로 채운다.
    func updateTextScale(_ scale: Double) {
        guard scale != textScale, let table else { return }
        textScale = scale
        fonts = TextCell.Fonts(scale: scale)
        table.rowHeight = TextScale.length(24, scale: scale)
        reloadVisible(table)
    }

    func updateWaveformMode(_ mode: WaveformColorMode) {
        guard mode != waveformMode, let table else { return }
        waveformMode = mode
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "preview" }) else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                         columnIndexes: IndexSet(integer: column))
    }

    func update(rows: [TrackRow], edited: Set<String>, selection: Set<TrackRow.ID>,
                sortOrder: [KeyPathComparator<TrackRow>], snapshotURL: URL?, previewRevision: Int) {
        guard let table else { return }
        applySortIndicator(sortOrder, table: table)
        let snapshotChanged = self.snapshotURL != snapshotURL || self.previewRevision != previewRevision
        self.snapshotURL = snapshotURL
        self.previewRevision = previewRevision
        // 같은 배열이면(== 는 저장소가 같을 때 바로 참) 비교 비용이 없다.
        if rows != self.rows || snapshotChanged {
            let ids = rows.map(\.id)
            let reordered = ids != rowIDs
            self.rows = rows
            rowIDs = ids
            self.edited = edited
            if reordered {
                table.reloadData()
                applySelection(selection, table: table, scroll: true)
            } else {
                // 순서는 같고 내용만 바뀜(새 스냅샷): 보이는 줄만 다시 그린다.
                reloadVisible(table)
            }
        } else if edited != self.edited {
            let changed = edited.symmetricDifference(self.edited)
            self.edited = edited
            if let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "edited" }) {
                let indexes = IndexSet(rows.indices.filter { changed.contains(rows[$0].track.uuid) })
                table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: column))
            }
        }
        if !syncing, selection != selectedIDs(table) {
            applySelection(selection, table: table, scroll: true)
        }
    }

    private var cueCounts: [String: CueCounts] = [:]

    /// 개수가 같은 이동이어도 그 곡의 미리 보기만 다시 그린다.
    func updatePreviewCues(_ cues: [String: [PreviewCueMark]]) {
        guard cues != previewCues, let table else { return }
        let changed = Set(cues.keys).union(previewCues.keys).filter { cues[$0] != previewCues[$0] }
        previewCues = cues
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "preview" }) else { return }
        let indexes = IndexSet(rows.indices.filter { changed.contains(rows[$0].track.uuid) })
        if !indexes.isEmpty { table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: column)) }
    }

    /// 초안 큐 개수가 바뀐 곡만 핫큐·메모리 칸을 다시 그린다.
    func updateCueCounts(_ counts: [String: CueCounts]) {
        guard counts != cueCounts, let table else { return }
        let changed = Set(counts.keys).union(cueCounts.keys).filter { counts[$0] != cueCounts[$0] }
        cueCounts = counts
        let columns = IndexSet(table.tableColumns.indices.filter { ["hotCues", "memoryCues"].contains(table.tableColumns[$0].identifier.rawValue) })
        let indexes = IndexSet(rows.indices.filter { changed.contains(rows[$0].track.uuid) })
        if !indexes.isEmpty, !columns.isEmpty { table.reloadData(forRowIndexes: indexes, columnIndexes: columns) }
    }

    private func selectedIDs(_ table: NSTableView) -> Set<TrackRow.ID> {
        Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
    }

    private func applySelection(_ selection: Set<TrackRow.ID>, table: NSTableView, scroll: Bool) {
        let indexes = IndexSet(rows.indices.filter { selection.contains(rows[$0].id) })
        syncing = true
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        syncing = false
        if scroll, let first = indexes.first { table.scrollRowToVisible(first) }
    }

    private func applySortIndicator(_ sortOrder: [KeyPathComparator<TrackRow>], table: NSTableView) {
        let wanted: [NSSortDescriptor] = sortOrder.first.flatMap { comparator in
            TrackColumn.sortKey(of: comparator.keyPath).map { [NSSortDescriptor(key: $0, ascending: comparator.order == .forward)] }
        } ?? []
        let current = table.sortDescriptors.prefix(1).map { ($0.key, $0.ascending) }
        if !current.elementsEqual(wanted.map { ($0.key, $0.ascending) }, by: ==) {
            syncing = true
            table.sortDescriptors = wanted
            syncing = false
        }
    }

    private func reloadVisible(_ table: NSTableView) {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                         columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    // MARK: - 표 → 스토어

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let table else { return }
        let ids = selectedIDs(table)
        if ids != store.selection {
            syncing = true
            store.selection = ids
            syncing = false
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !syncing else { return }
        guard let first = tableView.sortDescriptors.first, let key = first.key else {
            store.sortOrder = []
            return
        }
        if let comparator = TrackColumn.comparator(key: key, ascending: first.ascending) {
            syncing = true
            store.sortOrder = [comparator]
            syncing = false
        }
    }

    // MARK: - 오른쪽 클릭 메뉴

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    /// 오른쪽 클릭한 줄이 선택 밖이면 그 줄만, 아니면 선택 전체가 대상이다(Finder와 같다).
    private func menuTargets() -> [TrackRow] {
        guard let table else { return [] }
        let clicked = table.clickedRow
        let indexes = clicked >= 0 && !table.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : table.selectedRowIndexes
        return store.uniqueTracks(indexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil })
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier?.rawValue == "columns" { fillColumnMenu(menu); return }
        menu.removeAllItems()
        let targets = menuTargets()
        let pending = targets.filter { !$0.isStaged && store.pendingUUIDs.contains($0.track.uuid) }
        let reflect = NSMenuItem(title: pending.isEmpty ? "rekordbox에 반영할 초안이 없습니다" : "선택한 곡 rekordbox에 반영 (\(pending.count)곡)…",
                                 action: pending.isEmpty ? nil : #selector(reflectSelected), keyEquivalent: "")
        reflect.target = self
        menu.addItem(reflect)
        if !pending.isEmpty {
            let xml = NSMenuItem(title: "선택한 곡 반영 XML 만들기 (\(pending.count)곡)…", action: #selector(exportReflectionXML), keyEquivalent: "")
            xml.target = self
            menu.addItem(xml)
        }
        let staged = targets.filter(\.isStaged)
        if !staged.isEmpty {
            let add = NSMenuItem(title: "rekordbox에 바로 넣기 (\(staged.count)곡)…", action: #selector(addToRekordbox), keyEquivalent: "")
            add.target = self
            menu.addItem(add)
            let export = NSMenuItem(title: "추가한 곡 rekordbox XML로 내보내기 (\(staged.count)곡)…", action: #selector(exportStaged), keyEquivalent: "")
            export.target = self
            menu.addItem(export)
        }
        menu.addItem(.separator())
        let pendingList = NSMenuItem(title: "rekordbox 반영 대기 목록 보기", action: #selector(showPending), keyEquivalent: "")
        pendingList.target = self
        menu.addItem(pendingList)
        let removable = targets.filter { !$0.isStaged && !$0.track.isStreaming }
        if !removable.isEmpty {
            menu.addItem(.separator())
            let remove = NSMenuItem(title: "rekordbox에서 빼기 (\(removable.count)곡)…", action: #selector(deleteFromRekordbox), keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
        }
    }

    @objc private func addToRekordbox() {
        DirectWritePanels.addTracks(store: store, rows: menuTargets())
    }

    @objc private func deleteFromRekordbox() {
        DirectWritePanels.deleteTracks(store: store, rows: menuTargets())
    }

    @objc private func reflectSelected() {
        DirectWritePanels.write(store: store, rows: menuTargets())
    }

    @objc private func exportReflectionXML() {
        ReflectionPanels.export(store: store, rows: menuTargets())
    }

    @objc private func exportStaged() {
        store.selection = Set(menuTargets().filter(\.isStaged).map(\.id))
        StagingPanels.exportXML(store: store)
    }

    @objc private func showPending() {
        store.sidebar = .pending
    }

    // MARK: - 데이터 소스

    // MARK: - 칸 보이기·숨기기

    func makeColumnMenu(_ table: NSTableView) -> NSMenu {
        let menu = NSMenu(title: "칸")
        menu.delegate = self
        menu.identifier = NSUserInterfaceItemIdentifier("columns")
        return menu
    }

    private func fillColumnMenu(_ menu: NSMenu) {
        guard let table else { return }
        menu.removeAllItems()
        let header = NSMenuItem(title: "보일 칸", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for spec in TrackColumn.all {
            if spec.id == "class", commentPreset?.rule == nil { continue }
            guard let column = table.tableColumns.first(where: { $0.identifier.rawValue == spec.id }) else { continue }
            let title = spec.title.isEmpty ? "앨범 아트" : spec.id == "edited" ? "초안 표시" : spec.title == "#" ? "# 번호" : spec.title
            let item = NSMenuItem(title: title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.state = column.isHidden ? .off : .on
            item.representedObject = spec.id
            // 제목 칸은 숨기지 않는다.
            item.isEnabled = spec.id != "title"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let reset = NSMenuItem(title: "모든 칸 보이기", action: #selector(showAllColumns), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let column = table?.tableColumns.first(where: { $0.identifier.rawValue == id }) else { return }
        guard id != "class" || commentPreset?.rule != nil else { return }
        column.isHidden.toggle()
        if id == "class" { store.settings.set(SettingKeys.commentClassColumnHidden, column.isHidden) }
    }

    @objc func showAllColumns() {
        table?.tableColumns.forEach { $0.isHidden = $0.identifier.rawValue == "class" && commentPreset?.rule == nil }
        if commentPreset?.rule != nil { store.settings.set(SettingKeys.commentClassColumnHidden, false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// 드래그로는 여러 곡을 고르지 않는다(클릭 한 곡, Shift = 범위, ⌘ = 하나씩 더하기·빼기).
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDragged,
              event.modifierFlags.intersection([.shift, .command]).isEmpty else { return proposed }
        return tableView.selectedRowIndexes
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        tableColumn?.identifier.rawValue == "title" ? rows[row].title : nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, rows.indices.contains(index) else { return nil }
        let row = rows[index]
        switch id {
        case "preview":
            let cell = reuse(tableView, "preview") { PreviewWaveformCell() }
            cell.configure(url: RekordboxShare.analysisURL(row.track.analysisDataPath),
                           revision: "\(snapshotURL?.absoluteString ?? ""):\(previewRevision)", mode: waveformMode,
                           audioURL: row.track.isStreaming ? nil : URL(filePath: row.track.folderPath), key: row.track.uuid,
                           cues: PerfProbe.previewCuesVisible ? PreviewCueMark.current(saved: row.cues, draft: previewCues[row.track.uuid]) : [],
                           duration: Double(row.track.lengthSeconds))
            return cell
        case "thumb":
            let cell = reuse(tableView, "thumb") { ThumbnailCell() }
            cell.configure(track: row.track)
            return cell
        case "edited":
            let cell = reuse(tableView, "edited") { EditedMarkCell() }
            cell.configure(edited: edited.contains(row.track.uuid))
            return cell
        default:
            let cell = reuse(tableView, "text") { TextCell() }
            cell.fonts = fonts
            configure(cell, column: id, row: row, index: index)
            return cell
        }
    }

    private func reuse<Cell: NSView>(_ table: NSTableView, _ identifier: String, make: () -> Cell) -> Cell {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let cell = table.makeView(withIdentifier: id, owner: nil) as? Cell { return cell }
        let cell = make()
        cell.identifier = id
        return cell
    }

    private func configure(_ cell: TextCell, column: String, row: TrackRow, index: Int) {
        switch column {
        case "index": cell.set("\(row.historyTrackNumber ?? (index + 1))", color: .tertiaryLabelColor, digits: true)
        case "title": cell.set(row.title, color: .labelColor)
        case "artist": cell.set(row.artist, color: .secondaryLabelColor)
        case "genre": cell.set(row.genre, color: .secondaryLabelColor)
        case "album": cell.set(row.album, color: .secondaryLabelColor)
        case "comment":
            if row.comment.isEmpty {
                cell.set("—", color: .tertiaryLabelColor)
            } else {
                cell.set(row.comment, color: row.commentEvaluation?.isMatch == true ? .labelColor : .secondaryLabelColor)
            }
        case "class": cell.set(row.commentClassName, color: row.commentEvaluation?.tone.nsTint ?? .secondaryLabelColor)
        case "bpm": cell.set(row.bpmValue > 0 ? String(format: "%.0f", row.bpmValue) : "", color: .secondaryLabelColor, digits: true)
        case "key": cell.set(row.keyName, color: .secondaryLabelColor)
        case "length": cell.set(row.lengthText, color: .secondaryLabelColor, digits: true)
        case "format": cell.set(row.formatName, color: .secondaryLabelColor)
        case "tempo": cell.set(row.tempoChangeText, color: UIColors.tempo.nsColor, digits: true)
        case "imported": cell.set(row.importedOn, color: .secondaryLabelColor, digits: true)
        case "plays": cell.set(row.playCount > 0 ? "\(row.playCount)" : "", color: .labelColor, digits: true)
        case "hotCues":
            let hot = cueCounts[row.track.uuid]?.hot ?? row.hotCueCount
            cell.set(hot > 0 ? "\(hot)" : "", color: UIColors.hot.nsColor, digits: true)
        case "memoryCues":
            // DJCrate에서 찍은 큐(초안)가 있으면 그 개수를 보여 준다(반영 전이라도).
            if let counts = cueCounts[row.track.uuid] {
                cell.set(counts.memory > 0 ? "\(counts.memory)" : (counts.hot > 0 ? "" : "없음"),
                         color: counts.memory > 0 ? UIColors.memory.nsColor : UIColors.warning.nsColor, digits: true)
                break
            }
            switch row.cueState {
            case .none: cell.set("없음", color: UIColors.warning.nsColor)
            case .autoOnly: cell.set("자동", color: .tertiaryLabelColor)
            case .manual: cell.set(row.memoryCueCount > 0 ? "\(row.memoryCueCount)" : "", color: UIColors.memory.nsColor, digits: true)
            }
        default: cell.set("", color: .labelColor)
        }
    }
}

// MARK: - 셀

private final class TextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var normalColor = NSColor.labelColor

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColor() }
    }

    private func updateColor() {
        label.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : normalColor
    }

    /// 글자 배율에 맞춘 본문·숫자 글꼴(표가 배율이 바뀔 때 한 번 만든다)
    struct Fonts {
        let text: NSFont
        let digits: NSFont

        init(scale: Double) {
            let size = TextScale.pointSize(NSFont.systemFontSize, scale: scale)
            text = NSFont.systemFont(ofSize: size)
            digits = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        }
    }

    var fonts = Fonts(scale: 1)

    init() {
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ text: String, color: NSColor, digits: Bool = false) {
        if label.stringValue != text { label.stringValue = text }
        normalColor = color
        updateColor()
        let font = digits ? fonts.digits : fonts.text
        if label.font != font { label.font = font }
    }
}

/// 썸네일은 백그라운드에서 디코딩해 받아 온다. 셀이 다른 곡으로 재사용되면 늦게 온 결과는 버린다.
private final class ThumbnailCell: NSTableCellView {
    private let thumb = NSImageView()
    private var showingPlaceholder = true
    private var key: String?
    private var task: Task<Void, Never>?
    private static let placeholder: NSImage? = {
        let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "앨범 커버 없음")
        return image?.withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
    }()

    init() {
        super.init(frame: .zero)
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 3
        thumb.layer?.masksToBounds = true
        thumb.contentTintColor = .tertiaryLabelColor
        thumb.setAccessibilityLabel("앨범 커버")
        addSubview(thumb)
        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: 22),
            thumb.heightAnchor.constraint(equalToConstant: 22),
            thumb.centerXAnchor.constraint(equalTo: centerXAnchor),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(track: Track) {
        guard key != track.id else { return }
        key = track.id
        task?.cancel()
        show(nil)
        let path = track.imagePath, id = track.id
        task = Task { [weak self] in
            let box = await Thumbnails.shared.image(imagePath: path, key: id)
            guard !Task.isCancelled, let self, self.key == id else { return }
            self.show(box.map { NSImage(cgImage: $0.image, size: NSSize(width: 22, height: 22)) })
        }
    }

    private func show(_ image: NSImage?) {
        thumb.image = image ?? Self.placeholder
        thumb.imageScaling = image == nil ? .scaleNone : .scaleProportionallyUpOrDown
        showingPlaceholder = image == nil
        updateBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            thumb.layer?.backgroundColor = showingPlaceholder ? NSColor.quaternarySystemFill.cgColor : nil
        }
    }
}

private final class EditedMarkCell: NSTableCellView {
    private let mark = NSImageView()
    private static let image = NSImage(systemSymbolName: DraftMark.symbol, accessibilityDescription: "초안 있음")

    init() {
        super.init(frame: .zero)
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.contentTintColor = UIColors.draft.nsColor
        addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            mark.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : UIColors.draft.nsColor
        }
    }

    func configure(edited: Bool) {
        mark.image = edited ? Self.image : nil
        toolTip = edited ? "DJCrate 초안이 있습니다 (rekordbox·파일에는 아직 반영 안 됨)" : nil
    }
}

extension CommentEvaluation.Tone {
    var tint: Color { Color(nsColor: nsTint) }

    var nsTint: NSColor {
        switch self {
        case .matched: UIColors.hot.nsColor
        case .empty: UIColors.warning.nsColor
        case .info: UIColors.info.nsColor
        case .residue: UIColors.memory.nsColor
        case .secondary: .secondaryLabelColor
        }
    }
}
