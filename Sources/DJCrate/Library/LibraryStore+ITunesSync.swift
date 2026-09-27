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
    func iTunesSyncSource(forceRefresh: Bool = false,
                          arguments: [String] = ProcessInfo.processInfo.arguments,
                          environment: [String: String] = ProcessInfo.processInfo.environment,
                          captureITunes: @escaping @Sendable () -> ITunesLibrarySnapshot = {
                              RekordboxITunesReader.capture()
                          }) async -> ITunesLibrarySnapshot {
        if Self.explicitDatabaseRequested(arguments: arguments, environment: environment)
            || LibrarySnapshot.hasRekordboxDirectoryOverride(in: environment) {
            return iTunesSnapshot
        }
        guard let snapshot = snapshotURL else { return ITunesLibrarySnapshot(status: .unavailable) }
        let revision = previewRevision
        let epoch = iTunesSyncCatalogEpoch
        let sourceDirectory = LibrarySnapshot.sameDirectory(snapshot.deletingLastPathComponent(),
                                                             LibrarySnapshot.defaultDirectory(in: environment))
            ? LibrarySnapshot.rekordboxDirectory(in: environment) : snapshot.deletingLastPathComponent()

        if !forceRefresh {
            if let cached = iTunesSyncCatalogCache, cached.snapshot == snapshot, cached.revision == revision,
               cached.epoch == epoch,
               cached.sourceDirectory == sourceDirectory,
               Self.isCurrentITunesCatalog(cached.contents, directory: sourceDirectory) {
                return cached.contents
            }
            if Self.isCurrentITunesCatalog(iTunesSnapshot, directory: sourceDirectory) {
                return iTunesSnapshot
            }
        }

        // 초기 로드가 같은 DB의 Music 전체 목록을 이미 읽는 중이면 그 결과를 함께 쓴다.
        if let initial = currentInitialITunesRefresh(snapshot: snapshot, revision: revision) {
            await initial.value
            guard snapshotURL == snapshot, previewRevision == revision else {
                return ITunesLibrarySnapshot(status: .unavailable)
            }
            return iTunesSnapshot
        }

        // 쓸 수 있는 캐시가 없을 때만 진행 중인 Music 읽기를 함께 기다린다.
        if let pending = iTunesSyncCapture, pending.snapshot == snapshot, pending.revision == revision,
           pending.epoch == epoch, pending.sourceDirectory == sourceDirectory {
            let captured = await pending.task.value
            return currentITunesCatalogIfSuperseded(snapshot: snapshot, revision: revision,
                                                     epoch: epoch, directory: sourceDirectory) ?? captured
        }

        let id = UUID()
        let task = Task(priority: .userInitiated) {
            (try? await Self.runBlockingLibraryWork(captureITunes)) ?? ITunesLibrarySnapshot(status: .unavailable)
        }
        iTunesSyncCapture = .init(id: id, snapshot: snapshot, revision: revision, epoch: epoch,
                                  sourceDirectory: sourceDirectory, task: task)
        let captured = await task.value
        if iTunesSyncCapture?.id == id { iTunesSyncCapture = nil }
        if let current = currentITunesCatalogIfSuperseded(snapshot: snapshot, revision: revision,
                                                          epoch: epoch, directory: sourceDirectory) {
            return current
        }
        if snapshotURL == snapshot, previewRevision == revision, iTunesSyncCatalogEpoch == epoch,
           Self.isCurrentITunesCatalog(captured, directory: sourceDirectory) {
            iTunesSyncCatalogCache = .init(snapshot: snapshot, revision: revision, epoch: epoch,
                                            sourceDirectory: sourceDirectory, contents: captured)
        }
        return captured
    }

    private func currentITunesCatalogIfSuperseded(snapshot: URL, revision: Int, epoch: UInt64,
                                                   directory: URL) -> ITunesLibrarySnapshot? {
        guard snapshotURL != snapshot || previewRevision != revision || iTunesSyncCatalogEpoch != epoch else { return nil }
        guard snapshotURL == snapshot, previewRevision == revision,
              Self.isCurrentITunesCatalog(iTunesSnapshot, directory: directory) else {
            return ITunesLibrarySnapshot(status: .unavailable)
        }
        return iTunesSnapshot
    }

    private static func isCurrentITunesCatalog(_ value: ITunesLibrarySnapshot, directory: URL) -> Bool {
        value.status == .ready && value.sourcePlaylists != nil
            && !RekordboxITunesReader.selectionChanged(since: value.syncData, directory: directory)
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
            ? database : LibrarySnapshot.rekordboxDirectory(in: environment).appending(path: "master.db")
        let change = RekordboxITunesSyncChange(base: base, source: source.selectionNodes, selection: selection)
        let backups = backupDirectory
        invalidatePendingLoads()
        isWritingRekordbox = true
        defer { invalidatePendingLoads(); isWritingRekordbox = false }
        let data = try await Task.detached(priority: .userInitiated) {
            _ = try RekordboxWriter.write(drafts: [], iTunesSync: change, to: target, dryRun: false, backups: backups)
            return try Data(contentsOf: target.deletingLastPathComponent().appending(path: "playlists3.sync"))
        }.value
        let selected = try source.applyingRekordboxSelection(data)
        let active = snapshotURL
        let sameSource = !Self.explicitDatabaseRequested(arguments: arguments, environment: environment)
            && active.map { LibrarySnapshot.sameDirectory($0.deletingLastPathComponent(),
                                                           LibrarySnapshot.defaultDirectory(in: environment)) } == true
        let sourceDirectory = LibrarySnapshot.rekordboxDirectory(in: environment)
        let mayCacheDatabase = LibrarySnapshot.hasRekordboxDirectoryOverride(in: environment)
            || !LibrarySnapshot.sameDirectory(database.deletingLastPathComponent(), sourceDirectory)
        let destinations = Set((mayCacheDatabase ? [database] : []) + (sameSource ? [active].compactMap { $0 } : []))
        let invalidatedSources = Set(Array(destinations) + [target, database])
        var saveFailed = false
        ITunesRefreshCoordinator.shared.publish(sources: Array(invalidatedSources)) {
            for destination in destinations {
                do { try selected.save(for: destination) }
                catch { saveFailed = true }
            }
        }
        if saveFailed {
            reportLibraryError(String(ui: "rekordbox 동기화는 완료했지만 사본을 저장하지 못했습니다. 저장 폴더를 확인한 뒤 새로고침하세요."))
        }
        guard snapshotURL == database || sameSource else { return }
        iTunesSnapshot = selected
        iTunesLibrary = SyncedITunesLibrary(snapshot: selected, tracks: rows.map(\.track))
        if case let .itunesPlaylist(id) = sidebar, iTunesLibrary.index[id] == nil { sidebar = .filter(.all) }
        refreshBase()
        self.selection.formIntersection(Set(displayRows.map(\.id)))
    }
}
