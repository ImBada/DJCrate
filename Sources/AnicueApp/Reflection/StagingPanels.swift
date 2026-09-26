import RekordboxKit
import AnicueAnalysis
import AnicueDomain
import AnicueStorage
import AppKit
import SwiftUI

/// 파일 선택·저장 창.
@MainActor
enum StagingPanels {
    static func chooseFiles(store: LibraryStore) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.prompt = "추가"
        panel.message = "anicue에 추가할 음원 파일이나 폴더를 고르세요. 이미 rekordbox에 있는 파일은 건너뜁니다."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await store.addFiles(urls) }
    }

    static func exportXML(store: LibraryStore) {
        let selected = store.selection.filter { $0.hasPrefix("anicue-") }
        do {
            let url = try RekordboxLink.prepare()
            let result = try store.exportStaged(to: url, only: selected.isEmpty ? nil : selected)
            var text = "\(result.count)곡을 연동 XML에 썼습니다 · rekordbox: rekordbox xml 새로고침 › \"anicue 추가\" › Import To Collection"
            if result.withoutGrid > 0 { text += " · \(result.withoutGrid)곡은 그리드 없이(rekordbox가 분석)" }
            store.stagingMessage = text
            RekordboxLink.showSetupIfNeeded()
        } catch {
            store.stagingMessage = "내보내지 못했습니다: \(error.localizedDescription)"
        }
    }
}
