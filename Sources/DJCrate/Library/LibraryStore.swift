import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation
import Observation

/// 사이드바에서 고르는 대상: 라이브러리 필터 또는 rekordbox 플레이리스트·폴더.
enum SidebarItem: Hashable, Sendable {
    case filter(LibraryFilter)
    case playlist(String)
    case itunesPlaylist(String)
    case history(String)
    case duplicates
    /// DJCrate에 추가한 곡(아직 rekordbox에 없음)
    case staged
    /// 큐·그리드 초안이 있어 rekordbox에 반영할 곡
    case pending
}

@MainActor
@Observable
final class LibraryStore {
    enum Phase {
        case idle
        case loading(String)
        case loaded
        case failed(String)
    }

    @ObservationIgnored weak var undoManager: UndoManager? {
        didSet { if oldValue !== undoManager { oldValue?.removeAllActions(withTarget: self) } }
    }
    @ObservationIgnored let saveTagDrafts: ([TagDraft]) -> Void
    @ObservationIgnored let mergeDraftSaver: ([DuplicateMergeDraft]) throws -> Void
    var mergeDrafts: [DuplicateMergeDraft] = []
    /// 재생 목록 초안 파일 쓰기(시험은 메모리로 바꾼다)
    @ObservationIgnored let playlistDraftSaver: (PlaylistDraft) throws -> Void
    @ObservationIgnored let playlistImportURL: URL?
    @ObservationIgnored let stagingSaver: ([StagedTrack]) throws -> Void
    var playlistImports = PlaylistImports()
    var playlistImportsLoadFailed = false
    @ObservationIgnored let backupDirectory: URL
    private(set) var hasWriteBackup = false

    func refreshWriteBackups() {
        hasWriteBackup = RekordboxWriter.backups(in: backupDirectory).contains(where: \.isWrite)
    }

    let resultHistory: WriteResultHistory
    @ObservationIgnored var feedback: AppFeedback
    var showingWriteResult = false
    @ObservationIgnored var writeTask: Task<Void, Never>?
    @ObservationIgnored var previewWarmTask: Task<Void, Never>?

    func cancelWritePreparation() {
        guard writeStage?.cancellable == true else { return }
        writeTask?.cancel()
    }

    @ObservationIgnored let settings: SettingsStore
    var commentPreset: CommentPreset {
        didSet {
            guard commentPreset != oldValue else { return }
            settings.commentPreset = commentPreset
            refreshCommentRule()
        }
    }
    var commentRuleEnabled: Bool { commentPreset.rule != nil }

    init(settings: SettingsStore = SettingsStore(), resultHistory: WriteResultHistory = WriteResultHistory(url: DJCPaths.userData.appending(path: "last-write-result.json")),
         feedback: AppFeedback = AppFeedback(), saveTagDrafts: @escaping ([TagDraft]) -> Void = { DraftWriter.save($0) },
         backupDirectory: URL = DJCPaths.rekordboxBackups,
         playlistDraftSaver: @escaping (PlaylistDraft) throws -> Void = { try PlaylistDraftStore.save($0) },
         mergeDraftSaver: @escaping ([DuplicateMergeDraft]) throws -> Void = { try DuplicateMergeDraftStore.save($0) },
         playlistImportURL: URL? = PlaylistImportStore.url,
         iTunesSelectionURL: URL = ITunesSyncSelectionStore.url,
         stagingSaver: @escaping ([StagedTrack]) throws -> Void = { try StagingStore.save($0) }) {
        self.settings = settings
        self.commentPreset = settings.commentPreset
        self.saveTagDrafts = saveTagDrafts
        self.playlistDraftSaver = playlistDraftSaver
        self.mergeDraftSaver = mergeDraftSaver
        self.playlistImportURL = playlistImportURL
        self.iTunesSelectionURL = iTunesSelectionURL
        self.stagingSaver = stagingSaver
        self.resultHistory = resultHistory
        self.feedback = feedback
        self.backupDirectory = backupDirectory
        refreshWriteBackups()
        loadRecentPlaylists()
        loadPlaylistImports()
    }

    var phase: Phase = .idle
    private(set) var rows: [TrackRow] = []
    private(set) var report: LibraryReport?
    private(set) var snapshotURL: URL?
    private(set) var previewRevision = 0
    /// 표에 보이는 줄. 필터·검색·정렬이 바뀔 때만 다시 계산한다(그릴 때마다 계산하지 않는다).
    private(set) var displayRows: [TrackRow] = []
    private(set) var duplicateGroups: [LibraryRead.DuplicateGroup] = []
    private(set) var displayDuplicateGroups: [LibraryRead.DuplicateGroup] = []
    private(set) var filterCounts: [LibraryFilter: Int] = [:]
    var playlistCounts: [String: Int] = [:]
    var isLoading: Bool { if case .loading = phase { true } else { false } }

    var sidebar: SidebarItem = .filter(.all) {
        didSet {
            guard sidebar != oldValue else { return }
            // 플레이리스트는 rekordbox 순서가 기본, 필터는 임포트 최신순이 기본.
            suppressRefresh = true
            switch sidebar {
            case .playlist, .itunesPlaylist, .history, .duplicates, .staged, .pending: sortOrder = []
            case .filter:
                if case .filter = oldValue {} else { sortOrder = [KeyPathComparator(\TrackRow.importedOn, order: .reverse)] }
            }
            suppressRefresh = false
            refreshBase()
        }
    }
    /// 사이드바 재생 목록 트리(rekordbox 상태에 재생 목록 초안을 얹은 모양, LibraryStore+Playlists)
    var playlistTree: [PlaylistOutlineNode] = []
    var iTunesLibrary = SyncedITunesLibrary()
    var iTunesSnapshot = ITunesLibrarySnapshot(status: .notCaptured)
    let iTunesSelectionURL: URL
    var showingITunesSync = false
    var iTunesSync = ITunesSyncModel()
    var isITunesSelection: Bool { if case .itunesPlaylist = sidebar { true } else { false } }
    /// 새 항목의 부모만 펼치고 다른 폴더의 펼침 상태는 유지한다.
    var expandedPlaylistIDs: Set<String> = []
    var playlistIndex: [String: PlaylistOutlineNode] = [:] { didSet { playlistCount = playlistIndex.values.filter { !$0.isFolder }.count } }
    /// 폴더를 뺀 rekordbox 플레이리스트 수(사이드바 제목)
    private(set) var playlistCount = 0
    /// 스냅샷에서 읽은 rekordbox 재생 목록(초안을 얹기 전)
    var rekordboxPlaylists = PlaylistLayout()
    /// 재생 목록 초안(반영 때 쓴다). 바꿀 때는 `setPlaylistDraft`로(저장·화면·되돌리기).
    var playlistDraft = PlaylistDraft()
    /// 초안을 얹은 모양과 편집마다 막힌 이유
    var playlistProjection = PlaylistDraft().project(onto: PlaylistLayout())
    /// 목록마다 초안으로 넣은 곡(ContentID). 목록을 볼 때 초안 표식을 붙인다.
    var playlistAddedTracks: [String: Set<String>] = [:]
    /// 최근에 곡을 넣은 목록(최근 것부터). 오른쪽 클릭 메뉴 맨 위·'마지막에 쓴 목록에 넣기'.
    var recentPlaylistIDs: [String] = []
    /// 사이드바에서 이름을 고치는 중인 목록
    var renamingPlaylistID: String?
    /// 재생 목록 편집 결과 안내(넣은 곡 수·이미 든 곡·막힌 이유)
    var playlistMessage: AppMessage? {
        didSet { if let playlistMessage { feedback.announce(playlistMessage) } }
    }
    /// '재생 목록에 넣기…' 창과 넣을 곡(연 때 고른 곡)
    var showingPlaylistPicker = false
    var playlistPickerTracks: [TrackRow] = []
    var histories: [RekordboxHistory] = []
    private var historyIndex: [String: RekordboxHistory] = [:]

    var sidebarTitle: String {
        switch sidebar {
        case let .filter(filter): filter.title
        case let .playlist(id): playlistIndex[id]?.name ?? String(ui: "플레이리스트")
        case let .itunesPlaylist(id): iTunesLibrary.index[id]?.name ?? String(ui: "iTunes 동기화 목록")
        case let .history(id): historyIndex[id].map(historyTitle) ?? String(ui: "재생 기록")
        case .duplicates: String(ui: "중복 후보")
        case .staged: String(ui: "추가한 곡")
        case .pending: String(ui: "rekordbox 반영 대기")
        }
    }
    var search = "" { didSet { if search != oldValue { refreshFiltered() } } }
    var sortOrder = [KeyPathComparator(\TrackRow.importedOn, order: .reverse)] {
        didSet { if !suppressRefresh { refreshBase() } }
    }
    /// 목록에서 고른 곡(포커스). 덱은 따라가지 않는다: 덱에 올리기는 불러오기 명령(`loadToDeck`)으로만 한다(#93).
    var selection: Set<TrackRow.ID> = []
    /// 덱에 곡을 올리거나(nil이면 내리기) 새로 읽은 값으로 맞춘다. 덱과 잇는 곳은 여기 하나다.
    var onLoadToDeck: ((TrackRow?) -> Void)?
    /// 덱에 올린 곡(ContentID, 추가한 곡은 djc- ID). 목록의 덱 표시와 새로 읽을 때 덱을 맞추는 데 쓴다.
    private(set) var deckTrackID: String?

    /// 초안 상태(메모리). 표의 ✎ 표시는 디스크를 다시 읽지 않고 이것으로 계산한다.
    var tagDrafts: [String: TagDraft] = [:]
    private var cueDraftUUIDs: Set<String> = []
    private var gridDraftUUIDs: Set<String> = []
    private var gainDraftUUIDs: Set<String> = []
    private(set) var editedUUIDs: Set<String> = []

    var rowsByID: [TrackRow.ID: TrackRow] = [:]
    var rowsByUUID: [String: TrackRow] = [:]

    // 추가한 곡(LibraryStore+Staging.swift)
    var staged: [StagedTrack] = []
    var stagedRows: [TrackRow] = []
    /// 백그라운드 그리드 추정 진행(끝나면 nil)
    var gridJob: GridJob?
    var gridQueue: [GridJobItem] = []
    var gridTask: Task<Void, Never>?
    /// 곡 추가·내보내기 결과 안내
    var stagingMessage: AppMessage? {
        didSet { if let stagingMessage { feedback.announce(stagingMessage) } }
    }
    /// rekordbox 반영 내보내기·검증 결과 안내
    var reflectionMessage: AppMessage? {
        didSet { if let reflectionMessage { feedback.announce(reflectionMessage) } }
    }
    /// 마지막으로 내보낸 반영 묶음(가져온 뒤 검증 대기)
    var reflectionBatch: ReflectionStore.Batch?
    /// 이번 실행에서 rekordbox에 쓴 마지막 백업(토스트·툴바의 되돌리기)
    var lastWriteBackup: URL?
    /// detail 위쪽에 뜨는 알림(rekordbox 반영 완료 등)
    var toast: AppToast? {
        didSet {
            if let toast { feedback.announce(AppMessage(kind: toast.kind, text: [toast.title, toast.detail].compactMap { $0 }.joined(separator: "\n"))) }
        }
    }
    /// rekordbox 쓰기 단계 안내(있으면 창 전체를 덮어 조작을 막는다. 확인 창이 떠 있는 동안은 nil)
    var writeStage: WriteStage?
    /// rekordbox에 쓰는 중(미리 보기 포함)
    var isWritingRekordbox = false {
        didSet {
            if isWritingRekordbox { undoManager?.removeAllActions(withTarget: self) }
            // 쓰기·되돌리기 실패 때도 백업이 남거나 정리될 수 있다.
            if oldValue && !isWritingRekordbox { refreshWriteBackups() }
        }
    }
    /// 쓰는 동안 덱 큐 편집을 잠근다
    var onWriteLock: ((Bool) -> Void)?
    /// rekordbox에 쓰거나 되돌린 곡(UUID). 덱이 그 곡이면 다시 읽는다.
    var onRekordboxWritten: ((Set<String>) -> Void)?

    /// 큐 초안이 있는 곡의 (핫큐, 메모리 큐) 개수. 목록 숫자는 반영 전에도 초안 기준으로 보여 준다.
    var draftCueCounts: [String: CueCounts] = [:]
    var draftPreviewCues: [String: [PreviewCueMark]] = [:]

    /// 큐·그리드·게인·태그 초안이 있는 곡(태그도 반영하면 rekordbox 곡 정보에 쓴다)
    var pendingUUIDs: Set<String> { cueDraftUUIDs.union(gridDraftUUIDs).union(gainDraftUUIDs).union(tagDrafts.keys)
        .union(mergeDrafts.flatMap { $0.members.map(\.trackUUID) }) }
    /// 반영 대기 중인 rekordbox 곡 수(추가한 곡 제외)
    var pendingLibraryCount: Int { pendingUUIDs.filter { rowsByUUID[$0].map { !$0.isStaged } ?? false }.count }
    /// 백그라운드 추정이 초안을 저장했을 때(덱이 같은 곡을 보고 있으면 다시 읽게)
    var onGridDraftSaved: ((String) -> Void)?
    var onCueDraftsReloaded: (([String: CueDraft]) -> Void)?
    @ObservationIgnored private var draftFileStamps: [String: Date]?

    /// 필터·플레이리스트·정렬까지 적용한 줄(검색 전). 검색은 이 순서를 그대로 걸러 쓴다.
    private var sortedBase: [TrackRow] = []
    private var suppressRefresh = false
    private var loadGeneration = 0
    @ObservationIgnored private let snapshotRequests = SnapshotRequestQueue()
    private(set) var lastError: String?

    /// 불러오기 명령(⌘→·메뉴)이 덱에 올릴 곡: 선택 중 표 순서로 첫 곡.
    var primaryRow: TrackRow? {
        guard !selection.isEmpty else { return nil }
        if selection.count == 1, let id = selection.first, let row = rowsByID[id] { return row }
        if let row = displayRows.first(where: { selection.contains($0.id) }) { return rowsByID[row.track.id] ?? row }
        return selection.first.flatMap { rowsByID[$0] }
    }

    var selectedRows: [TrackRow] {
        uniqueTracks(displayRows.filter { selection.contains($0.id) })
    }

    /// 재생 기록의 반복 행을 함께 골라도 곡 편집·반영 대상은 한 번만 넘긴다.
    func uniqueTracks(_ candidates: [TrackRow]) -> [TrackRow] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.track.id).inserted }.map { rowsByID[$0.track.id] ?? $0 }
    }

    func historyTitle(_ history: RekordboxHistory) -> String {
        let date = history.dateCreated.map { String($0.prefix(10)) } ?? String(ui: "날짜 없음")
        return history.name.isEmpty || history.name == date ? date : "\(date) · \(history.name)"
    }

    func count(history: RekordboxHistory) -> Int {
        history.entries.lazy.filter { self.rowsByID[$0.contentID] != nil }.count
    }

    func count(_ filter: LibraryFilter) -> Int { filterCounts[filter] ?? 0 }

    func count(playlist node: PlaylistOutlineNode) -> Int { playlistCounts[node.id] ?? 0 }

    // MARK: - 덱에 불러오기(#93)

    /// 이 곡을 덱에 올린다(더블클릭·⌘→·오른쪽 클릭·끌어다 놓기). 재생 기록의 반복 행도 컬렉션 곡으로 올린다.
    /// rekordbox에 쓰는 동안은 덱을 바꾸지 않는다.
    func loadToDeck(_ row: TrackRow?) {
        guard writeLockPolicy.allowsLibraryInteraction, let row else { return }
        setDeckTrack(rowsByID[row.track.id] ?? row)
    }

    var canLoadSelectionToDeck: Bool { writeLockPolicy.allowsLibraryInteraction && primaryRow != nil }

    /// 고른 곡 중 표 순서로 첫 곡을 덱에 올린다(⌘→·덱 메뉴).
    func loadSelectionToDeck() {
        guard canLoadSelectionToDeck else { return }
        loadToDeck(primaryRow)
    }

    /// 덱 위에 놓은 곡(ContentID 또는 추가한 곡 ID) 중 라이브러리에 있는 첫 곡을 올린다.
    func loadDroppedTracks(_ ids: [String]) {
        loadToDeck(ids.lazy.compactMap { self.rowsByID[$0] }.first)
    }

    private func setDeckTrack(_ row: TrackRow?) {
        deckTrackID = row?.track.id
        onLoadToDeck?(row)
    }

    /// 라이브러리를 새로 읽거나 추가한 곡을 뺀 뒤: 덱의 곡을 새 값으로 맞추고, 없어진 곡은 내린다(지워진 곡을 붙들지 않게).
    func refreshDeckTrack() {
        guard let id = deckTrackID else { return }
        setDeckTrack(rowsByID[id])
    }

    /// 덱의 곡이 다른 ID로 바뀌었다(추가한 곡을 rekordbox에 넣음). 다음 `refreshDeckTrack`에서 새 곡으로 올린다.
    func moveDeckTrack(to id: String) {
        deckTrackID = id
    }

    func refreshBase() {
        let base: [TrackRow]
        switch sidebar {
        case let .filter(filter): base = rows.filter(filter.includes)
        case let .playlist(id): base = (playlistIndex[id]?.trackIDs ?? []).compactMap { rowsByID[$0] }
        case let .itunesPlaylist(id):
            let node = iTunesLibrary.index[id]
            var occurrences: [String: Int] = [:]
            base = zip(node?.trackIDs ?? [], node?.trackNumbers ?? []).compactMap { trackID, number in
                guard var row = rowsByID[trackID] else { return nil }
                let occurrence = occurrences[trackID, default: 0]
                occurrences[trackID] = occurrence + 1
                row.playlistOccurrence = .init(id: "\(id):\(trackID):\(occurrence)", number: number)
                return row
            }
        case let .history(id):
            base = (historyIndex[id]?.entries ?? []).compactMap { entry in
                guard var row = rowsByID[entry.contentID] else { return nil }
                row.historyEntry = entry
                return row
            }
        case .staged: base = stagedRows
        case .pending: base = rows.filter { pendingUUIDs.contains($0.track.uuid) }
        case .duplicates:
            var seen = Set<String>()
            base = duplicateGroups.flatMap(\.tracks).compactMap { member in
                seen.insert(member.id).inserted ? rowsByID[member.id] : nil
            }
        }
        sortedBase = sortOrder.isEmpty ? base : base.sorted(using: sortOrder)
        refreshFiltered()
    }

    /// 프리셋 전환은 초안·선택·스냅샷을 보존하고 코멘트 캐시만 갱신한다.
    private func refreshCommentRule() {
        let rule = commentPreset.rule
        for index in rows.indices { rows[index].applyCommentRule(rule) }
        for index in stagedRows.indices { stagedRows[index].applyCommentRule(rule) }
        for row in rows + stagedRows { rowsByID[row.id] = row; rowsByUUID[row.track.uuid] = row }
        report?.applyCommentRule(rule, comments: rows.map(\.comment))
        filterCounts = Dictionary(uniqueKeysWithValues: LibraryFilter.visible(commentPreset: commentPreset).map {
            ($0, rows.lazy.filter($0.includes).count)
        })
        suppressRefresh = true
        if !commentRuleEnabled {
            sortOrder.removeAll { $0.keyPath == \TrackRow.commentClassName }
        }
        suppressRefresh = false
        if !commentRuleEnabled, case let .filter(filter) = sidebar, filter.requiresCommentRule {
            sidebar = .filter(.all)
        } else {
            refreshBase()
        }
    }

    private func refreshFiltered() {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        if sidebar == .duplicates {
            // 검색한 곡의 비교 상대도 남겨 묶음이 한 곡으로 잘리지 않게 한다.
            displayDuplicateGroups = needle.isEmpty ? duplicateGroups : duplicateGroups.filter { group in
                group.tracks.contains { rowsByID[$0.id]?.searchKey.contains(needle) == true }
            }
            let visible = Set(displayDuplicateGroups.flatMap { $0.tracks.map(\.id) })
            displayRows = sortedBase.filter { visible.contains($0.id) }
            return
        }
        displayDuplicateGroups = []
        displayRows = needle.isEmpty ? sortedBase : sortedBase.filter { $0.searchKey.contains(needle) }
    }

    // MARK: - 로드

    static func explicitDatabaseRequested(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("--db") || environment["DJC_DB"] != nil
    }

    /// iTunes 버튼은 명시한 DB를 벗어나지 않는다. 사본 모드에서는 현재 DB 옆 목록만 다시 읽는다.
    func refreshITunesPlaylists(arguments: [String] = ProcessInfo.processInfo.arguments,
                                environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard !isLoading, !isWritingRekordbox else { return }
        if Self.explicitDatabaseRequested(arguments: arguments, environment: environment) {
            guard let snapshotURL else { return }
            await load(snapshot: snapshotURL)
        } else {
            await takeSnapshot(force: LibrarySnapshot.isRekordboxRunning())
        }
    }

    /// `--db PATH` 또는 `DJC_DB`가 있으면 그 사본을, 없으면 최신 스냅샷을 연다.
    func loadInitial() async {
        guard !isLoading, rows.isEmpty else { return }
        let args = ProcessInfo.processInfo.arguments
        let override = args.firstIndex(of: "--db").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            ?? ProcessInfo.processInfo.environment["DJC_DB"]
        if let override {
            await load(snapshot: URL(filePath: override))
        } else if let latest = try? LibrarySnapshot.latest() {
            await load(snapshot: latest, refreshITunes: !LibrarySnapshot.hasRekordboxDirectoryOverride())
            // 켠 순간의 창 활성화는 읽는 도중이라 건너뛰므로, 읽은 뒤 한 번 더 본다
            await refreshIfRekordboxChanged()
        } else {
            phase = .idle
        }
    }

    /// 창으로 돌아올 때: 지금 읽은 스냅샷 뒤에 rekordbox가 라이브러리를 바꿨으면 뒤에서 조용히 새로 읽는다.
    /// rekordbox가 켜져 있어도 읽기용 사본(WAL까지 사본 안에서 합침)으로 뜬다. 원본은 읽기만 한다.
    func refreshIfRekordboxChanged() async {
        guard case .loaded = phase, !isLoading, !isWritingRekordbox, let snapshotURL,
              snapshotURL.deletingLastPathComponent().standardizedFileURL.path == LibrarySnapshot.defaultDirectory.standardizedFileURL.path,
              LibrarySnapshot.changed(since: snapshotURL) else { return }
        FileHandle.standardError.write(Data("rekordbox 라이브러리가 바뀌어 다시 읽습니다\n".utf8))
        await takeSnapshot(force: true, quiet: true)
    }

    /// - Parameter quiet: 화면을 로딩으로 바꾸지 않고 뒤에서 다시 읽는다(rekordbox에 쓴 뒤 등).
    func takeSnapshot(force: Bool = false, quiet: Bool = false) async {
        guard !isLoading || snapshotRequests.isRunning else { return }
        await snapshotRequests.run(force: force, quiet: quiet) { [self] force, quiet in
            await takeSnapshotOnce(force: force, quiet: quiet)
        }
    }

    private func takeSnapshotOnce(force: Bool, quiet: Bool) async {
        let hadRows = !rows.isEmpty
        let refreshITunes = !LibrarySnapshot.hasRekordboxDirectoryOverride()
        let explicitDatabase = Self.explicitDatabaseRequested(arguments: ProcessInfo.processInfo.arguments,
                                                              environment: ProcessInfo.processInfo.environment)
        // 같은 초에 DB 파일 이름을 재사용해도 마지막 정상 iTunes 사본을 잃지 않게 먼저 읽는다.
        let previousURL = !explicitDatabase && refreshITunes
            && snapshotURL.map { LibrarySnapshot.sameDirectory($0.deletingLastPathComponent(), LibrarySnapshot.defaultDirectory) } == true
            ? snapshotURL : nil
        let previousITunesSnapshot = previousURL.map {
            LoadedLibrary.ITunesFallback(source: $0, contents: ITunesLibrarySnapshot.load(for: $0))
        }
        var isLoaded: Bool { if case .loaded = phase { true } else { false } }
        let quiet = quiet && hadRows && isLoaded
        if !quiet { phase = .loading(String(ui: "rekordbox DB 스냅샷을 뜨는 중…")) }
        do {
            let url = try await Task.detached { try LibrarySnapshot.take(force: force) }.value
            await load(snapshot: url, quiet: quiet, refreshITunes: refreshITunes, previousITunesSnapshot: previousITunesSnapshot)
        } catch {
            // 이미 라이브러리가 있으면 그대로 두고 오류만 알린다.
            let message = AppErrorMessage.message(for: error)
            if hadRows {
                phase = .loaded
                lastError = message
            } else {
                phase = .failed(message)
            }
        }
    }

    func load(snapshot: URL, quiet: Bool = false, refreshITunes: Bool = false,
              previousITunesSnapshot: LoadedLibrary.ITunesFallback? = nil) async {
        previewWarmTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let started = ContinuousClock.now
        if !quiet { phase = .loading(String(ui: "라이브러리를 읽는 중…")) }
        do {
            let preset = commentPreset
            // 메인 액터에서 정한 요청 순서를 캡처가 끝날 때까지 유지한다.
            let refreshTicket = refreshITunes ? ITunesRefreshCoordinator.shared.begin(snapshot: snapshot) : nil
            let loaded = try await Task.detached(priority: .userInitiated) {
                try LoadedLibrary.load(snapshot: snapshot, commentPreset: preset, refreshITunes: refreshITunes,
                                       previousITunesSnapshot: previousITunesSnapshot, refreshTicket: refreshTicket)
            }.value
            // 더 나중에 시작한 로드가 있으면 이 결과는 버린다.
            guard generation == loadGeneration else { return }
            undoManager?.removeAllActions(withTarget: self)
            rows = loaded.rows
            rowsByID = Dictionary(loaded.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rowsByUUID = Dictionary(loaded.rows.map { ($0.track.uuid, $0) }, uniquingKeysWith: { first, _ in first })
            report = loaded.report
            filterCounts = loaded.filterCounts
            duplicateGroups = loaded.duplicateGroups
            draftFileStamps = nil
            tagDrafts = loaded.tagDrafts
            cueDraftUUIDs = loaded.cueDraftUUIDs
            draftCueCounts = loaded.draftCueCounts
            draftPreviewCues = loaded.draftPreviewCues
            gridDraftUUIDs = loaded.gridDraftUUIDs
            gainDraftUUIDs = GainDraftStore.uuids()
            editedUUIDs = cueDraftUUIDs.union(gridDraftUUIDs).union(gainDraftUUIDs).union(tagDrafts.keys)
            rekordboxPlaylists = loaded.playlists
            playlistDraft = loaded.playlistDraft
            iTunesLibrary = loaded.iTunesLibrary
            iTunesSnapshot = loaded.iTunesSnapshot
            var iTunesError: String?
            do {
                if let selection = try ITunesSyncSelectionStore.load(url: iTunesSelectionURL) {
                    iTunesLibrary = SyncedITunesLibrary(snapshot: try iTunesSnapshot.applying(selection), tracks: loaded.rows.map(\.track))
                }
            } catch {
                iTunesError = String(ui: "iTunes 동기화 선택을 읽지 못했습니다. 동기화 창에서 목록을 다시 선택해 저장하세요.")
            }
            if case let .itunesPlaylist(id) = sidebar, iTunesLibrary.index[id] == nil { sidebar = .filter(.all) }
            mergeDrafts = DuplicateMergeDraftStore.load()
            refreshPlaylists(refreshList: false)
            histories = loaded.histories
            historyIndex = Dictionary(uniqueKeysWithValues: histories.map { ($0.id, $0) })
            snapshotURL = snapshot
            previewRevision += 1
            loadStaged()
            // 기다리는 동안 설정이 바뀌었으면 최신 프리셋으로 맞춘다.
            if preset != commentPreset { refreshCommentRule() }
            // rekordbox에서 지운 곡은 선택에서도 뺀다
            refreshBase()
            let visible = Set(displayRows.map(\.id))
            let existing = selection.filter { rowsByID[$0] != nil || visible.contains($0) }
            if existing != selection { selection = existing }
            verifyReflection()
            refreshBase()
            phase = .loaded
            let previewSources = loaded.rows.filter { !$0.track.isStreaming }.map {
                PreviewWaveformStore.Source(uuid: $0.track.uuid, url: RekordboxShare.analysisURL($0.track.analysisDataPath))
            }
            previewWarmTask = Task.detached(priority: .background) { await PreviewWaveformStore.shared.warm(previewSources) }
            lastError = iTunesError
            FileHandle.standardError.write(Data("라이브러리 로드 \(ContinuousClock.now - started) · \(rows.count)곡\n".utf8))
            refreshDeckTrack()
            applyLaunchSelection()
            runLaunchStagingTest()
            // 캐시 용량 상한(최근 사용 순)은 뒤에서 조용히 정리한다.
            Task.detached(priority: .background) { CacheMaintenance.prune() }
        } catch {
            guard generation == loadGeneration else { return }
            if quiet {
                lastError = AppErrorMessage.message(for: error)
            } else {
                phase = .failed(AppErrorMessage.message(for: error))
            }
        }
    }

    /// 개발용: `--select <ContentID>` 곡을 골라 덱에 올린다(처음 읽을 때 한 번).
    private func applyLaunchSelection() {
        let args = ProcessInfo.processInfo.arguments
        guard deckTrackID == nil, let i = args.firstIndex(of: "--select"), args.indices.contains(i + 1),
              let row = rowsByID[args[i + 1]]
        else { return }
        if case let .filter(filter) = sidebar, !filter.includes(row) { sidebar = .filter(.all) }
        selection = [row.id]
        loadToDeck(row)
    }

    // MARK: - 초안 표시

    /// CLI·외부 편집의 원자적 파일 교체를 확인한다. DB·파형·재생은 다시 불러오지 않는다.
    func refreshExternalDrafts(home: URL = DJCPaths.userData) {
        guard case .loaded = phase, !isWritingRekordbox else { return }
        DraftWriter.flush()
        let cueDirectory = home.appending(path: "cue-drafts")
        let tagDirectory = home.appending(path: "tag-drafts")
        var stamps: [String: Date] = [:]
        for directory in [cueDirectory, tagDirectory] {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "json" {
                stamps[file.path] = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
        }
        guard stamps != draftFileStamps else { return }
        draftFileStamps = stamps
        var cues: [String: CueDraft] = [:]
        for uuid in CueDraftStore.uuids(directory: cueDirectory) {
            if let draft = CueDraftStore.load(trackUUID: uuid, directory: cueDirectory), draft.hasChanges { cues[uuid] = draft }
        }
        var tags: [String: TagDraft] = [:]
        for uuid in TagDraftStore.uuids(directory: tagDirectory) {
            if let draft = TagDraftStore.load(trackUUID: uuid, directory: tagDirectory), draft.hasChanges { tags[uuid] = draft }
        }
        if tagDrafts.mapValues(\.fields) != tags.mapValues(\.fields) || tagDrafts.mapValues(\.base) != tags.mapValues(\.base) {
            tagDrafts = tags
            // 외부 변경 뒤 옛 되돌리기가 새 초안을 덮지 않게 한다.
            undoManager?.removeAllActions(withTarget: self)
            tagRevision += 1
        }
        cueDraftUUIDs = Set(cues.keys)
        draftCueCounts = cues.mapValues(CueCounts.init)
        draftPreviewCues = cues.mapValues { $0.cues.map(PreviewCueMark.init) }
        editedUUIDs = cueDraftUUIDs.union(gridDraftUUIDs).union(gainDraftUUIDs).union(tagDrafts.keys)
        if case .pending = sidebar { refreshBase() }
        onCueDraftsReloaded?(cues)
    }

    /// 덱에서 큐를 찍거나 지울 때마다 목록 숫자를 맞춘다.
    func cueDraftChanged(_ draft: CueDraft) {
        let counts = draft.hasChanges ? CueCounts(draft) : nil
        if draftCueCounts[draft.trackUUID] != counts { draftCueCounts[draft.trackUUID] = counts }
        let marks = draft.hasChanges ? draft.cues.map(PreviewCueMark.init) : nil
        if draftPreviewCues[draft.trackUUID] != marks { draftPreviewCues[draft.trackUUID] = marks }
    }

    func draftChanged(trackUUID: String, kind: DeckModel.DraftKind, exists: Bool) {
        switch kind {
        case .cue:
            if exists { cueDraftUUIDs.insert(trackUUID) } else {
                cueDraftUUIDs.remove(trackUUID)
                draftPreviewCues[trackUUID] = nil
            }
        case .grid: if exists { gridDraftUUIDs.insert(trackUUID) } else { gridDraftUUIDs.remove(trackUUID) }
        case .gain: if exists { gainDraftUUIDs.insert(trackUUID) } else { gainDraftUUIDs.remove(trackUUID) }
        }
        updateEdited(trackUUID)
        if case .pending = sidebar { refreshBase() }
    }

    func updateEdited(_ uuid: String) {
        let edited = cueDraftUUIDs.contains(uuid) || gridDraftUUIDs.contains(uuid) || gainDraftUUIDs.contains(uuid) || tagDrafts[uuid] != nil
        // 바뀔 때만 건드려서 표의 ✎ 칸이 불필요하게 다시 그려지지 않게 한다.
        if edited, !editedUUIDs.contains(uuid) { editedUUIDs.insert(uuid) }
        if !edited, editedUUIDs.contains(uuid) { editedUUIDs.remove(uuid) }
    }

    // 태그 시트 되돌리기(LibraryStore+Tags). 편집이 반영될 때마다 tagRevision이 올라 시트가 보이는 줄을 다시 그린다.
    var canFillDownTags = false
    var tagRevision = 0
}
