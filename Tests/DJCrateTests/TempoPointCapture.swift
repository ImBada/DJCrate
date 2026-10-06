@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import SwiftUI
import Testing

/// #207 화면 확인용: 합성 곡(128 BPM)을 덱에 올려 그리드 편집을 켜고, Q를 끈 채 박 사이(5마디 첫 박 뒤 0.6박)에서
/// 변속 지점 +를 눌러 그리드 편집 띠를 PNG로 남긴다. 창은 다른 앱 뒤에 둔 채 그려, 커서·키보드·초점을 쓰지 않는다. 변경 전 코드에서도 컴파일된다.
/// `DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=<없는 폴더> DJC_TEMPO_POINT_CAPTURE=<폴더> swift test --filter TempoPointCapture`
/// → `<폴더>/<light|dark>.png`
@MainActor
struct TempoPointCapture {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: ["DJC_TEMPO_POINT_CAPTURE", "DJC_HOME", "DJC_REKORDBOX_DIR"].allSatisfy { environment[$0] != nil }), .serialized,
          arguments: ["light", "dark"])
    func capture(_ appearance: String) async throws {
        guard let path = Self.environment["DJC_TEMPO_POINT_CAPTURE"], let rekordbox = Self.environment["DJC_REKORDBOX_DIR"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        // 분석 파일은 `DJC_REKORDBOX_DIR/share`에서 찾으므로 그 자리에 사본을 둔다(라이트·다크는 차례로 돈다).
        let library = URL(filePath: rekordbox)
        try? FileManager.default.removeItem(at: library)
        let fixture = try RekordboxFixture()
        _ = try MemoryCueLimitFixtureCapture.populate(fixture, audioRoot: library)
        try FileManager.default.copyItem(at: fixture.root, to: library)
        // 다른 시험이 접어 둔 사이드바를 이 캡처에서만 편다.
        let sidebar = UserDefaults.standard.object(forKey: SettingKeys.sidebarVisible.name)
        UserDefaults.standard.set(true, forKey: SettingKeys.sidebarVisible.name)
        defer { UserDefaults.standard.set(sidebar, forKey: SettingKeys.sidebarVisible.name) }
        let drafts = MemoryDrafts()
        let store = LibraryStore(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }))
        await store.load(snapshot: library.appending(path: "master.db"))
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(drafts), runsAnalysis: false)
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck, windowFrameRestored: false))
        let window = UnconstrainedWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        // 곡 목록 끝의 핫큐·메모리 칸까지 보이는 폭(화면보다 넓어도 된다)
        window.setContentSize(NSSize(width: 2100, height: 900))
        window.orderBack(nil)
        defer { window.close() }

        let row = try #require(store.rows.first)
        store.selection = [row.id]
        deck.load(row)
        for _ in 0..<300 where deck.gridDraft == nil || deck.waveform == nil { try await Task.sleep(for: .milliseconds(10)) }
        deck.gridEditing = true
        deck.quantize = false
        let beat = 60 / 128.0
        let position = 0.35 + 16 * beat + 0.6 * beat
        deck.seek(position)
        deck.addTempoChangeAtPlayhead()
        try await Task.sleep(for: .milliseconds(1500))
        print("변속 지점 시험: 재생 위치 \(position) 구간 \(deck.gridDraft?.segments.map(\.start) ?? [])")
        try save(window, to: folder.appending(path: "\(appearance).png"))
    }

    /// 화면 폭에 맞춰 줄이지 않는 창(캡처는 화면이 아니라 뷰를 그린다)
    final class UnconstrainedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func save(_ window: NSWindow, to url: URL) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(window.contentView?.superview ?? window.contentView)
        // 뷰를 따로 그리면(cacheDisplay) 선택 줄의 효과 레이어(합성 필터)가 검게 나온다. 캡처할 때만 비강조 선택 색으로 칠한다.
        var selection: CGColor?
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            selection = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
        }
        func flatten(_ view: NSView) {
            if let row = view as? NSTableRowView, row.isSelected {
                for layer in row.subviews.compactMap({ ($0 as? NSVisualEffectView)?.layer }).flatMap({ $0.sublayers ?? [] }) {
                    layer.compositingFilter = nil
                    layer.backgroundColor = selection
                }
            }
            view.subviews.forEach(flatten)
        }
        flatten(view)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
