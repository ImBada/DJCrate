@testable import DJCrate
import AppKit
import SwiftUI
import Testing

@MainActor
@Suite("반영 — 창 위쪽 배치", .serialized)
struct ReflectionLayoutTests {
    @Test(arguments: ["light", "dark"]) func 결과_알림은_최소_창의_detail_위쪽에_보인다(_ appearance: String) async throws {
        _ = NSApplication.shared
        let store = LibraryStore(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }))
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        store.toast = AppToast(kind: .warning, title: "배치 시험 결과", detail: "합성 데이터로 확인합니다")
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        window.contentView?.layoutSubtreeIfNeeded()
        let view = controller.view
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // 경고 아이콘·테두리의 실제 렌더링 위치를 검사한다(이미지 좌표는 위에서 아래로 증가).
        var orangeY: [Int] = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.7, color.greenComponent > 0.2, color.greenComponent < 0.8, color.blueComponent < 0.3 {
                    orangeY.append(y)
                }
            }
        }
        #expect(!orangeY.isEmpty)
        #expect(orangeY.reduce(0, +) / max(orangeY.count, 1) < bitmap.pixelsHigh / 2)
    }
}
