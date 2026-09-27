import DJCDomain
import DJCStorage
import Foundation
import Observation

@MainActor @Observable
final class ITunesSyncModel {
    var source = ITunesLibrarySnapshot(status: .notCaptured)
    var selection = ITunesSyncSelection()
    var database: URL?
    var isLoading = true
    var isSyncing = false
    var error: String?
    @ObservationIgnored private var loadSequence = 0
    var canSync: Bool { !isLoading && !isSyncing && source.status == .ready && source.syncData != nil && database != nil }
    var nodes: [ITunesSyncSelection.Node] { source.selectionNodes }
    var tree: [ITunesSyncOutline.Node] {
        guard let snapshot = try? source.applying(.init(selectedIDs: ["0"])) else { return [] }
        return ITunesSyncOutline(playlists: snapshot.playlists).tree
    }
    var preview: ITunesSyncOutline {
        guard source.status == .ready || source.status == .stale,
              let snapshot = try? source.applying(selection) else { return ITunesSyncOutline() }
        return ITunesSyncOutline(playlists: snapshot.playlists)
    }

    func load(store: LibraryStore, forceRefresh: Bool = false,
              arguments: [String] = ProcessInfo.processInfo.arguments,
              environment: [String: String] = ProcessInfo.processInfo.environment,
              captureITunes: @escaping @Sendable () -> ITunesLibrarySnapshot = {
                  RekordboxITunesReader.capture()
              }) async {
        loadSequence += 1
        let sequence = loadSequence
        let previousSource = source
        let previousSelection = selection
        let hadSource = previousSource.status == .ready || previousSource.status == .stale
        let selectionEdited = hadSource && previousSelection != previousSource.initialSelection
        isLoading = true
        error = nil
        let requestedDatabase = store.snapshotURL
        let requestedRevision = store.previewRevision
        database = requestedDatabase
        let captured = await store.iTunesSyncSource(forceRefresh: forceRefresh, arguments: arguments,
                                                     environment: environment, captureITunes: captureITunes)
        guard sequence == loadSequence else { return }
        guard !Task.isCancelled, store.iTunesSync === self, store.showingITunesSync else {
            isLoading = false
            return
        }
        guard store.snapshotURL == requestedDatabase, store.previewRevision == requestedRevision else {
            database = nil
            isLoading = false
            error = String(ui: "라이브러리가 바뀌었거나 목록을 읽지 못했습니다. 동기화 창을 다시 여세요.")
            return
        }
        if captured.status != .ready, hadSource {
            source = previousSource
            source.status = .stale
            selection = previousSelection
            isLoading = false
            return
        }
        source = captured
        if selectionEdited {
            let available = Set(source.selectionNodes.map(\.id)).union(["0"])
            selection = ITunesSyncSelection(selectedIDs: previousSelection.selectedIDs.intersection(available))
        } else {
            selection = source.initialSelection
        }
        if source.status == .ready, source.syncData == nil {
            error = String(ui: "rekordbox 동기화 파일 사본이 없습니다. rekordbox에서 한 번 동기화한 뒤 새로고침하세요.")
        }
        isLoading = false
    }

    func sync(store: LibraryStore) async -> Bool {
        guard canSync, let database else { return false }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await store.syncITunesPlaylists(selection, source: source, database: database)
            return true
        } catch {
            self.error = DJCError.reason(of: error)
            return false
        }
    }
}

/// 선택 창은 목록 이름과 계층만 쓰므로 곡 경로를 연결하지 않는다.
struct ITunesSyncOutline {
    struct Node: Identifiable {
        let id: String
        let name: String
        let children: [Node]?
        var isFolder: Bool { children != nil }
    }

    var tree: [Node] = []
    var playlistCount = 0

    init() {}

    init(playlists: [ITunesLibrarySnapshot.Playlist]) {
        let byParent = Dictionary(grouping: playlists, by: { $0.parentID ?? "0" })
        func build(_ parent: String) -> [Node] {
            (byParent[parent] ?? []).map { playlist in
                if playlist.isFolder {
                    return Node(id: "itunes:\(playlist.id)", name: playlist.name,
                                children: build(playlist.id))
                }
                playlistCount += 1
                return Node(id: "itunes:\(playlist.id)", name: playlist.name, children: nil)
            }
        }
        tree = build("0")
    }
}
