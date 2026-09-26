import RekordboxKit
import SwiftUI

enum LibraryMenuAction: CaseIterable {
    case addFiles, snapshot, exportXML, reflect, pending, writeResult, restore, removeTracks

    static let fileActions: [Self] = [.addFiles, .snapshot, .exportXML]
    static let rekordboxActions: [Self] = [.reflect, .pending, .writeResult, .restore, .removeTracks]

    var title: String {
        switch self {
        case .addFiles: "곡 추가…"
        case .snapshot: "새 스냅샷"
        case .exportXML: "rekordbox XML로 내보내기…"
        case .reflect: "반영…"
        case .pending: "반영 대기 목록 보기"
        case .writeResult: "마지막 쓰기 결과…"
        case .restore: "마지막 반영 되돌리기…"
        case .removeTracks: "rekordbox에서 빼기…"
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
        case .snapshot: return !store.isLoading
        case .exportXML: return store.sidebar == .staged ? !store.staged.isEmpty : !store.reflectionTargets.isEmpty
        case .reflect: return store.pendingLibraryCount > 0
        case .pending, .writeResult: return true
        case .restore: return store.lastWriteBackup != nil
        case .removeTracks: return store.selectedRows.contains { !$0.isStaged && !$0.track.isStreaming }
        }
    }

    @MainActor func perform(in store: LibraryStore) {
        guard isEnabled(in: store) else { return }
        switch self {
        case .addFiles: StagingPanels.chooseFiles(store: store)
        case .snapshot: Task { await store.takeSnapshot(force: LibrarySnapshot.isRekordboxRunning()) }
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
