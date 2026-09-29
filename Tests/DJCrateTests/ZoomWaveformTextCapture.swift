@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import SwiftUI
import Testing

/// #139 화면 확인용: 확대 파형의 글자(마디.박 눈금·큐 이름·핫큐 칩·루프 표시·다음 메모리 큐까지 알약, 그리드 편집의 박 번호)를
/// 고치기 전후에 같은 조건으로 그려 PNG로 남긴다. 합성 곡(128 BPM), 가짜 오디오, 창을 다른 앱 뒤에 둔 채(초점을 빼앗지 않게) 찍는다.
/// `DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=<없는 폴더> DJC_ZOOM_TEXT_CAPTURE=<폴더> swift test --filter ZoomWaveformTextCapture`
/// → `<폴더>/<light|dark|light-grid>.png`. 전후 PNG가 바이트까지 같은지 `cmp`로 본다.
@MainActor
struct ZoomWaveformTextCapture {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: ["DJC_ZOOM_TEXT_CAPTURE", "DJC_HOME", "DJC_REKORDBOX_DIR"].allSatisfy { environment[$0] != nil }), .serialized,
          arguments: ["light", "dark", "light-grid"])
    func capture(_ variant: String) async throws {
        guard let path = Self.environment["DJC_ZOOM_TEXT_CAPTURE"], let rekordbox = Self.environment["DJC_REKORDBOX_DIR"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let library = URL(filePath: rekordbox)
        try? FileManager.default.removeItem(at: library)
        let fixture = try RekordboxFixture()
        _ = try EditLayoutFixtureCapture.song(bpm: 128, first: 0.35, seconds: 150, to: fixture.audio.appending(path: "sample.wav"))
        var track = TrackSpec(id: "1")
        track.title = "합성 곡 (확대 파형 글자)"
        track.folderPath = library.appending(path: "audio/sample.wav").path
        track.fileType = 11
        track.length = 150
        track.analysisDataPath = "/PIONEER/USBANLZ/test1/ANLZ0000.DAT"
        func bar(_ number: Double) -> Double { 0.35 + (number - 1) * 4 * 60 / 128 }
        func ms(_ number: Double) -> Int { Int((bar(number) * 1000).rounded()) }
        var build = CueSpec(kind: 0, inMsec: ms(23)); build.comment = "Build"
        var drop = CueSpec(kind: 1, inMsec: ms(27)); drop.comment = "Drop"
        var fill = CueSpec(kind: 2, inMsec: ms(28))
        fill.comment = "Fill"; fill.outMsec = ms(28) + 4 * 60_000 / 128; fill.activeLoop = 1; fill.beatLoopSize = 4 << 16 | 1
        var breakdown = CueSpec(kind: 0, inMsec: ms(29.6)); breakdown.comment = "Break"
        track.cues = [build, drop, fill, breakdown, CueSpec(kind: 0, inMsec: ms(44))]
        try fixture.add(track)
        let beats = AnlzBuilder.beats(bpm: 128, first: 350, count: 318)
        try fixture.putAnalysis(for: track, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        try FileManager.default.copyItem(at: fixture.root, to: library)

        let store = LibraryStore(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }))
        await store.load(snapshot: library.appending(path: "master.db"))
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()))
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck, windowFrameRestored: false))
        let window = MemoryCueLimitCapture.UnconstrainedWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: variant == "dark" ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 1400, height: 800))
        window.orderBack(nil)
        defer { window.close() }

        let row = try #require(store.rows.first)
        deck.load(row)
        for _ in 0..<300 where deck.draft == nil || deck.waveform == nil { try await Task.sleep(for: .milliseconds(10)) }
        deck.setZoom(16)
        deck.seek(bar(25) + 0.01)
        if variant == "light-grid" { deck.gridEditing = true }
        try await Task.sleep(for: .milliseconds(1500))
        try save(window, to: folder.appending(path: "\(variant).png"))
    }

    private func save(_ window: NSWindow, to url: URL) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(window.contentView?.superview ?? window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
