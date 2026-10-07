import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 시점 스냅샷 복원(#225). 대상은 쓰기와 같은 `rekordboxDatabase`·`rekordboxShareRoot` 한 곳이다(#182).
/// 초안은 건드리지 않는다: 초안의 `base`가 복원한 rekordbox와 맞지 않는 곡은 쓸 때 걸러진다.
extension LibraryStore {
    @discardableResult
    func restorePointSnapshot(_ entry: RekordboxPointSnapshot.Entry, snapshots: URL,
                              changedTracks: Set<String>) async throws -> RekordboxWriter.PointRestoreReport {
        setWriteLock(true)
        defer { setWriteLock(false) }
        writeStage = WriteStage(String(ui: "시점 스냅샷으로 복원하는 중…"))
        defer { writeStage = nil }
        let database = rekordboxDatabase, share = rekordboxShareRoot, backups = backupDirectory
        let days = Int(settings.value(SettingKeys.pointSnapshotAutoDays))
        let report = try await Task.detached(priority: .userInitiated) {
            try RekordboxWriter.restore(pointSnapshot: entry.url, to: database, shareRoot: share, snapshots: snapshots, backups: backups,
                                        autoDays: days)
        }.value
        // 덱에 올린 곡도 되돌린 큐·그리드를 다시 읽게 한다.
        writtenAwaitingReload.formUnion(changedTracks)
        writeStage = WriteStage(String(ui: "복원한 라이브러리를 읽는 중…"))
        _ = await reloadAfterWrite()
        refreshWriteBackups()
        return report
    }

    func pointRestoreRefusal(_ backup: RekordboxWriter.Backup) -> String? {
        RekordboxWriter.pointRestoreRefusal(after: backup.url, in: backupDirectory)
    }
}
