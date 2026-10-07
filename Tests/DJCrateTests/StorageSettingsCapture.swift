@testable import DJCrate
import AppKit
import DJCDomain
import Foundation
import SwiftUI
import Testing

/// 설정 › 저장 공간(#227) 화면 확인용(합성 데이터만, 평소에는 건너뛴다).
/// `DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=$(mktemp -d) DJC_STORAGE_SETTINGS_CAPTURE=<폴더> swift test --filter StorageSettingsCapture`
/// → `<폴더>/settings-general-tab.png`·`settings-storage-tab.png`(탭 막대 포함 설정 창), `storage-filled.png`·`storage-cleared-waveforms.png`·`storage-cleared-all.png`·`storage-writing.png`.
/// 캐시·백업은 임시 `DJC_HOME` 아래에 합성 파일(내용 없는 성긴 파일)로 만든다. 창은 앞으로 가져오거나 입력을 보내지 않고 화면 밖에서 그린다.
@MainActor
struct StorageSettingsCapture {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    /// 합성 캐시·백업. 크기만 크고 디스크는 거의 쓰지 않는다
    static func seed(_ paths: DJCCachePaths) throws {
        func file(_ url: URL, _ bytes: UInt64) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: bytes)
            try handle.close()
        }
        for index in 0..<40 { try file(paths.waveforms.appending(path: "synthetic-\(index)-1.json"), 620_000) }
        for index in 0..<40 { try file(paths.analysis.appending(path: "chroma/synthetic-\(index)-1.bin"), 180_000) }
        for index in 0..<40 { try file(paths.analysis.appending(path: "grid-estimates/synthetic-\(index)-1.json"), 4_000) }
        try file(paths.loudness, 96_000)
        try file(paths.previewWaveforms, 2_400_000)
        for day in ["20260101T000000", "20260102T000000"] {
            try file(paths.usbSnapshots.appending(path: "00000000-0000-0000-0000-000000000001/\(day)/exportLibrary.db"), 3_000_000)
        }
        for day in ["01", "02", "03"] {
            try file(paths.snapshots.appending(path: "master-2026-01-\(day)T000000.db"), 150_000_000)
        }
        for name in ["20260101-000000-write", "20260102-000000-write"] {
            try file(paths.root.appending(path: "rekordbox-backups/\(name)/master.db"), 150_000_000)
        }
        try file(paths.root.appending(path: "usb-backups/00000000-0000-0000-0000-000000000001/20260101-000000-edit/export.pdb"), 2_000_000)
        try file(paths.root.appending(path: "cue-drafts/synthetic.json"), 400)
    }

    static func save(_ window: NSWindow, to url: URL) throws {
        let view = try #require(window.contentView?.superview ?? window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    static func window(_ root: some View, title: String) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = title
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.orderBack(nil)
        return window
    }

    @Test(.enabled(if: environment["DJC_STORAGE_SETTINGS_CAPTURE"] != nil && LiveDraftHome.isIsolated))
    func 저장_공간_탭() async throws {
        guard let path = Self.environment["DJC_STORAGE_SETTINGS_CAPTURE"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let paths = DJCCachePaths.current
        try Self.seed(paths)

        // 설정 창 전체(탭 막대에 '저장 공간')
        let defaults = UserDefaults(suiteName: "djc.test.storage-settings.capture.\(UUID())")!
        let store = LibraryStore(settings: SettingsStore(defaults: defaults, persist: true), resultHistory: WriteResultHistory(url: nil),
                                 feedback: AppFeedback(announce: { _ in }), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        // 창 밖에서 그리면 고른 탭의 이름이 비어 보여, 일반 탭을 고른 그림도 남긴다(탭 막대의 '저장 공간'이 보인다)
        for (tab, name) in [(SettingsTab.general, "settings-general-tab.png"), (.storage, "settings-storage-tab.png")] {
            let settings = Self.window(SettingsView(store: store, deck: deck, tab: tab), title: String(ui: "설정"))
            try await Task.sleep(for: .milliseconds(1_200))
            try Self.save(settings, to: folder.appending(path: name))
            settings.close()
        }

        // 칸 내용: 채움 → 파형 비움 → 모두 비움, 쓰는 중
        let model = StorageSettingsModel(paths: paths)
        let window = Self.window(StorageSettingsView(model: model), title: String(ui: "저장 공간"))
        defer { window.close() }
        await model.refresh()
        try await Task.sleep(for: .milliseconds(600))
        try Self.save(window, to: folder.appending(path: "storage-filled.png"))
        await model.clear([.waveforms])
        try await Task.sleep(for: .milliseconds(600))
        try Self.save(window, to: folder.appending(path: "storage-cleared-waveforms.png"))
        await model.clear(DJCCacheKind.allCases)
        try await Task.sleep(for: .milliseconds(600))
        try Self.save(window, to: folder.appending(path: "storage-cleared-all.png"))
        #expect(FileManager.default.fileExists(atPath: paths.root.appending(path: "cue-drafts/synthetic.json").path))

        try Self.seed(paths)
        let writing = StorageSettingsModel(paths: paths, busyReason: {
            StorageSettingsModel.busyReason(writingRekordbox: true, writingUsb: false)
        })
        let busyWindow = Self.window(StorageSettingsView(model: writing), title: String(ui: "저장 공간"))
        defer { busyWindow.close() }
        await writing.refresh()
        try await Task.sleep(for: .milliseconds(600))
        try Self.save(busyWindow, to: folder.appending(path: "storage-writing.png"))
    }
}
