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
    var tree: [SyncedITunesLibrary.Node] {
        SyncedITunesLibrary(snapshot: ITunesLibrarySnapshot(playlists: source.availablePlaylists), tracks: []).tree
    }
    var preview: SyncedITunesLibrary {
        guard let snapshot = try? source.applying(selection) else { return SyncedITunesLibrary() }
        return SyncedITunesLibrary(snapshot: snapshot, tracks: [])
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
