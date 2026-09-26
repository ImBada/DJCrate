import RekordboxKit
import AnicueAnalysis
import AnicueDomain
import AnicueStorage
import AppKit
import SwiftUI

/// anicue ↔ rekordbox 연동 XML. 저장 창 없이 늘 같은 파일에 쓴다.
/// rekordbox 환경설정 › 고급 › 데이터베이스 › rekordbox xml에 이 파일을 한 번만 지정하면,
/// 이후에는 rekordbox에서 트리 새로고침 → 재생 목록 → Import To Collection만 하면 된다.
@MainActor
enum RekordboxLink {
    static var url: URL {
        URL.documentsDirectory.appending(path: "anicue/anicue-rekordbox.xml")
    }

    static func prepare() throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    /// 처음 한 번만 rekordbox 설정 방법을 알려 주고 경로를 클립보드에 복사한다.
    static func showSetupIfNeeded() {
        let key = "rekordboxLinkSetupShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        let alert = NSAlert()
        alert.messageText = "rekordbox에 연동 파일을 한 번만 지정해 주세요"
        alert.informativeText = """
        anicue는 반영할 내용을 늘 이 파일에 씁니다(경로를 클립보드에 복사했습니다):
        \(url.path)

        1. rekordbox › 환경설정 › 고급 › 데이터베이스 › rekordbox xml › "가져온 라이브러리"에 이 파일을 지정합니다(처음 한 번만).
        2. 트리에 "rekordbox xml"이 보이게 합니다(환경설정 › 보기 › 레이아웃에서 켤 수 있습니다).

        이후 반영할 때마다 rekordbox에서:
        • "rekordbox xml" 옆 새로고침 → 재생 목록 "anicue 반영"(새 곡은 "anicue 추가") → 곡 모두 선택 → 오른쪽 클릭 › Import To Collection
        • anicue에서 새 스냅샷(⟳)을 누르면 곡마다 제대로 들어갔는지 자동으로 확인합니다.

        처음 반영하기 전에 rekordbox › 파일 › 라이브러리 › 라이브러리 백업을 한 번 해 두세요.
        """
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "Finder에서 보기")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        UserDefaults.standard.set(true, forKey: key)
    }
}
