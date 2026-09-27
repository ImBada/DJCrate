import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

extension LibraryStore {
    func presentITunesSync() {
        iTunesSync = ITunesSyncModel()
        showingITunesSync = true
    }

    /// 사본 실행에서는 Music에 접근하지 않고 함께 캡처한 전체 목록만 쓴다.
    func iTunesSyncSource(arguments: [String] = ProcessInfo.processInfo.arguments,
                          environment: [String: String] = ProcessInfo.processInfo.environment) async -> ITunesLibrarySnapshot {
        if Self.explicitDatabaseRequested(arguments: arguments, environment: environment)
            || LibrarySnapshot.hasRekordboxDirectoryOverride(in: environment) {
            return iTunesSnapshot
        }
        return await Task.detached(priority: .userInitiated) { RekordboxITunesReader.capture() }.value
    }

    func syncITunesPlaylists(_ selection: ITunesSyncSelection, source: ITunesLibrarySnapshot, database: URL) throws {
        guard !isLoading, !isWritingRekordbox, snapshotURL == database, source.status == .ready else {
            throw DJCError.writeRefused(String(ui: "라이브러리가 바뀌었거나 목록을 읽지 못했습니다. 동기화 창을 다시 여세요."))
        }
        let selected = try source.applying(selection)
        // 선택 저장에 실패하면 화면은 그대로 둔다. 전체 원본 사본은 다음에도 다시 선택할 수 있게 남긴다.
        try source.save(for: database)
        try ITunesSyncSelectionStore.save(selection, url: iTunesSelectionURL)
        iTunesSnapshot = source
        iTunesLibrary = SyncedITunesLibrary(snapshot: selected, tracks: rows.map(\.track))
        if case let .itunesPlaylist(id) = sidebar, iTunesLibrary.index[id] == nil { sidebar = .filter(.all) }
        refreshBase()
        self.selection.formIntersection(Set(displayRows.map(\.id)))
    }
}
