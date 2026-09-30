import DJCDomain
import RekordboxKit
import SwiftUI

enum LibraryMenuAction: CaseIterable {
    case addFiles, importAppleMusic, snapshot, exportXML, reflect, pending, writeResult, restore, removeTracks

    static let fileActions: [Self] = [.addFiles, .importAppleMusic, .snapshot, .exportXML]
    static let rekordboxActions: [Self] = [.reflect, .pending, .writeResult, .restore, .removeTracks]

    var title: String {
        switch self {
        case .addFiles: String(ui: "곡 추가…")
        case .importAppleMusic: String(ui: "Apple Music XML 가져오기…")
        case .snapshot: String(ui: "rekordbox와 동기화")
        case .exportXML: String(ui: "XML 만들기")
        case .reflect: String(ui: "rekordbox에 쓰기…")
        case .pending: String(ui: "쓰기 대기 목록 보기")
        case .writeResult: String(ui: "마지막 쓰기 결과…")
        case .restore: String(ui: "쓰기 전으로 복원…")
        case .removeTracks: String(ui: "rekordbox에서 빼기…")
        }
    }

    var shortcut: KeyboardShortcut? {
        switch self {
        case .addFiles: KeyboardShortcut("o", modifiers: .command)
        case .snapshot: KeyboardShortcut("r", modifiers: .command)
        case .reflect: KeyboardShortcut("e", modifiers: [.command, .shift])
        default: nil
        }
    }

    @MainActor func isEnabled(in store: LibraryStore) -> Bool {
        guard store.writeLockPolicy.allowsLibraryInteraction else { return false }
        switch self {
        case .addFiles: return !store.rows.isEmpty
        case .importAppleMusic: return !store.isLoading
        case .snapshot: return store.canSynchronizeLibrary
        case .exportXML: return store.sidebar == .staged ? !store.staged.isEmpty : !store.reflectionTargets.isEmpty
        case .reflect: return store.pendingLibraryCount > 0 || store.hasPlaylistDrafts
        case .pending, .writeResult: return true
        case .restore: return store.hasWriteBackup
        case .removeTracks: return !store.isITunesSelection && store.selectedRows.contains { !$0.isStaged && !$0.track.isStreaming }
        }
    }

    @MainActor func perform(in store: LibraryStore) {
        guard isEnabled(in: store) else { return }
        switch self {
        case .addFiles: StagingPanels.chooseFiles(store: store)
        case .importAppleMusic: AppleMusicImportWindow.shared.open(store: store)
        case .snapshot: Task { await store.synchronizeLibrary() }
        case .exportXML:
            if store.sidebar == .staged { StagingPanels.exportXML(store: store) }
            else { ReflectionPanels.export(store: store, rows: store.reflectionTargets) }
        case .reflect: DirectWritePanels.write(store: store, rows: store.reflectionTargets)
        case .pending: store.sidebar = .pending
        case .writeResult: store.showingWriteResult = true
        case .restore: DirectWritePanels.restoreLatest(store: store)
        case .removeTracks:
            DirectWritePanels.deleteTracks(store: store, rows: store.selectedRows.filter { !$0.isStaged && !$0.track.isStreaming })
        }
    }
}
