@testable import DJCrate
import AppKit
import DJCDomain
import DJCTestSupport
import Foundation
import SwiftUI
import Testing

/// 파일이 없는 곡 화면 확인용(#126): 일부 음원을 지운 합성 사본(`MissingFilesFixtureCapture`)을 읽은 주 창을
/// 전체 목록과 '파일 없음' 필터로 그려 PNG로 남긴다. 오디오 장치(가짜 오디오)와 화면 기록 권한 없이 찍는다.
/// 창을 따로 그리므로 다크에서는 사이드바 글자(vibrancy)가 실제 앱보다 어둡게 나온다.
/// 변경 전 코드에서도 컴파일되게 필터는 이름으로 찾는다(없으면 전체 목록만 찍는다).
/// `DJC_MISSING_FILES_CAPTURE=<폴더> swift test --filter MissingFilesCapture` → `<폴더>/<light|dark>-{all,filter}.png`
@MainActor
struct MissingFilesCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_MISSING_FILES_CAPTURE"] != nil), arguments: ["light", "dark"])
    func capture(_ appearance: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_MISSING_FILES_CAPTURE"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let fixture = try RekordboxFixture()
        for name in try MissingFilesFixtureCapture.populate(fixture, audioRoot: fixture.root) {
            try FileManager.default.removeItem(at: fixture.audio.appending(path: name))
        }
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
        // 파일 확인(뒤에서)과 목록 그리기를 기다린다.
        try await Task.sleep(for: .milliseconds(1500))
        try save(window, to: folder.appending(path: "\(appearance)-all.png"))
        if let filter = LibraryFilter(rawValue: "파일 없음") {
            store.sidebar = .filter(filter)
            try await Task.sleep(for: .milliseconds(800))
            try save(window, to: folder.appending(path: "\(appearance)-filter.png"))
        }
    }

    private func save(_ window: NSWindow, to url: URL) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(window.contentView?.superview ?? window.contentView)
        // 뷰를 따로 그리면(cacheDisplay) 선택 줄의 효과 레이어(합성 필터)가 검게 나와 사이드바에서 고른 필터가 가려진다.
        // 캡처할 때만 그 레이어를 비강조 선택 색으로 칠한다(목록에 초점이 없을 때의 모양).
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
