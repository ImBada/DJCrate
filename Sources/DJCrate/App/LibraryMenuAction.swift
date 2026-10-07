import DJCDomain
import RekordboxKit
import SwiftUI

enum LibraryMenuAction: CaseIterable {
    case addFiles, importAppleMusic, snapshot, exportXML, exportLibraryXML, reflect, pending, writeResult, restore, removeTracks

    static let fileActions: [Self] = [.addFiles, .importAppleMusic, .snapshot, .exportXML, .exportLibraryXML]
    static let rekordboxActions: [Self] = [.reflect, .pending, .writeResult, .restore, .removeTracks]

    var title: String {
        switch self {
        case .addFiles: String(ui: "곡 추가…")
        case .importAppleMusic: String(ui: "Apple Music XML 가져오기…")
        case .snapshot: String(ui: "rekordbox와 동기화")
        case .exportXML: String(ui: "XML 만들기")
        // 연동 파일을 만드는 "XML 만들기"와 달리 라이브러리 전체를 고른 파일로 내보낸다(저장 위치를 고르므로 …).
        case .exportLibraryXML: String(ui: "라이브러리 XML 내보내기…")
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

    @MainActor func menuTitle(in store: LibraryStore) -> String { title }

    @MainActor func isEnabled(in store: LibraryStore) -> Bool {
        guard store.writeLockPolicy.allowsLibraryInteraction else { return false }
        switch self {
        case .addFiles: return !store.rows.isEmpty
        case .importAppleMusic: return !store.isLoading
        case .snapshot: return store.canSynchronizeLibrary
        case .exportXML: return store.sidebar == .staged ? !store.staged.isEmpty : !store.reflectionTargets.isEmpty
        case .exportLibraryXML:
            guard case .loaded = store.phase else { return false }
            return store.snapshotURL != nil && !store.isLoading && !store.hasXMLExportJob
        case .reflect: return store.pendingLibraryCount > 0 || store.hasPlaylistDrafts
        case .pending, .writeResult: return true
        case .restore: return store.hasWriteBackup
        case .removeTracks: return !store.isITunesSelection && store.selectedRows.contains { !$0.isStaged && !$0.track.isStreaming }
        }
    }

    @MainActor func perform(in store: LibraryStore) {
        guard isEnabled(in: store) else {
            if let reason = disabledReason(in: store) { store.stagingMessage = AppMessage(kind: .warning, text: reason) }
            return
        }
        switch self {
        case .addFiles: StagingPanels.chooseFiles(store: store)
        case .importAppleMusic: AppleMusicImportWindow.shared.open(store: store)
        case .snapshot: Task { await store.synchronizeLibrary() }
        case .exportXML:
            if store.sidebar == .staged { StagingPanels.exportXML(store: store) }
            else { ReflectionPanels.export(store: store, rows: store.reflectionPreviewRows) }
        case .exportLibraryXML: LibraryXMLPanels.export(store: store)
        case .reflect: DirectWritePanels.write(store: store, rows: store.reflectionPreviewRows)
        case .pending: store.sidebar = .pending
        case .writeResult: store.showingWriteResult = true
        case .restore: DirectWritePanels.restoreLatest(store: store)
        case .removeTracks:
            DirectWritePanels.deleteTracks(store: store, rows: store.selectedRows.filter { !$0.isStaged && !$0.track.isStreaming })
        }
    }

    @MainActor func disabledReason(in store: LibraryStore) -> String? {
        guard !isEnabled(in: store) else { return nil }
        if !store.writeLockPolicy.allowsLibraryInteraction { return String(ui: "rekordbox 쓰기가 끝난 뒤 다시 시도하세요") }
        switch self {
        case .snapshot:
            if store.isLoading || store.isSynchronizingLibrary { return String(ui: "라이브러리 읽기가 끝난 뒤 다시 동기화하세요") }
            return String(ui: "덱의 큐 입력을 확정하고 끌기를 마친 뒤 동기화하세요")
        case .removeTracks:
            if store.isITunesSelection { return String(ui: "iTunes 동기화 목록에서는 곡을 뺄 수 없으니 rekordbox 컬렉션에서 곡을 고르세요") }
            return String(ui: "rekordbox 컬렉션에서 뺄 로컬 곡을 목록에서 고르세요")
        case .reflect: return String(ui: "쓸 초안이 없으니 곡을 편집하거나 재생 목록 초안을 먼저 만드세요")
        case .exportXML: return String(ui: "XML로 넘길 추가한 곡이나 큐·그리드 초안을 먼저 만드세요")
        case .exportLibraryXML:
            return store.hasXMLExportJob ? String(ui: "라이브러리 XML 내보내기가 끝난 뒤 다시 시도하세요") : String(ui: "라이브러리를 먼저 불러온 뒤 내보내세요")
        case .restore: return String(ui: "쓰기 전 백업이 없으니 마지막 쓰기 결과를 확인하세요")
        case .addFiles, .importAppleMusic: return String(ui: "라이브러리를 먼저 불러온 뒤 곡을 추가하세요")
        case .pending, .writeResult: return nil
        }
    }
}
