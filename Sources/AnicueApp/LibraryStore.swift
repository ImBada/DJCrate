import AnicueCore
import Foundation
import Observation

/// 사이드바에서 고르는 대상: 라이브러리 필터 또는 rekordbox 플레이리스트·폴더.
enum SidebarItem: Hashable, Sendable {
    case filter(LibraryFilter)
    case playlist(String)
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

    var phase: Phase = .idle
    private(set) var rows: [TrackRow] = []
    private(set) var report: LibraryReport?
    private(set) var snapshotURL: URL?
    /// 표에 보이는 줄. 필터·검색·정렬이 바뀔 때만 다시 계산한다(그릴 때마다 계산하지 않는다).
    private(set) var displayRows: [TrackRow] = []
    private(set) var filterCounts: [LibraryFilter: Int] = [:]
    private(set) var playlistCounts: [String: Int] = [:]
    var isLoading: Bool { if case .loading = phase { true } else { false } }

    var sidebar: SidebarItem = .filter(.backlog) {
        didSet {
            guard sidebar != oldValue else { return }
            // 플레이리스트는 rekordbox 순서가 기본, 필터는 임포트 최신순이 기본.
            suppressRefresh = true
            switch sidebar {
            case .playlist: sortOrder = []
            case .filter: if case .playlist = oldValue { sortOrder = [KeyPathComparator(\TrackRow.importedOn, order: .reverse)] }
            }
            suppressRefresh = false
            refreshBase()
        }
    }
    private(set) var playlistTree: [PlaylistNode] = []
    private var playlistIndex: [String: PlaylistNode] = [:]

    var sidebarTitle: String {
        switch sidebar {
        case let .filter(filter): filter.rawValue
        case let .playlist(id): playlistIndex[id]?.name ?? "플레이리스트"
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
    private(set) var tagDrafts: [String: TagDraft] = [:]
    private var cueDraftUUIDs: Set<String> = []
    private var gridDraftUUIDs: Set<String> = []
    private(set) var editedUUIDs: Set<String> = []

    private var rowsByID: [TrackRow.ID: TrackRow] = [:]
    private var rowsByUUID: [String: TrackRow] = [:]
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

    private func refreshBase() {
        let base: [TrackRow]
        switch sidebar {
        case let .filter(filter): base = rows.filter(filter.includes)
        case let .playlist(id): base = (playlistIndex[id]?.trackIDs ?? []).compactMap { rowsByID[$0] }
        }
        sortedBase = sortOrder.isEmpty ? base : base.sorted(using: sortOrder)
        refreshFiltered()
    }

    private func refreshFiltered() {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        displayRows = needle.isEmpty ? sortedBase : sortedBase.filter { $0.searchKey.contains(needle) }
    }

    // MARK: - 로드

    /// `--db PATH` 또는 `ANICUE_DB`가 있으면 그 사본을, 없으면 최신 스냅샷을 연다.
    func loadInitial() async {
        guard !isLoading, rows.isEmpty else { return }
        let args = ProcessInfo.processInfo.arguments
        let override = args.firstIndex(of: "--db").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            ?? ProcessInfo.processInfo.environment["ANICUE_DB"]
        if let override {
            await load(snapshot: URL(filePath: override))
        } else if let latest = try? LibrarySnapshot.latest() {
            await load(snapshot: latest)
        } else {
            phase = .idle
        }
    }

    func takeSnapshot(force: Bool = false) async {
        guard !isLoading else { return }
        let hadRows = !rows.isEmpty
        phase = .loading("rekordbox DB 스냅샷을 뜨는 중…")
        do {
            let url = try await Task.detached { try LibrarySnapshot.take(force: force) }.value
            await load(snapshot: url)
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

    func load(snapshot: URL) async {
        loadGeneration += 1
        let generation = loadGeneration
        let started = ContinuousClock.now
        phase = .loading("라이브러리를 읽는 중…")
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try LoadedLibrary.load(snapshot: snapshot) }.value
            // 더 나중에 시작한 로드가 있으면 이 결과는 버린다.
            guard generation == loadGeneration else { return }
            rows = loaded.rows
            rowsByID = Dictionary(loaded.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rowsByUUID = Dictionary(loaded.rows.map { ($0.track.uuid, $0) }, uniquingKeysWith: { first, _ in first })
            report = loaded.report
            filterCounts = loaded.filterCounts
            tagDrafts = loaded.tagDrafts
            cueDraftUUIDs = loaded.cueDraftUUIDs
            gridDraftUUIDs = loaded.gridDraftUUIDs
            editedUUIDs = cueDraftUUIDs.union(gridDraftUUIDs).union(tagDrafts.keys)
            playlistTree = loaded.tree
            var index: [String: PlaylistNode] = [:]
            func walk(_ nodes: [PlaylistNode]) { for node in nodes { index[node.id] = node; walk(node.children ?? []) } }
            walk(loaded.tree)
            playlistIndex = index
            let known = rowsByID
            playlistCounts = index.mapValues { node in node.trackIDs.lazy.filter { known[$0] != nil }.count }
            snapshotURL = snapshot
            refreshBase()
            phase = .loaded
            lastError = nil
            FileHandle.standardError.write(Data("라이브러리 로드 \(ContinuousClock.now - started) · \(rows.count)곡\n".utf8))
            applyLaunchSelection()
            onPrimaryRowChange?(primaryRow)
            // 캐시 용량 상한(최근 사용 순)은 뒤에서 조용히 정리한다.
            Task.detached(priority: .background) { CacheMaintenance.prune() }
        } catch {
            guard generation == loadGeneration else { return }
            phase = .failed(String(describing: error))
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

    func draftChanged(trackUUID: String, kind: DeckModel.DraftKind, exists: Bool) {
        switch kind {
        case .cue: if exists { cueDraftUUIDs.insert(trackUUID) } else { cueDraftUUIDs.remove(trackUUID) }
        case .grid: if exists { gridDraftUUIDs.insert(trackUUID) } else { gridDraftUUIDs.remove(trackUUID) }
        }
        updateEdited(trackUUID)
    }

    private func updateEdited(_ uuid: String) {
        let edited = cueDraftUUIDs.contains(uuid) || gridDraftUUIDs.contains(uuid) || tagDrafts[uuid] != nil
        // 바뀔 때만 건드려서 표의 ✎ 칸이 불필요하게 다시 그려지지 않게 한다.
        if edited, !editedUUIDs.contains(uuid) { editedUUIDs.insert(uuid) }
        if !edited, editedUUIDs.contains(uuid) { editedUUIDs.remove(uuid) }
    }

    // MARK: - 태그 편집 (초안만 바뀐다)

    func tagDraft(for row: TrackRow) -> TagDraft {
        tagDrafts[row.track.uuid] ?? TagDraft(track: row.track)
    }

    /// 선택한 곡들의 값. 모두 같으면 그 값, 다르면 `mixed`.
    func tagValue(_ key: TagFields.Key, rows: [TrackRow]) -> (value: String, mixed: Bool) {
        guard let first = rows.first else { return ("", false) }
        let value = tagCell(first, key)
        for row in rows.dropFirst() where tagCell(row, key) != value { return ("", true) }
        return (value, false)
    }

    func setTag(_ key: TagFields.Key, _ value: String, rows: [TrackRow]) {
        applyTagEdits(rows.map { (row: $0, key: key, value: value) })
    }

    func revertTags(rows: [TrackRow]) {
        applyTagEdits(rows.flatMap { row in
            TagFields.Key.allCases.map { (row: row, key: $0, value: tagDraft(for: row).base[$0]) }
        })
    }

    // MARK: - 태그 시트(엑셀식) 일괄 편집 + 되돌리기

    struct TagEdit: Sendable {
        let trackUUID: String
        let key: TagFields.Key
        let old: String
        let new: String
    }

    /// 편집이 반영될 때마다 올라간다. 시트가 보이는 줄을 다시 그리는 신호로 쓴다.
    private(set) var tagRevision = 0
    private var undoStack: [[TagEdit]] = []
    private var redoStack: [[TagEdit]] = []
    var canUndoTags: Bool { !undoStack.isEmpty }
    var canRedoTags: Bool { !redoStack.isEmpty }

    func tagCell(_ row: TrackRow, _ key: TagFields.Key) -> String {
        if let draft = tagDrafts[row.track.uuid] { return draft.fields[key] }
        return TagFields(track: row.track)[key]
    }

    func isTagEdited(_ row: TrackRow, _ key: TagFields.Key) -> Bool {
        guard let draft = tagDrafts[row.track.uuid] else { return false }
        return draft.base[key] != draft.fields[key]
    }

    /// 여러 셀을 한 번에 바꾼다. 되돌리기 한 단위가 된다.
    func applyTagEdits(_ changes: [(row: TrackRow, key: TagFields.Key, value: String)]) {
        var edits: [TagEdit] = []
        for change in changes {
            let old = tagCell(change.row, change.key)
            guard old != change.value else { continue }
            edits.append(TagEdit(trackUUID: change.row.track.uuid, key: change.key, old: old, new: change.value))
        }
        guard !edits.isEmpty else { return }
        apply(edits, forward: true)
        undoStack.append(edits)
        redoStack.removeAll()
    }

    func undoTags() {
        guard let edits = undoStack.popLast() else { return }
        apply(edits, forward: false)
        redoStack.append(edits)
    }

    func redoTags() {
        guard let edits = redoStack.popLast() else { return }
        apply(edits, forward: true)
        undoStack.append(edits)
    }

    /// 곡별로 묶어 초안을 한 번만 고치고, 곡마다 한 번만 백그라운드에서 저장한다.
    private func apply(_ edits: [TagEdit], forward: Bool) {
        var touched: [String: TagDraft] = [:]
        for edit in edits {
            guard let row = rowsByUUID[edit.trackUUID] else { continue }
            var draft = touched[edit.trackUUID] ?? tagDraft(for: row)
            draft.fields[edit.key] = forward ? edit.new : edit.old
            touched[edit.trackUUID] = draft
        }
        var updated = tagDrafts
        for (uuid, draft) in touched { updated[uuid] = draft.hasChanges ? draft : nil }
        tagDrafts = updated
        for uuid in touched.keys { updateEdited(uuid) }
        DraftWriter.save(Array(touched.values))
        tagRevision += 1
    }
}

/// 백그라운드에서 만드는 로드 결과.
private struct LoadedLibrary: Sendable {
    var rows: [TrackRow]
    var report: LibraryReport
    var filterCounts: [LibraryFilter: Int]
    var tagDrafts: [String: TagDraft]
    var cueDraftUUIDs: Set<String>
    var gridDraftUUIDs: Set<String>
    var tree: [PlaylistNode]

    static func load(snapshot: URL) throws -> LoadedLibrary {
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        let rows = library.tracks.map {
            TrackRow(track: $0, cues: library.cues(for: $0), playCount: library.playCounts[$0.id, default: 0])
        }
        var counts: [LibraryFilter: Int] = [:]
        for filter in LibraryFilter.allCases { counts[filter] = rows.lazy.filter(filter.includes).count }
        var tagDrafts: [String: TagDraft] = [:]
        for uuid in TagDraftStore.uuids() { tagDrafts[uuid] = TagDraftStore.load(trackUUID: uuid) }
        return LoadedLibrary(rows: rows, report: LibraryReport(library: library), filterCounts: counts,
                             tagDrafts: tagDrafts, cueDraftUUIDs: CueDraftStore.uuids(),
                             gridDraftUUIDs: GridDraftStore.uuids(), tree: PlaylistNode.tree(library.playlists))
    }
}
