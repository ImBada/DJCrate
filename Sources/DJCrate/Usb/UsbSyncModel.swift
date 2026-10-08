import DJCDomain
import DJCStorage
import Foundation
import Observation
import RekordboxKit

enum UsbSyncTargetDisplay: CaseIterable, Hashable {
    case currentUsb, afterSync

    var title: String {
        switch self {
        case .currentUsb: String(ui: "현재 USB")
        case .afterSync: String(ui: "동기화 후")
        }
    }
}

/// USB 원본이 바뀐 때는 rekordbox 선택을 다시 채택하고, 같은 원본에서 편집 중인 선택만 이어 쓴다.
struct UsbSyncPreferenceChoice {
    var selection: ITunesSyncSelection
    var enabled: Bool
    var usesSavedPreferences: Bool

    static func resolve(preferences: UsbSyncPreferences?, localDBID: Int64, hasNativeFiles: Bool,
                        fingerprint: String?, nativeSelection: ITunesSyncSelection, nativeEnabled: Bool?,
                        fallbackSelection: ITunesSyncSelection, currentEnabled: Bool = true) -> Self {
        let sameLibrary = preferences?.localDBID == localDBID
        let sameNative = fingerprint != nil && preferences?.nativeSelectionFingerprint == fingerprint
        if sameLibrary, let preferences, !hasNativeFiles || sameNative {
            // 동기화하지 않은 체크는 닫을 때 버리므로(rekordbox와 같다, 2026-10-08 실험 G2a) 선택 파일이 있으면 그 선택과
            // 켜짐이 정본이다. 저장한 설정은 USB 목록 연결(bindings)을 잇는 데만 쓴다.
            guard hasNativeFiles else {
                return Self(selection: preferences.selection, enabled: preferences.syncPlaylists, usesSavedPreferences: true)
            }
            return Self(selection: nativeSelection, enabled: nativeEnabled ?? preferences.syncPlaylists, usesSavedPreferences: true)
        }
        if hasNativeFiles {
            return Self(selection: nativeSelection,
                        enabled: nativeEnabled ?? (sameLibrary ? preferences?.syncPlaylists : nil) ?? currentEnabled,
                        usesSavedPreferences: false)
        }
        // rekordbox는 선택 파일이 없는 USB를 "장치와 플레이리스트 동기화" 꺼짐으로 연다(2026-10-08 빈 USB 실험).
        return Self(selection: fallbackSelection, enabled: false, usesSavedPreferences: false)
    }
}

/// 확인 취소 뒤에도 초안은 디스크에 남으므로 계획의 모든 입력이 같을 때만 이어 쓴다.
struct UsbSyncPlanInputs: Sendable, Equatable {
    var database: URL
    var share: URL
    var catalogRevision: Int
    var source: UsbSyncSource
    var volume: UsbVolumeInfo
    var library: UsbLibrary
    var usbBase: UsbFingerprint
    var localDBID: Int64
    var matches: [Int: String]
    var badges: [Int: UsbSyncStatus]
    var bindings: [String: UsbSyncPlaylistBinding]
    var selection: ITunesSyncSelection
    var syncPlaylists: Bool
    var nativeBaseFiles: [UsbFormat: Data]
    var nativeFingerprint: String?
    var nativePlaylistIDs: [String: Int]
    var nativeCanWrite: Bool
    var nativeIssues: [String]
    var readEpoch: Int = 0
    var snapshotProvenance: UsbSyncSnapshotProvenance? = nil
    var nativeRemovedPlaylistIDs: Set<Int> = []
}

struct UsbSyncQueuedPlan: Sendable {
    var edits: [UsbLibraryEdit]
    var inputs: UsbSyncPlanInputs

    func canReuse(edits: [UsbLibraryEdit], inputs: UsbSyncPlanInputs) -> Bool {
        self.edits == edits && self.inputs == inputs
    }
}

@MainActor @Observable final class UsbSyncModel {
    let volumeKey: String
    var selection = ITunesSyncSelection() { didSet { selectionChanged() } }
    var syncPlaylists = true {
        didSet {
            if !syncPlaylists { targetDisplay = .currentUsb }
            selectionChanged()
        }
    }
    var targetDisplay = UsbSyncTargetDisplay.currentUsb
    private(set) var isLoading = true
    private(set) var isSyncing = false
    private(set) var isImporting = false
    private(set) var error: String?
    private(set) var message: String?
    private var source = PlaylistLayout()
    private var loadedSources: UsbSyncSource?
    private var loadedVolume: UsbVolumeInfo?
    private var usbBase: UsbFingerprint?
    private var rekordboxSource = PlaylistLayout()
    private var iTunesSource = PlaylistLayout()
    private var sourceBlockReasons: [String: String] = [:]
    private var library: UsbLibrary?
    private var localDBID: Int64?
    private var matches: [Int: String] = [:]
    private var badges: [Int: UsbSyncStatus] = [:]
    private var bindings: [String: UsbSyncPlaylistBinding] = [:]
    private var database: URL?
    private var catalogRevision: Int?
    private var readEpoch: Int?
    private var snapshotProvenance: UsbSyncSnapshotProvenance?
    @ObservationIgnored private var snapshotLease: UsbSyncSnapshotLease?
    private var emptyVolume = false
    private var nativeSelectionFingerprint: String?
    private var nativeBaseFiles: [UsbFormat: Data] = [:]
    private var nativePlaylistIDs: [String: Int] = [:]
    /// 로컬에서 지운 원본의 선택 파일 행이 가리키던 USB 목록. SYNC 때 지운다(rekordbox와 같다).
    private var nativeRemovedPlaylistIDs: Set<Int> = []
    private var nativeSelectionCanWrite = true
    /// USB 선택 파일의 AutomaticSync(두 형식이 같을 때만). 닫을 때 바뀌었으면 이 칸만 쓴다.
    private var nativeEnabled: Bool?
    /// masterPlaylists6.xml의 NODE. 선택 파일의 Timestamp를 옮긴다.
    private var masterNodes: [MasterPlaylistsXML.Node] = []
    /// 닫으며 쓰지 못한 뒤 다시 닫으면 그대로 닫는다(초안은 쓰기 대기에 남는다).
    private var closeDeclined = false
    /// 지금 USB에 있는 선택(선택 파일, 없으면 창을 열 때의 선택). 닫을 때 이 선택과 다르면 동기화할지 묻는다.
    private(set) var usbSelection = ITunesSyncSelection()
    private(set) var nativeSelectionIssues: [String] = []
    @ObservationIgnored private weak var usb: UsbStore?
    @ObservationIgnored private var saveChain: Task<Bool, Never>?
    @ObservationIgnored private var queuedPlan: UsbSyncQueuedPlan?

    init(volumeKey: String, library: UsbLibrary? = nil) {
        self.volumeKey = volumeKey
        self.library = library
    }

    var tree: [PlaylistOutlineNode] { PlaylistOutlineNode.tree(source, blocked: sourceBlockReasons) }
    var rekordboxTree: [PlaylistOutlineNode] { PlaylistOutlineNode.tree(rekordboxSource) }
    var iTunesTree: [PlaylistOutlineNode] { PlaylistOutlineNode.tree(iTunesSource, blocked: sourceBlockReasons) }
    var nodes: [ITunesSyncSelection.Node] { UsbSyncPlan.nodes(source) }
    private var selected: PlaylistLayout { UsbSyncPlan.selectedLayout(source, selection: selection) }
    /// 동기화 뒤 USB 목록 트리(쓰기 계획과 같은 규칙). 라이브러리가 없거나 계획할 수 없으면 nil
    var afterSyncPlan: UsbSyncPlaylistPlan? {
        guard let library else { return nil }
        var counter = 0
        return try? UsbSyncPlan.playlistPlan(desired: selected, library: library, bindings: bindings,
                                             linkedPlaylistIDs: nativePlaylistIDs, removedPlaylistIDs: nativeRemovedPlaylistIDs,
                                             newKey: { counter += 1; return "preview-\(counter)" })
    }
    var previewTree: [PlaylistOutlineNode] {
        afterSyncPlan.map { PlaylistOutlineNode.tree($0.result) } ?? PlaylistOutlineNode.tree(selected)
    }
    /// 흐리게 보일 USB 목록: 현재 USB는 선택에 잇지 않은 목록, 동기화 후는 연결 없이 남는 목록
    var dimmedTargetIDs: Set<String> {
        switch targetDisplay {
        case .currentUsb: unlinkedUsbIDs
        case .afterSync: Set((afterSyncPlan?.marks ?? [:]).filter { $0.value == .unlinked }.keys)
        }
    }
    /// 동기화 후 미리 보기의 칸 표시(새로 만듦·옮김·연결 없음). 현재 USB 보기에서는 비어 있다
    var targetMarks: [String: UsbSyncPreviewMark] {
        targetDisplay == .afterSync ? afterSyncPlan?.marks ?? [:] : [:]
    }
    /// 동기화하면 지울 USB 목록(폴더면 안에 든 것까지)
    var deletedTargetSummary: String? {
        guard targetDisplay == .afterSync, syncPlaylists, let deleted = afterSyncPlan?.deleted, !deleted.isEmpty else { return nil }
        let names = deleted.map(\.name).joined(separator: ", ")
        return String(ui: "동기화하면 USB에서 지울 목록 \(deleted.count)개: \(names)")
    }
    private var usbLayout: PlaylistLayout { library.map(UsbSyncPlan.usbLayout) ?? PlaylistLayout() }
    var usbTree: [PlaylistOutlineNode] { PlaylistOutlineNode.tree(usbLayout) }
    /// 선택한 원본에 이어지지 않아 동기화가 건드리지 않는 USB 목록(rekordbox처럼 흐리게 보인다)
    var unlinkedUsbIDs: Set<String> {
        guard syncPlaylists else { return [] }
        let linked = Set(selected.outline.compactMap { item in nativePlaylistIDs[item.id] ?? bindings[item.id]?.usbID }.map(String.init))
        return Set(usbLayout.outline.map(\.id)).subtracting(linked)
    }
    var playlistCount: Int { selected.outline.filter(\.holdsTracks).count }
    var usbPlaylistCount: Int { usbLayout.outline.filter { !$0.isFolder }.count }
    var targetTree: [PlaylistOutlineNode] { targetDisplay == .currentUsb ? usbTree : previewTree }
    var targetPlaylistCount: Int { targetDisplay == .currentUsb ? usbPlaylistCount : playlistCount }
    var targetEmptyMessage: String {
        switch targetDisplay {
        case .currentUsb:
            library != nil || emptyVolume
                ? String(ui: "USB에 재생 목록이 없습니다")
                : String(ui: "USB 재생 목록을 아직 읽지 못했습니다. 새로고침하세요")
        case .afterSync:
            String(ui: "동기화할 목록을 선택하세요")
        }
    }
    var trackCount: Int { Set(selected.outline.filter(\.holdsTracks).flatMap(\.trackIDs)).count }
    /// rekordbox처럼 "장치와 플레이리스트 동기화"가 꺼져 있으면 SYNC를 누를 수 없다.
    var canSync: Bool {
        !isLoading && !isSyncing && !isImporting && database != nil && localDBID != nil && syncPlaylists
            && nativeSelectionCanWrite && nativeSelectionIssues.isEmpty
            && (library != nil || (emptyVolume && syncPlaylists && playlistCount > 0 && trackCount > 0))
    }
    var canImport: Bool { !isLoading && !isSyncing && !isImporting && library != nil && database != nil && !matches.isEmpty }

    /// rekordbox는 "장치와 플레이리스트 동기화"가 꺼져 있으면 체크를 바꿀 수 없게 막았다(2026-10-08 실험 G5b).
    var canEditSelection: Bool { syncPlaylists }

    func selectAll() { guard canEditSelection else { return }; selection = ITunesSyncSelection(selectedIDs: ["0"]) }
    func clearSelection() { guard canEditSelection else { return }; selection = ITunesSyncSelection() }
    func selectAllRekordbox() { setSelected(true, id: UsbSyncSource.rekordboxSelectionID) }
    func clearRekordboxSelection() { setSelected(false, id: UsbSyncSource.rekordboxSelectionID) }
    func selectAllITunes() { setSelected(true, id: UsbSyncSource.iTunesSelectionID) }
    func clearITunesSelection() { setSelected(false, id: UsbSyncSource.iTunesSelectionID) }
    func toggle(_ id: String) { setSelected(selection.state(of: id, in: nodes) != .on, id: id) }
    private func setSelected(_ selected: Bool, id: String) {
        guard canEditSelection else { return }
        selection.setSelected(selected, id: id, in: nodes)
    }

    func load(store: LibraryStore, usb: UsbStore) async {
        guard !isSyncing, !isImporting else { return }
        self.usb = usb
        // 새로 읽은 상태를 옛 디스크 초안의 계획 입력으로 삼지 않는다. 초안 자체는 대기 목록에 보존한다.
        queuedPlan = nil
        loadedSources = nil
        loadedVolume = nil
        usbBase = nil
        source = PlaylistLayout()
        rekordboxSource = PlaylistLayout()
        iTunesSource = PlaylistLayout()
        sourceBlockReasons = [:]
        matches = [:]
        badges = [:]
        bindings = [:]
        isLoading = true
        database = nil
        localDBID = nil
        catalogRevision = nil
        readEpoch = nil
        snapshotProvenance = nil
        snapshotLease = nil
        error = nil
        message = nil
        nativeSelectionIssues = []
        nativeSelectionFingerprint = nil
        nativeBaseFiles = [:]
        nativePlaylistIDs = [:]
        nativeRemovedPlaylistIDs = []
        nativeSelectionCanWrite = true
        nativeEnabled = nil
        masterNodes = []
        closeDeclined = false
        usbSelection = ITunesSyncSelection()
        // USB 내용은 로컬 목록과 설정을 읽기 전에도 보여 준다.
        self.library = usb.libraries[volumeKey]
        emptyVolume = usb.shapes[volumeKey] == .emptyExportable
        guard let snapshot = store.snapshotURL, let volume = usb.volume(volumeKey) else {
            error = String(ui: "로컬 라이브러리와 USB를 다시 읽은 뒤 동기화 창을 여세요")
            isLoading = false
            return
        }
        let sources = currentSources(store)
        let source = sources.layout
        self.source = source
        rekordboxSource = sources.rekordbox
        iTunesSource = sources.iTunes
        sourceBlockReasons = sources.notices
        let revision = store.previewRevision
        let epoch = store.snapshotReadEpoch
        guard let lease = await store.leaseUsbSyncSnapshot(), store.snapshotReadEpoch == epoch,
              store.snapshotURL == snapshot, store.previewRevision == revision, currentSources(store) == sources,
              usb.volume(volumeKey) == volume else {
            error = String(ui: "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요")
            isLoading = false
            return
        }
        let library = usb.libraries[volumeKey]
        let directory = usb.syncSelectionDirectory
        let key = volumeKey
        let formats = library?.formats ?? UsbFormat.defaultSet
        let service = usb.writeService
        let wasEmpty = emptyVolume
        // 라이브 폴더의 파일이지만 읽기만 한다. 못 읽으면 체크한 목록을 쓸 때 막힌다.
        let masterURL = store.rekordboxDatabase.deletingLastPathComponent().appending(path: "masterPlaylists6.xml")
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(LocalLibraryKeys, Result<UsbSyncPreferences?, any Error>, UsbSyncSelectionBundle, UsbFingerprint, [MasterPlaylistsXML.Node]), any Error> in
            Result {
                let local = try LocalLibraryKeys.load(snapshot: lease.database)
                let current = try UsbRead.currentVolume(matching: volume)
                let native = try UsbSyncSelectionBundle.read(root: UsbRoot(URL(filePath: current.mountPoint)), formats: formats)
                let prefs = Result { try directory.map { try UsbSyncPreferencesStore(directory: $0).load(volumeKey: key) } ?? nil }
                let master = (try? MasterPlaylistsXML(contentsOf: masterURL))?.nodes ?? []
                return (local, prefs, native, try service.draftBase(current), master)
            }
        }.value
        defer { isLoading = false }
        guard !Task.isCancelled, store.snapshotReadEpoch == epoch, store.snapshotForUsbSync == lease.provenance,
              store.snapshotURL == snapshot, store.previewRevision == revision, usb.volume(key) == volume,
              currentSources(store) == sources, usb.libraries[key] == library,
              (usb.shapes[key] == .emptyExportable) == wasEmpty else {
            error = String(ui: "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요")
            return
        }
        switch result {
        case .failure:
            // 원본 선택 파일에는 개인 식별값이 있으므로 파서 오류의 원문을 로그에 싣지 않는다.
            error = String(ui: "USB 동기화 선택이나 로컬 라이브러리를 읽지 못했습니다. USB와 라이브러리를 새로고침한 뒤 다시 시도하세요")
        case let .success((local, preferences, native, base, master)):
            self.library = library
            masterNodes = master
            loadedSources = sources
            loadedVolume = volume
            usbBase = base
            database = snapshot
            catalogRevision = revision
            readEpoch = epoch
            snapshotProvenance = lease.provenance
            snapshotLease = lease
            localDBID = local.localDBID
            emptyVolume = usb.shapes[key] == .emptyExportable
            nativeSelectionFingerprint = native.semanticFingerprint
            nativeBaseFiles = native.baseFiles
            let resolved = native.resolution(sourceNodes: sources.nativeNodes, localDBID: local.localDBID,
                                             usbPlaylistIDs: library.map(UsbSyncSelectionBundle.playlistIDs(of:)),
                                             representatives: library.map(UsbSyncSelectionBundle.representatives(of:)),
                                             masterNodeIDs: Self.masterNodeIDs(master))
            nativePlaylistIDs = resolved.playlistIDs
            nativeRemovedPlaylistIDs = resolved.removedSourcePlaylistIDs
            nativeEnabled = native.files.isEmpty ? nil : resolved.enabled
            nativeSelectionCanWrite = resolved.canWrite
            nativeSelectionIssues = resolved.issues.map(\.message)
            let prefs: UsbSyncPreferences?
            switch preferences {
            case let .success(saved): prefs = saved
            case .failure:
                prefs = nil
                error = String(ui: "USB 동기화 설정을 읽지 못했습니다. 데이터 폴더의 usb-sync-selections 파일을 확인한 뒤 다시 시도하세요")
            }
            let choice = UsbSyncPreferenceChoice.resolve(preferences: prefs, localDBID: local.localDBID,
                                                        hasNativeFiles: !native.files.isEmpty, fingerprint: native.semanticFingerprint,
                                                        nativeSelection: resolved.selection, nativeEnabled: resolved.enabled,
                                                        fallbackSelection: library.map { UsbSyncPlan.initialSelection(source: source, library: $0) } ?? ITunesSyncSelection(),
                                                        currentEnabled: syncPlaylists)
            selection = choice.selection
            usbSelection = choice.selection
            syncPlaylists = choice.enabled
            bindings = choice.usesSavedPreferences ? prefs?.bindings ?? [:] : [:]
            // 원본 ID를 USB 현재 폴더에 직접 잇는다. 이름 변경도 같은 목록으로 따라간다.
            for (sourceID, usbID) in nativePlaylistIDs {
                guard let item = source.item(sourceID), let usbItem = usbLayout.item(String(usbID)),
                      item.isFolder == usbItem.isFolder else { continue }
                bindings[sourceID] = UsbSyncPlaylistBinding(usbID: usbID, path: UsbSyncPlan.path(usbItem, in: usbLayout),
                                                           isFolder: item.isFolder)
            }
            let availableIDs = Set(nodes.map(\.id)).union(["0"])
            if !selection.selectedIDs.isSubset(of: availableIDs) {
                nativeSelectionIssues.append(String(ui: "USB에서 선택했던 원본 목록을 찾지 못했습니다. iTunes와 rekordbox 목록을 다시 읽거나 rekordbox에서 USB 동기화 선택을 확인하세요"))
            }
            if let library {
                let evaluated = UsbSyncBadges.evaluate(library: library, local: local)
                matches = evaluated.matches
                badges = evaluated.badges
            } else {
                matches = [:]
                badges = [:]
            }
        }
    }

    private func currentSources(_ store: LibraryStore) -> UsbSyncSource {
        UsbSyncSource.make(rekordbox: store.rekordboxPlaylists, iTunes: store.iTunesLibrary)
    }

    private func sourcesAreCurrent(_ store: LibraryStore) -> Bool {
        loadedSources == currentSources(store) && readEpoch == store.snapshotReadEpoch
            && snapshotProvenance != nil && snapshotProvenance == store.snapshotForUsbSync
    }

    private func planInputs(store: LibraryStore, volume: UsbVolumeInfo) -> UsbSyncPlanInputs? {
        guard let database, let catalogRevision, let readEpoch, let loadedSources, let library, let usbBase, let localDBID else { return nil }
        return UsbSyncPlanInputs(database: database, share: store.rekordboxShareRoot ?? RekordboxShare.directory,
                                 catalogRevision: catalogRevision, source: loadedSources, volume: volume,
                                 library: library, usbBase: usbBase, localDBID: localDBID, matches: matches, badges: badges,
                                 bindings: bindings, selection: selection, syncPlaylists: syncPlaylists,
                                 nativeBaseFiles: nativeBaseFiles, nativeFingerprint: nativeSelectionFingerprint,
                                 nativePlaylistIDs: nativePlaylistIDs, nativeCanWrite: nativeSelectionCanWrite,
                                 nativeIssues: nativeSelectionIssues, readEpoch: readEpoch, snapshotProvenance: snapshotProvenance,
                                 nativeRemovedPlaylistIDs: nativeRemovedPlaylistIDs)
    }

    private func inputsAreCurrent(_ inputs: UsbSyncPlanInputs, store: LibraryStore, usb: UsbStore) -> Bool {
        database == store.snapshotURL && catalogRevision == store.previewRevision && sourcesAreCurrent(store)
            && usb.volume(volumeKey) == inputs.volume && library == usb.libraries[volumeKey]
            && emptyVolume == (usb.shapes[volumeKey] == .emptyExportable)
            && planInputs(store: store, volume: inputs.volume) == inputs
            && !store.isLoading && !store.isWritingRekordbox && !usb.ejecting.contains(volumeKey)
            && queuedPlan?.canReuse(edits: usb.draftEdits[volumeKey] ?? [], inputs: inputs) == true
    }

    func refresh(store: LibraryStore, usb: UsbStore) async {
        guard !isLoading, !isSyncing, !isImporting, usb.activeWrite == nil else { return }
        isLoading = true
        queuedPlan = nil
        snapshotLease = nil
        defer { isLoading = false }
        if localDBID != nil, !(await savePreferences(usb: usb)) { return }
        await usb.refresh()
        await load(store: store, usb: usb)
    }

    private func selectionChanged() {
        guard !isLoading else { return }
        queuedPlan = nil
        snapshotLease = nil
        message = nil
        if let usb { Task { await savePreferences(usb: usb) } }
    }

    /// 연속으로 고른 선택도 누른 차례로 저장해 이전 선택이 나중에 남지 않게 한다.
    @discardableResult
    func savePreferences(usb: UsbStore) async -> Bool {
        guard let localDBID else { return false }
        guard let directory = usb.syncSelectionDirectory else { return true }
        let prefs = UsbSyncPreferences(volumeKey: volumeKey, localDBID: localDBID, selection: selection,
                                       syncPlaylists: syncPlaylists, bindings: bindings,
                                       nativeSelectionFingerprint: nativeSelectionFingerprint)
        let previous = saveChain
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            let result = await Task.detached(priority: .utility) { Result { try UsbSyncPreferencesStore(directory: directory).save(prefs) } }.value
            if case let .failure(failure) = result {
                AppErrorMessage.log(failure)
                self?.error = String(ui: "USB 동기화 설정을 저장하지 못했습니다. 데이터 폴더의 usb-sync-selections 파일을 확인한 뒤 다시 시도하세요")
                return false
            }
            return true
        }
        saveChain = task
        return await task.value
    }

    func sync(store: LibraryStore, usb: UsbStore) async -> Bool {
        defer { snapshotLease = nil }
        guard canSync, !store.isLoading, !store.isWritingRekordbox, store.writeLockPolicy.allowsLibraryInteraction,
              usb.activeWrite == nil, !usb.ejecting.contains(volumeKey), let volume = usb.volume(volumeKey) else { return false }
        error = nil
        message = nil
        guard database == store.snapshotURL, catalogRevision == store.previewRevision,
              sourcesAreCurrent(store), library == usb.libraries[volumeKey], loadedVolume == volume,
              emptyVolume == (usb.shapes[volumeKey] == .emptyExportable) else {
            error = String(ui: "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요")
            return false
        }
        if let reason = loadedSources?.blockReason(selection: selection) {
            error = reason
            return false
        }
        isSyncing = true
        // 실행 중에는 아래 지역 소유자가 유지하고, 저장한 native 초안은 UsbStore가 창을 닫은 뒤에도 이어 소유한다.
        defer { isSyncing = false }
        let running = await Task.detached(priority: .utility) { LibrarySnapshot.isRekordboxRunning() }.value
        guard !running else {
            error = String(ui: "rekordbox와 rekordboxAgent를 종료한 뒤 USB와 동기화하세요")
            return false
        }
        guard await nativeFilesAreCurrent(usb: usb, volume: volume) else { return false }
        if let block = UsbSyncSelectionStage.gateBlock(baseFiles: nativeBaseFiles, formats: library?.formats ?? UsbFormat.defaultSet) {
            error = block.message
            return false
        }
        if UsbSyncSource.lacksMasterNode(UsbSyncSource.nativeNodes(source, master: masterNodes), selection: selection) {
            error = String(ui: "masterPlaylists6.xml에서 동기화할 목록을 찾지 못했습니다. rekordbox를 한 번 켰다가 종료하고 새 스냅샷을 읽은 뒤 동기화하세요")
            return false
        }
        guard await savePreferences(usb: usb), usb.volume(volumeKey) == volume else { return false }
        guard database == store.snapshotURL, catalogRevision == store.previewRevision,
              sourcesAreCurrent(store),
              library == usb.libraries[volumeKey], loadedVolume == volume,
              emptyVolume == (usb.shapes[volumeKey] == .emptyExportable),
              !store.isLoading, !store.isWritingRekordbox else {
            error = String(ui: "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요")
            return false
        }
        if let reason = loadedSources?.blockReason(selection: selection) {
            error = reason
            return false
        }
        if snapshotLease == nil { snapshotLease = await store.leaseUsbSyncSnapshot() }
        guard let lease = snapshotLease, sourcesAreCurrent(store), usb.volume(volumeKey) == volume,
              lease.provenance == snapshotProvenance, let readEpoch else {
            error = String(ui: "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요")
            return false
        }
        // rekordbox처럼 USB에 넣을 수 없는 곡(잇지 못한 iTunes 곡·스트리밍 곡 등)은 빼고 동기화하고, 넣지 못한 곡으로 알린다
        let localSkips = skippedLocalTracks(store: store)
        let skippedTracks = skippedTrackBlocks(localSkips: localSkips)
        if emptyVolume {
            guard syncPlaylists, let coordinator = store.usbCoordinator,
                  let localDBID, let loadedSources, let catalogRevision else { return false }
            let topIDs = selected.childIDs(of: PlaylistLayout.root)
            let job = UsbExportJob(database: lease.database, share: store.rekordboxShareRoot ?? RekordboxShare.directory,
                                   volume: volume, selection: .playlists(topIDs), formats: UsbFormat.defaultSet, snapshotTime: lease.provenance.snapshotTime,
                                   playlistLayout: UsbSyncPlan.removing(Set(localSkips.keys), from: selected),
                                   syncSelection: UsbSyncSelectionDraft(localDBID: localDBID, sourceNodes: UsbSyncSource.nativeNodes(source, master: masterNodes),
                                                                        selection: selection, enabled: syncPlaylists,
                                                                        playlistRefs: [:], baseFiles: nativeBaseFiles,
                                                                        skippedTracks: skippedTracks),
                                   syncSourceContext: UsbExportSyncSourceContext(source: loadedSources, catalogRevision: catalogRevision,
                                                                                 readEpoch: readEpoch, snapshot: lease.reference),
                                   snapshotLease: lease)
            guard await coordinator.export(job) else {
                message = store.toast?.detail
                return false
            }
            if let written = usb.libraries[volumeKey] {
                bindings = UsbSyncPlan.bindings(source: source, target: selected, library: written)
                usbSelection = selection
                guard await adoptWrittenNativeFiles(usb: usb) else { return false }
                _ = await savePreferences(usb: usb)
                return true
            }
            message = store.toast?.detail
            return false
        }
        guard let localDBID, let actions = store.usbEdits, let coordinator = store.usbCoordinator,
              let inputs = planInputs(store: store, volume: volume) else { return false }
        let draft = usb.draftEdits[volumeKey] ?? []
        if !draft.isEmpty {
            guard queuedPlan?.canReuse(edits: draft, inputs: inputs) == true else {
                error = String(ui: "이 USB에 쓰기 대기 중인 초안이 있습니다. 쓰기 대기 목록에서 쓰거나 버린 뒤 동기화하세요")
                return false
            }
        } else {
            do {
                var edits: [UsbLibraryEdit] = []
                var refs = nativePlaylistIDs.mapValues { PlaylistRef.id(String($0)) }
                for (sourceID, binding) in bindings where refs[sourceID] == nil {
                    refs[sourceID] = .id(String(binding.usbID))
                }
                if syncPlaylists {
                    let plan = try UsbSyncPlan.build(source: inputs.source, selection: selection, library: inputs.library, matches: matches,
                                                     badges: badges, bindings: bindings, linkedPlaylistIDs: inputs.nativePlaylistIDs,
                                                     removedPlaylistIDs: inputs.nativeRemovedPlaylistIDs, excluding: Set(localSkips.keys))
                    edits = plan.edits
                    refs.merge(plan.playlistRefs) { _, planned in planned }
                    // rekordbox처럼 어느 목록에도 남지 않는 USB 곡은 확인을 받고 뺀다. 음원 파일은 곡 빼기 규칙을 따른다.
                    if !plan.orphanTrackIDs.isEmpty {
                        guard actions.prompter.show(Self.orphanPrompt(count: plan.orphanTrackIDs.count)) else {
                            message = String(ui: "동기화를 취소했습니다. USB는 그대로입니다.")
                            return false
                        }
                        edits.append(.removeTracks(usbContentIDs: plan.orphanTrackIDs))
                    }
                }
                // 목록 내용이 같아도 선택·상위 부분 체크와 동기화 켜짐은 USB 파일에 따로 써야 한다.
                edits.append(.syncSelection(draft: UsbSyncSelectionDraft(localDBID: localDBID,
                                                                         sourceNodes: UsbSyncSource.nativeNodes(source, master: masterNodes),
                                                                         selection: selection, enabled: syncPlaylists,
                                                                         playlistRefs: refs, baseFiles: nativeBaseFiles,
                                                                         skippedTracks: syncPlaylists ? skippedTracks : [])))
                if let reason = actions.blockReason(edits, volumeKey: volumeKey) {
                    error = reason
                    return false
                }
                guard await actions.append(edits, to: volumeKey, detail: String(ui: "재생 목록 동기화")) else {
                    error = String(ui: "USB 동기화 초안을 저장하지 못했습니다. 데이터 폴더를 확인한 뒤 다시 시도하세요")
                    return false
                }
                queuedPlan = UsbSyncQueuedPlan(edits: edits, inputs: inputs)
            } catch let failure as PlaylistLayout.Blocked {
                error = failure.reason
                return false
            } catch {
                AppErrorMessage.log(error)
                self.error = String(ui: "USB 동기화를 준비하지 못했습니다. 목록을 새로고침한 뒤 다시 시도하세요")
                return false
            }
        }
        guard inputsAreCurrent(inputs, store: store, usb: usb) else {
            queuedPlan = nil
            error = String(ui: "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요")
            return false
        }
        guard await nativeFilesAreCurrent(usb: usb, volume: volume) else { queuedPlan = nil; return false }
        guard inputsAreCurrent(inputs, store: store, usb: usb) else {
            queuedPlan = nil
            error = String(ui: "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요")
            return false
        }
        // 계획 뒤 곡 상태가 바뀌었으면(빼는 곡이 달라짐) 계획한 초안을 쓰지 않는다
        guard skippedLocalTracks(store: store) == localSkips else {
            queuedPlan = nil
            error = String(ui: "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요")
            return false
        }
        let job = UsbEditJob(database: lease.database, share: inputs.share, volume: inputs.volume,
                             snapshotTime: lease.provenance.snapshotTime,
                             syncSourceContext: .init(source: inputs.source, catalogRevision: inputs.catalogRevision,
                                                      readEpoch: inputs.readEpoch, snapshot: lease.reference))
        guard await coordinator.writeSyncDraft(job, edits: usb.draftEdits[volumeKey] ?? []) else {
            message = store.toast?.detail
            return false
        }
        guard (usb.draftEdits[volumeKey] ?? []).isEmpty, let written = usb.libraries[volumeKey] else {
            message = String(ui: "동기화 초안은 USB 쓰기 대기에 남았습니다. 쓰기 대기 목록에서 결과와 막힌 이유를 확인하세요")
            return false
        }
        queuedPlan = nil
        bindings = UsbSyncPlan.bindings(source: source, target: selected, library: written)
        usbSelection = selection
        guard await adoptWrittenNativeFiles(usb: usb) else { return false }
        _ = await savePreferences(usb: usb)
        return true
    }

    /// 선택한 목록 중 USB에 넣을 수 없는 로컬 곡(스트리밍·추가 대기·찾지 못한 곡). 동기화는 이 곡만 빼고 쓴다
    func skippedLocalTracks(store: LibraryStore) -> [String: UsbBlock] {
        guard syncPlaylists else { return [:] }
        return UsbSyncSource.skippedLocalTracks(selected) { id in
            guard let row = store.rowsByID[id] else { return .missing }
            if row.isStaged { return .staged }
            if row.isUsb { return .usb }
            return row.track.isStreaming ? .streaming : nil
        }
    }

    /// 동기화 계획이 USB에 넣지 않고 건너뛸 곡(잇지 못한 iTunes 곡 + 넣을 수 없는 로컬 곡, 목록 순서대로)
    private func skippedTrackBlocks(localSkips: [String: UsbBlock]) -> [UsbBlock] {
        guard syncPlaylists else { return [] }
        var seen = Set<String>()
        let local = selected.outline.filter(\.holdsTracks).flatMap(\.trackIDs).compactMap { id in
            seen.insert(id).inserted ? localSkips[id] : nil
        }
        return (loadedSources?.skippedITunesTracks(selection: selection) ?? []) + local
    }

    /// SYNC 전에 보이는 알림: USB에 넣지 못할 곡 수(이유별). 음원·분석 파일 문제는 쓰기 확인 창에서 더 알린다
    func skippedSummary(store: LibraryStore) -> String? {
        let blocks = skippedTrackBlocks(localSkips: skippedLocalTracks(store: store))
        guard !blocks.isEmpty else { return nil }
        return Self.skippedSummary(blocks)
    }

    /// "USB에 넣지 못할 곡 N개" + 이유별 수(처음 나온 순서). 같은 곡은 한 번 센다
    nonisolated static func skippedSummary(_ blocks: [UsbBlock]) -> String {
        var order: [String] = [], targets: [String: Set<UsbBlock.Scope>] = [:]
        for block in blocks {
            if targets[block.message] == nil { order.append(block.message) }
            targets[block.message, default: []].insert(block.scope)
        }
        let count = Set(blocks.map(\.scope)).count
        return ([String(ui: "USB에 넣지 못할 곡 \(count)개:")] + order.map { "• \($0) (\(targets[$0]?.count ?? 0))" })
            .joined(separator: "\n")
    }

    /// masterPlaylists6.xml의 rekordbox NODE Id. 못 읽었으면 nil(지운 원본을 판정하지 않고 막는다)
    nonisolated static func masterNodeIDs(_ nodes: [MasterPlaylistsXML.Node]) -> Set<String>? {
        let ids = nodes.filter { $0.libType == 0 }.map(\.id)
        return ids.isEmpty ? nil : Set(ids)
    }

    /// rekordbox의 내보내기 확인 창과 같은 문구(OK/취소). 취소하면 동기화 전체를 하지 않는다.
    static func orphanPrompt(count: Int) -> ReflectionPrompt {
        ReflectionPrompt(title: String(ui: "플레이리스트에 더 이상 존재하지 않는 트랙은 삭제될 것입니다."),
                         text: String(ui: "USB의 어느 재생 목록에도 남지 않는 곡 \(count)개를 USB에서 뺍니다. 음원 파일은 다른 곡이 쓰지 않을 때만 지웁니다."),
                         confirm: String(ui: "확인"), destructive: true)
    }

    /// 닫을 때 USB에 쓸 것이 있는지: "장치와 플레이리스트 동기화"를 USB 파일과 다르게 바꿨을 때만.
    /// 선택 파일이 없는 USB는 꺼짐으로 본다. rekordbox처럼 켜면 행 없는 선택 파일을 만들고, 꺼진 채면 쓰지 않는다.
    /// 라이브러리가 없는 빈 USB는 켜짐만 쓰지 않는다(rekordbox는 이때 빈 DB도 만들지만 DJCrate는 SYNC 때 함께 만든다).
    var enabledChanged: Bool {
        Self.enabledChanged(hasNativeFiles: !nativeBaseFiles.isEmpty, nativeEnabled: nativeEnabled,
                            hasLibrary: localDBID != nil && library != nil && !emptyVolume, syncPlaylists: syncPlaylists)
    }

    nonisolated static func enabledChanged(hasNativeFiles: Bool, nativeEnabled: Bool?, hasLibrary: Bool, syncPlaylists: Bool) -> Bool {
        guard hasNativeFiles else { return hasLibrary && syncPlaylists }
        return nativeEnabled != nil && nativeEnabled != syncPlaylists
    }

    /// USB의 선택과 다르게 체크했는지. 폴더 자체 체크와 하위를 모두 체크한 것은 선택 파일에서 다르다(폴더 행 1과 2).
    var selectionDiffersFromUsb: Bool { Self.selectionDiffers(selection, from: usbSelection, nodes: nodes) }

    nonisolated static func selectionDiffers(_ selection: ITunesSyncSelection, from usb: ITunesSyncSelection,
                                             nodes: [ITunesSyncSelection.Node]) -> Bool {
        selection.selectedIDs.contains("0") != usb.selectedIDs.contains("0")
            || selection.expandedIDs(in: nodes) != usb.expandedIDs(in: nodes)
    }

    /// rekordbox는 동기화가 켜진 채 동기화하지 않은 변경(체크 변경, 켜기)이 있으면 닫을 때 지금 동기화할지 물었다
    /// (2026-10-08 실험 G2a·G3·G5c). 끄고 닫을 때는 묻지 않았다(G5a). SYNC를 누를 수 없는 상태면 묻지 않는다.
    nonisolated static func asksToSyncOnClose(syncPlaylists: Bool, canSync: Bool, selectionDiffers: Bool,
                                              enabledChanged: Bool) -> Bool {
        syncPlaylists && canSync && (selectionDiffers || enabledChanged)
    }

    /// rekordbox의 닫기 확인과 같은 문구(예/아니오)
    nonisolated static var unsyncedClosePrompt: ReflectionPrompt {
        ReflectionPrompt(title: String(ui: "변경 사항이 동기화되지 않았습니다."),
                         text: String(ui: "변경한 내용을 지금 바로 동기화합니까?"),
                         confirm: String(ui: "예"), cancel: String(ui: "아니오"))
    }

    /// 동기화하지 않고 닫을 때 바꾼 체크를 버린다. rekordbox도 "아니오"로 닫으면 체크 변경을 버렸다(2026-10-08 실험 G2a).
    func discardUnsyncedSelection() {
        guard selection != usbSelection else { return }
        selection = usbSelection
    }

    /// rekordbox처럼 동기화가 켜진 채 바뀐 것이 있으면 지금 동기화할지 묻고, "예"면 SYNC와 같은 흐름으로 쓴다.
    /// "아니오"나 꺼진 채 닫으면 바꾼 체크는 버리고, 동기화 켜짐을 바꿨으면 두 선택 파일의 AutomaticSync만 쓴다
    /// (다른 칸·선택은 그대로, G5c에서 켜고 "아니오"로 닫아도 이 칸만 바뀌었다). 다른 USB 쓰기와 같은 미리 보기·확인 창을 거친다.
    /// 닫아도 되면 true.
    func close(store: LibraryStore, usb: UsbStore) async -> Bool {
        guard !isLoading, !isSyncing, !isImporting else { return true }
        if !closeDeclined, Self.asksToSyncOnClose(syncPlaylists: syncPlaylists, canSync: canSync,
                                                  selectionDiffers: selectionDiffersFromUsb, enabledChanged: enabledChanged) {
            let prompter = store.usbEdits?.prompter ?? AlertPrompter()
            if prompter.show(Self.unsyncedClosePrompt) {
                if await sync(store: store, usb: usb) { return true }
                // 동기화하지 못했으면 이유를 보이고 창을 남긴다. 한 번 더 닫으면 묻지 않고 닫는다.
                closeDeclined = true
                let hint = String(ui: "한 번 더 닫으면 USB에 쓰지 않고 닫습니다.")
                if let error { self.error = error + "\n" + hint } else { message = (message.map { $0 + "\n" } ?? "") + hint }
                return false
            }
        }
        discardUnsyncedSelection()
        if localDBID != nil { _ = await savePreferences(usb: usb) }
        guard enabledChanged, !closeDeclined else { return true }
        error = nil
        message = nil
        func decline(_ reason: String) -> Bool {
            closeDeclined = true
            error = reason + "\n" + String(ui: "한 번 더 닫으면 USB에 쓰지 않고 닫습니다.")
            return false
        }
        guard let volume = usb.volume(volumeKey), usb.activeWrite == nil, !usb.ejecting.contains(volumeKey),
              !store.isLoading, !store.isWritingRekordbox, store.writeLockPolicy.allowsLibraryInteraction,
              let localDBID, let actions = store.usbEdits, let coordinator = store.usbCoordinator,
              database == store.snapshotURL, catalogRevision == store.previewRevision, sourcesAreCurrent(store),
              library == usb.libraries[volumeKey], loadedVolume == volume else {
            return decline(String(ui: "라이브러리가 바뀌어 USB 동기화 켜짐을 저장하지 못했습니다. 새로고침한 뒤 다시 바꾸세요"))
        }
        if let block = UsbSyncSelectionStage.gateBlock(baseFiles: nativeBaseFiles, formats: library?.formats ?? UsbFormat.defaultSet) {
            return decline(block.message)
        }
        guard (usb.draftEdits[volumeKey] ?? []).isEmpty else {
            return decline(String(ui: "이 USB에 쓰기 대기 중인 초안이 있어 동기화 켜짐을 저장하지 못했습니다. 쓰기 대기 목록에서 쓰거나 버린 뒤 다시 바꾸세요"))
        }
        isSyncing = true
        defer { isSyncing = false; snapshotLease = nil }
        let running = await Task.detached(priority: .utility) { LibrarySnapshot.isRekordboxRunning() }.value
        guard !running else { return decline(String(ui: "rekordbox와 rekordboxAgent를 종료한 뒤 USB와 동기화하세요")) }
        guard await nativeFilesAreCurrent(usb: usb, volume: volume) else { closeDeclined = true; return false }
        guard await savePreferences(usb: usb) else { closeDeclined = true; return false }
        if snapshotLease == nil { snapshotLease = await store.leaseUsbSyncSnapshot() }
        guard let lease = snapshotLease, lease.provenance == snapshotProvenance, sourcesAreCurrent(store),
              usb.volume(volumeKey) == volume, let inputs = planInputs(store: store, volume: volume) else {
            return decline(String(ui: "라이브러리가 바뀌어 USB 동기화 켜짐을 저장하지 못했습니다. 새로고침한 뒤 다시 바꾸세요"))
        }
        let edits: [UsbLibraryEdit] = [.syncSelection(draft: .enabledOnly(localDBID: localDBID, enabled: syncPlaylists,
                                                                          baseFiles: nativeBaseFiles))]
        if let reason = actions.blockReason(edits, volumeKey: volumeKey) { return decline(reason) }
        guard await actions.append(edits, to: volumeKey, detail: String(ui: "USB 동기화 켜짐 저장")) else {
            return decline(String(ui: "USB 동기화 초안을 저장하지 못했습니다. 데이터 폴더를 확인한 뒤 다시 시도하세요"))
        }
        queuedPlan = UsbSyncQueuedPlan(edits: edits, inputs: inputs)
        guard inputsAreCurrent(inputs, store: store, usb: usb) else {
            queuedPlan = nil
            return decline(String(ui: "라이브러리가 바뀌어 USB 동기화 켜짐을 저장하지 못했습니다. 새로고침한 뒤 다시 바꾸세요"))
        }
        let job = UsbEditJob(database: lease.database, share: inputs.share, volume: inputs.volume,
                             snapshotTime: lease.provenance.snapshotTime,
                             syncSourceContext: .init(source: inputs.source, catalogRevision: inputs.catalogRevision,
                                                      readEpoch: inputs.readEpoch, snapshot: lease.reference))
        guard await coordinator.writeSyncDraft(job, edits: usb.draftEdits[volumeKey] ?? []),
              (usb.draftEdits[volumeKey] ?? []).isEmpty else {
            closeDeclined = true
            message = String(ui: "동기화 켜짐 초안은 USB 쓰기 대기에 남았습니다. 쓰기 대기 목록에서 결과와 막힌 이유를 확인하세요")
            return false
        }
        queuedPlan = nil
        _ = await adoptWrittenNativeFiles(usb: usb)
        _ = await savePreferences(usb: usb)
        return true
    }

    /// 다른 앱이 선택 파일을 바꾼 뒤에는 화면에 없던 선택을 덮지 않고 다시 읽도록 한다.
    private func nativeFilesAreCurrent(usb: UsbStore, volume: UsbVolumeInfo) async -> Bool {
        let formats = library?.formats ?? UsbFormat.defaultSet
        let service = usb.writeService
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                let current = try UsbRead.currentVolume(matching: volume)
                let native = try UsbSyncSelectionBundle.read(root: UsbRoot(URL(filePath: current.mountPoint)), formats: formats)
                return (native, try service.draftBase(current))
            }
        }.value
        guard usb.volume(volumeKey) == volume else {
            error = String(ui: "USB가 바뀌었습니다. USB를 다시 읽은 뒤 동기화하세요")
            return false
        }
        switch result {
        case let .success((native, base)) where native.baseFiles == nativeBaseFiles
            && native.semanticFingerprint == nativeSelectionFingerprint && usbBase?.sameContent(as: base) == true:
            return true
        case let .success((native, _)) where native.baseFiles == nativeBaseFiles:
            error = String(ui: "USB가 바뀌었습니다. USB를 다시 읽은 뒤 동기화하세요")
        case .success:
            error = String(ui: "USB 동기화 선택이 다른 앱에서 바뀌었습니다. 새로고침해 바뀐 선택을 확인한 뒤 동기화하세요")
        case .failure:
            error = String(ui: "USB 동기화 선택 파일을 다시 읽지 못했습니다. USB를 새로고침한 뒤 동기화하세요")
        }
        return false
    }

    /// 성공한 쓰기의 새 원본에 지문을 맞춰 두면 다음 창에서도 편집 중 선택과 원본을 혼동하지 않는다.
    private func adoptWrittenNativeFiles(usb: UsbStore) async -> Bool {
        guard let volume = usb.volume(volumeKey), let localDBID else { return false }
        let formats = usb.libraries[volumeKey]?.formats ?? UsbFormat.defaultSet
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                let current = try UsbRead.currentVolume(matching: volume)
                return try UsbSyncSelectionBundle.read(root: UsbRoot(URL(filePath: current.mountPoint)), formats: formats)
            }
        }.value
        guard usb.volume(volumeKey) == volume else { return false }
        switch result {
        case let .success(native):
            nativeBaseFiles = native.baseFiles
            nativeSelectionFingerprint = native.semanticFingerprint
            let resolved = native.resolution(sourceNodes: UsbSyncSource.nativeNodes(source), localDBID: localDBID,
                                             usbPlaylistIDs: usb.libraries[volumeKey].map(UsbSyncSelectionBundle.playlistIDs(of:)),
                                             representatives: usb.libraries[volumeKey].map(UsbSyncSelectionBundle.representatives(of:)),
                                             masterNodeIDs: Self.masterNodeIDs(masterNodes))
            nativePlaylistIDs = resolved.playlistIDs
            nativeRemovedPlaylistIDs = resolved.removedSourcePlaylistIDs
            nativeEnabled = native.files.isEmpty ? nil : resolved.enabled
            nativeSelectionCanWrite = resolved.canWrite
            nativeSelectionIssues = resolved.issues.map(\.message)
            return resolved.canWrite
        case .failure:
            error = String(ui: "쓴 USB 동기화 선택 파일을 읽지 못했습니다. USB를 새로고침해 결과를 확인하세요")
            return false
        }
    }

    /// rekordbox의 "← CUE GRID INFO" 확인(2026-10-08 실험 G5b)을 DJCrate에 맞게 고친 문구. rekordbox는 바로 바꾸지만
    /// DJCrate는 초안만 만든다. rekordbox 창은 곡 정보(색상·레이팅·코멘트)도 적지만 실제로는 바꾸지 않아(실험 X1) 적지 않는다.
    nonisolated static var cueGridImportPrompt: ReflectionPrompt {
        ReflectionPrompt(title: String(ui: "USB에 있는 모든 곡의 다음 정보로 로컬 곡 정보를 바꾸는 초안을 만듭니다."),
                         text: String(ui: "- 큐 포인트와 루프 포인트\n- 핫 큐\n- 비트 그리드\n\nrekordbox의 곡이 더 최근에 바뀌었어도 USB 값으로 바꿉니다. 레이팅·색상·코멘트는 rekordbox처럼 가져오지 않습니다. 초안이 이미 있는 곡은 건너뜁니다. 가져온 초안을 확인한 뒤 rekordbox에 쓰기…로 반영하세요.\n\n계속하시겠습니까?"),
                         confirm: String(ui: "가져오기"))
    }

    func importCueGrid(store: LibraryStore, usb: UsbStore) async {
        guard canImport, usb.activeWrite == nil, !store.isLoading, !store.isWritingRekordbox else { return }
        let prompter = store.usbEdits?.prompter ?? AlertPrompter()
        guard prompter.show(Self.cueGridImportPrompt) else { return }
        error = nil
        isImporting = true
        defer { isImporting = false }
        let result = await store.importUsbCueGrid(volumeKey: volumeKey)
        let remaining = result.details.dropFirst()
        message = result.message + (remaining.isEmpty ? "" : "\n" + remaining.joined(separator: "\n"))
    }
}
