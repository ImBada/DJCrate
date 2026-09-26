import RekordboxKit
import AnicueAnalysis
import AnicueDomain
import AnicueStorage
import AppKit
import SwiftUI

/// rekordbox에 바로 쓰기·되돌리기 버튼의 입구. 흐름은 `ReflectionCoordinator`.
@MainActor
enum DirectWritePanels {
    static func write(store: LibraryStore, rows: [TrackRow]) {
        Task { await ReflectionCoordinator(host: store).write(rows: rows) }
    }

    static func restoreLatest(store: LibraryStore) {
        guard let backup = RekordboxWriter.backups(in: AnicuePaths.rekordboxBackups).first(where: \.isWrite) else {
            _ = AlertPrompter().show(ReflectionPrompt(title: "되돌릴 쓰기 기록이 없습니다", text: "anicue가 rekordbox에 쓴 적이 없거나 백업이 정리됐습니다."))
            return
        }
        Task { await ReflectionCoordinator(host: store).restore(backup) }
    }

    static func restore(store: LibraryStore, backupURL: URL) {
        guard let backup = RekordboxWriter.backups(in: AnicuePaths.rekordboxBackups).first(where: { $0.url.path == backupURL.path }) else {
            _ = AlertPrompter().show(ReflectionPrompt(title: "백업을 찾지 못했습니다", text: backupURL.path))
            return
        }
        Task { await ReflectionCoordinator(host: store).restore(backup) }
    }
}
