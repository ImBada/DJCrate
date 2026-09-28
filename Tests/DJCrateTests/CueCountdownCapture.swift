@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import SwiftUI
import Testing

/// #144 화면 확인용: 합성 곡(128 BPM)을 덱에 올리고 25.1마디에 재생선을 둔 채 44.1마디의 메모리 큐까지 남은 76박을
/// 확대 파형 위 알약(`−N.M Bars`)으로 그려 PNG로 남긴다. 가짜 오디오로(파형은 합성 음원을 분석해 그린다), 창을 다른 앱 뒤에 둔 채(초점을 빼앗지 않게) 찍는다.
/// `DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=<없는 폴더> DJC_CUE_COUNTDOWN_CAPTURE=<폴더> swift test --filter CueCountdownCapture`
/// → `<폴더>/<light|dark>.png`
@MainActor
struct CueCountdownCapture {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: ["DJC_CUE_COUNTDOWN_CAPTURE", "DJC_HOME", "DJC_REKORDBOX_DIR"].allSatisfy { environment[$0] != nil }), .serialized,
          arguments: ["light", "dark"])
    func capture(_ appearance: String) async throws {
        guard let path = Self.environment["DJC_CUE_COUNTDOWN_CAPTURE"], let rekordbox = Self.environment["DJC_REKORDBOX_DIR"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        // 분석 파일은 `DJC_REKORDBOX_DIR/share`에서 찾으므로 그 자리에 사본을 둔다(라이트·다크는 차례로 돈다).
        let library = URL(filePath: rekordbox)
        try? FileManager.default.removeItem(at: library)
        let fixture = try RekordboxFixture()
        _ = try EditLayoutFixtureCapture.song(bpm: 128, first: 0.35, seconds: 150, to: fixture.audio.appending(path: "sample.wav"))
        var track = TrackSpec(id: "1")
        track.title = "합성 곡 (다음 메모리 큐까지 76박)"
        track.folderPath = library.appending(path: "audio/sample.wav").path
        track.fileType = 11
        track.length = 150
        track.analysisDataPath = "/PIONEER/USBANLZ/test1/ANLZ0000.DAT"
        try fixture.add(track)
        let beats = AnlzBuilder.beats(bpm: 128, first: 350, count: 318)
        try fixture.putAnalysis(for: track, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        try FileManager.default.copyItem(at: fixture.root, to: library)

        func bar(_ number: Int) -> Double { 0.35 + Double(number - 1) * 4 * 60 / 128 }
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: [])
        draft.place(EditableCue(kind: .memory, time: bar(44)))
        try CueDraftStore.save(draft)
        defer { CueDraftStore.remove(trackUUID: draft.trackUUID) }
        let drafts = MemoryDrafts()
        drafts.save(draft)
        let store = LibraryStore(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }))
        await store.load(snapshot: library.appending(path: "master.db"))
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(drafts))
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck, windowFrameRestored: false))
        let window = MemoryCueLimitCapture.UnconstrainedWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 1400, height: 800))
        window.orderBack(nil)
        defer { window.close() }

        let row = try #require(store.rows.first)
        deck.load(row)
        for _ in 0..<300 where deck.draft == nil || deck.waveform == nil { try await Task.sleep(for: .milliseconds(10)) }
        deck.seek(bar(25) + 0.01)
        try await Task.sleep(for: .milliseconds(1500))
        try save(window, to: folder.appending(path: "\(appearance).png"))
    }

    private func save(_ window: NSWindow, to url: URL) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(window.contentView?.superview ?? window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
