@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import SwiftUI
import Testing

/// #146·#147·#148 화면 확인용: #145 합성 곡(자동 큐 4개 + 초안 메모리 큐 6개)을 읽은 주 창에서
/// 덱 경고 알림(메모리 큐 한도)을 띄운 뒤 1초·6초 때, 쓰기 결과 알림(막힌 항목이 있는 쓰기, 참고 사유만 붙은 빼기),
/// 쓴 라이브러리를 다시 읽는 진행 카드를 창 그대로 그려 PNG로 남긴다.
/// 가짜 오디오로, 화면 기록 권한 없이 창을 다른 앱 뒤에 둔 채(초점을 빼앗지 않게) 찍는다. 변경 전 코드에서도 컴파일된다.
/// `DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=<없는 폴더> DJC_FEEDBACK_CAPTURE=<폴더> swift test --filter FeedbackCapture`
/// → `<폴더>/<light|dark>-{deck-1s,deck-6s,result-blocked,result-note,progress}.png`
@MainActor
struct FeedbackCapture {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: ["DJC_FEEDBACK_CAPTURE", "DJC_HOME", "DJC_REKORDBOX_DIR"].allSatisfy { environment[$0] != nil }), .serialized,
          arguments: ["light", "dark"])
    func capture(_ appearance: String) async throws {
        guard let path = Self.environment["DJC_FEEDBACK_CAPTURE"], let rekordbox = Self.environment["DJC_REKORDBOX_DIR"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let library = URL(filePath: rekordbox)
        try? FileManager.default.removeItem(at: library)
        let fixture = try RekordboxFixture()
        let draft = try MemoryCueLimitFixtureCapture.populate(fixture, audioRoot: library)
        try FileManager.default.copyItem(at: fixture.root, to: library)
        let sidebar = UserDefaults.standard.object(forKey: SettingKeys.sidebarVisible.name)
        UserDefaults.standard.set(true, forKey: SettingKeys.sidebarVisible.name)
        defer { UserDefaults.standard.set(sidebar, forKey: SettingKeys.sidebarVisible.name) }
        try CueDraftStore.save(draft)
        defer { CueDraftStore.remove(trackUUID: draft.trackUUID) }
        let drafts = MemoryDrafts()
        drafts.save(draft)
        let feedback = AppFeedback(announce: { _ in }, isVoiceOverEnabled: { false })
        let store = LibraryStore(resultHistory: WriteResultHistory(url: nil), feedback: feedback)
        await store.load(snapshot: library.appending(path: "master.db"))
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(drafts), runsAnalysis: false)
        deck.feedback = feedback
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck, windowFrameRestored: false))
        let window = MemoryCueLimitCapture.UnconstrainedWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.orderBack(nil)
        defer { window.close() }

        // #146 덱 경고 알림: 메모리 큐 한도(자동 큐 4 + 메모리 큐 6)에 걸린 뒤 1초·6초
        let row = try #require(store.rows.first)
        store.selection = [row.id]
        deck.load(row)
        for _ in 0..<300 where deck.draft == nil || deck.waveform == nil { try await Task.sleep(for: .milliseconds(10)) }
        let bar61 = 0.35 + 60 * 4 * 60 / 128.0
        deck.seek(bar61)
        deck.addMemoryCue(at: bar61)
        try await Task.sleep(for: .seconds(1))
        try save(window, to: folder.appending(path: "\(appearance)-deck-1s.png"))
        try await Task.sleep(for: .seconds(5))
        try save(window, to: folder.appending(path: "\(appearance)-deck-6s.png"))
        deck.toastTask?.cancel()
        deck.toast = nil

        // #147 쓰기 결과: 큐 2곡·그리드 3곡·재생 목록 1건을 쓰고 그리드 1곡은 분석 파일이 없어 막힘
        for (name, result) in [("result-blocked", Self.blockedWrite), ("result-note", Self.deleteWithFileNote)] {
            store.resultHistory.record(result)
            var toast = result.toast
            toast.undoBackup = fixture.root
            store.toast = toast
            try await Task.sleep(for: .milliseconds(1500))
            try save(window, to: folder.appending(path: "\(appearance)-\(name).png"))
            store.toast = nil
        }

        // #148 쓴 뒤 다시 읽는 진행 카드
        store.writeStage = .reloadingLibrary
        try await Task.sleep(for: .milliseconds(800))
        try save(window, to: folder.appending(path: "\(appearance)-progress.png"))
        store.writeStage = nil
    }

    static var blockedWrite: WriteResult {
        func outcome(_ id: String, _ status: RekordboxWriter.Outcome.Status, reason: String? = nil) -> RekordboxWriter.Outcome {
            .init(trackUUID: id, title: "합성 곡 \(id)", status: status, reason: reason, removed: 0, added: 1)
        }
        var predicted = RekordboxWriter.Report(outcomes: [outcome("1", .written), outcome("2", .written)], backup: nil, dryRun: true,
                                               createdAt: "", finalUpdateCount: nil)
        predicted.gridOutcomes = [outcome("3", .written), outcome("4", .written), outcome("5", .written),
                                  outcome("6", .blocked, reason: String(ui: "rekordbox 분석 파일이 없습니다. rekordbox에서 트랙 분석을 먼저 하세요"))]
        predicted.playlistOutcomes = [PlaylistOutcome(edit: .create(key: "k", name: "합성 세트", isFolder: false, parent: .root),
                                                      playlistID: "1", name: "합성 세트", status: .written, reason: nil)]
        var actual = predicted
        actual.dryRun = false
        actual.gridOutcomes?.removeAll { $0.status != .written }
        actual.backup = "/tmp/synthetic-backup"
        return .written(actual, preview: predicted)
    }

    /// 곡을 뺐고 분석 파일만 경로가 예상과 달라 남긴 경우(참고 사유)
    static var deleteWithFileNote: WriteResult {
        var report = RekordboxTrackWriter.Report(dryRun: false)
        report.deleted = [.init(path: "/synthetic/a.wav", contentID: "7", title: "합성 곡 7", written: true,
                                reason: RekordboxWriter.fileOwnershipWarning)]
        report.backup = "/tmp/synthetic-backup"
        return .tracks(report, preview: report, adding: false)
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
