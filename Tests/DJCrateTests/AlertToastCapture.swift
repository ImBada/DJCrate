@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import SwiftUI
import Testing

/// 알림 창 → 토스트 화면 확인용(#230): 합성 라이브러리(곡 둘)에서 앱 흐름(`ReflectionCoordinator`)을 그대로 부른다.
/// - `running`: rekordbox가 켜져 있을 때 "rekordbox에 쓰기"
/// - `no-drafts`: 초안 없는 곡을 골라 "선택한 곡 rekordbox에 쓰기"
/// - `error-line`: 목록 위 오류 줄
/// 창이 뜨면 `<폴더>/<장면>-prompt.png`로 그려 남기고 닫는다. 뒤에 주 창을 `<장면>-window.png`로 남긴다.
/// 쓰지 않는다. 실제 마우스·키보드 초점을 쓰지 않는다(창은 앞으로 가져오지 않고 그리기만 한다).
/// `DJC_HOME=<임시> DJC_ALERT_TOAST_CAPTURE=<폴더> swift test --filter AlertToastCapture`
@MainActor
struct AlertToastCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_ALERT_TOAST_CAPTURE"] != nil && LiveDraftHome.isIsolated),
          arguments: ["running", "no-drafts", "error-line"])
    func capture(_ scene: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_ALERT_TOAST_CAPTURE"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let fixture = try RekordboxFixture()
        for (index, title) in ["합성 곡 하나", "합성 곡 둘"].enumerated() {
            var track = TrackSpec(id: String(101 + index), uuid: "alert-\(scene)-\(index)-\(UUID())")
            track.title = title
            try fixture.add(track)
        }
        try FileManager.default.createDirectory(at: fixture.root.appending(path: "share/PIONEER/USBANLZ"), withIntermediateDirectories: true)
        let store = LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.alert.\(UUID())")!, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 backupDirectory: fixture.backups, playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in },
                                 playlistImportURL: nil, stagingSaver: { _ in }, draftHome: fixture.root.appending(path: "drafts"))
        store.rekordboxDatabase = fixture.database
        store.rekordboxShareRoot = fixture.shareRoot
        store.launchArguments = ["test"]
        store.launchEnvironment = [:]
        await store.load(snapshot: fixture.database, arguments: ["test", "--db", fixture.database.path], environment: [:])
        let rows = store.rows.sorted { $0.track.id < $1.track.id }
        try #require(rows.count == 2)
        store.sidebar = .filter(.all)
        store.selection = [rows[0].id]

        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.orderFront(nil)
        defer { window.close() }

        let prompter = SceneCapturingPrompter(url: folder.appending(path: "\(scene)-prompt.png"))
        switch scene {
        case "running":
            await ReflectionCoordinator(host: store, prompter: prompter, isRekordboxRunning: { true }).write(rows: [rows[0]])
        case "no-drafts":
            await ReflectionCoordinator(host: store, prompter: prompter, isRekordboxRunning: { false }).write(rows: [rows[0]], playlists: false)
        default:
            store.reportLibraryError("라이브러리 사본을 열지 못해 이전 목록을 보입니다. 저장 공간과 권한을 확인한 뒤 ⟳로 다시 읽으세요")
        }
        FileHandle.standardError.write(Data("[알림 캡처] \(scene): 창 \(prompter.count)개 · 토스트 \(store.toast?.title ?? "없음")\n".utf8))
        try await Task.sleep(for: .milliseconds(1200))
        try WriteConfirmCapture.save(window.contentView?.superview ?? window.contentView, to: folder.appending(path: "\(scene)-window.png"))
    }
}

/// 뜬 창을 그려 남기고 닫는다(모달로 띄우지 않는다).
@MainActor
final class SceneCapturingPrompter: NoRecoverySheetPrompter {
    let url: URL
    var count = 0
    init(url: URL) { self.url = url }

    func show(_ prompt: ReflectionPrompt) -> Bool { choose(prompt) == .confirm }

    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice {
        count += 1
        let alert = AlertPrompter().makeAlert(prompt)
        alert.window.appearance = NSAppearance(named: .aqua)
        alert.layout()
        try? WriteConfirmCapture.save(alert.window.contentView?.superview ?? alert.window.contentView, to: url)
        return .cancel
    }
}
