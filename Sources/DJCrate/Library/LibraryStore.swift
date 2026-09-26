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

    let resultHistory: WriteResultHistory
    @ObservationIgnored var feedback: AppFeedback
    var showingWriteResult = false
    @ObservationIgnored var writeTask: Task<Void, Never>?
    @ObservationIgnored var previewWarmTask: Task<Void, Never>?

    func cancelWritePreparation() {
        guard writeStage?.cancellable == true else { return }
        writeTask?.cancel()
    }

    init(resultHistory: WriteResultHistory = WriteResultHistory(url: DJCPaths.userData.appending(path: "last-write-result.json")),
         feedback: AppFeedback = AppFeedback(), saveTagDrafts: @escaping ([TagDraft]) -> Void = { DraftWriter.save($0) }) {
        self.saveTagDrafts = saveTagDrafts
        self.resultHistory = resultHistory
        self.feedback = feedback
    }

    var phase: Phase = .idle
    private(set) var rows: [TrackRow] = []
    private(set) var report: LibraryReport?
    private(set) var snapshotURL: URL?
    private(set) var previewRevision = 0
    /// 표에 보이는 줄. 필터·검색·정렬이 바뀔 때만 다시 계산한다(그릴 때마다 계산하지 않는다).
    private(set) var displayRows: [TrackRow] = []
    private(set) var filterCounts: [LibraryFilter: Int] = [:]
    private(set) var playlistCounts: [String: Int] = [:]
    var isLoading: Bool { if case .loading = phase { true } else { false } }

    var sidebar: SidebarItem = .filter(.all) {
        didSet {
            guard sidebar != oldValue else { return }
            // 플레이리스트는 rekordbox 순서가 기본, 필터는 임포트 최신순이 기본.
            suppressRefresh = true
            switch sidebar {
            case .playlist, .staged, .pending: sortOrder = []
            case .filter:
                if case .filter = oldValue {} else { sortOrder = [KeyPathComparator(\TrackRow.importedOn, order: .reverse)] }
            }
            suppressRefresh = false
            refreshBase()
        }
    }
    private(set) var playlistTree: [PlaylistNode] = []
    private var playlistIndex: [String: PlaylistNode] = [:] { didSet { playlistCount = playlistIndex.values.filter { !$0.isFolder }.count } }
    /// 폴더를 뺀 rekordbox 플레이리스트 수(사이드바 제목)
    private(set) var playlistCount = 0

    var sidebarTitle: String {
        switch sidebar {
        case let .filter(filter): filter.rawValue
        case let .playlist(id): playlistIndex[id]?.name ?? "플레이리스트"
        case .staged: "추가한 곡"
        case .pending: "rekordbox 반영 대기"
        }
    }
    var search = "" { didSet { if search != oldValue { refreshFiltered() } } }
    var sortOrder = [KeyPathComparator(\TrackRow.importedOn, order: .reverse)] {
        didSet { if !suppressRefresh { refreshBase() } }
    }
    /// 선택이 바뀌면 150ms 뒤 덱에 올릴 곡을 알린다(방향키로 지나가는 곡마다 덱을 올리지 않도록).
    var selection: Set<TrackRow.ID> = [] { didSet { if selection != oldValue { schedulePrimaryChange() } } }
    var onPrimaryRowChange: ((TrackRow?) -> Void)?

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
    /// 이번 실행에서 rekordbox에 쓴 마지막 백업(토스트·사이드바의 되돌리기)
    var lastWriteBackup: URL?
    /// 창 아래에 잠깐 뜨는 알림(rekordbox 반영 완료 등)
    var toast: AppToast? {
        didSet {
            if let toast { feedback.announce(AppMessage(kind: toast.kind, text: [toast.title, toast.detail].compactMap { $0 }.joined(separator: "\n"))) }
        }
    }
    /// rekordbox 쓰기 단계 안내(있으면 창 전체를 덮어 조작을 막는다. 확인 창이 떠 있는 동안은 nil)
    var writeStage: WriteStage?
    /// rekordbox에 쓰는 중(미리 보기 포함)
    var isWritingRekordbox = false {
        didSet { if isWritingRekordbox { undoManager?.removeAllActions(withTarget: self) } }
    }
    /// 쓰는 동안 덱 큐 편집을 잠근다
    var onWriteLock: ((Bool) -> Void)?
    /// rekordbox에 쓰거나 되돌린 곡(UUID). 덱이 그 곡이면 다시 읽는다.
    var onRekordboxWritten: ((Set<String>) -> Void)?

    /// 큐 초안이 있는 곡의 (핫큐, 메모리 큐) 개수. 목록 숫자는 반영 전에도 초안 기준으로 보여 준다.
    var draftCueCounts: [String: CueCounts] = [:]
    var draftPreviewCues: [String: [PreviewCueMark]] = [:]

    /// 큐·그리드 초안이 있는 곡(태그 초안은 파일 태그로 반영하므로 여기엔 넣지 않는다)
    var pendingUUIDs: Set<String> { cueDraftUUIDs.union(gridDraftUUIDs).union(gainDraftUUIDs) }
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
    private var primaryTask: Task<Void, Never>?
    private(set) var lastError: String?

    /// 덱에 올릴 곡: 선택 중 표 순서로 첫 곡.
    var primaryRow: TrackRow? {
        guard !selection.isEmpty else { return nil }
        if selection.count == 1, let id = selection.first { return rowsByID[id] }
        if let row = displayRows.first(where: { selection.contains($0.id) }) { return row }
        return selection.first.flatMap { rowsByID[$0] }
    }

    var selectedRows: [TrackRow] {
        displayRows.filter { selection.contains($0.id) }
    }

    func count(_ filter: LibraryFilter) -> Int { filterCounts[filter] ?? 0 }

    func count(playlist node: PlaylistNode) -> Int { playlistCounts[node.id] ?? 0 }

    private func schedulePrimaryChange() {
        primaryTask?.cancel()
        primaryTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self.onPrimaryRowChange?(self.primaryRow)
        }
    }

    func refreshBase() {
        let base: [TrackRow]
        switch sidebar {
        case let .filter(filter): base = rows.filter(filter.includes)
        case let .playlist(id): base = (playlistIndex[id]?.trackIDs ?? []).compactMap { rowsByID[$0] }
        case .staged: base = stagedRows
        case .pending: base = rows.filter { pendingUUIDs.contains($0.track.uuid) }
        }
        sortedBase = sortOrder.isEmpty ? base : base.sorted(using: sortOrder)
        refreshFiltered()
    }

    private func refreshFiltered() {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        displayRows = needle.isEmpty ? sortedBase : sortedBase.filter { $0.searchKey.contains(needle) }
    }

    // MARK: - 로드

    /// `--db PATH` 또는 `DJC_DB`가 있으면 그 사본을, 없으면 최신 스냅샷을 연다.
    func loadInitial() async {
        guard !isLoading, rows.isEmpty else { return }
        let args = ProcessInfo.processInfo.arguments
        let override = args.firstIndex(of: "--db").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            ?? ProcessInfo.processInfo.environment["DJC_DB"]
        if let override {
            await load(snapshot: URL(filePath: override))
        } else if let latest = try? LibrarySnapshot.latest() {
            await load(snapshot: latest)
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
        guard !isLoading else { return }
        let hadRows = !rows.isEmpty
        var isLoaded: Bool { if case .loaded = phase { true } else { false } }
        let quiet = quiet && hadRows && isLoaded
        if !quiet { phase = .loading("rekordbox DB 스냅샷을 뜨는 중…") }
        do {
            let url = try await Task.detached { try LibrarySnapshot.take(force: force) }.value
            await load(snapshot: url, quiet: quiet)
        } catch {
            // 이미 라이브러리가 있으면 그대로 두고 오류만 알린다.
            if hadRows {
                phase = .loaded
                lastError = String(describing: error)
            } else {
                phase = .failed(String(describing: error))
            }
        }
    }

    func load(snapshot: URL, quiet: Bool = false) async {
        previewWarmTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let started = ContinuousClock.now
        if !quiet { phase = .loading("라이브러리를 읽는 중…") }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try LoadedLibrary.load(snapshot: snapshot) }.value
            // 더 나중에 시작한 로드가 있으면 이 결과는 버린다.
            guard generation == loadGeneration else { return }
            undoManager?.removeAllActions(withTarget: self)
            rows = loaded.rows
            rowsByID = Dictionary(loaded.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rowsByUUID = Dictionary(loaded.rows.map { ($0.track.uuid, $0) }, uniquingKeysWith: { first, _ in first })
            report = loaded.report
            filterCounts = loaded.filterCounts
            draftFileStamps = nil
            tagDrafts = loaded.tagDrafts
            cueDraftUUIDs = loaded.cueDraftUUIDs
            draftCueCounts = loaded.draftCueCounts
            draftPreviewCues = loaded.draftPreviewCues
            gridDraftUUIDs = loaded.gridDraftUUIDs
            gainDraftUUIDs = GainDraftStore.uuids()
            editedUUIDs = cueDraftUUIDs.union(gridDraftUUIDs).union(gainDraftUUIDs).union(tagDrafts.keys)
            playlistTree = loaded.tree
            var index: [String: PlaylistNode] = [:]
            func walk(_ nodes: [PlaylistNode]) { for node in nodes { index[node.id] = node; walk(node.children ?? []) } }
            walk(loaded.tree)
            playlistIndex = index
            let known = rowsByID
            playlistCounts = index.mapValues { node in node.trackIDs.lazy.filter { known[$0] != nil }.count }
            snapshotURL = snapshot
            previewRevision += 1
            loadStaged()
            // rekordbox에서 지운 곡은 선택에서도 뺀다(덱이 지워진 곡을 붙들지 않게)
            let existing = selection.filter { rowsByID[$0] != nil }
            if existing != selection { selection = existing }
            verifyReflection()
            refreshBase()
            phase = .loaded
            let previewSources = loaded.rows.filter { !$0.track.isStreaming }.map {
                PreviewWaveformStore.Source(uuid: $0.track.uuid, url: RekordboxShare.analysisURL($0.track.analysisDataPath))
            }
            previewWarmTask = Task.detached(priority: .background) { await PreviewWaveformStore.shared.warm(previewSources) }
            lastError = nil
            FileHandle.standardError.write(Data("라이브러리 로드 \(ContinuousClock.now - started) · \(rows.count)곡\n".utf8))
            applyLaunchSelection()
            onPrimaryRowChange?(primaryRow)
            runLaunchStagingTest()
            // 캐시 용량 상한(최근 사용 순)은 뒤에서 조용히 정리한다.
            Task.detached(priority: .background) { CacheMaintenance.prune() }
        } catch {
            guard generation == loadGeneration else { return }
            if quiet {
                lastError = String(describing: error)
            } else {
                phase = .failed(String(describing: error))
            }
        }
    }

    /// 개발용: `--select <ContentID>`
    private func applyLaunchSelection() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--select"), args.indices.contains(i + 1),
              let row = rowsByID[args[i + 1]]
        else { return }
        if case let .filter(filter) = sidebar, !filter.includes(row) { sidebar = .filter(.all) }
        selection = [row.id]
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
