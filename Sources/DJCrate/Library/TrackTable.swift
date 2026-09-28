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
        TrackListView(store: store, mode: deck.waveformColorMode, deckPlaying: deck.isPlaying)
    }
}

private struct TrackListView: NSViewRepresentable {
    let store: LibraryStore
    let mode: WaveformColorMode
    /// 덱에 올린 곡의 # 칸 스피커 모양(재생 중이면 소리 나는 모양)
    let deckPlaying: Bool

    func makeCoordinator() -> TrackListCoordinator { TrackListCoordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = TrackListTableView()
        table.identifier = KeyRouter.trackListID
        table.coordinator = context.coordinator
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
            if spec.id == "thumb" {
                column.headerCell.attributedStringValue = TrackColumn.artworkHeader
                column.headerCell.setAccessibilityLabel(spec.title)
            }
            if spec.id == "edited" {
                column.headerCell.attributedStringValue = TrackColumn.draftHeader
                column.headerCell.setAccessibilityLabel(spec.title)
            }
            column.isHidden = TrackColumn.hiddenByDefault.contains(spec.id)
            table.addTableColumn(column)
        }
        table.menu = context.coordinator.makeMenu()
        // 앱 안에서는 재생 목록에 넣거나 순서를 바꾸고, 앱 밖에는 음원 파일을 복사한다.
        table.registerForDraggedTypes([PlaylistDragType.pasteboardTracks])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.draggingDestinationFeedbackStyle = .gap
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
        // 새 태그 칸(#88)도 저장된 배치에는 없어 끝으로 밀린다. 한 번만 앨범 옆으로 옮긴다(처음엔 숨김).
        let tagKey = "djc.trackList.tagColumnsPlaced"
        if !UserDefaults.standard.bool(forKey: tagKey) {
            var anchor = "album"
            for id in ["albumArtist", "composer", "year", "trackNumber"] {
                if let from = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }),
                   let to = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == anchor }) {
                    table.moveColumn(from, toColumn: from > to ? to + 1 : to)
                }
                anchor = id
            }
            UserDefaults.standard.set(true, forKey: tagKey)
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
        context.coordinator.updateWriteLock(store.isWritingRekordbox)
        context.coordinator.updateTextScale(context.environment.textScale)
        context.coordinator.updateCommentPreset(store.commentPreset)
        context.coordinator.update(rows: store.displayRows, edited: store.listMarkedUUIDs,
                                   selection: store.selection, sortOrder: store.sortOrder, snapshotURL: store.snapshotURL,
                                   previewRevision: store.previewRevision)
        context.coordinator.updateTagRevision(store.tagRevision)
        context.coordinator.updateCueCounts(store.draftCueCounts)
        context.coordinator.updatePreviewCues(store.draftPreviewCues)
        context.coordinator.updateWaveformMode(mode)
        context.coordinator.updateDeck(trackID: store.deckTrackID, playing: deckPlaying)
    }
}

struct TrackColumn {
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
        TrackColumn(id: "index", title: "#", width: 48, minWidth: 48, help: String(ui: "지금 목록에서 몇 번째 곡인지")),
        TrackColumn(id: "thumb", title: String(ui: "앨범 아트"), width: 26, minWidth: 26, help: String(ui: "앨범 아트")),
        TrackColumn(id: "edited", title: String(ui: "초안"), width: 18, minWidth: 18, help: String(ui: "DJCrate 초안이 있는 곡 (rekordbox·파일에 쓰기 전)")),
        TrackColumn(id: "title", title: String(ui: "제목"), width: 220, minWidth: 140, flexible: true, sortKey: "title"),
        TrackColumn(id: "preview", title: String(ui: "미리 보기"), width: 160, minWidth: 80,
                    help: String(ui: "곡 전체 파형과 핫큐·메모리 큐·루프 위치")),
        TrackColumn(id: "artist", title: String(ui: "아티스트"), width: 140, minWidth: 80, flexible: true, sortKey: "artist"),
        TrackColumn(id: "album", title: String(ui: "앨범"), width: 150, minWidth: 60, flexible: true, sortKey: "album"),
        TrackColumn(id: "albumArtist", title: String(ui: "앨범 아티스트"), width: 120, minWidth: 60, flexible: true, sortKey: "albumArtist"),
        TrackColumn(id: "composer", title: String(ui: "작곡가"), width: 110, minWidth: 60, flexible: true, sortKey: "composer"),
        TrackColumn(id: "year", title: String(ui: "연도"), width: 46, minWidth: 38, sortKey: "year", ascendingFirst: false),
        TrackColumn(id: "trackNumber", title: String(ui: "트랙 번호"), width: 60, minWidth: 40, sortKey: "trackNumber"),
        TrackColumn(id: "genre", title: String(ui: "장르"), width: 90, minWidth: 50, flexible: true, sortKey: "genre"),
        TrackColumn(id: "comment", title: String(ui: "코멘트"), width: 250, minWidth: 140, flexible: true, sortKey: "comment"),
        TrackColumn(id: "class", title: String(ui: "분류"), width: 52, minWidth: 40, sortKey: "class", help: String(ui: "코멘트 분류: 규칙·구형·잔재·크레딧·빈 값·기타")),
        TrackColumn(id: "bpm", title: "BPM", width: 44, minWidth: 34, sortKey: "bpm", ascendingFirst: false),
        TrackColumn(id: "key", title: String(ui: "키"), width: 36, minWidth: 30, sortKey: "key"),
        TrackColumn(id: "length", title: String(ui: "길이"), width: 46, minWidth: 38, sortKey: "length", ascendingFirst: false, help: String(ui: "곡 전체 재생 시간")),
        TrackColumn(id: "format", title: String(ui: "형식"), width: 44, minWidth: 36, sortKey: "format", help: String(ui: "파일 확장자(MP3·M4A·FLAC·WAV 등)")),
        TrackColumn(id: "tempo", title: String(ui: "변속"), width: 90, minWidth: 44, sortKey: "tempo", ascendingFirst: false,
                    help: String(ui: "rekordbox 그리드에서 BPM이 바뀌는 곡의 흐름(예: 175→128→175)")),
        TrackColumn(id: "imported", title: String(ui: "임포트"), width: 86, minWidth: 70, sortKey: "imported", ascendingFirst: false),
        TrackColumn(id: "plays", title: String(localized: "library.column.plays", defaultValue: "재생", bundle: UIStrings.bundle), width: 42, minWidth: 34, sortKey: "plays", ascendingFirst: false),
        TrackColumn(id: "hotCues", title: String(ui: "핫큐"), width: 42, minWidth: 34, sortKey: "hotCues", ascendingFirst: false,
                    help: String(ui: "직접 찍은 핫큐 수(초록)")),
        TrackColumn(id: "memoryCues", title: String(ui: "메모리"), width: 50, minWidth: 40, sortKey: "memoryCues", ascendingFirst: false,
                    help: String(ui: "직접 찍은 메모리 큐 수(빨강). rekordbox 자동 큐만 있으면 '자동'")),
    ]

    /// 처음에 숨기는 칸(머리글 오른쪽 클릭으로 보인다). 태그 칸은 모두 목록에서 바로 고칠 수 있게 두되(#88) 자주 쓰지 않는 칸은 숨긴다.
    static let hiddenByDefault: Set<String> = ["preview", "albumArtist", "composer", "year", "trackNumber"]

    /// 초안 칸 머리글: 글자 '✎' 대신 pencil 심볼을 머리글 글자색·크기로 넣는다(칸이 좁아 '초안'이 들어가지 않는다).
    /// 제목 '초안'은 칸 메뉴와 VoiceOver에 쓴다.
    @MainActor static var draftHeader: NSAttributedString {
        symbolHeader("pencil", label: String(ui: "초안"))
    }

    // NSTableHeaderCell은 image를 직접 그리지 않아 초안 머리글처럼 글자 안에 심볼을 넣는다.
    @MainActor static var artworkHeader: NSAttributedString {
        symbolHeader("photo", label: String(ui: "앨범 아트"))
    }

    @MainActor private static func symbolHeader(_ symbol: String, label: String) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
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
        case "albumArtist": return KeyPathComparator(\TrackRow.albumArtist, order: order)
        case "composer": return KeyPathComparator(\TrackRow.composer, order: order)
        case "year": return KeyPathComparator(\TrackRow.releaseYear, order: order)
        case "trackNumber": return KeyPathComparator(\TrackRow.trackNumber, order: order)
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
        case \TrackRow.albumArtist: "albumArtist"
        case \TrackRow.composer: "composer"
        case \TrackRow.releaseYear: "year"
        case \TrackRow.trackNumber: "trackNumber"
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
final class TrackListCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let store: LibraryStore
    weak var table: NSTableView?
    private var rows: [TrackRow] = []
    private var largestRowIndex = 0
    private var rowIDs: [TrackRow.ID] = []
    private var edited: Set<String> = []
    private var snapshotURL: URL?
    private var previewRevision = 0
    private var commentPreset: CommentPreset?
    private var classHiddenWhenEnabled = false
    private var waveformMode = WaveformColorMode.threeBand
    private var previewCues: [String: [PreviewCueMark]] = [:]
    private var textScale = 1.0
    private var fonts = TrackTextCell.Fonts(scale: 1)
    private var tagRevision = 0
    /// 표 → 스토어로 선택·정렬을 넘기는 중에는 스토어 → 표 동기화를 건너뛴다(되먹임 방지).
    private var syncing = false

    /// 칸에서 바로 고치는 중인 태그(#88). 대상 곡과 시작 값은 편집을 시작할 때 정한다.
    private struct InlineEdit {
        let row: Int
        let column: String
        let session: TrackListTagEditing.Session
        weak var cell: TrackTextCell?
        weak var field: NSTextField?
    }
    private var inlineEdit: InlineEdit?
    /// 다시 누른 태그 칸을 고치기 전 기다림(더블클릭이면 취소)
    private var pendingEdit: Task<Void, Never>?
    /// 줄 끌기를 시작한 횟수. 누른 줄을 끌었으면(덱에 놓기 등) 그 클릭으로 칸을 고치지 않는다.
    private(set) var dragGeneration = 0
    /// 덱에 올린 곡(ContentID)과 재생 중인지. # 칸에 스피커로 보인다.
    private var deckTrackID: String?
    private var deckPlaying = false
    var isEditing: Bool { inlineEdit != nil }
    /// 고치는 중인 칸 이름(시험용)
    var editingColumn: String? { inlineEdit?.column }

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
        cancelEditing()
        reloadVisible(table)
    }

    /// 글자 배율(보기 › 글자 크게·작게)이 바뀌면 글자 크기와 줄 높이를 함께 바꾼다. 보이지 않는 줄은 나타날 때 새 글자로 채운다.
    func updateTextScale(_ scale: Double) {
        guard scale != textScale, let table else { return }
        textScale = scale
        fonts = TrackTextCell.Fonts(scale: scale)
        table.rowHeight = TextScale.length(24, scale: scale)
        updateIndexWidth(table)
        cancelEditing()
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
            // 줄이 바뀌면(필터·검색·정렬·새 스냅샷) 고치던 칸을 먼저 닫는다. 편집 위치가 줄 번호라 그대로 두면 다른 곡에 남는다.
            cancelPendingEdit()
            cancelEditing()
            let ids = rows.map(\.id)
            let reordered = ids != rowIDs
            self.rows = rows
            largestRowIndex = max(rows.count, rows.compactMap { $0.historyTrackNumber ?? $0.playlistTrackNumber }.max() ?? 0)
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
        updateIndexWidth(table)
    }

    private func updateIndexWidth(_ table: NSTableView) {
        guard let column = table.tableColumns.first(where: { $0.identifier.rawValue == "index" }) else { return }
        let width = ceil((String(largestRowIndex) as NSString).size(withAttributes: [.font: fonts.digits]).width) + 12
        // 저장된 v2 배치가 좁아도 번호·글자 배율에 필요한 너비를 되찾는다.
        column.minWidth = max(48, width)
        column.width = max(column.width, column.minWidth)
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
        // 머리글을 눌러 정렬을 바꾸면 줄이 바뀌기 전에 고치던 칸을 확정한다.
        finishEditing(commit: true, restoreFocus: true)
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
        // 누른 줄(없으면 고른 첫 줄)을 덱에 올린다(#93). ⌘→는 고른 첫 곡을 올린다.
        let load = NSMenuItem(title: String(ui: "덱에 불러오기"), action: loadMenuRowIndex == nil ? nil : #selector(loadMenuRow),
                              keyEquivalent: Self.loadKey)
        load.keyEquivalentModifierMask = .command
        load.target = self
        menu.addItem(load)
        let pending = targets.filter { !$0.isStaged && store.pendingUUIDs.contains($0.track.uuid) }
        if !pending.isEmpty {
            menu.addItem(.separator())
            let reflect = NSMenuItem(title: String(ui: "선택한 곡 rekordbox에 쓰기 (\(pending.count)곡)…"),
                                     action: #selector(reflectSelected), keyEquivalent: "")
            reflect.target = self
            menu.addItem(reflect)
            let xml = NSMenuItem(title: String(ui: "선택한 곡 XML 만들기 (\(pending.count)곡)"), action: #selector(exportReflectionXML), keyEquivalent: "")
            xml.target = self
            menu.addItem(xml)
        }
        addPlaylistItems(to: menu, targets: targets)
        let staged = targets.filter(\.isStaged)
        if !staged.isEmpty {
            menu.addItem(.separator())
            let add = NSMenuItem(title: String(ui: "rekordbox에 바로 넣기 (\(staged.count)곡)…"), action: #selector(addToRekordbox), keyEquivalent: "")
            add.target = self
            menu.addItem(add)
            let export = NSMenuItem(title: String(ui: "추가한 곡 XML 만들기 (\(staged.count)곡)"), action: #selector(exportStaged), keyEquivalent: "")
            export.target = self
            menu.addItem(export)
        }
        menu.addItem(.separator())
        let pendingList = NSMenuItem(title: String(ui: "rekordbox 쓰기 대기 목록 보기"), action: #selector(showPending), keyEquivalent: "")
        pendingList.target = self
        menu.addItem(pendingList)
        let removable = targets.filter { !$0.isStaged && !$0.track.isStreaming }
        if !store.isITunesSelection, !removable.isEmpty {
            menu.addItem(.separator())
            // 재생 목록에서 빼기(⌫, 초안)와 헷갈리지 않게 컬렉션에서 지운다는 것을 적는다.
            let remove = NSMenuItem(title: String(ui: "rekordbox 컬렉션에서 빼기 (\(removable.count)곡)…"), action: #selector(deleteFromRekordbox), keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
        }
    }

    /// 메뉴의 '덱에 불러오기'가 올릴 줄: 오른쪽 클릭한 줄, 없으면 고른 첫 줄.
    private var loadMenuRowIndex: Int? {
        guard let table else { return nil }
        let index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRowIndexes.first ?? -1
        return rows.indices.contains(index) ? index : nil
    }

    @objc private func loadMenuRow() {
        if let index = loadMenuRowIndex { loadRow(at: index) }
    }

    @objc private func addToRekordbox() {
        DirectWritePanels.addTracks(store: store, rows: menuTargets())
    }

    @objc private func deleteFromRekordbox() {
        DirectWritePanels.deleteTracks(store: store, rows: menuTargets())
    }

    @objc private func reflectSelected() {
        // 고른 곡의 초안만 쓴다(재생 목록 초안은 ⇧⌘E·반영 대기 목록에서).
        DirectWritePanels.write(store: store, rows: menuTargets(), playlists: false)
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
        let menu = NSMenu(title: String(ui: "칸"))
        menu.delegate = self
        menu.identifier = NSUserInterfaceItemIdentifier("columns")
        return menu
    }

    private func fillColumnMenu(_ menu: NSMenu) {
        guard let table else { return }
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: String(ui: "보일 칸")))
        for spec in TrackColumn.all {
            if spec.id == "class", commentPreset?.rule == nil { continue }
            guard let column = table.tableColumns.first(where: { $0.identifier.rawValue == spec.id }) else { continue }
            let title = spec.title.isEmpty ? String(ui: "앨범 아트") : spec.id == "edited" ? String(ui: "초안 표시") : spec.title == "#" ? String(ui: "# 번호") : spec.title
            let item = NSMenuItem(title: title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.state = column.isHidden ? .off : .on
            item.representedObject = spec.id
            // 제목 칸은 숨기지 않는다.
            item.isEnabled = spec.id != "title"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let reset = NSMenuItem(title: String(ui: "모든 칸 보이기"), action: #selector(showAllColumns), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let column = table?.tableColumns.first(where: { $0.identifier.rawValue == id }) else { return }
        guard id != "class" || commentPreset?.rule != nil else { return }
        finishEditing(commit: true, restoreFocus: true)
        column.isHidden.toggle()
        if id == "class" { store.settings.set(SettingKeys.commentClassColumnHidden, column.isHidden) }
    }

    @objc func showAllColumns() {
        finishEditing(commit: true, restoreFocus: true)
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
        case "index":
            let cell = reuse(tableView, "index") { TrackIndexCell() }
            cell.configure(number: "\(row.historyTrackNumber ?? row.playlistTrackNumber ?? (index + 1))", font: fonts.digits,
                           deck: row.track.id == deckTrackID ? .init(playing: deckPlaying) : nil)
            return cell
        default:
            let cell = reuse(tableView, "text") { TrackTextCell() }
            // 고치던 칸이 다른 자리로 다시 쓰이면(스크롤로 줄이 사라짐) 그 입력을 확정한다. 대상 곡은 편집을 시작할 때 정해 두었다.
            if let edit = inlineEdit, edit.cell === cell, edit.row != index || edit.column != id {
                Task { @MainActor [weak self] in self?.finishEditing(commit: true, restoreFocus: true) }
            }
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

    private func configure(_ cell: TrackTextCell, column: String, row: TrackRow, index: Int) {
        if let key = TrackListTagEditing.key(forColumn: column) {
            configureTag(cell, key: key, row: row)
            return
        }
        switch column {
        case "class":
            // 코멘트 초안이 있으면 초안 코멘트로 다시 가른다(반영 전 값이라 초안 표식을 붙인다).
            let draft = store.tagDrafts[row.track.uuid]
            let evaluation = TrackListTagEditing.commentEvaluation(row, draft: draft, rule: commentPreset?.rule)
            cell.set(evaluation?.displayName ?? "", color: evaluation?.tone.nsTint ?? .secondaryLabelColor,
                     draft: draft.map { $0.base.comment != $0.fields.comment } ?? false)
        case "bpm": cell.set(row.bpmValue > 0 ? String(format: "%.0f", row.bpmValue) : "", color: .secondaryLabelColor, digits: true)
        case "key":
            // 추가한 곡의 추정 키는 제안 색·기울임으로 구분하고, 툴팁·VoiceOver로 "추정"을 알린다(#124).
            cell.set(row.keyName, color: row.keyEstimated ? UIColors.suggestion.nsColor : .secondaryLabelColor,
                     estimated: row.keyEstimated)
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
            // 큐 없는 곡은 핫큐 칸처럼 비운다(사이드바 '큐 없음'으로 찾는다, #121).
            let label = row.memoryCueLabel(draft: cueCounts[row.track.uuid])
            cell.set(label.text, color: label == .autoOnly ? .tertiaryLabelColor : UIColors.memory.nsColor, digits: label != .autoOnly)
        default: cell.set("", color: .labelColor)
        }
    }

    /// 태그 칸: 초안 값이면 초안 색·모서리 표식·VoiceOver "초안"으로 보인다(태그 시트와 같다, #34).
    private func configureTag(_ cell: TrackTextCell, key: TagFields.Key, row: TrackRow) {
        let (text, edited) = TrackListTagEditing.text(row, key, draft: store.tagDrafts[row.track.uuid])
        // 스트리밍 곡은 제목 앞 아이콘과 흐린 글자로 로컬 곡과 구분한다(사이드바 '스트리밍'과 같은 아이콘, #121).
        let streaming = key == .title && row.track.isStreaming
        let color: NSColor = switch key {
        case .title: streaming ? .secondaryLabelColor : .labelColor
        case .comment: row.commentEvaluation?.isMatch == true ? .labelColor : .secondaryLabelColor
        default: .secondaryLabelColor
        }
        if key == .comment, text.isEmpty {
            cell.set("—", color: edited ? UIColors.draft.nsColor : .tertiaryLabelColor, draft: edited)
        } else {
            cell.set(text, color: edited ? UIColors.draft.nsColor : color,
                     digits: key == .year || key == .trackNumber, draft: edited,
                     symbol: streaming ? LibraryFilter.streaming.systemImage : nil, symbolLabel: streaming ? String(ui: "스트리밍 곡") : nil)
        }
    }

    // MARK: - 칸에서 바로 태그 고치기(#88)

    /// 태그 초안이 바뀌면(목록·시트·인스펙터·되돌리기·외부 초안) 보이는 태그 칸과 분류 칸을 제자리에서 다시 채운다.
    /// 다시 불러오지 않으므로 고치던 칸이 닫히지 않는다.
    func updateTagRevision(_ revision: Int) {
        guard revision != tagRevision, let table else { return }
        tagRevision = revision
        refreshTagCells(table)
    }

    /// rekordbox에 쓰기 시작하면 고치던 칸을 닫는다(쓰는 동안에는 초안을 바꾸지 않는다).
    func updateWriteLock(_ locked: Bool) {
        if locked { cancelEditing() }
    }

    private func refreshTagCells(_ table: NSTableView) {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        let columns = table.tableColumns.indices.filter {
            let id = table.tableColumns[$0].identifier.rawValue
            return TrackListTagEditing.key(forColumn: id) != nil || id == "class"
        }
        for index in visible.location..<NSMaxRange(visible) where rows.indices.contains(index) {
            for column in columns {
                guard let cell = table.view(atColumn: column, row: index, makeIfNecessary: false) as? TrackTextCell else { continue }
                configure(cell, column: table.tableColumns[column].identifier.rawValue, row: rows[index], index: index)
            }
        }
    }

    private func visibleColumnIDs(_ table: NSTableView) -> [String] {
        table.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue)
    }

    // MARK: - 덱에 불러오기(#93)

    /// 더블클릭: 누른 줄의 곡을 덱에 올린다(rekordbox와 같다). 한 번 클릭은 고르기만 한다.
    @objc func doubleClicked(_ sender: Any?) {
        guard let table else { return }
        loadRow(at: table.clickedRow)
    }

    /// 이 줄의 곡을 덱에 올린다. 다시 누른 칸을 고치려고 기다리던 것은 취소한다(더블클릭의 첫 클릭이었다).
    func loadRow(at index: Int) {
        cancelPendingEdit()
        guard rows.indices.contains(index) else { return }
        store.loadToDeck(rows[index])
    }

    /// ⌘→: 고른 줄 중 표에서 첫 곡을 덱에 올린다.
    func loadSelection() {
        guard let index = table?.selectedRowIndexes.first else { return }
        loadRow(at: index)
    }

    /// 목록·메뉴에 보이는 불러오기 키(⌘ 와 함께)
    static let loadKey = String(UnicodeScalar(NSRightArrowFunctionKey)!)

    /// 덱에 올린 곡이나 재생 상태가 바뀌면 그 곡의 # 칸만 다시 그린다.
    func updateDeck(trackID: String?, playing: Bool) {
        guard trackID != deckTrackID || playing != deckPlaying, let table else { return }
        let changed = Set([deckTrackID, trackID].compactMap { $0 })
        deckTrackID = trackID
        deckPlaying = playing
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "index" }) else { return }
        let indexes = IndexSet(rows.indices.filter { changed.contains(rows[$0].track.id) })
        if !indexes.isEmpty { table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: column)) }
    }

    // MARK: - 다시 눌러 고치기(#88)

    /// 이미 고른 줄의 태그 칸을 다시 누르면, 더블클릭이 아닌 것을 확인한 뒤(더블클릭 간격) 그 칸을 고친다(Finder 이름 바꾸기처럼).
    func scheduleEdit(row index: Int, column: String, after delay: Duration = .seconds(NSEvent.doubleClickInterval)) {
        cancelPendingEdit()
        guard TrackListTagEditing.key(forColumn: column) != nil, rows.indices.contains(index) else { return }
        let id = rows[index].id
        pendingEdit = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let table = self.table else { return }
            self.pendingEdit = nil
            // 그 사이 줄·선택·포커스가 바뀌었거나 아직 누르고 있으면(끌기) 고치지 않는다.
            // 선택 알림은 늦게 올 때가 있어 알림으로 취소하지 않고 여기서 본다.
            guard self.rows.indices.contains(index), self.rows[index].id == id,
                  table.selectedRowIndexes == IndexSet(integer: index), table.window?.firstResponder === table,
                  NSEvent.pressedMouseButtons == 0 else { return }
            self.beginEditing(row: index, column: column)
        }
    }

    /// 다시 누른 칸을 고치려고 기다리는 중인지(시험용)
    var hasPendingEdit: Bool { pendingEdit != nil }

    func cancelPendingEdit() {
        pendingEdit?.cancel()
        pendingEdit = nil
    }

    /// Return·Enter: 고른 줄 중 표에서 첫 곡(스트리밍 제외)의 보이는 첫 태그 칸부터 고친다(Finder 이름 바꾸기처럼).
    @discardableResult
    func beginEditingSelection() -> Bool {
        guard let table, let column = TrackListTagEditing.firstColumn(in: visibleColumnIDs(table)),
              let row = table.selectedRowIndexes.first(where: { rows.indices.contains($0) && !rows[$0].track.isStreaming })
        else { return false }
        return beginEditing(row: row, column: column)
    }

    /// 칸 자리에 입력 칸을 띄운다. 고른 줄 안이면 고른 곡 모두가 대상이다(인스펙터 여러 곡 편집과 같다).
    @discardableResult
    func beginEditing(row index: Int, column: String) -> Bool {
        guard inlineEdit == nil, store.writeLockPolicy.allowsLibraryInteraction, let table, rows.indices.contains(index),
              let key = TrackListTagEditing.key(forColumn: column),
              let columnIndex = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == column && !$0.isHidden })
        else { return false }
        let selected = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        let targets = TrackListTagEditing.targets(anchor: rows[index], selection: selected)
        guard let session = TrackListTagEditing.Session(key: key, targets: targets, value: { store.tagCell($0, key) }) else { return false }
        table.scrollRowToVisible(index)
        table.scrollColumnToVisible(columnIndex)
        guard let cell = table.view(atColumn: columnIndex, row: index, makeIfNecessary: true) as? TrackTextCell else { return false }
        let field = cell.beginEditing(text: session.original,
                                      placeholder: session.mixed ? String(ui: "(여러 값 — 입력하면 모두 바뀜)") : nil)
        field.delegate = self
        field.setAccessibilityLabel(key.label)
        if targets.count > 1 {
            let help = String(ui: "고른 \(targets.count)곡에 모두 적용합니다")
            field.toolTip = help
            field.setAccessibilityHelp(help)
        }
        inlineEdit = InlineEdit(row: index, column: column, session: session, cell: cell, field: field)
        table.window?.makeFirstResponder(field)
        return true
    }

    func cancelEditing() {
        finishEditing(commit: false, restoreFocus: true)
    }

    /// 편집을 끝낸다. 키나 표 쪽 사정으로 끝낼 때만 표로 포커스를 되돌린다(다른 곳을 눌러 끝나면 그곳에 둔다).
    /// - Parameter forward: Tab(true)·⇧Tab(false)이면 확정 뒤 보이는 옆 태그 칸을 이어서 고친다.
    private func finishEditing(commit: Bool, restoreFocus: Bool, thenMove forward: Bool? = nil) {
        guard let edit = inlineEdit, let table else { return }
        inlineEdit = nil
        let value = edit.field?.stringValue ?? edit.session.original
        if restoreFocus { table.window?.makeFirstResponder(table) }
        edit.cell?.endEditing()
        if commit {
            let targets = TrackListTagEditing.changes(edit.session, committing: value)
            if !targets.isEmpty { store.setTag(edit.session.key, value, rows: targets) }
        }
        refreshTagCells(table)
        if let forward, let next = TrackListTagEditing.column(after: edit.column, forward: forward, in: visibleColumnIDs(table)) {
            beginEditing(row: edit.row, column: next)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard inlineEdit?.field === control else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): finishEditing(commit: true, restoreFocus: true)
        case #selector(NSResponder.insertTab(_:)): finishEditing(commit: true, restoreFocus: true, thenMove: true)
        case #selector(NSResponder.insertBacktab(_:)): finishEditing(commit: true, restoreFocus: true, thenMove: false)
        case #selector(NSResponder.cancelOperation(_:)): finishEditing(commit: false, restoreFocus: true)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // 다른 곳을 눌러 칸을 벗어나면 확정한다(태그 시트와 같다).
        guard let field = notification.object as? NSTextField, inlineEdit?.field === field else { return }
        finishEditing(commit: true, restoreFocus: false)
    }
}

/// 곡 목록 표. 한 번 클릭은 고르기만 하고, 더블클릭·⌘→로 덱에 올린다(#93).
/// 곡을 고른 채 Return·Enter를 누르거나 이미 고른 줄의 태그 칸을 다시 누르면 그 칸을 바로 고친다(#88). 나머지 키는 표가 처리한다.
final class TrackListTableView: NSTableView {
    weak var coordinator: TrackListCoordinator? {
        didSet {
            target = coordinator
            doubleAction = #selector(TrackListCoordinator.doubleClicked(_:))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), column = column(at: point)
        let slowEdit = TrackListTagEditing.startsSlowEdit(clickCount: event.clickCount, row: row, selected: selectedRowIndexes,
                                                          modifiers: event.modifierFlags)
        coordinator?.cancelPendingEdit()
        let drags = coordinator?.dragGeneration
        super.mouseDown(with: event)
        // 누른 채 끌어 놓았으면(끌기가 마우스를 놓기 전에 시작됨) 고치지 않는다.
        if slowEdit, coordinator?.dragGeneration == drags, tableColumns.indices.contains(column) {
            coordinator?.scheduleEdit(row: row, column: tableColumns[column].identifier.rawValue)
        }
    }

    override func keyDown(with event: NSEvent) {
        coordinator?.cancelPendingEdit()
        // ⌘→: 고른 곡을 덱에 올린다. 목록에서 ⌘ 조합은 덱 단축키로 가지 않고 여기로 온다(→·⇧→는 덱의 박·마디 이동).
        if event.specialKey == .rightArrow, event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            coordinator?.loadSelection()
            return
        }
        // Return(36)·Enter(76)는 덱 단축키로 줄 수 없는 예약 키라 덱과 부딪히지 않는다.
        if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           coordinator?.beginEditingSelection() == true { return }
        super.keyDown(with: event)
    }
}

// MARK: - 셀

/// 목록 글자 칸. 태그 초안이면 왼쪽 위 모서리 표식과 VoiceOver 값 "…, 초안"을 붙이고(#34),
/// 칸에서 바로 고칠 때(#88)는 목록 글자를 가리고 같은 자리에 입력 칸을 띄운다.
final class TrackTextCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    private let draftMark = DraftCornerView()
    private var normalColor = NSColor.labelColor
    /// 글자 앞 작은 심볼(스트리밍 곡 제목, #121). 쓰는 칸이 드물어 처음 필요할 때 만든다.
    private var icon: NSImageView?
    private var labelLeading: NSLayoutConstraint!
    /// 보이는 글자 앞 심볼 이름(시험용)
    private(set) var leadingSymbol: String?
    private var iconPointSize: CGFloat = 0
    /// 접근성 값을 한 번이라도 덮었는지. 셀에 nil을 넣으면 기본값으로 돌아가지 않아 그 뒤로는 글자를 계속 넣는다.
    private var speaksCustomValue = false
    private var field: NSTextField?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColor() }
    }

    private func updateColor() {
        let emphasized = backgroundStyle == .emphasized
        label.textColor = emphasized ? .alternateSelectedControlTextColor : normalColor
        icon?.contentTintColor = label.textColor
        draftMark.color = emphasized ? .alternateSelectedControlTextColor : UIColors.draft.nsColor
    }

    /// 글자 배율에 맞춘 본문·숫자 글꼴(표가 배율이 바뀔 때 한 번 만든다)
    struct Fonts {
        let text: NSFont
        let digits: NSFont
        /// 추정값(추가한 곡의 추정 키)
        let estimated: NSFont

        init(scale: Double) {
            let size = TextScale.pointSize(NSFont.systemFontSize, scale: scale)
            text = NSFont.systemFont(ofSize: size)
            digits = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
            estimated = NSFontManager.shared.convert(text, toHaveTrait: .italicFontMask)
        }
    }

    var fonts = Fonts(scale: 1)

    /// 칸 글자·초안 표식(시험용)
    var text: String { label.stringValue }
    var showsDraftMark: Bool { !draftMark.isHidden }

    init() {
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        draftMark.translatesAutoresizingMaskIntoConstraints = false
        draftMark.isHidden = true
        addSubview(draftMark)
        labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        NSLayoutConstraint.activate([
            labelLeading,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            draftMark.leadingAnchor.constraint(equalTo: leadingAnchor),
            draftMark.topAnchor.constraint(equalTo: topAnchor),
            draftMark.widthAnchor.constraint(equalToConstant: 7),
            draftMark.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// - Parameter draft: 반영 전 초안 값. 색과 함께 모서리 표식·VoiceOver "초안"으로도 알린다.
    /// - Parameter estimated: DJCrate 추정값. 색과 함께 기울임·툴팁·VoiceOver "추정"으로도 알린다.
    /// - Parameter symbol: 글자 앞 SF 심볼. 칸을 다시 쓸 때마다 부르므로 nil이면 지운다.
    func set(_ text: String, color: NSColor, digits: Bool = false, draft: Bool = false, estimated: Bool = false,
             symbol: String? = nil, symbolLabel: String? = nil) {
        if label.stringValue != text { label.stringValue = text }
        let font = estimated ? fonts.estimated : digits ? fonts.digits : fonts.text
        if label.font != font { label.font = font }
        if symbol != leadingSymbol || (symbol != nil && iconPointSize != font.pointSize) {
            showSymbol(symbol, label: symbolLabel, pointSize: font.pointSize)
        }
        normalColor = color
        updateColor()
        if draftMark.isHidden == draft { draftMark.isHidden = !draft }
        let tip = estimated ? String(ui: "DJCrate가 소리로 추정한 키입니다. rekordbox 분석과 다를 수 있습니다") : nil
        if toolTip != tip { toolTip = tip }
        if draft || estimated || speaksCustomValue {
            let spoken = draft ? "\(text), \(DraftMark.spoken)" : estimated ? "\(text), \(String(ui: "추정"))" : text
            label.cell?.setAccessibilityValue(spoken)
            speaksCustomValue = true
        }
    }

    private func showSymbol(_ name: String?, label text: String?, pointSize: CGFloat) {
        leadingSymbol = name
        iconPointSize = pointSize
        if name != nil, icon == nil {
            let view = NSImageView()
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                view.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            icon = view
        }
        let image = name.flatMap { Self.symbolImage($0, label: text, pointSize: round(pointSize * 0.85)) }
        icon?.image = image
        icon?.toolTip = image == nil ? nil : text
        icon?.isHidden = image == nil
        // 제약을 켜고 끄지 않고 글자 시작점만 옮긴다(스크롤 중 칸을 다시 쓸 때 배치 비용을 줄인다).
        labelLeading.constant = 2 + (image.map { ceil($0.size.width) + 3 } ?? 0)
    }

    /// 스크롤로 칸을 다시 쓸 때마다 심볼 이미지를 새로 만들지 않는다.
    private static var symbolImages: [String: NSImage] = [:]

    private static func symbolImage(_ name: String, label: String?, pointSize: CGFloat) -> NSImage? {
        let key = "\(name)|\(label ?? "")|\(pointSize)"
        if let image = symbolImages[key] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        symbolImages[key] = image
        return image
    }

    /// 칸 자리에 입력 칸을 띄운다(목록 글자는 가린다). 끝나면 `endEditing`으로 걷는다.
    func beginEditing(text: String, placeholder: String?) -> NSTextField {
        endEditing()
        let field = NSTextField(string: text)
        field.font = label.font
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        label.isHidden = true
        self.field = field
        return field
    }

    func endEditing() {
        field?.removeFromSuperview()
        field = nil
        label.isHidden = false
    }
}

/// # 칸: 목록 순번. 덱에 올린 곡은 번호 대신 스피커로 보인다(재생 중이면 소리 나는 모양, Apple Music처럼, #93).
/// 색만이 아니라 모양으로 알리고, VoiceOver는 번호 대신 '덱에 올린 곡'을 읽는다.
final class TrackIndexCell: NSTableCellView {
    struct DeckState: Equatable {
        var playing: Bool
    }

    let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    /// 보이는 스피커 심볼(시험용). 덱에 올린 곡이 아니면 nil.
    private(set) var deckSymbol: String?
    private var iconPointSize: CGFloat = 0

    var text: String { label.stringValue }
    /// VoiceOver가 읽는 덱 상태(시험용)
    var spokenDeckState: String? { deckSymbol == nil ? nil : icon.accessibilityLabel() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColor() }
    }

    init() {
        super.init(frame: .zero)
        label.lineBreakMode = .byClipping
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.isHidden = true
        addSubview(icon)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(number: String, font: NSFont, deck: DeckState?) {
        if label.stringValue != number { label.stringValue = number }
        if label.font != font { label.font = font }
        let symbol = deck.map { $0.playing ? "speaker.wave.2.fill" : "speaker.fill" }
        label.isHidden = symbol != nil
        icon.isHidden = symbol == nil
        if symbol != deckSymbol || iconPointSize != font.pointSize {
            iconPointSize = font.pointSize
            let spoken = deck.map { $0.playing ? String(ui: "덱에 올린 곡, 재생 중") : String(ui: "덱에 올린 곡") }
            icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: spoken) }?
                .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular))
            icon.setAccessibilityLabel(spoken)
            icon.toolTip = spoken
        }
        deckSymbol = symbol
        updateColor()
    }

    private func updateColor() {
        let emphasized = backgroundStyle == .emphasized
        label.textColor = emphasized ? .alternateSelectedControlTextColor : .tertiaryLabelColor
        icon.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .controlAccentColor
    }
}

/// 썸네일은 백그라운드에서 디코딩해 받아 온다. 셀이 다른 곡으로 재사용되면 늦게 온 결과는 버린다.
private final class ThumbnailCell: NSTableCellView {
    private let thumb = NSImageView()
    private var showingPlaceholder = true
    private var key: String?
    private var task: Task<Void, Never>?
    private static let placeholder: NSImage? = {
        let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: String(ui: "앨범 커버 없음"))
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
        thumb.setAccessibilityLabel(String(ui: "앨범 커버"))
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
    private static let image = NSImage(systemSymbolName: DraftMark.symbol, accessibilityDescription: String(ui: "초안 있음"))

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
        toolTip = edited ? String(ui: "DJCrate 초안이 있습니다 (rekordbox·파일에 쓰기 전)") : nil
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

// MARK: - 재생 목록(#39)

extension TrackListCoordinator {
    /// 오른쪽 클릭 메뉴: '재생 목록에 넣기 ▸'(최근 목록 → 폴더 트리 → 찾아서 넣기·새 목록), 목록을 볼 때 '이 목록에서 빼기'
    fileprivate func addPlaylistItems(to menu: NSMenu, targets: [TrackRow]) {
        let tracks = targets.filter { !$0.isStaged }
        guard !tracks.isEmpty, store.snapshotURL != nil else { return }
        menu.addItem(.separator())
        let add = NSMenuItem(title: String(ui: "재생 목록에 넣기"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let recent = store.recentPlaylists
        for item in recent { submenu.addItem(playlistItem(item, path: store.playlistProjection.layout.ancestors(of: item.id).map(\.name))) }
        if !recent.isEmpty { submenu.addItem(.separator()) }
        fillPlaylistTree(submenu, parent: PlaylistLayout.root)
        if submenu.items.last?.isSeparatorItem == false { submenu.addItem(.separator()) }
        let find = NSMenuItem(title: String(ui: "찾아서 넣기…"), action: #selector(pickPlaylist), keyEquivalent: "")
        find.target = self
        submenu.addItem(find)
        let create = NSMenuItem(title: String(ui: "새 재생 목록으로 (\(tracks.count)곡)"), action: #selector(createPlaylistFromTracks), keyEquivalent: "")
        create.target = self
        submenu.addItem(create)
        add.submenu = submenu
        menu.addItem(add)
        if let id = store.editablePlaylistID, let name = store.playlistItem(id)?.name {
            let remove = NSMenuItem(title: String(ui: "‘\(name)’에서 빼기 (\(tracks.count)곡)"), action: #selector(removeFromPlaylist), keyEquivalent: "\u{8}")
            remove.keyEquivalentModifierMask = []
            remove.target = self
            menu.addItem(remove)
        }
    }

    private func fillPlaylistTree(_ menu: NSMenu, parent: String) {
        for item in store.playlistProjection.layout.children(of: parent) where !item.isSmart {
            if item.isFolder {
                let folder = NSMenuItem(title: item.name, action: nil, keyEquivalent: "")
                folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                let submenu = NSMenu()
                fillPlaylistTree(submenu, parent: item.id)
                if submenu.items.isEmpty {
                    let empty = NSMenuItem(title: String(ui: "(빈 폴더)"), action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    submenu.addItem(empty)
                }
                folder.submenu = submenu
                menu.addItem(folder)
            } else {
                menu.addItem(playlistItem(item, path: []))
            }
        }
    }

    private func playlistItem(_ item: PlaylistLayout.Item, path: [String]) -> NSMenuItem {
        let title = path.isEmpty ? item.name : (path + [item.name]).joined(separator: " › ")
        let menuItem = NSMenuItem(title: title, action: #selector(addToPlaylist(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = item.id
        menuItem.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: nil)
        return menuItem
    }

    @objc private func addToPlaylist(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.addTracks(menuTargets(), toPlaylist: id)
    }

    @objc private func removeFromPlaylist() {
        guard let id = store.editablePlaylistID else { return }
        store.removeTracks(menuTargets(), fromPlaylist: id)
    }

    @objc private func pickPlaylist() {
        store.openPlaylistPicker(tracks: menuTargets())
    }

    @objc private func createPlaylistFromTracks() {
        store.createPlaylist(isFolder: false, tracks: menuTargets())
    }

    // MARK: 끌어다 놓기

    /// 곡을 끌면 ID를 싣는다: 덱 위에 놓아 불러오기(#93), 사이드바 목록에 놓아 넣기, 목록 안에서 순서 바꾸기.
    /// 추가한 곡은 아직 rekordbox에 없어 재생 목록용으로는 싣지 않는다(덱에는 올릴 수 있다).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row), !isEditing else { return nil }
        let item = NSPasteboardItem()
        item.setString(rows[row].track.id, forType: DeckDragType.pasteboard)
        if !rows[row].isStaged { item.setString(rows[row].track.id, forType: PlaylistDragType.pasteboardTracks) }
        let track = rows[row].track
        if !track.isStreaming {
            let url = URL(filePath: track.folderPath)
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
               values.isRegularFile == true, values.isReadable == true {
                item.setString(url.absoluteString, forType: .fileURL)
            }
        }
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        dragGeneration += 1
        cancelPendingEdit()
    }

    /// 목록을 # 순서로 볼 때만 줄 사이에 놓아 순서를 바꾼다.
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as? NSTableView) === tableView, store.canReorderDisplayedTracks else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = store.editablePlaylistID, store.canReorderDisplayedTracks else { return false }
        let ids = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: PlaylistDragType.pasteboardTracks) }
        guard !ids.isEmpty else { return false }
        let moving = Set(ids)
        // 놓은 자리 아래에서 옮기지 않는 첫 곡 앞으로(없으면 맨 끝)
        let before = rows[min(row, rows.count)...].first { !moving.contains($0.track.id) }?.track.id
        store.moveTracks(ids, inPlaylist: id, before: before)
        return true
    }
}
