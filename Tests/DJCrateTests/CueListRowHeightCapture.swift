@testable import DJCrate
import AppKit
import DJCDomain
import SwiftUI
import Testing

/// #152 화면 확인용: 큐 목록만 창에 올려 첫 곡의 모습과, 곡이 바뀌어 큐가 통째로 교체된 뒤의 모습을 PNG로 남긴다.
/// 가짜 오디오·메모리 저장소를 쓰고, 창은 다른 앱 뒤에 둔 채(초점을 빼앗지 않게) 찍는다.
/// `DJC_HOME=$(mktemp -d) DJC_CUE_LIST_CAPTURE=<폴더> swift test --filter CueListRowHeightCapture`
/// → `<폴더>/<light|dark>-<first|second>.png`
@MainActor
struct CueListRowHeightCapture {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: ["DJC_CUE_LIST_CAPTURE", "DJC_HOME"].allSatisfy { environment[$0] != nil }), .serialized,
          arguments: ["light", "dark"])
    func capture(_ appearance: String) async throws {
        guard let path = Self.environment["DJC_CUE_LIST_CAPTURE"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let firstSong = [
            Cue(id: "a1", contentID: "1", kind: 0, inMsec: 350, name: "CUE(Auto)", colorTableIndex: nil),
            Cue(id: "a2", contentID: "1", kind: 1, inMsec: 15_350, name: "인트로", colorTableIndex: nil),
            Cue(id: "a3", contentID: "1", kind: 2, inMsec: 45_350, name: "드롭", colorTableIndex: nil,
                outMsec: 49_100, activeLoop: 1, beatLoopSize: 8 << 16 | 1),
            Cue(id: "a4", contentID: "1", kind: 0, inMsec: 75_350, name: "브레이크", colorTableIndex: nil),
            Cue(id: "a5", contentID: "1", kind: 3, inMsec: 105_350, name: "아웃트로", colorTableIndex: nil),
        ]
        let h = try DeckHarness(cues: firstSong)
        try await h.loaded()
        h.deck.draft?.place(EditableCue(kind: .memory, time: 60, name: "새 메모리 큐"))

        let view = CueListView(deck: h.deck).environment(\.textScale, 1).padding(12).frame(width: 440, height: 300)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(1200))
        try save(window, to: folder.appending(path: "\(appearance)-first.png"))

        // 다른 곡을 올린 것처럼 큐 id가 모두 다른 초안으로 바꾼다.
        var next = CueDraft(trackUUID: "track-2", rekordboxCues: [
            Cue(id: "b1", contentID: "2", kind: 1, inMsec: 8_000, name: "킥", colorTableIndex: nil),
            Cue(id: "b2", contentID: "2", kind: 0, inMsec: 32_000, name: "", colorTableIndex: nil),
            Cue(id: "b3", contentID: "2", kind: 2, inMsec: 64_000, name: "빌드업", colorTableIndex: nil,
                outMsec: 68_000, activeLoop: 0, beatLoopSize: 8 << 16 | 1),
            Cue(id: "b4", contentID: "2", kind: 0, inMsec: 96_000, name: "CUE(Auto)", colorTableIndex: nil),
            Cue(id: "b5", contentID: "2", kind: 3, inMsec: 128_000, name: "", colorTableIndex: nil),
        ])
        next.place(EditableCue(kind: .memory, time: 80, name: "새 메모리 큐"))
        h.deck.draft = next
        try await Task.sleep(for: .milliseconds(1200))
        try save(window, to: folder.appending(path: "\(appearance)-second.png"))
    }

    private func save(_ window: NSWindow, to url: URL) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(window.contentView?.superview ?? window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
