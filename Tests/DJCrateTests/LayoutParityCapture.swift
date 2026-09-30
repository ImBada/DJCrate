@testable import DJCrate
import AppKit
import DJCDomain
import DJCAnalysis
import DJCStorage
import DJCTestSupport
import Foundation
import SwiftUI
import Testing

/// #138 화면 확인용: 합성 곡(128 BPM, 메모리 큐 포함)을 덱에 올린 주 창을 창 폭마다 PNG로 남긴다.
/// 배치를 고친 뒤에도 덱·목록 모양이 그대로인지 고치기 전 그림과 화소 단위로 견주는 데 쓴다. 가짜 오디오, 창은 다른 앱 뒤에 둔다.
/// `DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=<없는 폴더> DJC_LAYOUT_PARITY_CAPTURE=<폴더> swift test --filter LayoutParityCapture`
/// → `<폴더>/<light|dark>-<글자 배율>-<순서>-<창 폭>.png`
@MainActor
struct LayoutParityCapture {
    nonisolated static let environment = ProcessInfo.processInfo.environment
    nonisolated static let scales = environment["DJC_LAYOUT_CAPTURE_SCALE"].flatMap(Double.init).map { [$0] } ?? [1.0, 1.3, 1.5]

    @Test(.enabled(if: ["DJC_LAYOUT_PARITY_CAPTURE", "DJC_HOME", "DJC_REKORDBOX_DIR"].allSatisfy { environment[$0] != nil }), .serialized,
          arguments: ["light", "dark"], scales)
    func capture(_ appearance: String, _ textScale: Double) async throws {
        guard let path = Self.environment["DJC_LAYOUT_PARITY_CAPTURE"], let rekordbox = Self.environment["DJC_REKORDBOX_DIR"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let settingNames = [SettingKeys.sidebarVisible.name, SettingKeys.showTagEditor.name, SettingKeys.sheetMode.name, SettingKeys.waveformHeight.name, SettingKeys.cueListFilter.name]
        let savedSettings = settingNames.map { UserDefaults.standard.object(forKey: $0) }
        UserDefaults.standard.set(true, forKey: SettingKeys.sidebarVisible.name)
        UserDefaults.standard.set(false, forKey: SettingKeys.showTagEditor.name)
        UserDefaults.standard.set(false, forKey: SettingKeys.sheetMode.name)
        let requestedHeight = Self.environment["DJC_LAYOUT_CAPTURE_HEIGHT"].flatMap(Double.init) ?? 150
        UserDefaults.standard.set(requestedHeight, forKey: SettingKeys.waveformHeight.name)
        UserDefaults.standard.set(CueListFilter.all.rawValue, forKey: SettingKeys.cueListFilter.name)
        defer {
            for (key, value) in zip(settingNames, savedSettings) { UserDefaults.standard.set(value, forKey: key) }
        }
        let library = URL(filePath: rekordbox)
        try FileManager.default.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(!FileManager.default.fileExists(atPath: library.path), "새 합성 라이브러리 폴더가 필요합니다")
        let fixture = try RekordboxFixture()
        _ = try EditLayoutFixtureCapture.song(bpm: 128, first: 0.35, seconds: 150, to: fixture.audio.appending(path: "sample.wav"))
        var track = TrackSpec(id: "1")
        track.title = "합성 곡 (배치 확인)"
        track.folderPath = library.appending(path: "audio/sample.wav").path
        track.fileType = 11
        track.length = 150
        track.analysisDataPath = "/PIONEER/USBANLZ/test1/ANLZ0000.DAT"
        try fixture.add(track)
        let beats = AnlzBuilder.beats(bpm: 128, first: 350, count: 318)
        try fixture.putAnalysis(for: track, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        try FileManager.default.copyItem(at: fixture.root, to: library)
        defer { try? FileManager.default.removeItem(at: library) }

        func bar(_ number: Int) -> Double { 0.35 + Double(number - 1) * 4 * 60 / 128 }
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: [])
        for number in [9, 17, 25, 33, 41] { draft.place(EditableCue(kind: .memory, time: bar(number))) }
        try CueDraftStore.save(draft)
        defer { CueDraftStore.remove(trackUUID: draft.trackUUID) }
        let drafts = MemoryDrafts()
        drafts.save(draft)
        let store = LibraryStore(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }))
        await store.load(snapshot: library.appending(path: "master.db"))
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(drafts), runsAnalysis: false)
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck, windowFrameRestored: false).environment(\.textScale, textScale))
        let window = MemoryCueLimitCapture.UnconstrainedWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 1700, height: 900))
        window.orderBack(nil)
        defer { window.close() }

        let row = try #require(store.rows.first)
        deck.load(row)
        for _ in 0..<300 where deck.draft == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(deck.draft != nil && deck.hasRekordboxGrid, "합성 그리드가 있어야 배치를 비교할 수 있습니다")
        deck.waveform = try WaveformCache.load(fileAt: library.appending(path: "audio/sample.wav"), key: row.track.uuid)
        deck.seek(bar(25))
        // 큐 목록 폭 단계와 컨트롤 줄바꿈을 확인하고, 넓은 폭으로 돌아오는 배치도 찍는다.
        for (index, width) in [1700, 1440, 1300, 1200, 1100, 1300, 1700].enumerated() {
            window.setContentSize(NSSize(width: Double(width), height: 900))
            try await Task.sleep(for: .milliseconds(1200))
            print("CAPTURE_STATE", appearance, textScale, "requested", requestedHeight, "width", width, "grid", deck.hasRekordboxGrid)
            try save(window, to: folder.appending(path: "\(appearance)-\(textScale)-\(index)-\(width).png"))
        }
    }

    private func save(_ window: NSWindow, to url: URL) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(window.contentView?.superview ?? window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
