@testable import DJCrate
import AppKit
import DJCDomain
import DJCTestSupport
import Foundation
import SwiftUI
import Testing

/// 반영 알림·진행 카드 화면 확인용(#122): 합성 라이브러리(곡 다섯·재생 목록 둘)를 읽은 주 창에
/// 위쪽 알림 줄(곡 추가 메시지) + 쓰기 결과 토스트, 미리 보기 진행 카드를 띄우고 창을 그대로 그려 PNG로 남긴다.
/// 오디오 장치(가짜 오디오)와 화면 기록 권한 없이 찍는다. 실데이터는 쓰지 않는다.
/// `DJC_REFLECTION_CAPTURE=<폴더> swift test --filter ReflectionCapture` → `<폴더>/<light|dark>-{toast,progress}.png`
@MainActor
struct ReflectionCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_REFLECTION_CAPTURE"] != nil), arguments: ["light", "dark"])
    func capture(_ appearance: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_REFLECTION_CAPTURE"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let fixture = try RekordboxFixture()
        for (index, title) in ["합성 곡 하나", "합성 곡 둘", "합성 곡 셋", "합성 곡 넷", "합성 곡 다섯"].enumerated() {
            var track = TrackSpec(id: String(101 + index))
            track.title = title
            try fixture.add(track)
        }
        try fixture.add(PlaylistSpec(id: "1001", name: "합성 폴더", seq: 1, isFolder: true))
        try fixture.add(PlaylistSpec(id: "1002", name: "합성 목록", parentID: "1001", seq: 1, contentIDs: ["101", "102"]))
        let store = LibraryStore(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }))
        await store.load(snapshot: fixture.database)
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.orderFront(nil)
        defer { window.close() }

        // 쓰기 결과: 실제 쓰기 뒤와 같은 문구·버튼(결과 보기·쓰기 전으로 복원…), 위쪽에는 곡 추가 메시지
        store.stagingMessage = AppMessage(text: String(ui: "\(2)곡을 추가 목록에서 뺐습니다(파일은 그대로)."))
        var toast = WriteResult(kind: .success, title: String(ui: "rekordbox에 썼습니다 · \(PlaylistWriteText.summary(4))"), text: "").toast
        toast.undoBackup = fixture.root
        store.toast = toast
        try await Task.sleep(for: .milliseconds(1500))
        try save(window, to: folder.appending(path: "\(appearance)-toast.png"))

        // 미리 보기 진행: 막대가 있는 단계
        store.toast = nil
        store.stagingMessage = nil
        store.writeStage = WriteStage(String(ui: "미리 보기 2/2단계 · 바꿀 내용을 검사하는 중…"), completed: 1, total: 2, cancellable: true)
        try await Task.sleep(for: .milliseconds(800))
        try save(window, to: folder.appending(path: "\(appearance)-progress.png"))
        store.writeStage = nil
    }

    private func save(_ window: NSWindow, to url: URL) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(window.contentView?.superview ?? window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
