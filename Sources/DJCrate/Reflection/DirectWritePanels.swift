import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import SwiftUI

/// rekordbox에 바로 쓰기·되돌리기 버튼의 입구. 흐름은 `ReflectionCoordinator`.
@MainActor
enum DirectWritePanels {
    /// - Parameter playlists: 재생 목록 초안도 함께 쓸지(곡을 골라 쓰는 오른쪽 클릭 메뉴는 false)
    static func write(store: LibraryStore, rows: [TrackRow], playlists: Bool = true) {
        guard !store.isWritingRekordbox, store.writeTask == nil else { return }
        store.writeTask = Task {
            defer { store.writeTask = nil }
            await ReflectionCoordinator(host: store).write(rows: rows, playlists: playlists)
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
        guard !store.isITunesSelection, !store.isWritingRekordbox, store.writeTask == nil else { return }
        store.writeTask = Task {
            defer { store.writeTask = nil }
            await ReflectionCoordinator(host: store).deleteTracks(rows: rows)
        }
    }

    static func restoreLatest(store: LibraryStore) {
        store.refreshWriteBackups()
        guard let backup = RekordboxWriter.backups(in: store.backupDirectory).first(where: \.isWrite) else {
            // 메뉴는 백업이 있을 때만 열린다. 그 사이 백업이 정리됐으면 창 대신 토스트로 알린다(#230).
            store.toast = .notice(String(ui: "복원할 쓰기 기록이 없습니다"), String(ui: "DJCrate가 rekordbox에 쓴 적이 없거나 백업이 정리됐습니다."))
            return
        }
        guard !store.isWritingRekordbox, store.writeTask == nil else { return }
        store.writeTask = Task {
            defer { store.writeTask = nil }
            await ReflectionCoordinator(host: store).restore(backup)
        }
    }

    /// 쓰기 결과 토스트의 복원 단추. 누른 것이 확인이라 그 뒤 변경·초안 충돌이 없으면 묻지 않는다(#210).
    static func restore(store: LibraryStore, backupURL: URL) {
        guard let backup = backup(matching: backupURL, in: RekordboxWriter.backups(in: DJCPaths.rekordboxBackups)) else {
            store.toast = .notice(String(ui: "백업을 찾지 못했습니다"), backupURL.path)
            return
        }
        guard !store.isWritingRekordbox, store.writeTask == nil else { return }
        store.writeTask = Task {
            defer { store.writeTask = nil }
            await ReflectionCoordinator(host: store).restore(backup, confirmed: true)
        }
    }

    static func backup(matching url: URL, in backups: [RekordboxWriter.Backup]) -> RekordboxWriter.Backup? {
        guard url.isFileURL else { return nil }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        // /tmp 별칭과 디렉터리 표기를 맞추되, 모호한 후보는 복원하지 않는다.
        let matches = backups.filter { $0.url.isFileURL && $0.url.resolvingSymlinksInPath().standardizedFileURL.path == path }
        return matches.count == 1 ? matches[0] : nil
    }
}
