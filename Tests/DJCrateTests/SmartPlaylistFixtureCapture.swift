@testable import DJCrate
import AppKit
import DJCDomain
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import SwiftUI
import Testing

/// 실험실 '인텔리전트 재생 목록 보기'(#68) 화면 확인용(합성 데이터만, 평소에는 건너뛴다).
/// - 합성 사본: 곡 8, 일반 재생 목록 1, 인텔리전트 목록 4(계산하는 조건 둘·계산하지 않는 조건·빈 조건 칸).
///   `DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=<임시> DJC_SMART_PLAYLIST_FIXTURE=<없는 폴더> swift test --filter SmartPlaylistFixtureCapture`
///   → `<폴더>/master.db`
/// - 주 창·설정 창 그림: `DJC_SMART_PLAYLIST_CAPTURE=<폴더>` → `<폴더>/<off|on>-<목록>.png`, `<폴더>/settings-lab-<off|on>.png`.
///   창은 앞으로 가져오거나 입력을 보내지 않고 화면 밖에서 그린다.
@MainActor
struct SmartPlaylistFixtureCapture {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["DJC_SMART_PLAYLIST_FIXTURE"] != nil))
    func 합성_사본() throws {
        guard let path = Self.environment["DJC_SMART_PLAYLIST_FIXTURE"] else { return }
        try Self.buildLibrary(at: URL(filePath: path))
    }

    static func condition(_ property: String, _ op: Int, _ left: String, _ right: String = "") -> String {
        "<CONDITION PropertyName=\"\(property)\" Operator=\"\(op)\" ValueUnit=\"\" ValueLeft=\"\(left)\" ValueRight=\"\(right)\"/>"
    }

    static func smartList(_ match: Int = 1, _ conditions: String...) -> String {
        "<NODE Id=\"-1\" LogicalOperator=\"\(match)\" AutomaticUpdate=\"0\">" + conditions.joined() + "</NODE>"
    }

    /// 합성 라이브러리를 `root`(없는 폴더)에 만든다. 곡은 `root/audio`의 합성 WAV를 가리킨다.
    static func buildLibrary(at root: URL) throws {
        let fixture = try RekordboxFixture()
        let audio = try AudioFixture.wav(seconds: 10, in: fixture.audio)
        try fixture.addArtist(id: "ar1", name: "합성 아티스트 가")
        try fixture.addArtist(id: "ar2", name: "합성 아티스트 나")
        let years = [2012, 2014, 2015, 2017, 2019, 2020, 2021, 2023]
        for (index, year) in years.enumerated() {
            let id = String(index + 1)
            var track = TrackSpec(id: id, uuid: "smart-capture-\(id)")
            track.title = "합성 곡 \(id)"
            track.folderPath = root.appending(path: "audio/\(audio.lastPathComponent)").path
            track.fileType = 11
            track.artistID = index % 2 == 0 ? "ar1" : "ar2"
            try fixture.add(track)
            try fixture.execute("UPDATE djmdContent SET ReleaseYear = ? WHERE ID = ?", [.int(year), .text(id)])
        }
        try fixture.addPlaylist(id: "F", name: "합성 폴더", seq: 1, attribute: 1)
        try fixture.addPlaylist(id: "P", name: "합성 일반 목록", parentID: "F", seq: 1, contentIDs: ["1", "2", "3"])
        try fixture.addPlaylist(id: "S1", name: "합성 연도 2015~2020", parentID: "F", seq: 2, attribute: 4,
                                smartList: smartList(1, condition("name", 8, "합성 곡"), condition("year", 5, "2015", "2020")))
        try fixture.addPlaylist(id: "S2", name: "합성 아티스트 가", parentID: "F", seq: 3, attribute: 4,
                                smartList: smartList(1, condition("artist", 1, "합성 아티스트 가")))
        try fixture.addPlaylist(id: "S3", name: "합성 별점 3 초과", parentID: "F", seq: 4, attribute: 4,
                                smartList: smartList(1, condition("rating", 3, "3")))
        try fixture.addPlaylist(id: "S4", name: "합성 조건 칸 없음", parentID: "F", seq: 5, attribute: 4)
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }

    static func makeStore(_ library: URL, lab: Bool) async -> LibraryStore {
        let defaults = UserDefaults(suiteName: "djc.test.smart-playlists.capture.\(UUID())")!
        let store = LibraryStore(settings: SettingsStore(defaults: defaults, persist: true), resultHistory: WriteResultHistory(url: nil),
                                 feedback: AppFeedback(announce: { _ in }), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
        await store.load(snapshot: library.appending(path: "master.db"), arguments: ["test"], environment: [:])
        store.showSmartPlaylists = lab
        store.expandedPlaylistIDs = ["F"]
        return store
    }

    /// 뷰를 따로 그리면(cacheDisplay) 선택 줄의 효과 레이어가 검게 나와 캡처할 때만 비강조 선택 색으로 칠한다(`MemoryCueLimitCapture`와 같다).
    static func save(_ window: NSWindow, to url: URL) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(window.contentView?.superview ?? window.contentView)
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

    @Test(.enabled(if: environment["DJC_SMART_PLAYLIST_CAPTURE"] != nil))
    func 주_창과_설정_창() async throws {
        guard let path = Self.environment["DJC_SMART_PLAYLIST_CAPTURE"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let library = folder.appending(path: "library")
        try? FileManager.default.removeItem(at: library)
        try Self.buildLibrary(at: library)
        let sidebarVisible = UserDefaults.standard.object(forKey: SettingKeys.sidebarVisible.name)
        UserDefaults.standard.set(true, forKey: SettingKeys.sidebarVisible.name)
        defer { UserDefaults.standard.set(sidebarVisible, forKey: SettingKeys.sidebarVisible.name) }

        // 주 창: 끔(지금 dev와 같다)·켬
        for lab in [false, true] {
            let store = await Self.makeStore(library, lab: lab)
            let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
            let controller = NSHostingController(rootView: ContentView(store: store, deck: deck, windowFrameRestored: false))
            let window = MemoryCueLimitCapture.UnconstrainedWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(NSSize(width: 1300, height: 760))
            window.orderBack(nil)
            for id in ["S1", "S3"] {
                store.sidebar = .playlist(id)
                try await Task.sleep(for: .milliseconds(900))
                try Self.save(window, to: folder.appending(path: "\(lab ? "on" : "off")-\(id).png"))
            }
            window.close()
        }

        // 설정 창 실험실 칸: 끔·켬
        let store = await Self.makeStore(library, lab: false)
        // 설정 창의 탭 막대는 창 밖에서 그리면 고른 탭 이름이 비어 보여, 실험실 칸 내용만 창 제목과 함께 그린다.
        let controller = NSHostingController(rootView: LabSettingsView(store: store))
        let window = NSWindow(contentViewController: controller)
        window.title = String(ui: "실험실")
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.orderBack(nil)
        defer { window.close() }
        for lab in [false, true] {
            store.showSmartPlaylists = lab
            try await Task.sleep(for: .milliseconds(600))
            let view = try #require(window.contentView?.superview ?? window.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appending(path: "settings-lab-\(lab ? "on" : "off").png"))
        }
    }
}
