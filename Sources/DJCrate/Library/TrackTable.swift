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
            column.isHidden = TrackColumn.hiddenByDefault.contains(spec.id) || spec.id == TrackColumn.usbSyncID
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
        // 평점·곡 색 칸(#65)도 저장된 배치에는 없어 끝으로 밀린다. 한 번만 키 칸 뒤로 옮긴다.
        let ratingKey = "djc.trackList.ratingColorColumnsPlaced"
        if !UserDefaults.standard.bool(forKey: ratingKey) {
            var anchor = "key"
            for id in ["rating", "color"] {
                if let from = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }),
                   let to = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == anchor }) {
                    table.moveColumn(from, toColumn: from > to ? to + 1 : to)
                }
                anchor = id
            }
            if !PerfProbe.enabled { UserDefaults.standard.set(true, forKey: ratingKey) }
        }
        TrackColumn.migrateRatingWidth(in: table, remember: !PerfProbe.enabled)
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
        PerfProbe.count("TrackListView.update")
        context.coordinator.updateWriteLock(store.isWritingRekordbox)
        context.coordinator.updateUsbMode(store.isUsbSelection)
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
        TrackColumn(id: "thumb", title: String(ui: "앨범아트"), width: 26, minWidth: 26, help: String(ui: "앨범아트")),
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
        TrackColumn(id: "rating", title: String(ui: "평점"), width: ratingWidth, minWidth: ratingMinWidth, sortKey: "rating", ascendingFirst: false,
                    help: String(ui: "rekordbox 평점(별 1~5개). 더블클릭하면 고른다")),
        TrackColumn(id: "color", title: String(ui: "곡 색"), width: 70, minWidth: 30, sortKey: "color",
                    help: String(ui: "rekordbox 곡 색. 더블클릭하면 고른다")),
        TrackColumn(id: "length", title: String(ui: "길이"), width: 46, minWidth: 38, sortKey: "length", ascendingFirst: false, help: String(ui: "곡 전체 재생 시간")),
        TrackColumn(id: "format", title: String(ui: "형식"), width: 44, minWidth: 36, sortKey: "format", help: String(ui: "파일 확장자(MP3·M4A·FLAC·WAV 등)")),
        TrackColumn(id: "tempo", title: String(ui: "변속"), width: 90, minWidth: 44, sortKey: "tempo", ascendingFirst: false,
                    help: String(ui: "rekordbox 그리드에서 BPM이 바뀌는 곡의 흐름(예: 175→128→175)")),
        TrackColumn(id: "imported", title: String(ui: "임포트"), width: 86, minWidth: 70, sortKey: "imported", ascendingFirst: false),
        TrackColumn(id: "plays", title: String(localized: "library.column.plays", defaultValue: "재생", bundle: UIStrings.bundle), width: 42, minWidth: 34, sortKey: "plays", ascendingFirst: false),
        TrackColumn(id: "hotCues", title: String(ui: "핫큐"), width: 42, minWidth: 34, sortKey: "hotCues", ascendingFirst: false,
                    help: String(ui: "직접 찍은 핫큐 수(초록)")),
        TrackColumn(id: "memoryCues", title: String(ui: "메모리"), width: 50, minWidth: 40, sortKey: "memoryCues", ascendingFirst: false,
                    help: String(ui: "메모리 큐 수(빨강, rekordbox 자동 큐 포함). 자동 큐뿐이면 흐린 글자")),
        TrackColumn(id: usbSyncID, title: String(ui: "갱신 상태"), width: 96, minWidth: 60, sortKey: usbSyncID,
                    help: String(ui: "로컬 rekordbox 곡과 견준 USB 곡의 상태(USB 목록에서만 보인다)")),
    ]

    /// 평점 칸 기본 폭: 별 다섯 칸(`TrackRating.stars`, 13pt에서 65.6pt)과 글자 자리 여백 4pt가 들어가고 조금 남는다.
    /// 좁은 폭·큰 글자 배율에서는 칸이 알아서 "5★"로 줄여 보인다(`TrackTextCell.set(compact:)`).
    static let ratingWidth: CGFloat = 76

    /// 평점 칸 최소 폭: 가장 큰 글자 배율(1.5배, 19.5pt)에서도 숫자 표기("5★", 31pt)와 글자 자리 여백 4pt가 들어간다.
    static let ratingMinWidth: CGFloat = 40

    /// 평점 칸의 옛 기본 폭. 별 다섯 칸이 안 들어가 "★★★…"로 잘려 3·4·5가 같아 보였고(#65), 이 폭으로 저장된 배치가 남아 있다.
    static let legacyRatingWidth: CGFloat = 66

    /// 저장된 평점 칸 폭이 옛 기본 폭 그대로면 새 기본 폭. 사용자가 끌어 바꾼 폭은 건드리지 않는다(nil).
    static func migratedRatingWidth(saved: CGFloat) -> CGFloat? {
        saved == legacyRatingWidth ? ratingWidth : nil
    }

    static let ratingWidthMigratedKey = "djc.trackList.ratingWidthMigrated"

    /// 저장된 배치를 읽은 직후 한 번만: 옛 기본 폭(66) 그대로인 평점 칸을 새 기본 폭으로 넓힌다(#65).
    /// 한 번 했다는 표시를 남기므로 그 뒤 사용자가 일부러 66으로 줄여도 덮어쓰지 않는다(좁아도 칸이 숫자로 줄여 보여 읽힌다).
    /// - Parameter remember: 했다는 표시를 남길지(성능 측정 때는 칸 배치를 저장하지 않으므로 남기지 않는다)
    @MainActor static func migrateRatingWidth(in table: NSTableView, defaults: UserDefaults = .standard, remember: Bool = true) {
        guard !defaults.bool(forKey: ratingWidthMigratedKey) else { return }
        if let column = table.tableColumns.first(where: { $0.identifier.rawValue == "rating" }),
           let width = migratedRatingWidth(saved: column.width) {
            column.width = width
        }
        if remember { defaults.set(true, forKey: ratingWidthMigratedKey) }
    }

    /// USB 갱신 상태 칸. USB 목록을 볼 때만 보이고 다른 목록에서는 숨긴다
    static let usbSyncID = "usbSync"

    /// USB 목록에서 보이는 칸: # 번호·제목·아티스트·BPM·키·갱신 상태. 나머지는 USB에서 읽지 않았거나(큐·그리드·미리 보기)
    /// 로컬 초안·분류에 쓰는 칸이라 숨긴다
    static let usbColumns: Set<String> = ["index", "title", "artist", "bpm", "key", usbSyncID]

    /// USB 곡에서 읽지 않은 값의 칸(칸이 보이더라도 비운다 — 큐 없음·자동 같은 표시가 틀린 정보가 된다)
    static let usbUnreadColumns: Set<String> = ["hotCues", "memoryCues", "tempo"]

    /// 처음에 숨기는 칸(머리글 오른쪽 클릭으로 보인다). 태그 칸은 모두 목록에서 바로 고칠 수 있게 두되(#88) 자주 쓰지 않는 칸은 숨긴다.
    static let hiddenByDefault: Set<String> = ["preview", "albumArtist", "composer", "year", "trackNumber"]

    /// 초안 칸 머리글: 글자 '✎' 대신 pencil 심볼을 머리글 글자색·크기로 넣는다(칸이 좁아 '초안'이 들어가지 않는다).
    /// 제목 '초안'은 칸 메뉴와 VoiceOver에 쓴다.
    @MainActor static var draftHeader: NSAttributedString {
        symbolHeader("pencil", label: String(ui: "초안"))
    }

    // NSTableHeaderCell은 image를 직접 그리지 않아 초안 머리글처럼 글자 안에 심볼을 넣는다.
    @MainActor static var artworkHeader: NSAttributedString {
        symbolHeader("photo", label: String(ui: "앨범아트"))
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
        case "rating": return KeyPathComparator(\TrackRow.ratingValue, order: order)
        case "color": return KeyPathComparator(\TrackRow.colorSortKey, order: order)
        case "length": return KeyPathComparator(\TrackRow.lengthSeconds, order: order)
        case "format": return KeyPathComparator(\TrackRow.formatName, order: order)
        case "tempo": return KeyPathComparator(\TrackRow.tempoChangeCount, order: order)
        case "imported": return KeyPathComparator(\TrackRow.importedOn, order: order)
        case "plays": return KeyPathComparator(\TrackRow.playCount, order: order)
        case "hotCues": return KeyPathComparator(\TrackRow.hotCueCount, order: order)
        case "memoryCues": return KeyPathComparator(\TrackRow.memoryCueCount, order: order)
        case usbSyncID: return KeyPathComparator(\TrackRow.usbSyncText, order: order)
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
        case \TrackRow.ratingValue: "rating"
        case \TrackRow.colorSortKey: "color"
        case \TrackRow.lengthSeconds: "length"
        case \TrackRow.formatName: "format"
        case \TrackRow.tempoChangeCount: "tempo"
        case \TrackRow.importedOn: "imported"
        case \TrackRow.playCount: "plays"
        case \TrackRow.hotCueCount: "hotCues"
        case \TrackRow.memoryCueCount: "memoryCues"
        case \TrackRow.usbSyncText: usbSyncID
        default: nil
        }
    }
}

@MainActor
final class TrackListCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let store: LibraryStore
    private lazy var recoveryMenu = DraftRecoveryMenu(store: store)
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
    /// USB 목록을 보는 중(읽기 전용, 갱신 상태 칸을 보인다). 처음 한 번은 저장된 칸 배치와 무관하게 맞추려고 nil에서 시작한다
    private var usbMode: Bool?
    /// USB 목록에 들어가기 전의 칸 숨김 상태와 칸 배치 자동 저장 여부. 나오면 되돌린다
    private struct SavedLayout {
        var hidden: [String: Bool]
        var autosave: Bool
        /// 들어가기 전 칸 순서·너비. USB 칸 배치(갱신 상태 칸을 키 뒤로)와 남는 폭 나누기를 나올 때 직접 되돌린다(#241)
        var order: [String] = []
        var widths: [String: CGFloat] = [:]
    }
    private var usbSavedLayout: SavedLayout?
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
    /// 마우스 버튼이 눌려 있는지(누른 채 끌면 고치지 않는다). 시스템 전체 상태라 시험이 바꿔 끼운다.
    var isMouseDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }
    /// 줄 끌기를 시작한 횟수. 누른 줄을 끌었으면(덱에 놓기 등) 그 클릭으로 칸을 고치지 않는다.
    private(set) var dragGeneration = 0
    /// 덱에 올린 곡(ContentID)과 재생 중인지. # 칸에 스피커로 보인다.
    private var deckTrackID: String?
    private var deckPlaying = false
    /// 열려 있는 고르기 메뉴(키 #204, 평점·곡 색 #65). 메뉴 추적은 동기식이라 여는 동안만 있다.
    private var activeKeyMenu: NSMenu?
    var isEditing: Bool { inlineEdit != nil || activeKeyMenu != nil }
    /// 고치는 중인 칸 이름(시험용)
    var editingColumn: String? { inlineEdit?.column }
    /// 마지막으로 누른 칸(줄 ID와 칸 이름). 키 칸을 누른 뒤의 Return은 그 줄에서 키 메뉴를 연다(표에는 칸 커서가 없다).
    struct ClickedCell: Equatable {
        let rowID: TrackRow.ID
        let column: String
    }
    private(set) var clickedCell: ClickedCell?

    /// 누른 줄이 선택에서 빠졌으면(키보드로 옮김·검색에서 돌아옴·스토어가 다른 줄을 고름) 기억을 버린다.
    /// 클릭은 누른 줄을 고르므로 클릭 자체의 선택 알림에는 지워지지 않는다(알림 시점에 기대지 않는다).
    private func forgetClickedCell(unlessSelected ids: Set<TrackRow.ID>) {
        if let clicked = clickedCell, !ids.contains(clicked.rowID) { clickedCell = nil }
    }

    /// 누른 자리를 기억한다. 줄이나 칸 밖이면 잊는다.
    func noteClick(row: Int, column: String?) {
        clickedCell = rows.indices.contains(row) ? column.map { ClickedCell(rowID: rows[row].id, column: $0) } : nil
    }

    /// 메뉴 추적은 동기식이라 시험은 이것을 바꿔 끼워 표시만 보고 고르기는 따로 보낸다.
    var presentKeyMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: point, in: view)
    }

    init(store: LibraryStore) {
        self.store = store
    }

    // MARK: - 스토어 → 표

    func updateCommentPreset(_ preset: CommentPreset) {
        guard commentPreset != preset, let table,
              let column = table.tableColumns.first(where: { $0.identifier.rawValue == "class" }) else { return }
        // 강제로 숨긴 상태가 사용자가 고른 열 숨김 설정을 덮지 않게 따로 기억한다.
        // USB 목록을 보는 중이면 들어가기 전 상태를 기준으로 하고, 바뀐 숨김도 나올 때 돌릴 상태에 둔다.
        let hidden = usbSavedLayout?.hidden["class"] ?? column.isHidden
        if commentPreset == nil {
            classHiddenWhenEnabled = store.settings.defaults.object(forKey: SettingKeys.commentClassColumnHidden.name) as? Bool ?? hidden
        } else if commentPreset?.rule != nil {
            classHiddenWhenEnabled = hidden
        }
        store.settings.set(SettingKeys.commentClassColumnHidden, classHiddenWhenEnabled)
        commentPreset = preset
        if usbSavedLayout != nil {
            usbSavedLayout?.hidden["class"] = preset.rule == nil || classHiddenWhenEnabled
        } else {
            column.isHidden = preset.rule == nil || classHiddenWhenEnabled
        }
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
            clickedCell = nil
            let ids = rows.map(\.id)
            let reordered = ids != rowIDs
            self.rows = rows
            largestRowIndex = max(rows.count, rows.compactMap { $0.historyTrackNumber ?? $0.playlistTrackNumber }.max() ?? 0)
            rowIDs = ids
            self.edited = edited
            if reordered {
                replaceRows(table)
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
            forgetClickedCell(unlessSelected: selection)
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

    /// 줄이 바뀌면(사이드바 항목·정렬·검색) `reloadData`로 다시 불러오지 않는다. 그러면 만들어 둔 셀·행 뷰를 모두 버리고
    /// 새로 만들어 목록 전환마다 곡 수와 상관없이 무거웠다(#137). 줄 수만 알리고, 만들어 둔 줄(보이는 줄과 미리 준비한 줄)의 칸을 제자리에서 다시 채운다.
    /// `reloadData(forRowIndexes:)`도 쓰지 않는다. 칸을 뗐다 붙이며 줄마다 키 뷰 순서를 다시 계산해 그것만으로 전환 비용의 큰 몫이었다.
    private func replaceRows(_ table: NSTableView) {
        // 줄 수가 줄며 표가 선택을 잘라도 스토어 선택은 그대로 둔다(바로 뒤에 새 목록 기준으로 다시 고른다).
        // 표 높이는 기본으로 0.25초 동안 늘고 줄며 프레임마다 창을 다시 배치하므로 애니메이션 없이 바로 바꾼다.
        syncing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteNumberOfRowsChanged()
        }
        syncing = false
        let columns = table.tableColumns.map(\.identifier.rawValue)
        table.enumerateAvailableRowViews { rowView, index in
            guard rows.indices.contains(index) else { return }
            for (column, id) in columns.enumerated() {
                if let cell = rowView.view(atColumn: column) as? NSView { fill(cell, column: id, row: index) }
            }
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
        forgetClickedCell(unlessSelected: ids)
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
        clickedCell = nil
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
        if store.isUsbSelection || menuTargetsIncludeUsb {
            addReadOnlyItems(to: menu)
            return
        }
        let targets = menuTargets()
        // 누른 줄(없으면 고른 첫 줄)을 덱에 올린다(#93). ⌘→는 고른 첫 곡을 올린다.
        let load = NSMenuItem(title: String(ui: "덱에 불러오기"), action: loadMenuRowIndex == nil ? nil : #selector(loadMenuRow),
                              keyEquivalent: Self.loadKey)
        load.keyEquivalentModifierMask = .command
        load.target = self
        menu.addItem(load)
        recoveryMenu.append(to: menu, rows: targets)
        let pending = targets.filter { !$0.isStaged && store.pendingUUIDs.contains($0.track.uuid) }
        if !pending.isEmpty {
            menu.addItem(.separator())
            let reflect = NSMenuItem(title: String(ui: "선택한 곡 rekordbox에 쓰기 (\(pending.count)곡)"),
                                     action: #selector(reflectSelected), keyEquivalent: "")
            reflect.target = self
            menu.addItem(reflect)
            let xml = NSMenuItem(title: String(ui: "선택한 곡 XML 만들기 (\(pending.count)곡)"), action: #selector(exportReflectionXML), keyEquivalent: "")
            xml.target = self
            menu.addItem(xml)
        }
        addPlaylistItems(to: menu, targets: targets)
        addUsbItems(to: menu, targets: targets)
        let staged = targets.filter(\.isStaged)
        if !staged.isEmpty {
            menu.addItem(.separator())
            let add = NSMenuItem(title: String(ui: "rekordbox에 바로 넣기 (\(staged.count)곡)"), action: #selector(addToRekordbox), keyEquivalent: "")
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

    /// 오른쪽 클릭한 줄·고른 줄에 USB 곡이 있는지(USB 곡은 편집·쓰기 메뉴를 달지 않는다)
    private var menuTargetsIncludeUsb: Bool {
        guard let table else { return false }
        let clicked = table.clickedRow
        let indexes = clicked >= 0 && !table.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : table.selectedRowIndexes
        return indexes.contains { rows.indices.contains($0) && rows[$0].isUsb }
    }

    /// USB 곡은 직접 고치지 않는다: 덱 불러오기도 아직 닫혀 있음을 비활성 항목으로 알리고, 고치기는 USB 초안 항목으로만 한다
    private func addReadOnlyItems(to menu: NSMenu) {
        let load = NSMenuItem(title: String(ui: "덱에 불러오기"), action: nil, keyEquivalent: "")
        load.isEnabled = false
        menu.addItem(load)
        guard !addUsbEditItems(to: menu) else { return }
        let note = NSMenuItem(title: String(ui: "USB 곡은 읽기만 합니다"), action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
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
            // 갱신 상태 칸은 USB 목록이 정한다
            if spec.id == TrackColumn.usbSyncID { continue }
            guard let column = table.tableColumns.first(where: { $0.identifier.rawValue == spec.id }) else { continue }
            let title = spec.title.isEmpty ? String(ui: "앨범아트") : spec.id == "edited" ? String(ui: "초안 표시") : spec.title == "#" ? String(ui: "# 번호") : spec.title
            // USB 목록의 칸은 정해져 있다(상태만 보이고 바꾸지 않는다)
            let item = NSMenuItem(title: title, action: usbMode == true ? nil : #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.state = column.isHidden ? .off : .on
            item.representedObject = spec.id
            // 제목 칸은 숨기지 않는다.
            item.isEnabled = spec.id != "title"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let reset = NSMenuItem(title: String(ui: "모든 칸 보이기"), action: usbMode == true ? nil : #selector(showAllColumns), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let column = table?.tableColumns.first(where: { $0.identifier.rawValue == id }) else { return }
        guard id != "class" || commentPreset?.rule != nil, usbMode != true else { return }
        finishEditing(commit: true, restoreFocus: true)
        column.isHidden.toggle()
        if id == "class" { store.settings.set(SettingKeys.commentClassColumnHidden, column.isHidden) }
    }

    @objc func showAllColumns() {
        guard usbMode != true else { return }
        finishEditing(commit: true, restoreFocus: true)
        table?.tableColumns.forEach {
            let id = $0.identifier.rawValue
            $0.isHidden = (id == "class" && commentPreset?.rule == nil) || id == TrackColumn.usbSyncID
        }
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
        let cell: NSView = switch id {
        case "preview": reuse(tableView, "preview") { PreviewWaveformCell() }
        case "thumb": reuse(tableView, "thumb") { ThumbnailCell() }
        case "edited": reuse(tableView, "edited") { EditedMarkCell() }
        case "index": reuse(tableView, "index") { TrackIndexCell() }
        default: reuse(tableView, "text") { TrackTextCell() }
        }
        // 고치던 칸이 다른 자리로 다시 쓰이면(스크롤로 줄이 사라짐) 그 입력을 확정한다. 대상 곡은 편집을 시작할 때 정해 두었다.
        if let edit = inlineEdit, edit.cell === cell, edit.row != index || edit.column != id {
            Task { @MainActor [weak self] in self?.finishEditing(commit: true, restoreFocus: true) }
        }
        fill(cell, column: id, row: index)
        return cell
    }

    /// 칸 하나를 그 줄의 곡으로 채운다(새로 만들었거나 다시 쓴 칸, 목록이 바뀌어 제자리에서 다시 채우는 칸).
    private func fill(_ view: NSView, column id: String, row index: Int) {
        let row = rows[index]
        switch view {
        case let cell as PreviewWaveformCell:
            // USB 곡은 음원에서 파형을 새로 만들지 않는다(USB를 오래 읽고 로컬 캐시를 채운다)
            cell.configure(url: RekordboxShare.analysisURL(row.track.analysisDataPath),
                           revision: "\(snapshotURL?.absoluteString ?? ""):\(previewRevision)", mode: waveformMode,
                           audioURL: row.track.isStreaming || row.isUsb ? nil : URL(filePath: row.track.folderPath), key: row.track.uuid,
                           cues: PerfProbe.previewCuesVisible ? PreviewCueMark.current(saved: row.cues, draft: previewCues[row.track.uuid]) : [],
                           duration: Double(row.track.lengthSeconds))
        case let cell as ThumbnailCell:
            cell.configure(track: row.track)
        case let cell as EditedMarkCell:
            cell.configure(edited: edited.contains(row.track.uuid))
        case let cell as TrackIndexCell:
            cell.configure(number: "\(row.historyTrackNumber ?? row.playlistTrackNumber ?? (index + 1))", font: fonts.digits,
                           deck: row.track.id == deckTrackID ? .init(playing: deckPlaying) : nil)
        case let cell as TrackTextCell:
            cell.fonts = fonts
            configure(cell, column: id, row: row, index: index)
        default: break
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
        if row.isUsb, TrackColumn.usbUnreadColumns.contains(column) {
            cell.set("", color: .secondaryLabelColor)
            return
        }
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
        case "length": cell.set(row.lengthText, color: .secondaryLabelColor, digits: true)
        case "format": cell.set(row.formatName, color: .secondaryLabelColor)
        case TrackColumn.usbSyncID:
            // 최신이 아니면(갱신 가능·기기에서 고침·로컬에 없음) 주의 색
            let settled = row.usbSync.map { if case .upToDate = $0 { true } else { false } } ?? true
            cell.set(row.usbSyncText, color: settled ? .secondaryLabelColor : UIColors.warning.nsColor)
        case "tempo": cell.set(row.tempoChangeText, color: UIColors.tempo.nsColor, digits: true)
        case "imported": cell.set(row.importedOn, color: .secondaryLabelColor, digits: true)
        case "plays": cell.set(row.playCount > 0 ? "\(row.playCount)" : "", color: .labelColor, digits: true)
        case "hotCues":
            let hot = cueCounts[row.track.uuid]?.hot ?? row.hotCueCount
            cell.set(hot > 0 ? "\(hot)" : "", color: UIColors.hot.nsColor, digits: true)
        case "memoryCues":
            // DJCrate에서 찍은 큐(초안)가 있으면 그 개수를 보여 준다(반영 전이라도).
            // 큐 없는 곡은 핫큐 칸처럼 비운다(사이드바 '큐 없음'으로 찾는다, #121). 자동 큐뿐이면 흐린 글자(#145).
            let label = row.memoryCueLabel(draft: cueCounts[row.track.uuid])
            let autoOnly = if case .autoOnly = label { true } else { false }
            cell.set(label.text, color: autoOnly ? .tertiaryLabelColor : UIColors.memory.nsColor, digits: true)
        default: cell.set("", color: .labelColor)
        }
    }

    /// 태그 칸: 초안 값이면 초안 색·모서리 표식·VoiceOver "초안"으로 보인다(태그 시트와 같다, #34).
    private func configureTag(_ cell: TrackTextCell, key: TagFields.Key, row: TrackRow) {
        if key == .rating || key == .color {
            // 평점은 별, 곡 색은 색 점과 rekordbox 이름. 초안이면 초안 색·표식·VoiceOver "초안"(다른 태그 칸과 같다)
            let (value, edited) = TrackListTagEditing.text(row, key, draft: store.tagDrafts[row.track.uuid])
            let colors = store.trackColors
            let text = TagChoice.display(key, value, colors: colors)
            // 별 다섯 칸이 안 들어가는 폭에서는 "5★"로 줄인다(잘린 "★★★…"은 3·4·5가 같아 보인다, #65)
            cell.set(text, color: edited ? UIColors.draft.nsColor : .secondaryLabelColor, draft: edited,
                     swatch: key == .color ? TagChoice.swatchImage(value) : nil, spoken: TagChoice.spoken(key, value, colors: colors),
                     compact: key == .rating ? TrackRating.compact(value) : nil)
            if let reason = TrackListTagEditing.unavailableReason(row, key: key) { cell.toolTip = reason }
            return
        }
        if key == .musicalKey {
            let edited = store.isTagEdited(row, key)
            // 키를 고치지 않은 추가 곡은 다른 태그 초안이 있어도 음원 태그·추정 제안을 그대로 보인다(#5).
            let estimated = !edited && row.keyEstimated
            cell.set(edited ? store.tagCell(row, key) : row.keyName,
                     color: edited ? UIColors.draft.nsColor : estimated ? UIColors.suggestion.nsColor : .secondaryLabelColor,
                     draft: edited, estimated: estimated)
            if let reason = KeyPicker.unavailableReason(row) { cell.toolTip = reason }
            return
        }
        let (text, edited) = TrackListTagEditing.text(row, key, draft: store.tagDrafts[row.track.uuid])
        // 스트리밍 곡은 제목 앞 아이콘과 흐린 글자로 로컬 곡과 구분한다(사이드바 '스트리밍'과 같은 아이콘, #121).
        // 파일이 없는 곡도 흐린 글자에 경고 아이콘을 붙인다(#126).
        let streaming = key == .title && row.track.isStreaming
        let missing = key == .title && row.fileMissing
        let color: NSColor = switch key {
        case .title: streaming || missing ? .secondaryLabelColor : .labelColor
        case .comment: row.commentEvaluation?.isMatch == true ? .labelColor : .secondaryLabelColor
        default: .secondaryLabelColor
        }
        if key == .comment, text.isEmpty {
            cell.set("—", color: edited ? UIColors.draft.nsColor : .tertiaryLabelColor, draft: edited)
        } else {
            cell.set(text, color: edited ? UIColors.draft.nsColor : color,
                     digits: key == .year || key == .trackNumber, draft: edited,
                     symbol: streaming ? LibraryFilter.streaming.systemImage : missing ? WarningMark.symbol : nil,
                     symbolLabel: streaming ? String(ui: "스트리밍 곡") : missing ? String(ui: "파일을 찾지 못한 곡") : nil,
                     symbolColor: missing ? UIColors.warning.nsColor : nil)
        }
        if let reason = TrackListTagEditing.unavailableReason(row, key: key) { cell.toolTip = reason }
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

    /// USB 목록이면 USB 칸(`TrackColumn.usbColumns`)만 보이고 갱신 상태 칸을 키 칸 바로 뒤에 둔다.
    /// 나오면 들어가기 전 칸 순서·너비·숨김 상태로 돌리고 갱신 상태 칸은 숨긴다. 고치던 칸은 닫는다.
    func updateUsbMode(_ usb: Bool) {
        guard usbMode != usb else { return }
        usbMode = usb
        cancelPendingEdit()
        cancelEditing()
        clickedCell = nil
        guard let table else { return }
        if usb {
            // USB 목록의 칸 배치가 사용자 칸 배치로 저장되지 않게 자동 저장을 멈춘 뒤 바꾼다(켠 채 앱을 끝내도 로컬 배치가 남게)
            usbSavedLayout = SavedLayout(hidden: Dictionary(table.tableColumns.map { ($0.identifier.rawValue, $0.isHidden) },
                                                            uniquingKeysWith: { first, _ in first }),
                                         autosave: table.autosaveTableColumns,
                                         order: table.tableColumns.map(\.identifier.rawValue),
                                         widths: Dictionary(table.tableColumns.map { ($0.identifier.rawValue, $0.width) },
                                                            uniquingKeysWith: { first, _ in first }))
            table.autosaveTableColumns = false
            for column in table.tableColumns { column.isHidden = !TrackColumn.usbColumns.contains(column.identifier.rawValue) }
            let ids = table.tableColumns.map(\.identifier.rawValue)
            if let from = ids.firstIndex(of: TrackColumn.usbSyncID), let key = ids.firstIndex(of: "key"), from != key + 1 {
                table.moveColumn(from, toColumn: from > key ? key + 1 : key)
            }
        } else {
            let saved = usbSavedLayout
            usbSavedLayout = nil
            // 순서는 moveColumn으로 먼저 되돌린다. 자동 저장을 다시 켜면 AppKit이 저장된 배치를 읽어 moveColumn 없이 순서·너비를 바꾸고,
            // 그 뒤 머리글이 USB 때 칸 순서·숨김으로 그린 모양으로 남아 데이터 열과 어긋났다(#241). 끝에서 머리글·표도 다시 그린다.
            for (target, id) in (saved?.order ?? []).enumerated() {
                if let from = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }), from != target,
                   target < table.numberOfColumns {
                    table.moveColumn(from, toColumn: target)
                }
            }
            for column in table.tableColumns {
                let id = column.identifier.rawValue
                column.isHidden = id == TrackColumn.usbSyncID || (saved?.hidden[id] ?? column.isHidden)
            }
            // 칸을 다시 보이면 남는 폭을 나눠 가진 칸 너비가 바뀌므로 숨김을 다 돌린 뒤 너비를 맞춘다
            for column in table.tableColumns {
                if let width = saved?.widths[column.identifier.rawValue], column.width != width { column.width = width }
            }
            if let saved { table.autosaveTableColumns = saved.autosave }
        }
        table.tile()
        table.headerView?.needsDisplay = true
        table.needsDisplay = true
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

    /// 더블클릭: 누른 곡을 덱에 올린다(rekordbox와 같다). 키 칸은 키 고르기 메뉴를 연다(#204). 한 번 클릭은 고르기만 한다.
    @objc func doubleClicked(_ sender: Any?) {
        guard let table else { return }
        let column = table.tableColumns.indices.contains(table.clickedColumn)
            ? table.tableColumns[table.clickedColumn].identifier.rawValue : nil
        doubleClicked(row: table.clickedRow, column: column)
    }

    /// 그 칸을 고칠 수 없는 곡(USB·스트리밍, 평점·곡 색은 추가한 곡·확인 밖 곡)이나 쓰는 중이면 메뉴 칸도 다른 칸처럼 덱에 올린다(경고로 막지 않는다).
    func doubleClicked(row index: Int, column: String?) {
        cancelPendingEdit()
        if let column, TrackListTagEditing.isMenuColumn(column), let key = TrackListTagEditing.key(forColumn: column), canPick(key, row: index) {
            beginEditing(row: index, column: column)
        } else {
            loadRow(at: index)
        }
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
        // 키 칸은 메뉴라 클릭 한 번에 저절로 열지 않는다(더블클릭·Return으로 연다)
        guard TrackListTagEditing.isTextColumn(column), rows.indices.contains(index), !rows[index].isUsb else { return }
        let id = rows[index].id
        pendingEdit = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let table = self.table else { return }
            self.pendingEdit = nil
            // 그 사이 줄·선택·포커스가 바뀌었거나 아직 누르고 있으면(끌기) 고치지 않는다.
            // 선택 알림은 늦게 올 때가 있어 알림으로 취소하지 않고 여기서 본다.
            guard self.rows.indices.contains(index), self.rows[index].id == id,
                  table.selectedRowIndexes == IndexSet(integer: index), table.window?.firstResponder === table,
                  !self.isMouseDown() else { return }
            self.beginEditing(row: index, column: column)
        }
    }

    /// 다시 누른 칸을 고치려고 기다리는 중인지(시험용)
    var hasPendingEdit: Bool { pendingEdit != nil }

    func cancelPendingEdit() {
        pendingEdit?.cancel()
        pendingEdit = nil
    }

    /// Return·Enter: 방금 누른 줄이 고른 줄 안에 있고 고칠 수 있으면(스트리밍·USB 제외) 그 줄에서, 아니면 고른 줄 중 표에서 첫 곡에서
    /// 보이는 첫 태그 칸부터 고친다(Finder 이름 바꾸기처럼). 방금 키 칸을 눌렀으면 그 줄에서 키 고르기 메뉴를 연다(#204).
    /// 누른 줄이 선택에서 빠졌거나 기억이 지워졌으면 보이는 첫 글자 칸이다. 어느 줄에서 시작하든 고칠 곡은 고른 곡 모두다.
    @discardableResult
    func beginEditingSelection() -> Bool {
        guard let table else { return false }
        let selected = table.selectedRowIndexes
        let isEditable = { (index: Int) in self.rows.indices.contains(index) && !self.rows[index].track.isStreaming && !self.rows[index].isUsb }
        let clicked = clickedCell.flatMap { cell in
            selected.first { isEditable($0) && rows[$0].id == cell.rowID }.map { (row: $0, column: cell.column) }
        }
        guard let row = clicked?.row ?? selected.first(where: isEditable),
              let column = TrackListTagEditing.firstColumn(in: visibleColumnIDs(table), clicked: clicked?.column)
        else { return false }
        return beginEditing(row: row, column: column)
    }

    /// 칸 자리에 입력 칸을 띄운다. 고른 줄 안이면 고른 곡 모두가 대상이다(인스펙터 여러 곡 편집과 같다).
    @discardableResult
    func beginEditing(row index: Int, column: String) -> Bool {
        if rows.indices.contains(index), let reason = TrackListTagEditing.unavailableReason(rows[index], key: TrackListTagEditing.key(forColumn: column)) {
            store.stagingMessage = AppMessage(kind: .warning, text: reason)
            return false
        }
        guard !isEditing, store.writeLockPolicy.allowsLibraryInteraction, let table, rows.indices.contains(index), !rows[index].isUsb,
              let key = TrackListTagEditing.key(forColumn: column),
              let columnIndex = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == column && !$0.isHidden })
        else { return false }
        if TagChoice.keys.contains(key) {
            // 키·평점·곡 색은 글자 대신 메뉴로 고른다. 메뉴는 고를 때까지 돌아오지 않는다.
            guard let menu = choiceMenu(key, row: index) else { return false }
            table.scrollRowToVisible(index)
            table.scrollColumnToVisible(columnIndex)
            let rect = table.frameOfCell(atColumn: columnIndex, row: index)
            activeKeyMenu = menu
            defer { activeKeyMenu = nil }
            presentKeyMenu(menu, NSPoint(x: rect.minX, y: rect.maxY), table)
            return true
        }
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
        activeKeyMenu?.cancelTracking()
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

    // MARK: - 키·평점·곡 색 고르기(#204·#65)

    /// 이 줄의 고르기 메뉴를 열 수 있는지: 쓰는 중이 아니고 그 칸을 고칠 수 있는 곡(USB·스트리밍, 평점·곡 색은 추가한 곡·확인 밖 곡 제외)
    private func canPick(_ key: TagFields.Key, row index: Int) -> Bool {
        store.writeLockPolicy.allowsLibraryInteraction && rows.indices.contains(index)
            && TrackListTagEditing.unavailableReason(rows[index], key: key) == nil
    }

    private struct Choice {
        let key: TagFields.Key
        let targets: [TrackRow]
        let value: String
    }

    /// 키 칸의 고르기 메뉴(`choiceMenu(.musicalKey, row:)`)
    func keyMenu(row index: Int) -> NSMenu? { choiceMenu(.musicalKey, row: index) }

    /// 고르기 메뉴: 키는 없음·Camelot 24개, 평점은 없음·별 1~5개, 곡 색은 없음·rekordbox 색(태그 시트와 같다). 지금 값에 체크하고, 고를 수 없는
    /// 현재 값(옛 표기 키·모르는 색 번호)은 맨 앞에 흐리게 보인다. 누른 줄이 고른 줄 안이면 고른 곡 모두(고칠 수 없는 곡은 빼고)가 대상이다.
    /// 값이 서로 다르면 아무 항목에도 체크하지 않는다.
    func choiceMenu(_ key: TagFields.Key, row index: Int) -> NSMenu? {
        guard canPick(key, row: index), let table else { return nil }
        let selected = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        let targets = TagChoice.targets(key, TrackListTagEditing.targets(anchor: rows[index], selection: selected))
        guard !targets.isEmpty else { return nil }
        return TagChoice.menu(key, current: store.tagValue(key, rows: targets), colors: store.trackColors, targetCount: targets.count,
                              action: #selector(pickKey(_:)), target: self) { Choice(key: key, targets: targets, value: $0) }
    }

    @objc private func pickKey(_ sender: NSMenuItem) {
        guard store.writeLockPolicy.allowsLibraryInteraction, let choice = sender.representedObject as? Choice,
              TagChoice.accepted(choice.key, choice.value, colors: store.trackColors) == choice.value else { return }
        // 초안은 고를 때만 만든다(열기·취소는 그대로, #5). 여러 값에서 "없음"을 고르면 모두 비운다.
        // 메뉴를 연 사이 목록이 바뀌어도 엉뚱한 곡에 들어가지 않게 줄 ID로 다시 찾는다.
        // 줄 ID는 계산 값이라 대상마다 줄 전체를 훑지 않고, 캐시한 ID(rowIDs)를 한 번만 훑는다(같은 ID가 겹치면 앞 줄).
        let wanted = Set(choice.targets.map(\.id))
        var firstIndex: [TrackRow.ID: Int] = [:]
        for (index, id) in rowIDs.enumerated() where wanted.contains(id) && firstIndex[id] == nil {
            firstIndex[id] = index
            if firstIndex.count == wanted.count { break }
        }
        let targets = choice.targets.compactMap { target in firstIndex[target.id].map { rows[$0] } }
        store.setTag(choice.key, choice.value, rows: TagChoice.targets(choice.key, targets))
        if let table { refreshTagCells(table) }
    }
}

/// 곡 목록 표. 한 번 클릭은 고르기만 하고, 키 칸 더블클릭은 메뉴, 나머지 더블클릭·⌘→는 덱에 올린다(#93·#204).
/// 곡을 고른 채 Return·Enter를 누르거나 이미 고른 줄의 태그 칸을 다시 누르면 그 칸을 바로 고친다(#88). 나머지 키는 표가 처리한다.
final class TrackListTableView: NSTableView {
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        PerfProbe.measure("table.resize") { super.resize(withOldSuperviewSize: oldSize) }
    }

    override func sizeToFit() {
        PerfProbe.measure("table.columns") { super.sizeToFit() }
    }

    override func layout() {
        PerfProbe.measure("table.layout") { super.layout() }
    }

    weak var coordinator: TrackListCoordinator? {
        didSet {
            target = coordinator
            doubleAction = #selector(TrackListCoordinator.doubleClicked(_:))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, column) = noteClick(at: point)
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

    /// 누른 자리를 조정자에 기억시키고 (줄 번호, 칸 번호)를 돌려준다. 숨긴 칸·옮긴 칸이 있어도 칸 번호가 아니라 이름으로 잇는다.
    /// mouseDown이 쓰는 길이라, 시험은 mouseDown(mouseUp까지 기다리는 추적 루프) 대신 이것을 부른다.
    @discardableResult
    func noteClick(at point: NSPoint) -> (row: Int, column: Int) {
        let row = row(at: point), column = column(at: point)
        coordinator?.noteClick(row: row, column: tableColumns.indices.contains(column) ? tableColumns[column].identifier.rawValue : nil)
        return (row, column)
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
    let label: NSTextField
    private let draftMark = DraftCornerView()
    private var normalColor = NSColor.labelColor
    /// 심볼만 따로 칠할 색(파일이 없는 곡의 경고 아이콘, #126). nil이면 글자색을 따른다.
    private var symbolColor: NSColor?
    /// 글자 앞 작은 심볼(스트리밍 곡 제목, #121). 쓰는 칸이 드물어 처음 필요할 때 만든다.
    private var icon: NSImageView?
    /// 글자 자리 시작점(심볼이 있으면 그 뒤)
    private var labelLeading: CGFloat = 2
    /// 보이는 글자 앞 심볼 이름·색(시험용)
    private(set) var leadingSymbol: String?
    var symbolTint: NSColor? { icon?.contentTintColor }
    private var iconPointSize: CGFloat = 0
    /// 접근성 값을 한 번이라도 덮었는지. 셀에 nil을 넣으면 기본값으로 돌아가지 않아 그 뒤로는 글자를 계속 넣는다.
    private var speaksCustomValue = false
    private var field: NSTextField?
    private var textHeight = TrackTextHeight()
    /// 칸에 넣은 글자 전체와, 그것이 칸 자리에 안 들어갈 때 대신 보일 짧은 글자(평점 "5★", #65). 보이는 글자는 `label.stringValue`다.
    private var fullText = ""
    private var compactText: String?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColor() }
    }

    private func updateColor() {
        let emphasized = backgroundStyle == .emphasized
        label.textColor = emphasized ? .alternateSelectedControlTextColor : normalColor
        // 곡 색 점은 템플릿이 아니라 칠하지 않는다(고른 줄에서도 색이 보이게)
        icon?.contentTintColor = swatchShown ? nil : emphasized ? label.textColor : symbolColor ?? label.textColor
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

    init(label: NSTextField = NSTextField(labelWithString: "")) {
        self.label = label
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
        draftMark.isHidden = true
        addSubview(draftMark)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 제약으로 두면 줄을 다시 채울 때마다(글자가 바뀌면 고유 크기도 바뀐다) 제약 엔진이 칸마다 다시 풀어
    // 목록 전환·스크롤이 무거웠다(#137). 글자 자리·심볼·초안 표식·입력 칸은 칸 크기로 정해지므로 프레임으로 둔다.
    override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size else { return }
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        textHeight.invalidate()
        needsLayout = true
    }

    /// 칸 자리에 `fullText`가 들어가면 그대로, 모자라면 `compactText`를 보인다(짧은 글자가 없으면 끝을 줄이는 기본 동작).
    /// 잘린 글자("★★★…")가 다른 값처럼 읽히지 않게, 줄이지 않고 숫자로 바꾼다.
    /// 글자 자리 = 칸 폭 − 글자 앞(`labelLeading`) − 뒤 2pt. 칸 폭을 모르는 동안(배치 전)은 전체 글자다.
    @discardableResult
    private func showFittingText() -> Bool {
        let shown = FittingText.choose(full: fullText, compact: compactText, font: label.font,
                                       slot: bounds.width > 0 ? bounds.width - labelLeading - 2 : nil)
        guard label.stringValue != shown else { return false }
        label.stringValue = shown
        return true
    }

    override func layout() {
        super.layout()
        showFittingText()
        let height = bounds.height
        if let icon, !icon.isHidden, let size = icon.image?.size {
            icon.frame = backingAlignedRect(NSRect(x: 2, y: (height - size.height) / 2, width: size.width, height: size.height),
                                            options: .alignAllEdgesNearest)
        }
        // 글자 자리(정렬 사각형)는 양옆 2pt 안쪽에서 세로 가운데다. 글자 칸 프레임은 정렬 여백만큼 더 넓다.
        for text in [label, field].compactMap({ $0 }) {
            // 입력 칸은 편집 중 내용·필드 편집기가 바뀌므로 높이를 계속 직접 잰다.
            let measuredHeight = text === label
                ? textHeight.height(text: text.stringValue, font: text.font) { text.intrinsicContentSize.height }
                : text.intrinsicContentSize.height
            let slot = NSRect(x: labelLeading, y: (height - measuredHeight) / 2,
                              width: max(0, bounds.width - labelLeading - 2), height: measuredHeight)
            let frame = backingAlignedRect(text.frame(forAlignmentRect: slot), options: .alignAllEdgesNearest)
            if text.frame != frame { text.frame = frame }
        }
        draftMark.frame = NSRect(x: 0, y: isFlipped ? 0 : height - 7, width: 7, height: 7)
    }

    /// - Parameter draft: 반영 전 초안 값. 색과 함께 모서리 표식·VoiceOver "초안"으로도 알린다.
    /// - Parameter estimated: DJCrate 추정값. 색과 함께 기울임·툴팁·VoiceOver "추정"으로도 알린다.
    /// - Parameter symbol: 글자 앞 SF 심볼. 칸을 다시 쓸 때마다 부르므로 nil이면 지운다.
    /// - Parameter swatch: 글자 앞 색 점(곡 색, 템플릿이 아닌 그림이라 고른 줄에서도 색이 그대로다). `symbol`보다 먼저 쓴다.
    /// - Parameter spoken: VoiceOver가 읽을 글자(평점 별 대신 "별 3개"). nil이면 보이는 글자.
    /// - Parameter compact: `text`가 칸 자리에 안 들어갈 때 대신 보일 짧은 글자(평점 "3★"). nil이면 안 들어가도 `text`를 그대로 두고 끝을 줄인다.
    func set(_ text: String, color: NSColor, digits: Bool = false, draft: Bool = false, estimated: Bool = false,
             symbol: String? = nil, symbolLabel: String? = nil, symbolColor: NSColor? = nil, swatch: NSImage? = nil, spoken: String? = nil,
             compact: String? = nil) {
        if fullText != text || compactText != compact {
            fullText = text
            compactText = compact
            needsLayout = true
        }
        let font = estimated ? fonts.estimated : digits ? fonts.digits : fonts.text
        if label.font != font {
            label.font = font
            needsLayout = true
        }
        if let swatch {
            showSwatch(swatch, label: text)
        } else if symbol != leadingSymbol || (symbol != nil && iconPointSize != font.pointSize) || swatchShown {
            showSymbol(symbol, label: symbolLabel, pointSize: font.pointSize)
        }
        // 글자 앞 심볼·색 점(`labelLeading`)이 정해진 뒤에 자리를 잰다
        if showFittingText() { needsLayout = true }
        normalColor = color
        self.symbolColor = symbolColor
        updateColor()
        if draftMark.isHidden == draft { draftMark.isHidden = !draft }
        let tip = estimated ? String(ui: "DJCrate가 소리로 추정한 키입니다. rekordbox 분석과 다를 수 있습니다") : nil
        if toolTip != tip { toolTip = tip }
        if draft || estimated || speaksCustomValue || spoken != nil {
            let words = spoken ?? text
            let value = draft ? "\(words), \(DraftMark.spoken)" : estimated ? "\(words), \(String(ui: "추정"))" : words
            label.cell?.setAccessibilityValue(value)
            speaksCustomValue = true
        }
    }

    /// 지금 글자 앞에 색 점을 보이는지(시험용)
    private(set) var swatchShown = false

    private func showSwatch(_ image: NSImage, label text: String) {
        leadingSymbol = nil
        swatchShown = true
        if icon == nil {
            let view = NSImageView()
            addSubview(view)
            icon = view
        }
        if icon?.image !== image { icon?.image = image }
        icon?.contentTintColor = nil
        icon?.toolTip = text
        icon?.isHidden = false
        labelLeading = 2 + ceil(image.size.width) + 4
        needsLayout = true
    }

    private func showSymbol(_ name: String?, label text: String?, pointSize: CGFloat) {
        leadingSymbol = name
        swatchShown = false
        iconPointSize = pointSize
        if name != nil, icon == nil {
            let view = NSImageView()
            addSubview(view)
            icon = view
        }
        let image = name.flatMap { Self.symbolImage($0, label: text, pointSize: round(pointSize * 0.85)) }
        icon?.image = image
        icon?.toolTip = image == nil ? nil : text
        icon?.isHidden = image == nil
        labelLeading = 2 + (image.map { ceil($0.size.width) + 3 } ?? 0)
        needsLayout = true
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
        addSubview(field)
        label.isHidden = true
        self.field = field
        // 입력을 시작하기 전에 글자 자리에 둔다(필드 편집기가 필드 크기로 뜬다).
        needsLayout = true
        layoutSubtreeIfNeeded()
        return field
    }

    func endEditing() {
        textHeight.invalidate()
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
        let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: String(ui: "앨범아트 없음"))
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
        thumb.setAccessibilityLabel(String(ui: "앨범아트"))
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
        // 그림을 쓴 곡은 번호가 붙은 새 열쇠라 같은 ContentID여도 다시 읽는다(#66)
        let id = ArtworkRevisions.key(track.id)
        guard key != id else { return }
        key = id
        task?.cancel()
        show(nil)
        let path = track.imagePath
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

    // MARK: USB 초안

    /// 로컬 곡 메뉴 'USB에 넣기 ▸ <볼륨> ▸ 컬렉션·목록'. 막힐 편집은 누를 수 없게 하고 이유를 도움말로 단다
    fileprivate func addUsbItems(to menu: NSMenu, targets: [TrackRow]) {
        guard let actions = store.usbEdits else { return }
        let tracks = targets.filter { !$0.isStaged && !$0.track.isStreaming }
        let volumes = actions.targets
        guard !tracks.isEmpty, !volumes.isEmpty else { return }
        menu.addItem(.separator())
        let add = NSMenuItem(title: String(ui: "USB에 넣기"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let ids = tracks.map(\.track.id)
        for volume in volumes {
            let title = volume.isConnected ? volume.name : String(ui: "\(volume.name) (연결 안 됨)")
            let volumeItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            volumeItem.image = NSImage(systemSymbolName: volume.isConnected ? "externaldrive.fill" : "externaldrive.badge.xmark",
                                       accessibilityDescription: nil)
            let volumeMenu = NSMenu()
            volumeMenu.addItem(usbAddItem(String(ui: "컬렉션"), target: .collection(volumeKey: volume.volumeKey), ids: ids, actions: actions))
            let nodes = UsbPlaylistTree.build(volume.library)
            if !nodes.isEmpty { volumeMenu.addItem(.separator()) }
            fillUsbPlaylistTree(volumeMenu, nodes: nodes, volumeKey: volume.volumeKey, ids: ids, actions: actions)
            volumeItem.submenu = volumeMenu
            submenu.addItem(volumeItem)
        }
        add.submenu = submenu
        menu.addItem(add)
    }

    private func fillUsbPlaylistTree(_ menu: NSMenu, nodes: [UsbPlaylistNode], volumeKey: String, ids: [String], actions: UsbEditActions) {
        for node in nodes where !node.isSmart {
            if node.isFolder {
                let folder = NSMenuItem(title: node.name, action: nil, keyEquivalent: "")
                folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                let submenu = NSMenu()
                fillUsbPlaylistTree(submenu, nodes: node.children ?? [], volumeKey: volumeKey, ids: ids, actions: actions)
                if submenu.items.isEmpty {
                    let empty = NSMenuItem(title: String(ui: "(빈 폴더)"), action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    submenu.addItem(empty)
                }
                folder.submenu = submenu
                menu.addItem(folder)
            } else {
                let item = usbAddItem(node.name, target: .playlist(volumeKey: volumeKey, id: node.id), ids: ids, actions: actions)
                item.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
    }

    private func usbAddItem(_ title: String, target: UsbSidebarTarget, ids: [String], actions: UsbEditActions) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(addToUsb(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = target
        let playlist: PlaylistRef? = if case let .playlist(_, id) = target { .id(String(id)) } else { nil }
        if let reason = actions.blockReason(.addTracks(localContentIDs: ids, playlist: playlist), volumeKey: target.volumeKey) {
            item.action = nil
            item.toolTip = reason
        }
        return item
    }

    @objc private func addToUsb(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? UsbSidebarTarget, let actions = store.usbEdits else { return }
        let rows = menuTargets()
        Task { await actions.addTracks(rows, to: target) }
    }

    /// 오른쪽 클릭한 USB 줄(선택 밖이면 그 줄만). 같은 곡이 목록에 여러 번 있으면 줄마다
    private func usbMenuTargets() -> [TrackRow] {
        guard let table else { return [] }
        let clicked = table.clickedRow
        let indexes = clicked >= 0 && !table.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : table.selectedRowIndexes
        return indexes.compactMap { rows.indices.contains($0) && rows[$0].isUsb ? rows[$0] : nil }
    }

    /// USB 곡 메뉴: 이 목록에서 빼기·USB에서 빼기·로컬 변경 반영(초안). 초안을 받지 않는 USB면 false
    private func addUsbEditItems(to menu: NSMenu) -> Bool {
        guard case let .usb(target) = store.sidebar, let actions = store.usbEdits, actions.usb.acceptsEdits(target.volumeKey) else { return false }
        let key = target.volumeKey
        let targets = usbMenuTargets()
        let ids = UsbEditActions.usbContentIDs(targets, volumeKey: key)
        guard !ids.isEmpty else { return false }
        menu.addItem(.separator())
        if case let .playlist(_, playlist) = target, let name = actions.usb.editLibrary(key)?.playlists.first(where: { $0.id == playlist })?.name,
           let edit = UsbEditActions.removeFromPlaylistEdit(targets, volumeKey: key, playlist: playlist) {
            menu.addItem(usbEditItem(String(ui: "‘\(name)’에서 빼기 (\(targets.count)곡)"), #selector(removeFromUsbPlaylist), edit, actions: actions, key: key))
        }
        menu.addItem(usbEditItem(String(ui: "USB에서 빼기 (\(ids.count)곡)"), #selector(removeFromUsb), .removeTracks(usbContentIDs: ids),
                                 actions: actions, key: key))
        let updatable = actions.updatableTracks(volumeKey: key, rows: targets)
        let refreshReason = updatable.isEmpty ? String(ui: "로컬에서 더 고친 곡(갱신 가능)이 없습니다")
            : actions.refreshBlockReason(volumeKey: key, rows: targets)
        let refresh = NSMenuItem(title: String(ui: "로컬 변경을 USB에 반영 (\(updatable.count)곡)"),
                                 action: refreshReason == nil ? #selector(refreshUsbTracks) : nil, keyEquivalent: "")
        refresh.target = self
        refresh.toolTip = refreshReason
        menu.addItem(refresh)
        menu.addItem(.separator())
        let pending = NSMenuItem(title: String(ui: "USB 쓰기 대기 목록 보기"), action: #selector(showUsbPending), keyEquivalent: "")
        pending.target = self
        menu.addItem(pending)
        return true
    }

    private func usbEditItem(_ title: String, _ action: Selector, _ edit: UsbLibraryEdit, actions: UsbEditActions, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let reason = actions.blockReason(edit, volumeKey: key) {
            item.action = nil
            item.toolTip = reason
        }
        return item
    }

    @objc private func removeFromUsb() {
        guard case let .usb(target) = store.sidebar, let actions = store.usbEdits else { return }
        let rows = usbMenuTargets()
        Task { await actions.removeTracks(rows, volumeKey: target.volumeKey) }
    }

    @objc private func removeFromUsbPlaylist() {
        guard case let .usb(.playlist(key, playlist)) = store.sidebar, let actions = store.usbEdits else { return }
        let rows = usbMenuTargets()
        Task { await actions.removeFromPlaylist(rows, volumeKey: key, playlist: playlist) }
    }

    @objc private func refreshUsbTracks() {
        guard case let .usb(target) = store.sidebar, let actions = store.usbEdits else { return }
        let rows = usbMenuTargets()
        Task { await actions.refreshLocalChanges(volumeKey: target.volumeKey, rows: rows) }
    }

    @objc private func showUsbPending() {
        guard case let .usb(target) = store.sidebar else { return }
        store.sidebar = .usb(.pending(volumeKey: target.volumeKey))
    }

    // MARK: 끌어다 놓기

    /// 곡을 끌면 ID를 싣는다: 덱 위에 놓아 불러오기(#93), 사이드바 목록에 놓아 넣기, 목록 안에서 순서 바꾸기.
    /// 추가한 곡은 아직 rekordbox에 없어 재생 목록용으로는 싣지 않는다(덱에는 올릴 수 있다).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        // USB 곡은 덱·재생 목록·앱 밖 어디로도 끌지 않는다(읽기 전용)
        guard rows.indices.contains(row), !isEditing, !rows[row].isUsb else { return nil }
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
        // 간격 표시는 끄는 동안 끄는 줄을 숨긴다. 숨긴 채 덱에 곡이 올라가 목록 높이가 바뀌면 표 높이가 틀어지므로(#143)
        // 목록 안에 놓아 순서를 바꿀 수 있을 때만 쓴다.
        tableView.draggingDestinationFeedbackStyle = store.canReorderDisplayedTracks ? .gap : .regular
    }

    /// 끄는 줄을 숨긴 채 목록 높이가 바뀌면 AppKit이 표 높이를 줄 끝보다 짧게 잡고, 끌기가 끝나 줄을 다시 보여도 다시 재지 않는다.
    /// 그러면 놓은 뒤 휠 스크롤이 짧은 높이에 막혔다(#143). 표는 이 대리자를 부른 뒤에 줄을 다시 보이므로 다음 차례에 잰다.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        Task { @MainActor [weak tableView] in tableView?.tile() }
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
