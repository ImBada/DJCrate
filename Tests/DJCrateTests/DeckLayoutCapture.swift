@testable import DJCrate
import AppKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import SwiftUI
import Testing

/// PR #151 화면 확인용: 합성 곡 3개를 읽은 주 창에서 첫 곡을 덱에 올리고, 핫큐·메모리 큐(자동 큐 4개 + 초안 6개)·
/// 그리드 편집(템포 구간 추가)·큰 음량 경고를 만든 뒤 창 그대로 그려 PNG로 남긴다.
/// 가짜 오디오로, 화면 기록 권한 없이 창을 다른 앱 뒤에 둔 채(초점을 빼앗지 않게) 찍는다. 변경 전 코드에서도 컴파일된다.
/// `DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=<없는 폴더> DJC_DECK_LAYOUT_CAPTURE=<폴더> swift test --filter DeckLayoutCapture`
/// → `<폴더>/<light|dark>-<short|wide|narrow>.png`
@MainActor
struct DeckLayoutCapture {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: ["DJC_DECK_LAYOUT_CAPTURE", "DJC_HOME", "DJC_REKORDBOX_DIR"].allSatisfy { environment[$0] != nil }), .serialized,
          arguments: ["light", "dark"])
    func capture(_ appearance: String) async throws {
        guard let path = Self.environment["DJC_DECK_LAYOUT_CAPTURE"], let rekordbox = Self.environment["DJC_REKORDBOX_DIR"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let library = URL(filePath: rekordbox)
        try? FileManager.default.removeItem(at: library)
        let fixture = try RekordboxFixture()
        let draft = try Self.populate(fixture, audioRoot: library)
        try FileManager.default.copyItem(at: fixture.root, to: library)
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
        let window = MemoryCueLimitCapture.UnconstrainedWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        // 낮은 창에서 곡을 처음 올린 모습(파형 높이가 덱 내용에 맞는지)을 먼저 찍고, 키운 뒤 넓은 창·좁은 창을 찍는다.
        window.setContentSize(NSSize(width: 1500, height: 680))
        window.orderBack(nil)
        defer { window.close() }

        let row = try #require(store.rows.first { $0.title.contains("자동 큐") })
        store.selection = [row.id]
        deck.load(row)
        for _ in 0..<300 where deck.draft == nil || deck.waveform == nil { try await Task.sleep(for: .milliseconds(10)) }
        // 핫큐 A·B·C, 루프 하나, 큰 음량 경고, 그리드 편집 중 템포 구간 추가
        let beat = 60 / 128.0
        for (slot, bar) in [(0, 1), (1, 9), (2, 17)] {
            deck.seek(0.35 + Double(bar - 1) * 4 * beat)
            deck.pressHotCue(slot: slot)
        }
        deck.loudness = Loudness(integrated: -5.4, peak: 0, clippedRuns: 1500)
        deck.metronome = true
        deck.seek(0.35 + 60 * 4 * beat)
        deck.gridEditing = true
        deck.addTempoChangeAtPlayhead()
        deck.seek(0.35 + 20 * 4 * beat)
        try await Task.sleep(for: .milliseconds(1500))
        try save(window, to: folder.appending(path: "\(appearance)-short.png"))

        window.setContentSize(NSSize(width: 1500, height: 900))
        try await Task.sleep(for: .milliseconds(1200))
        try save(window, to: folder.appending(path: "\(appearance)-wide.png"))

        window.setContentSize(NSSize(width: 1100, height: 900))
        try await Task.sleep(for: .milliseconds(1200))
        try save(window, to: folder.appending(path: "\(appearance)-narrow.png"))
    }

    /// 합성 곡 3개(첫 곡은 rekordbox 자동 큐 4개 + 자동 큐 없이 만든 초안에 메모리 큐 6개).
    static func populate(_ fixture: RekordboxFixture, audioRoot: URL) throws -> CueDraft {
        _ = try EditLayoutFixtureCapture.song(bpm: 128, first: 0.35, seconds: 150, to: fixture.audio.appending(path: "sample.wav"))
        let beats = AnlzBuilder.beats(bpm: 128, first: 350, count: 318)
        var first: TrackSpec?
        for (index, title) in ["합성 곡 (자동 큐 4개)", "합성 곡 둘", "합성 곡 셋"].enumerated() {
            var track = TrackSpec(id: "\(index + 1)")
            track.title = title
            track.folderPath = audioRoot.appending(path: "audio/sample.wav").path
            track.fileType = 11
            track.length = 150
            track.analysisDataPath = "/PIONEER/USBANLZ/test\(index + 1)/ANLZ0000.DAT"
            if index == 0 {
                var named = CueSpec.autoCue(at: 350)
                named.comment = "CUE(Auto)"
                track.cues = [named, CueSpec.autoCue(at: 7_850), CueSpec.autoCue(at: 67_850), CueSpec.autoCue(at: 127_850)]
                first = track
            }
            try fixture.add(track)
            try fixture.putAnalysis(for: track, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        }
        var draft = CueDraft(trackUUID: try #require(first).uuid, rekordboxCues: [])
        for bar in [3, 9, 15, 33, 45, 57] {
            draft.place(EditableCue(kind: .memory, time: 0.35 + Double(bar - 1) * 4 * 60 / 128))
        }
        return draft
    }

    private func save(_ window: NSWindow, to url: URL) throws {
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
}
