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
    var error: String?
    var canSync: Bool { !isLoading && source.status == .ready && database != nil }
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
        do {
            selection = try ITunesSyncSelectionStore.load(url: store.iTunesSelectionURL) ?? source.initialSelection
        } catch {
            selection = source.initialSelection
            self.error = String(ui: "iTunes 동기화 선택을 읽지 못했습니다. 동기화 창에서 목록을 다시 선택해 저장하세요.")
        }
        isLoading = false
    }

    func sync(store: LibraryStore) -> Bool {
        guard canSync, let database else { return false }
        do {
            try store.syncITunesPlaylists(selection, source: source, database: database)
            return true
        } catch {
            self.error = String(ui: "동기화 선택을 저장하지 못했습니다. 라이브러리와 저장 폴더를 확인한 뒤 다시 시도하세요.")
            return false
        }
    }
}
