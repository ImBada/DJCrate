@testable import DJCrate
import AppKit
import DJCDomain
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import SwiftUI
import Testing

/// 설정 '스트리밍 곡 숨기기' 화면 확인용(합성 데이터만).
/// - 합성 사본: 로컬 곡 6·스트리밍 곡 4, 재생 목록 3(섞임·스트리밍뿐·로컬뿐), 재생 기록 1.
///   `DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=<임시> DJC_HIDE_STREAMING_FIXTURE=<없는 폴더> swift test --filter HideStreamingFixtureCapture`
///   → `<폴더>/master.db`(앱은 `--db`로, `DJC_REKORDBOX_DIR=<폴더>`와 함께)
/// - 설정 창 그림: `DJC_HIDE_STREAMING_SETTINGS_CAPTURE=<폴더>` → `<폴더>/settings-<off|on>.png`
@MainActor
struct HideStreamingFixtureCapture {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["DJC_HIDE_STREAMING_FIXTURE"] != nil))
    func 합성_사본() throws {
        guard let path = Self.environment["DJC_HIDE_STREAMING_FIXTURE"] else { return }
        try Self.buildLibrary(at: URL(filePath: path))
    }

    /// 합성 라이브러리를 `root`(없는 폴더)에 만든다. 로컬 곡은 `root/audio`의 합성 WAV를 가리킨다.
    static func buildLibrary(at root: URL) throws {
        let fixture = try RekordboxFixture()
        let audio = try AudioFixture.wav(seconds: 10, in: fixture.audio)
        let local = (1...6).map(String.init)
        let streaming = (7...10).map(String.init)
        for id in local + streaming {
            var track = TrackSpec(id: id, uuid: "capture-\(id)")
            if streaming.contains(id) {
                track.title = "합성 스트리밍 \(id)"
                track.folderPath = (Int(id) ?? 0) % 2 == 1 ? "spotify:track:synthetic\(id)" : "apple-music:synthetic\(id)"
            } else {
                track.title = "합성 로컬 \(id)"
                track.folderPath = root.appending(path: "audio/\(audio.lastPathComponent)").path
                track.fileType = 11
            }
            try fixture.add(track)
        }
        // 섞인 순서: 로컬·스트리밍을 번갈아
        let mixed = ["1", "7", "2", "8", "3", "4", "9", "5", "10", "6"]
        try fixture.add(playlists: [
            PlaylistSpec(id: "P", name: "합성 섞인 목록", seq: 1, contentIDs: mixed),
            PlaylistSpec(id: "Q", name: "합성 스트리밍뿐", seq: 2, contentIDs: streaming),
            PlaylistSpec(id: "R", name: "합성 로컬뿐", seq: 3, contentIDs: local),
        ])
        try fixture.insert("djmdHistory", ["ID": .text("h"), "Name": .text("합성 기록"), "DateCreated": .text("2025-02-03"),
            "Seq": .int(1), "Attribute": .int(0), "ParentID": .text("root"), "rb_local_deleted": .int(0)])
        for (id, content, number) in [("e1", "1", 1), ("e2", "7", 2), ("e3", "2", 3)] {
            try fixture.insert("djmdSongHistory", ["ID": .text(id), "HistoryID": .text("h"), "ContentID": .text(content),
                "TrackNo": .int(number), "rb_local_deleted": .int(0)])
        }
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }

    /// 주 창을 그대로 그려 숨기기 끔·켬을 같은 보기에서 견준다(`DJC_HIDE_STREAMING_WINDOW_CAPTURE=<폴더>` → `<폴더>/<off|on>-<all|P|Q|history>.png`).
    @Test(.enabled(if: environment["DJC_HIDE_STREAMING_WINDOW_CAPTURE"] != nil))
    func 주_창() async throws {
        guard let path = Self.environment["DJC_HIDE_STREAMING_WINDOW_CAPTURE"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let library = folder.appending(path: "library")
        try? FileManager.default.removeItem(at: library)
        try Self.buildLibrary(at: library)
        let sidebarVisible = UserDefaults.standard.object(forKey: SettingKeys.sidebarVisible.name)
        UserDefaults.standard.set(true, forKey: SettingKeys.sidebarVisible.name)
        defer { UserDefaults.standard.set(sidebarVisible, forKey: SettingKeys.sidebarVisible.name) }
        let defaults = UserDefaults(suiteName: "djc.test.hide-streaming.window.\(UUID())")!
        let store = LibraryStore(settings: SettingsStore(defaults: defaults, persist: true), resultHistory: WriteResultHistory(url: nil),
                                 feedback: AppFeedback(announce: { _ in }), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
        await store.load(snapshot: library.appending(path: "master.db"), arguments: ["test"], environment: [:])
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck, windowFrameRestored: false))
        let window = MemoryCueLimitCapture.UnconstrainedWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1300, height: 760))
        window.orderBack(nil)
        defer { window.close() }
        for hidden in [false, true] {
            store.hideStreaming = hidden
            for (name, item) in [("all", SidebarItem.filter(.all)), ("P", .playlist("P")), ("Q", .playlist("Q")), ("history", .history("h"))] {
                store.sidebar = item
                try await Task.sleep(for: .milliseconds(900))
                try Self.save(window, to: folder.appending(path: "\(hidden ? "on" : "off")-\(name).png"))
            }
        }
    }

    /// 뷰를 따로 그리면(cacheDisplay) 선택 줄의 효과 레이어가 검게 나와 비강조 색으로 칠한다(`MemoryCueLimitCapture`와 같다).
    static func save(_ window: NSWindow, to url: URL) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(window.contentView?.superview ?? window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test(.enabled(if: environment["DJC_HIDE_STREAMING_SETTINGS_CAPTURE"] != nil))
    func 설정_창() async throws {
        guard let path = Self.environment["DJC_HIDE_STREAMING_SETTINGS_CAPTURE"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "djc.test.hide-streaming.capture.\(UUID())")!
        let store = LibraryStore(settings: SettingsStore(defaults: defaults, persist: true), resultHistory: WriteResultHistory(url: nil),
                                 feedback: AppFeedback(announce: { _ in }), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        let controller = NSHostingController(rootView: SettingsView(store: store, deck: deck))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.orderBack(nil)
        defer { window.close() }
        for hidden in [false, true] {
            store.hideStreaming = hidden
            try await Task.sleep(for: .milliseconds(600))
            let view = try #require(window.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appending(path: "settings-\(hidden ? "on" : "off").png"))
        }
    }
}
