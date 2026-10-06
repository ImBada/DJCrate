import AppKit
import DJCDomain
import Foundation
import UniformTypeIdentifiers

/// 라이브러리 XML 내보내기 저장 창. 연동 파일을 늘 같은 자리에 만드는 "XML 만들기"(`RekordboxLink`)와 달리 저장 위치를 고른다.
@MainActor
enum LibraryXMLPanels {
    static func export(store: LibraryStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        panel.nameFieldStringValue = defaultFileName()
        // 연동 XML이 있는 Documents/DJCrate가 아니라 Documents에서 시작한다.
        panel.directoryURL = URL.documentsDirectory
        panel.canCreateDirectories = true
        panel.title = String(ui: "라이브러리 XML 내보내기")
        panel.message = String(ui: "라이브러리 전체(곡·큐·그리드·재생 목록)를 rekordbox XML 파일로 내보냅니다. rekordbox 라이브러리는 바뀌지 않으며, 쓰지 않은 초안은 넣지 않습니다.")
        panel.prompt = String(ui: "내보내기")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.exportLibraryXML(to: url)
    }

    /// 파일 이름은 번역하지 않는다.
    static func defaultFileName(now: Date = .now) -> String {
        "DJCrate-library-\(now.formatted(.iso8601.year().month().day())).xml"
    }
}
