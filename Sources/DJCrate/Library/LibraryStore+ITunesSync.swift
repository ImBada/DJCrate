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

    func syncITunesPlaylists(_ selection: ITunesSyncSelection, source: ITunesLibrarySnapshot, database: URL,
                             arguments: [String] = ProcessInfo.processInfo.arguments,
                             environment: [String: String] = ProcessInfo.processInfo.environment) async throws {
        guard !isLoading, !isWritingRekordbox, snapshotURL == database, source.status == .ready else {
            throw DJCError.writeRefused(String(ui: "라이브러리가 바뀌었거나 목록을 읽지 못했습니다. 동기화 창을 다시 여세요."))
        }
        guard let base = source.syncData else {
            throw DJCError.writeRefused(String(ui: "rekordbox 동기화 파일 사본이 없습니다. rekordbox에서 한 번 동기화한 뒤 새로고침하세요."))
        }
        let target = Self.explicitDatabaseRequested(arguments: arguments, environment: environment)
            ? database : LibrarySnapshot.rekordboxDirectory.appending(path: "master.db")
        let change = RekordboxITunesSyncChange(base: base, source: source.selectionNodes, selection: selection)
        let backups = backupDirectory
        isWritingRekordbox = true
        defer { isWritingRekordbox = false }
        let data = try await Task.detached(priority: .userInitiated) {
            _ = try RekordboxWriter.write(drafts: [], iTunesSync: change, to: target, dryRun: false, backups: backups)
            return try Data(contentsOf: target.deletingLastPathComponent().appending(path: "playlists3.sync"))
        }.value
        let selected = try source.applyingRekordboxSelection(data)
        do { try selected.save(for: database) }
        catch {
            reportLibraryError(String(ui: "rekordbox 동기화는 완료했지만 사본을 저장하지 못했습니다. 저장 폴더를 확인한 뒤 새로고침하세요."))
        }
        guard snapshotURL == database else { return }
        iTunesSnapshot = selected
        iTunesLibrary = SyncedITunesLibrary(snapshot: selected, tracks: rows.map(\.track))
        if case let .itunesPlaylist(id) = sidebar, iTunesLibrary.index[id] == nil { sidebar = .filter(.all) }
        refreshBase()
        self.selection.formIntersection(Set(displayRows.map(\.id)))
    }
}
