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

    func load(store: LibraryStore) async {
        isLoading = true
        error = nil
        database = store.snapshotURL
        let captured = await store.iTunesSyncSource()
        guard !Task.isCancelled else { return }
        source = captured
        selection = source.initialSelection
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
