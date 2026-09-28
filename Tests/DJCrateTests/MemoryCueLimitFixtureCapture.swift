@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import SwiftUI
import Testing

/// #145 메모리 큐 한도 확인용 합성 라이브러리. rekordbox 자동 큐 4개(`CUE(Auto)` 1·`1.1Bars` 3)뿐인 곡과,
/// 보고 때처럼 자동 큐 없이 만든 초안에 메모리 큐 6개를 찍은 옛 초안(초안 변경 6).
/// 디버그 앱: `DJC_MEMORY_LIMIT_FIXTURE=<폴더> swift test --filter MemoryCueLimitFixtureCapture` 뒤
/// `DJC_HOME=<사본 home> DJC_REKORDBOX_DIR=<폴더>/rekordbox .build/debug/DJCrate --db <폴더>/rekordbox/master.db --select 1`
struct MemoryCueLimitFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_MEMORY_LIMIT_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_MEMORY_LIMIT_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        let root = URL(filePath: path)
        let library = root.appending(path: "rekordbox")
        let draft = try Self.populate(fixture, audioRoot: library)
        try CueDraftStore.save(draft, directory: root.appending(path: "home/cue-drafts"))
        try FileManager.default.copyItem(at: fixture.root, to: library)
    }

    /// 합성 곡 하나를 넣고 보고 때와 같은 옛 초안(자동 큐 없이 만든 base + 새 메모리 큐 6개)을 돌려준다.
    /// - Parameter audioRoot: 곡 경로가 가리킬 rekordbox 폴더(사본을 옮길 자리)
    static func populate(_ fixture: RekordboxFixture, audioRoot: URL) throws -> CueDraft {
        _ = try EditLayoutFixtureCapture.song(bpm: 128, first: 0.35, seconds: 150, to: fixture.audio.appending(path: "sample.wav"))
        var track = TrackSpec(id: "1")
        track.title = "합성 곡 (자동 큐 4개)"
        track.folderPath = audioRoot.appending(path: "audio/sample.wav").path
        track.fileType = 11
        track.length = 150
        track.analysisDataPath = "/PIONEER/USBANLZ/test1/ANLZ0000.DAT"
        var named = CueSpec.autoCue(at: 350)
        named.comment = "CUE(Auto)"
        track.cues = [named, CueSpec.autoCue(at: 7_850), CueSpec.autoCue(at: 67_850), CueSpec.autoCue(at: 127_850)]
        try fixture.add(track)
        let beats = AnlzBuilder.beats(bpm: 128, first: 350, count: 318)
        try fixture.putAnalysis(for: track, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))

        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: [])
        for bar in [3, 9, 15, 33, 45, 57] {
            draft.place(EditableCue(kind: .memory, time: 0.35 + Double(bar - 1) * 4 * 60 / 128))
        }
        return draft
    }
}

/// #145 화면 확인용: 위 합성 곡을 읽은 주 창에서 곡을 덱에 올리고 61마디에 메모리 큐를 하나 더 찍은 뒤 창을 그대로 그려 PNG로 남긴다.
/// 오디오 장치(가짜 오디오)·화면 기록 권한 없이, 창을 다른 앱 뒤에 둔 채(초점을 빼앗지 않게) 찍는다. 변경 전 코드에서도 컴파일된다.
/// 초안은 `DJC_HOME`의 cue-drafts에서, 분석 파일은 `DJC_REKORDBOX_DIR`(없는 폴더를 주면 합성 사본을 그 자리에 만든다)에서 읽는다.
/// `DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=<없는 폴더> DJC_MEMORY_LIMIT_CAPTURE=<폴더> swift test --filter MemoryCueLimitCapture`
/// → `<폴더>/<light|dark>.png`
@MainActor
struct MemoryCueLimitCapture {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: ["DJC_MEMORY_LIMIT_CAPTURE", "DJC_HOME", "DJC_REKORDBOX_DIR"].allSatisfy { environment[$0] != nil }), .serialized,
          arguments: ["light", "dark"])
    func capture(_ appearance: String) async throws {
        guard let path = Self.environment["DJC_MEMORY_LIMIT_CAPTURE"], let rekordbox = Self.environment["DJC_REKORDBOX_DIR"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        // 분석 파일은 `DJC_REKORDBOX_DIR/share`에서 찾으므로 그 자리에 사본을 둔다(라이트·다크는 차례로 돈다).
        let library = URL(filePath: rekordbox)
        try? FileManager.default.removeItem(at: library)
        let fixture = try RekordboxFixture()
        let draft = try MemoryCueLimitFixtureCapture.populate(fixture, audioRoot: library)
        try FileManager.default.copyItem(at: fixture.root, to: library)
        // 다른 시험이 접어 둔 사이드바를 이 캡처에서만 편다.
        let sidebar = UserDefaults.standard.object(forKey: SettingKeys.sidebarVisible.name)
        UserDefaults.standard.set(true, forKey: SettingKeys.sidebarVisible.name)
        defer { UserDefaults.standard.set(sidebar, forKey: SettingKeys.sidebarVisible.name) }
        try CueDraftStore.save(draft)
        defer { CueDraftStore.remove(trackUUID: draft.trackUUID) }
        let drafts = MemoryDrafts()
        drafts.save(draft)
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
        for _ in 0..<300 where deck.draft == nil || deck.waveform == nil { try await Task.sleep(for: .milliseconds(10)) }
        let bar61 = 0.35 + 60 * 4 * 60 / 128.0
        deck.seek(bar61)
        deck.addMemoryCue(at: bar61)
        try await Task.sleep(for: .milliseconds(1500))
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
