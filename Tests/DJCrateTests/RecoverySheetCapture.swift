@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import SwiftUI
import Testing

/// 막힌 초안 복구 시트 화면 확인용(#232): 곡·종류·재생 목록에 막힌 초안이 섞인 합성 라이브러리(`RecoveryScenario`)에서
/// 실제 시트 뷰(`RecoverySheetView`)를 화면 밖 창에 그려 `<폴더>/after-*.png`로 남긴다. 저장하지 않고 합성 사본만 읽는다.
/// 실제 마우스·키보드 초점을 쓰지 않는다(창은 앞으로 가져오지 않고 그리기만 한다).
/// 전(before)은 연속 창이던 468e7b7 때 같은 시나리오로 `AlertPrompter` 창을 그려 `docs/images/issues/232/before-*.jpg`로 남겼다.
/// `DJC_HOME=<임시> DJC_RECOVERY_CAPTURE=<폴더> swift test --filter RecoverySheetCapture`
@MainActor
struct RecoverySheetCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_RECOVERY_CAPTURE"] != nil && LiveDraftHome.isIsolated),
          arguments: ["light", "dark"])
    func capture(_ appearance: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_RECOVERY_CAPTURE"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let scenario = try await RecoveryScenario.make()
        let nsAppearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let initial = scenario.outcome()

        func open(_ targets: [RecoveryScenario.Target], maxListHeight: CGFloat = 460) async throws -> (RecoverySheetModel, NSWindow) {
            let model = RecoverySheetModel(store: scenario.store, requests: targets.map { RecoverySheetTests.request(scenario, $0) },
                                           dependencies: .init(home: scenario.home))
            let window = hosted(RecoverySheetView(model: model, maxListHeight: maxListHeight), appearance: nsAppearance)
            _ = await waitUntil { !model.isLoading && model.lines.allSatisfy { $0.phase != .loading } }
            return (model, window)
        }

        // 여러 줄: 곡·종류·재생 목록이 한 시트에. 줄마다 다르게 골랐다(C 큐는 대상을 이어야 하는 줄).
        // 실제 크기는 목록 높이가 460pt에서 멈추고 스크롤된다(`after-sheet`). `after-sheet-all`은 모든 줄이 보이게 한계를 풀어 그렸다.
        var (model, window) = try await open(RecoveryScenario.allTargets)
        defer { window.close() }
        try await settle(window)
        try save(window, to: folder.appending(path: "after-sheet-\(appearance).png"))
        window.close()
        (model, window) = try await open(RecoveryScenario.allTargets, maxListHeight: 2000)
        model.choose(.useCurrent, for: try #require(model.lines.first { $0.id.hasSuffix("/cues") && $0.title == "합성 곡 A" }))
        model.choose(.later, for: try #require(model.lines.first { $0.title == "합성 곡 B" && $0.kindLabel == "태그" }))
        model.choose(.useCurrent, for: try #require(model.lines.first { $0.isPlaylist && $0.title == "외부 이름 둘" }))
        try await settle(window)
        try save(window, to: folder.appending(path: "after-sheet-all-\(appearance).png"))
        window.close()

        // 큐 대상 다시 지정: 줄 안에서 펼쳐 고른다(이어 주기 전 → 이은 뒤)
        (model, window) = try await open([.draft("C", .cues)])
        try await settle(window)
        try save(window, to: folder.appending(path: "after-remap-\(appearance).png"))
        let line = try #require(model.lines.first)
        let mapping = try #require(line.cueMapping)
        model.mapCue(try #require(mapping.missing.first?.sourceID), to: mapping.candidates.first?.sourceID, in: line)
        line.detailsExpanded = true
        try await settle(window)
        try save(window, to: folder.appending(path: "after-remap-mapped-\(appearance).png"))
        window.close()

        // 한 곡·한 종류만 고른 진입(인스펙터·목록 메뉴): 그 줄만 든 시트
        (model, window) = try await open([.draft("A", .tags)])
        try await settle(window)
        try save(window, to: folder.appending(path: "after-single-\(appearance).png"))
        window.close()

        // 여기까지 저장하지 않았다
        #expect(scenario.outcome() == initial)

        // 실제 메인 창이 스토어의 시트를 시트로 띄우고, 닫으면 내린다(진입점이 모두 쓰는 길). 메인 창은 외부 초안을 다시 읽으므로 이 뒤로는 견주지 않는다.
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        let main = NSWindow(contentViewController: NSHostingController(rootView: ContentView(store: scenario.store, deck: deck)))
        main.isReleasedWhenClosed = false
        main.appearance = nsAppearance
        main.setContentSize(NSSize(width: 1280, height: 800))
        main.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        main.orderFront(nil)
        defer { main.close() }
        try await Task.sleep(for: .milliseconds(600))
        scenario.installDrafts()
        let sheetModel = RecoverySheetModel(store: scenario.store, requests: [.draft(try #require(scenario.rows["A"]), .cues), .draft(try #require(scenario.rows["B"]), .grid)],
                                            dependencies: .init(home: scenario.home))
        scenario.store.recoverySheet = sheetModel
        #expect(await waitUntil { main.attachedSheet != nil }, "메인 창에 시트가 뜨지 않았다")
        _ = await waitUntil { !sheetModel.isLoading && sheetModel.lines.allSatisfy { $0.phase != .loading } }
        if let sheet = main.attachedSheet {
            try await Task.sleep(for: .milliseconds(900))
            try save(sheet, to: folder.appending(path: "after-in-window-\(appearance).png"))
        }
        sheetModel.cancel()
        #expect(await waitUntil { main.attachedSheet == nil }, "시트를 닫아도 내려가지 않았다")
        #expect(scenario.store.recoverySheet == nil)
        FileHandle.standardError.write(Data("[복구 캡처] \(appearance): 저장 없이 그림 6장\n".utf8))
    }

    private func hosted(_ view: RecoverySheetView, appearance: NSAppearance?) -> NSWindow {
        // 시트처럼 제목 줄 없이 그린다. 화면 밖에 둔다(그려서 비트맵으로 뜨므로 보이지 않아도 된다).
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 720, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.appearance = appearance
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        return window
    }

    /// 내용 높이에 맞게 창을 줄이고(시트가 내용에 맞춰지는 것처럼) 그려질 때까지 기다린다.
    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(350))
            if let view = window.contentView {
                view.layoutSubtreeIfNeeded()
                window.setContentSize(NSSize(width: 720, height: view.fittingSize.height))
            }
        }
        try await Task.sleep(for: .milliseconds(350))
    }

    private func save(_ window: NSWindow, to url: URL) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(window.contentView?.superview ?? window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func waitUntil(timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
