import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import SwiftUI

/// rekordbox에 바로 쓰기·되돌리기 버튼의 입구. 흐름은 `ReflectionCoordinator`.
@MainActor
enum DirectWritePanels {
    static func write(store: LibraryStore, rows: [TrackRow]) {
        guard !store.isWritingRekordbox, store.writeTask == nil else { return }
        store.writeTask = Task {
            defer { store.writeTask = nil }
            await ReflectionCoordinator(host: store).write(rows: rows)
        }
    }

    /// 추가한 곡을 rekordbox 컬렉션에 바로 넣는다.
    static func addTracks(store: LibraryStore, rows: [TrackRow]) {
        guard !store.isWritingRekordbox, store.writeTask == nil else { return }
        store.writeTask = Task {
            defer { store.writeTask = nil }
            await ReflectionCoordinator(host: store).addTracks(rows: rows)
        }
    }

    /// rekordbox 컬렉션에서 곡을 뺀다(음원 파일은 그대로).
    static func deleteTracks(store: LibraryStore, rows: [TrackRow]) {
        guard !store.isWritingRekordbox, store.writeTask == nil else { return }
        store.writeTask = Task {
            defer { store.writeTask = nil }
            await ReflectionCoordinator(host: store).deleteTracks(rows: rows)
        }
    }

    static func restoreLatest(store: LibraryStore) {
        store.refreshWriteBackups()
        guard let backup = RekordboxWriter.backups(in: store.backupDirectory).first(where: \.isWrite) else {
            _ = AlertPrompter().show(ReflectionPrompt(title: String(ui: "되돌릴 쓰기 기록이 없습니다"),
                                                      text: String(ui: "DJCrate가 rekordbox에 쓴 적이 없거나 백업이 정리됐습니다.")))
            return
        }
        guard !store.isWritingRekordbox, store.writeTask == nil else { return }
        store.writeTask = Task {
            defer { store.writeTask = nil }
            await ReflectionCoordinator(host: store).restore(backup)
        }
    }

    static func restore(store: LibraryStore, backupURL: URL) {
        guard let backup = RekordboxWriter.backups(in: DJCPaths.rekordboxBackups).first(where: { $0.url.path == backupURL.path }) else {
            _ = AlertPrompter().show(ReflectionPrompt(title: String(ui: "백업을 찾지 못했습니다"), text: backupURL.path))
            return
        }
        guard !store.isWritingRekordbox, store.writeTask == nil else { return }
        store.writeTask = Task {
            defer { store.writeTask = nil }
            await ReflectionCoordinator(host: store).restore(backup)
        }
    }
}
