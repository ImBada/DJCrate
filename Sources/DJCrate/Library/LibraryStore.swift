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
    /// 연결한 USB의 컬렉션·재생 목록(읽기 전용)
    case usb(UsbSidebarTarget)
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
    @ObservationIgnored private var tagSaveAttempts: Set<String> = []

    func persistTagDrafts(_ drafts: [TagDraft]) {
        tagSaveAttempts.formUnion(drafts.map(\.trackUUID))
        saveTagDrafts(drafts)
    }

    func retryFailedTagSaves(in directory: URL = TagDraftStore.directory) {
        DraftWriter.flush()
        let failed = failedTagSaves(in: directory)
        guard !failed.isEmpty else { return }
        // 실패한 삭제도 재시도한다. 디스크에 남은 옛 초안으로 입력을 되살리지 않는다.
        persistTagDrafts(failed.map { tagDrafts[$0] ?? TagDraft(trackUUID: $0, base: TagFields()) })
        DraftWriter.flush()
    }

    func failedTagSaves(in directory: URL = TagDraftStore.directory) -> Set<String> {
        DraftWriter.failedTagSaveUUIDs(in: directory).intersection(tagSaveAttempts)
    }
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
         stagingSaver: @escaping ([StagedTrack]) throws -> Void = { try StagingStore.save($0) }) {
        self.settings = settings
        self.commentPreset = settings.commentPreset
        self.saveTagDrafts = saveTagDrafts
        self.playlistDraftSaver = playlistDraftSaver
        self.mergeDraftSaver = mergeDraftSaver
        self.playlistImportURL = playlistImportURL
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
    /// 마지막 파일 확인 결과(#126). 연결되지 않은 외장 디스크는 목록 위 작업 줄에 알린다.
    private(set) var missingFiles = MissingFiles()
    private(set) var isCheckingFiles = false
    @ObservationIgnored var missingFileTask: Task<Void, Never>?
    /// 파일 확인(시험은 가짜로 바꾼다). 메인 스레드 밖에서 부른다.
    @ObservationIgnored var fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    /// 지난 확인에서 없던 경로. 다시 읽은 직후 확인이 끝날 때까지 이것으로 표시해 개수가 0으로 깜빡이지 않게 한다.
    @ObservationIgnored private var missingPathCache: Set<String> = []
    var playlistCounts: [String: Int] = [:]
    var isLoading: Bool { if case .loading = phase { true } else { false } }

    var sidebar: SidebarItem = .filter(.all) {
        didSet {
            guard sidebar != oldValue else { return }
            // 플레이리스트는 rekordbox 순서가 기본, 필터는 임포트 최신순이 기본.
            suppressRefresh = true
            switch sidebar {
            case .playlist, .itunesPlaylist, .history, .duplicates, .staged, .pending, .usb: sortOrder = []
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
    var iTunesSnapshot = ITunesLibrarySnapshot(status: .notCaptured) {
        didSet {
            iTunesSyncCatalogEpoch &+= 1
            iTunesSyncCatalogCache = nil
        }
    }
    var showingITunesSync = false
    var iTunesSync = ITunesSyncModel()
    struct ITunesSyncCatalogCache {
        let snapshot: URL
        let revision: Int
        let epoch: UInt64
        let sourceDirectory: URL
        let contents: ITunesLibrarySnapshot
    }
    struct ITunesSyncCapture {
        let id: UUID
        let snapshot: URL
        let revision: Int
        let epoch: UInt64
        let sourceDirectory: URL
        let task: Task<ITunesLibrarySnapshot, Never>
    }
    @ObservationIgnored var iTunesSyncCatalogCache: ITunesSyncCatalogCache?
    @ObservationIgnored var iTunesSyncCapture: ITunesSyncCapture?
    @ObservationIgnored var iTunesSyncCatalogEpoch: UInt64 = 0
    var isITunesSelection: Bool { if case .itunesPlaylist = sidebar { true } else { false } }
    /// USB 목록을 보는 중(읽기 전용: 편집·쓰기·끌기·덱 불러오기를 막는다)
    var isUsbSelection: Bool { if case .usb = sidebar { true } else { false } }
    /// 사이드바 USB 절(앱이 붙인다. 시험·캡처에서는 없다)
    var usb: UsbStore? {
        didSet { usb?.onChange = { [weak self] in self?.usbChanged() } }
    }
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
        case .pending: String(ui: "rekordbox 쓰기 대기")
        case let .usb(target): usb?.title(for: target) ?? "USB"
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
    /// 스냅샷을 새로 읽었을 때(USB 갱신 상태의 로컬 짝짓기 키를 다시 읽는다)
    @ObservationIgnored var onSnapshotLoaded: ((URL) -> Void)?
    /// 띄운 인자·환경. 스냅샷을 새로 떠도 되는지(`snapshotTakeAllowed`) 정한다. 시험은 바꿔 넣는다
    @ObservationIgnored var launchArguments = ProcessInfo.processInfo.arguments
    @ObservationIgnored var launchEnvironment = ProcessInfo.processInfo.environment
    /// rekordbox 폴더의 master.db에서 기본 스냅샷 폴더로 사본을 뜬다(`force`). 시험은 라이브를 건드리지 않게 바꿔 넣는다
    @ObservationIgnored var takeLiveSnapshot: @Sendable (Bool) throws -> URL = { try LibrarySnapshot.take(force: $0) }
    /// 추가한 곡·초안 없는 곡의 그리드 추정(파일, 캐시 키). 시험은 가짜로 바꿔 넣는다
    @ObservationIgnored var gridEstimator: @Sendable (URL, String) async throws -> GridEstimator.Estimate? = {
        try await GridSuggestion.estimate(fileAt: $0, cacheKey: $1)
    }
    var allowsLibrarySync: (() -> Bool)?
    private(set) var isSynchronizingLibrary = false
    var canSynchronizeLibrary: Bool { !isLoading && !isSynchronizingLibrary && !isWritingRekordbox && (allowsLibrarySync?() ?? true) }
    /// 덱에 올린 곡(ContentID, 추가한 곡은 djc- ID). 목록의 덱 표시와 새로 읽을 때 덱을 맞추는 데 쓴다.
    private(set) var deckTrackID: String?

    /// 초안 상태(메모리). 표의 ✎ 표시는 디스크를 다시 읽지 않고 이것으로 계산한다.
    var tagDrafts: [String: TagDraft] = [:]
    @ObservationIgnored var recoveryMemoryInput: ((String, DraftRecoveryKind) -> RecoveryDraft?)?
    @ObservationIgnored var onDraftRecovered: ((RecoveryDraft, TrackRow?, BeatGrid?) -> Void)?
    var isRecoveringDraft = false
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
    var gridJob: GridJob? {
        didSet { if (oldValue == nil) != (gridJob == nil) { hasGridJob = gridJob != nil } }
    }
    /// 추정이 도는 중인지. 진행(`done`)이 오를 때마다가 아니라 시작·끝에만 바뀌어, 사이드바 본문은 이것만 읽고 진행 줄을 넣고 뺀다(#141).
    private(set) var hasGridJob = false
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
    /// detail 아래쪽에 뜨는 알림(rekordbox 반영 완료 등)
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

    /// 큐·그리드·게인·태그 초안이 있는 곡(태그도 반영하면 rekordbox 곡 정보에 쓴다).
    /// 부를 때마다 합집합을 새로 만든다. 곡마다 거를 때는 한 번 받아 두고 쓴다(#129: 초안 600곡이면 곡을 고를 때마다 수백 ms였다).
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
    func invalidatePendingLoads() { loadGeneration += 1 }
    @ObservationIgnored private let snapshotRequests = SnapshotRequestQueue()
    /// 뒤에서 도는 Music 최신화. 쓰기 뒤 다시 읽기가 버리면 새 사본이 같은 조회를 이어받는다.
    struct ITunesRefresh {
        let id: UUID
        let generation: Int
        let capture: Task<ITunesLibrarySnapshot, Never>
        let task: Task<Void, Never>
    }
    @ObservationIgnored private(set) var iTunesRefresh: ITunesRefresh?
    /// 이 사본에 곧 결과를 채택할 Music 최신화. 끝나기 전에는 선택 창이 낡은 목록으로 쓰지 않는다.
    func currentITunesRefresh(snapshot: URL?, revision: Int) -> Task<Void, Never>? {
        guard let snapshot, snapshotURL == snapshot, previewRevision == revision,
              let iTunesRefresh, iTunesRefresh.generation == loadGeneration else { return nil }
        return iTunesRefresh.task
    }
    private(set) var lastError: String?
    func reportLibraryError(_ message: String) { lastError = message }

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
    /// USB 곡은 읽기 전용이라 편집·쓰기·재생 목록 대상에 넣지 않는다.
    func uniqueTracks(_ candidates: [TrackRow]) -> [TrackRow] {
        var seen = Set<String>()
        return candidates.filter { !$0.isUsb && seen.insert($0.track.id).inserted }.map { rowsByID[$0.track.id] ?? $0 }
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
        // USB 곡은 아직 덱에 올리지 않는다(덱이 로컬 분석 파일·초안을 기준으로 읽는다)
        guard writeLockPolicy.allowsLibraryInteraction, let row, !row.isUsb else { return }
        setDeckTrack(rowsByID[row.track.id] ?? row)
    }

    var canLoadSelectionToDeck: Bool { writeLockPolicy.allowsLibraryInteraction && primaryRow.map { !$0.isUsb } == true }

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
        case .pending:
            let pending = pendingUUIDs
            base = rows.filter { pending.contains($0.track.uuid) }
        case let .usb(target): base = usb?.rows(for: target) ?? []
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

    /// 스냅샷을 새로 떠도 되는지. 명시한 사본(`--db`·`DJC_DB`)으로 띄웠는데 사본 rekordbox 폴더(`DJC_REKORDBOX_DIR`)가 없으면 거짓:
    /// 그때 뜨면 라이브 master.db를 원본으로 읽고 사용자 스냅샷 폴더에 새 사본을 만들고 옛 사본을 정리한다(`DJC_HOME`은 스냅샷을 옮기지 않는다).
    static func snapshotTakeAllowed(arguments: [String], environment: [String: String]) -> Bool {
        !(explicitDatabaseRequested(arguments: arguments, environment: environment)
            && !LibrarySnapshot.hasRekordboxDirectoryOverride(in: environment))
    }

    /// 스냅샷을 뜨지 않은 이유(`snapshotTakeAllowed`가 거짓일 때)
    static var snapshotRefusedMessage: String { String(ui: "명시한 사본(--db)으로 연 창에서는 스냅샷을 뜨지 않습니다. --db 없이 다시 여세요") }

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
    func loadInitial(snapshotDirectory: URL? = nil,
                     arguments: [String] = ProcessInfo.processInfo.arguments,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     captureITunes: @escaping @Sendable () -> ITunesLibrarySnapshot = {
                         RekordboxITunesReader.capture()
                     }) async {
        guard !isLoading, rows.isEmpty else { return }
        let override = arguments.firstIndex(of: "--db")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            ?? environment["DJC_DB"]
        let snapshotDirectory = snapshotDirectory ?? LibrarySnapshot.defaultDirectory(in: environment)
        if let override {
            await load(snapshot: URL(filePath: override), arguments: arguments, environment: environment,
                       captureITunes: captureITunes)
        } else if let latest = try? LibrarySnapshot.latest(in: snapshotDirectory) {
            let mayCaptureMusic = !LibrarySnapshot.hasRekordboxDirectoryOverride(in: environment)
            let sourceDatabase = LibrarySnapshot.sameDirectory(snapshotDirectory, LibrarySnapshot.defaultDirectory(in: environment))
                ? LibrarySnapshot.rekordboxDirectory(in: environment).appending(path: "master.db") : nil
            let cached = ITunesLibrarySnapshot.load(for: latest)
            let sourceDirectory = (sourceDatabase ?? latest).deletingLastPathComponent()
            let hasCurrentCatalog = mayCaptureMusic && cached.status == .ready && cached.sourcePlaylists != nil
                && !RekordboxITunesReader.selectionChanged(since: cached.syncData, directory: sourceDirectory)
            let expectedGeneration = loadGeneration + 1
            await load(snapshot: latest, refreshITunes: mayCaptureMusic && !hasCurrentCatalog,
                       arguments: arguments, environment: environment, captureITunes: captureITunes)
            // 켠 순간의 창 활성화는 읽는 도중이라 건너뛰므로, 읽은 뒤 한 번 더 본다
            let loadedRevision = previewRevision
            await refreshIfRekordboxChanged(arguments: arguments, environment: environment)
            guard hasCurrentCatalog, snapshotURL == latest, loadGeneration == expectedGeneration,
                  previewRevision == loadedRevision, lastError == nil else { return }
            startITunesRefresh(snapshot: latest, quiet: true,
                previousITunesSnapshot: nil, fallbackDirectory: snapshotDirectory,
                sourceDatabase: sourceDatabase, captureITunes: captureITunes)
        } else {
            phase = .idle
        }
    }

    /// 창으로 돌아올 때: 지금 읽은 스냅샷 뒤에 rekordbox가 라이브러리를 바꿨으면 뒤에서 조용히 새로 읽는다.
    /// rekordbox가 켜져 있어도 읽기용 사본(WAL까지 사본 안에서 합침)으로 뜬다. 원본은 읽기만 한다.
    func refreshIfRekordboxChanged(arguments: [String]? = nil,
                                  environment: [String: String]? = nil) async {
        let arguments = arguments ?? launchArguments
        let environment = environment ?? launchEnvironment
        guard case .loaded = phase, !isLoading, !isWritingRekordbox, let snapshotURL,
              !Self.explicitDatabaseRequested(arguments: arguments, environment: environment),
              LibrarySnapshot.sameDirectory(snapshotURL.deletingLastPathComponent(),
                                            LibrarySnapshot.defaultDirectory(in: environment)) else { return }
        if !LibrarySnapshot.changed(since: snapshotURL,
                                    source: LibrarySnapshot.rekordboxDirectory(in: environment).appending(path: "master.db")) {
            if !LibrarySnapshot.hasRekordboxDirectoryOverride(in: environment),
               iTunesRefresh?.generation != loadGeneration,
               RekordboxITunesReader.selectionChanged(since: iTunesSnapshot.syncData) {
                await load(snapshot: snapshotURL, quiet: true, refreshITunes: true)
            }
            return
        }
        FileHandle.standardError.write(Data("rekordbox 라이브러리가 바뀌어 다시 읽습니다\n".utf8))
        await takeSnapshot(force: true, quiet: true)
    }

    /// 명시적 동기화만 비충돌 태그 기준을 맞춘다. 사본 모드에서는 지정한 DB를 다시 읽는다.
    func synchronizeLibrary(arguments: [String]? = nil,
                            environment: [String: String]? = nil) async {
        let arguments = arguments ?? launchArguments
        let environment = environment ?? launchEnvironment
        guard canSynchronizeLibrary else { return }
        isSynchronizingLibrary = true
        defer { isSynchronizingLibrary = false }
        DraftWriter.flush()
        retryFailedTagSaves()
        if Self.explicitDatabaseRequested(arguments: arguments, environment: environment) {
            guard let snapshotURL else { return }
            await load(snapshot: snapshotURL, quiet: true, synchronizingDrafts: true, arguments: arguments, environment: environment)
        } else {
            await takeSnapshot(force: LibrarySnapshot.isRekordboxRunning(), synchronizingDrafts: true,
                               arguments: arguments, environment: environment)
        }
    }

    /// - Parameter quiet: 화면을 로딩으로 바꾸지 않고 뒤에서 다시 읽는다(rekordbox에 쓴 뒤 등).
    /// - Parameter refreshITunes: 쓰기 뒤에는 기존 목록을 재사용해 Music 응답을 기다리지 않는다.
    func takeSnapshot(force: Bool = false, quiet: Bool = false, refreshITunes: Bool = true, synchronizingDrafts: Bool = false,
                      snapshotDirectory: URL = LibrarySnapshot.defaultDirectory,
                      snapshotCopy: (@Sendable (Bool) throws -> URL)? = nil,
                      captureITunes: @escaping @Sendable () -> ITunesLibrarySnapshot = { RekordboxITunesReader.capture() },
                      arguments: [String]? = nil,
                      environment: [String: String]? = nil) async {
        guard !synchronizingDrafts || !isWritingRekordbox else { return }
        let arguments = arguments ?? launchArguments
        let environment = environment ?? launchEnvironment
        guard Self.snapshotTakeAllowed(arguments: arguments, environment: environment) else {
            let message = Self.snapshotRefusedMessage
            if rows.isEmpty { phase = .failed(message) } else { lastError = message }
            return
        }
        let snapshotCopy = snapshotCopy ?? takeLiveSnapshot
        guard !isLoading || snapshotRequests.isRunning || !refreshITunes else { return }
        await snapshotRequests.runWithFollowUp(force: force, quiet: quiet, refreshITunes: refreshITunes, synchronizingDrafts: synchronizingDrafts) { [self] force, quiet in
            await takeSnapshotOnce(force: force, quiet: quiet, refreshITunes: refreshITunes, synchronizingDrafts: synchronizingDrafts, snapshotDirectory: snapshotDirectory,
                                   snapshotCopy: snapshotCopy, captureITunes: captureITunes,
                                   arguments: arguments, environment: environment)
        }
    }

    private func takeSnapshotOnce(force: Bool, quiet: Bool, refreshITunes: Bool, synchronizingDrafts: Bool, snapshotDirectory: URL,
                                  snapshotCopy: @escaping @Sendable (Bool) throws -> URL,
                                  captureITunes: @escaping @Sendable () -> ITunesLibrarySnapshot,
                                  arguments: [String], environment: [String: String]) async -> Task<Void, Never>? {
        // 이 다시 읽기가 버리는 Music 최신화는 새 사본에서 이어받는다. 지난 세션 목록이 세션 내내 남지 않게.
        let interrupted = iTunesRefresh.flatMap { $0.generation == loadGeneration ? $0 : nil }
        invalidatePendingLoads()
        if let snapshotURL { ITunesRefreshCoordinator.shared.invalidateSnapshots([snapshotURL]) }
        let hadRows = !rows.isEmpty
        let refreshITunes = refreshITunes && !LibrarySnapshot.hasRekordboxDirectoryOverride(in: environment)
        let explicitDatabase = Self.explicitDatabaseRequested(arguments: arguments, environment: environment)
        // 같은 초에 DB 파일 이름을 재사용해도 마지막 정상 iTunes 사본을 잃지 않게 먼저 읽는다.
        let previousURL = !explicitDatabase
            && snapshotURL.map { LibrarySnapshot.sameDirectory($0.deletingLastPathComponent(), snapshotDirectory) } == true
            ? snapshotURL : nil
        let sourceDatabase = LibrarySnapshot.sameDirectory(snapshotDirectory, LibrarySnapshot.defaultDirectory(in: environment))
            ? LibrarySnapshot.rekordboxDirectory(in: environment).appending(path: "master.db") : nil
        let previousITunesSnapshot = previousURL.map {
            LoadedLibrary.ITunesFallback(source: $0, contents: ITunesLibrarySnapshot.load(for: $0),
                preferOverCurrent: !refreshITunes, sourceDatabase: sourceDatabase)
        }
        var isLoaded: Bool { if case .loaded = phase { true } else { false } }
        let quiet = quiet && hadRows && isLoaded
        if !quiet { phase = .loading(String(ui: "rekordbox DB 스냅샷을 뜨는 중…")) }
        do {
            let url = try await Self.runBlockingLibraryWork { try snapshotCopy(force) }
            ITunesRefreshCoordinator.shared.invalidateSnapshots([url])
            let fallback = latestITunesFallback(previousITunesSnapshot)
            let expectedGeneration = loadGeneration + 1
            await load(snapshot: url, quiet: quiet, refreshITunes: false, synchronizingDrafts: synchronizingDrafts,
                       previousITunesSnapshot: fallback,
                       arguments: arguments, environment: environment, captureITunes: captureITunes)
            guard loadGeneration == expectedGeneration, snapshotURL == url, lastError == nil else { return nil }
            guard refreshITunes else {
                // 쓰기는 Music을 기다리지 않게 후속 작업으로 돌려주지 않는다.
                if let interrupted {
                    startITunesRefresh(snapshot: url, quiet: true, previousITunesSnapshot: fallback,
                                       fallbackDirectory: snapshotDirectory, sourceDatabase: sourceDatabase,
                                       captureITunes: captureITunes, continuing: interrupted.capture)
                }
                return nil
            }
            return startITunesRefresh(snapshot: url, quiet: quiet, previousITunesSnapshot: fallback,
                                      fallbackDirectory: snapshotDirectory, sourceDatabase: sourceDatabase,
                                      captureITunes: captureITunes)
        } catch {
            // 이미 라이브러리가 있으면 그대로 두고 오류만 알린다.
            let message = AppErrorMessage.message(for: error)
            if hadRows {
                phase = .loaded
                // 목록 위 경고는 초안 저장 오류와 같은 자리이므로 무엇이 실패했는지 앞에 적는다.
                lastError = String(ui: "스냅샷을 새로 뜨지 못했습니다: \(message)")
            } else {
                phase = .failed(message)
            }
            return nil
        }
    }

    /// DB/행은 이미 읽은 뒤 Music 결과만 결합한다. 오래된 요청은 sidecar와 화면 모두 순서표로 거른다.
    /// - Parameter capture: 버려진 최신화가 하던 Music 조회. 주면 Music을 다시 조회하지 않고 그 결과를 기다린다.
    @discardableResult
    private func startITunesRefresh(snapshot: URL, quiet: Bool,
                                    previousITunesSnapshot: LoadedLibrary.ITunesFallback?, fallbackDirectory: URL,
                                    sourceDatabase: URL?, captureITunes: @escaping @Sendable () -> ITunesLibrarySnapshot,
                                    continuing capture: Task<ITunesLibrarySnapshot, Never>? = nil) -> Task<Void, Never> {
        let generation = loadGeneration
        let refreshTicket = ITunesRefreshCoordinator.shared.begin(snapshot: snapshot, sourceDatabase: sourceDatabase)
        if !quiet { phase = .loading(LoadedLibrary.Stage.music.message) }
        let capture = capture ?? Task {
            (try? await Self.runBlockingLibraryWork {
                LoadedLibrary.Stage.music.measure(progress: { _ in }, captureITunes)
            }) ?? ITunesLibrarySnapshot(status: .unavailable)
        }
        let id = UUID()
        let task = Task { [self] in
            defer { if iTunesRefresh?.id == id { iTunesRefresh = nil } }
            let captured = await capture.value
            guard generation == loadGeneration, snapshotURL == snapshot else { return }
            let result = try? await Self.runBlockingLibraryWork {
                LoadedLibrary.loadITunes(snapshot: snapshot, refreshITunes: true, captured: captured,
                                         previousITunesSnapshot: previousITunesSnapshot,
                                         fallbackDirectory: fallbackDirectory, refreshTicket: refreshTicket,
                                         sourceDatabase: sourceDatabase)
            }
            guard generation == loadGeneration, snapshotURL == snapshot else { return }
            if let result {
                iTunesSnapshot = result
                iTunesLibrary = SyncedITunesLibrary(snapshot: result, tracks: rows.map(\.track))
                if case let .itunesPlaylist(id) = sidebar, iTunesLibrary.index[id] == nil { sidebar = .filter(.all) }
                refreshBase()
                let visible = Set(displayRows.map(\.id))
                let existing = selection.filter { rowsByID[$0] != nil || visible.contains($0) }
                if existing != selection { selection = existing }
            }
            if !quiet { phase = .loaded }
        }
        iTunesRefresh = ITunesRefresh(id: id, generation: generation, capture: capture, task: task)
        return task
    }

    #if DEBUG
    /// 자가 테스트용: 사본 모드는 Music을 읽지 않으므로 멈춘 Music 최신화를 흉내 내 선택 창이 기다리는지 본다.
    func startSimulatedITunesRefresh(capture: @escaping @Sendable () -> ITunesLibrarySnapshot) -> Task<Void, Never>? {
        guard let snapshotURL else { return nil }
        return startITunesRefresh(snapshot: snapshotURL, quiet: true, previousITunesSnapshot: nil,
                                  fallbackDirectory: snapshotURL.deletingLastPathComponent(),
                                  sourceDatabase: nil, captureITunes: capture)
    }
    #endif

    /// 사본을 뜨는 동안 동기화 선택을 저장했다면, 뜨기 전에 붙든 이전 선택보다 현재 화면을 우선한다.
    func latestITunesFallback(_ previous: LoadedLibrary.ITunesFallback?) -> LoadedLibrary.ITunesFallback? {
        guard let previous, snapshotURL == previous.source else { return previous }
        let hasUsableDiskCache = previous.contents.status == .ready || previous.contents.status == .stale
        guard iTunesSnapshot.status == .ready || iTunesSnapshot.status == .stale
                || (iTunesSnapshot.status == .unavailable && !hasUsableDiskCache) else { return previous }
        return .init(source: previous.source, contents: iTunesSnapshot,
                     preferOverCurrent: previous.preferOverCurrent || previous.contents.syncData != iTunesSnapshot.syncData,
                     sourceDatabase: previous.sourceDatabase)
    }

    func load(snapshot: URL, quiet: Bool = false, refreshITunes: Bool = false, synchronizingDrafts: Bool = false,
              previousITunesSnapshot: LoadedLibrary.ITunesFallback? = nil,
              arguments: [String] = ProcessInfo.processInfo.arguments,
              environment: [String: String] = ProcessInfo.processInfo.environment,
              captureITunes: @escaping @Sendable () -> ITunesLibrarySnapshot = { RekordboxITunesReader.capture() }) async {
        guard !synchronizingDrafts || !isWritingRekordbox else { return }
        DraftWriter.flush()
        let initialTagRevision = tagRevision
        previewWarmTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let started = ContinuousClock.now
        if !quiet { phase = .loading(LoadedLibrary.Stage.database.message) }
        do {
            let preset = commentPreset
            let sourceDatabase: URL? = !Self.explicitDatabaseRequested(arguments: arguments, environment: environment)
                && LibrarySnapshot.sameDirectory(snapshot.deletingLastPathComponent(), LibrarySnapshot.defaultDirectory(in: environment))
                ? LibrarySnapshot.rekordboxDirectory(in: environment).appending(path: "master.db") : nil
            // 메인 액터에서 정한 요청 순서를 캡처가 끝날 때까지 유지한다.
            let refreshTicket = ITunesRefreshCoordinator.shared.begin(snapshot: snapshot, sourceDatabase: sourceDatabase)
            let loaded = try await Self.runBlockingLibraryWork {
                try LoadedLibrary.load(snapshot: snapshot, commentPreset: preset, refreshITunes: refreshITunes,
                                       previousITunesSnapshot: previousITunesSnapshot, refreshTicket: refreshTicket,
                                       sourceDatabase: sourceDatabase, progress: { stage in
                                           Task { @MainActor in
                                               // 늦게 도착한 진행 표시가 끝난 읽기나 새 요청을 덮지 않는다.
                                               guard generation == self.loadGeneration, self.isLoading else { return }
                                               self.phase = .loading(stage.message)
                                           }
                                       }, captureITunes: captureITunes)
            }
            // 더 나중에 시작한 로드가 있으면 이 결과는 버린다.
            guard generation == loadGeneration else { return }
            // 기다리는 동안 시작한 쓰기·복원의 초안과 동기화 결과를 섞지 않는다.
            guard !synchronizingDrafts || !isWritingRekordbox else {
                if !quiet { phase = rows.isEmpty ? .idle : .loaded }
                return
            }
            undoManager?.removeAllActions(withTarget: self)
            let loadedRows = loaded.rows.map { row in
                var row = row
                row.fileMissing = missingPathCache.contains(row.track.folderPath)
                return row
            }
            rows = loadedRows
            rowsByID = Dictionary(loadedRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rowsByUUID = Dictionary(loadedRows.map { ($0.track.uuid, $0) }, uniquingKeysWith: { first, _ in first })
            report = loaded.report
            filterCounts = loaded.filterCounts
            filterCounts[.missingFile] = rows.lazy.filter(LibraryFilter.missingFile.includes).count
            duplicateGroups = loaded.duplicateGroups
            draftFileStamps = nil
            // 읽는 동안 사용자가 편집했거나 저장에 실패한 입력은 디스크의 오래된 값으로 덮지 않는다.
            let failedTags = failedTagSaves()
            var latestTags = tagRevision == initialTagRevision ? loaded.tagDrafts : tagDrafts
            for uuid in failedTags { latestTags[uuid] = tagDrafts[uuid] }
            var conflicts = 0
            var rebased: [TagDraft] = []
            if synchronizingDrafts {
                for (uuid, draft) in latestTags where !failedTags.contains(uuid) {
                    guard let row = rowsByUUID[uuid], let updated = draft.rebased(onto: TagFields(track: row.track)) else {
                        conflicts += 1
                        continue
                    }
                    if updated != draft {
                        latestTags[uuid] = updated.hasChanges ? updated : nil
                        rebased.append(updated)
                    }
                }
            }
            tagDrafts = latestTags
            if !rebased.isEmpty { persistTagDrafts(rebased); DraftWriter.flush() }
            tagRevision += 1
            cueDraftUUIDs = loaded.cueDraftUUIDs
            draftCueCounts = loaded.draftCueCounts
            draftPreviewCues = loaded.draftPreviewCues
            gridDraftUUIDs = loaded.gridDraftUUIDs
            preserveUnsavedDraftIndicators()
            gainDraftUUIDs = GainDraftStore.uuids()
            editedUUIDs = cueDraftUUIDs.union(gridDraftUUIDs).union(gainDraftUUIDs).union(tagDrafts.keys)
            rekordboxPlaylists = loaded.playlists
            playlistDraft = loaded.playlistDraft
            iTunesLibrary = loaded.iTunesLibrary
            iTunesSnapshot = loaded.iTunesSnapshot
            if case let .itunesPlaylist(id) = sidebar, iTunesLibrary.index[id] == nil { sidebar = .filter(.all) }
            mergeDrafts = DuplicateMergeDraftStore.load()
            refreshPlaylists(refreshList: false)
            histories = loaded.histories
            historyIndex = Dictionary(uniqueKeysWithValues: histories.map { ($0.id, $0) })
            snapshotURL = snapshot
            onSnapshotLoaded?(snapshot)
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
            lastError = failedTagSaves().isEmpty ? nil : DraftWriter.tagSaveFailureMessage
            if synchronizingDrafts {
                toast = conflicts == 0
                    ? AppToast(title: String(ui: "현재 rekordbox 내용을 불러왔습니다"))
                    : AppToast(kind: .warning, title: String(ui: "태그 충돌을 확인하세요"),
                               detail: String(ui: "같은 칸이 바뀐 \(conflicts)곡의 초안을 보존했습니다. 곡 정보에서 현재 값과 초안을 확인하세요."))
            }
            FileHandle.standardError.write(Data("라이브러리 로드 \(ContinuousClock.now - started) · \(rows.count)곡\n".utf8))
            // 동기화 중 시작한 드래그는 메모리에만 있을 수 있어 덱을 덮지 않는다.
            if !synchronizingDrafts || (allowsLibrarySync?() ?? true) {
                refreshDeckTrack()
                if synchronizingDrafts, let deckTrackID, let row = rowsByID[deckTrackID] {
                    onRekordboxWritten?([row.track.uuid])
                }
            }
            checkMissingFiles()
            applyLaunchSelection()
            runLaunchStagingTest()
            // 캐시 용량 상한(최근 사용 순)은 뒤에서 조용히 정리한다.
            Task.detached(priority: .background) { CacheMaintenance.prune() }
        } catch {
            guard generation == loadGeneration else { return }
            if quiet {
                lastError = String(ui: "스냅샷을 새로 뜨지 못했습니다: \(AppErrorMessage.message(for: error))")
            } else {
                phase = .failed(AppErrorMessage.message(for: error))
            }
        }
    }

    // MARK: - 파일이 없는 곡(#126)

    /// 음원 파일이 있는지 뒤에서 확인해 행·'파일 없음' 개수에 반영한다. 읽은 뒤·디스크를 연결하거나 뺄 때·다시 확인 버튼에서 부른다.
    /// 큰 라이브러리의 확인(곡마다 파일 시스템 조회)이 메인 스레드를 막지 않게 한다.
    func checkMissingFiles() {
        missingFileTask?.cancel()
        let generation = loadGeneration
        let tracks = rows.map(\.track)
        let exists = fileExists
        isCheckingFiles = true
        missingFileTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { MissingFiles.scan(tracks, exists: exists) }.value
            guard let self, !Task.isCancelled else { return }
            // 그사이 다시 읽기 시작했으면 버린다(새로 읽은 뒤 다시 확인한다).
            guard generation == loadGeneration else {
                isCheckingFiles = false
                return
            }
            applyMissingFiles(result)
        }
    }

    private func applyMissingFiles(_ result: MissingFiles) {
        isCheckingFiles = false
        missingFiles = result
        // 사본을 고쳐 한 번에 넣는다(곡마다 고치면 관찰 알림이 곡 수만큼 나간다).
        var updated = rows, byID = rowsByID, byUUID = rowsByUUID
        var changed = false
        for index in updated.indices {
            let missing = result.trackIDs.contains(updated[index].track.id)
            guard updated[index].fileMissing != missing else { continue }
            updated[index].fileMissing = missing
            byID[updated[index].id] = updated[index]
            byUUID[updated[index].track.uuid] = updated[index]
            changed = true
        }
        missingPathCache = Set(updated.lazy.filter(\.fileMissing).map(\.track.folderPath))
        filterCounts[.missingFile] = updated.lazy.filter(LibraryFilter.missingFile.includes).count
        guard changed else { return }
        rows = updated
        rowsByID = byID
        rowsByUUID = byUUID
        refreshBase()
    }

    // 동기 읽기·복사의 대기가 cooperative pool을 점유하지 않게 한다.
    nonisolated static func runBlockingLibraryWork<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result(catching: operation))
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

    /// USB 목록·라이브러리가 바뀌었다: 보고 있던 USB 대상이 없어졌으면 라이브러리로 돌아가고, 아니면 줄을 다시 만든다.
    func usbChanged() {
        guard case let .usb(target) = sidebar else { return }
        if usb?.contains(target) == true { refreshBase() } else { sidebar = .filter(.all) }
    }

    /// CLI·외부 편집의 원자적 파일 교체를 확인한다. DB·파형·재생은 다시 불러오지 않는다.
    func refreshExternalDrafts(home: URL = DJCPaths.userData) {
        guard case .loaded = phase, !isWritingRekordbox else { return }
        DraftWriter.flush()
        let cueDirectory = home.appending(path: "cue-drafts")
        let tagDirectory = home.appending(path: "tag-drafts")
        let gridDirectory = home.appending(path: "grid-drafts")
        let unsaved = DraftWriter.unsavedUUIDs(cueDirectory: cueDirectory, gridDirectory: gridDirectory)
        let failedTags = failedTagSaves(in: tagDirectory)
        if !failedTags.isEmpty { lastError = DraftWriter.tagSaveFailureMessage }
        else if lastError == DraftWriter.tagSaveFailureMessage { lastError = nil }
        var stamps: [String: Date] = [:]
        for directory in [cueDirectory, tagDirectory, gridDirectory] {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "json" {
                stamps[file.path] = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
        }
        guard stamps != draftFileStamps || !unsaved.isEmpty else { return }
        draftFileStamps = stamps
        var cues: [String: CueDraft] = [:]
        for uuid in CueDraftStore.uuids(directory: cueDirectory).union(unsaved) {
            // 자동 큐를 빼고 만든 옛 초안에는 곡의 자동 큐를 채운다(#145).
            if let draft = (DraftWriter.pendingCue(trackUUID: uuid, directory: cueDirectory)
                ?? CueDraftStore.load(trackUUID: uuid, directory: cueDirectory))?.includingAutoCues(from: rowsByUUID[uuid]?.cues ?? []),
               draft.hasChanges { cues[uuid] = draft }
        }
        var tags: [String: TagDraft] = [:]
        for uuid in TagDraftStore.uuids(directory: tagDirectory) {
            if let draft = TagDraftStore.load(trackUUID: uuid, directory: tagDirectory), draft.hasChanges { tags[uuid] = draft }
        }
        for uuid in failedTags { tags[uuid] = tagDrafts[uuid] }
        if tagDrafts.mapValues(\.fields) != tags.mapValues(\.fields) || tagDrafts.mapValues(\.base) != tags.mapValues(\.base) {
            tagDrafts = tags
            // 외부 변경 뒤 옛 되돌리기가 새 초안을 덮지 않게 한다.
            undoManager?.removeAllActions(withTarget: self)
            tagRevision += 1
        }
        cueDraftUUIDs = Set(cues.keys)
        draftCueCounts = cues.mapValues(CueCounts.init)
        draftPreviewCues = cues.mapValues { $0.cues.map(PreviewCueMark.init) }
        gridDraftUUIDs = GridDraftStore.uuids(directory: gridDirectory)
        preserveUnsavedDraftIndicators(home: home)
        editedUUIDs = cueDraftUUIDs.union(gridDraftUUIDs).union(gainDraftUUIDs).union(tagDrafts.keys)
        if case .pending = sidebar { refreshBase() }
        onCueDraftsReloaded?(cues)
    }

    /// 실패한 저장의 입력이 디스크보다 최신이므로 다시 읽어도 복구 진입점을 남긴다.
    private func preserveUnsavedDraftIndicators(home: URL = DJCPaths.userData) {
        let cues = home.appending(path: "cue-drafts"), grids = home.appending(path: "grid-drafts")
        for uuid in DraftWriter.unsavedUUIDs(cueDirectory: cues, gridDirectory: grids) {
            if let draft = DraftWriter.pendingCue(trackUUID: uuid, directory: cues) {
                if draft.hasChanges { cueDraftUUIDs.insert(uuid) } else { cueDraftUUIDs.remove(uuid) }
                cueDraftChanged(draft)
            }
            if let draft = DraftWriter.pendingGrid(trackUUID: uuid, directory: grids) {
                if draft.hasChanges { gridDraftUUIDs.insert(uuid) } else { gridDraftUUIDs.remove(uuid) }
            }
        }
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

    func recoveryKinds(for row: TrackRow) -> [DraftRecoveryKind] {
        guard !row.isUsb, !row.isStaged, !row.track.isStreaming else { return [] }
        let uuid = row.track.uuid
        return DraftRecoveryKind.allCases.filter { kind in
            switch kind {
            case .tags: tagDrafts[uuid]?.hasChanges == true
            case .cues: cueDraftUUIDs.contains(uuid) || recoveryMemoryInput?(uuid, kind)?.hasChanges == true
            case .grid: gridDraftUUIDs.contains(uuid) || recoveryMemoryInput?(uuid, kind)?.hasChanges == true
            }
        }
    }

    /// 선택한 곡의 현재 정보만 갱신한다. 다른 종류의 초안은 다시 읽지 않는다.
    func updateRecoveryRow(_ current: TrackRow) {
        let previous = rowsByUUID[current.track.uuid]
        var row = TrackRow(track: current.track, cues: current.cues, playCount: current.playCount,
                           tempoChanges: previous?.tempoChanges ?? current.tempoChanges,
                           autoGain: previous?.autoGain ?? current.autoGain, commentRule: commentPreset.rule)
        row.fileMissing = previous?.fileMissing ?? current.fileMissing
        row.keyEstimated = previous?.keyEstimated ?? current.keyEstimated
        rows = rows.map { $0.track.uuid == row.track.uuid ? row : $0 }
        rowsByUUID[row.track.uuid] = row
        rowsByID[row.track.id] = row
        tagRevision += 1
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
