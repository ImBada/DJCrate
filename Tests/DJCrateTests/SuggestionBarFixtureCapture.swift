@testable import DJCrate
import AppKit
import DJCDomain
import DJCTestSupport
import Foundation
import SwiftUI
import Testing

/// 덱 제안 줄 화면 확인용 합성 라이브러리: 덱에 올리면 게인·그리드·키 제안이 모두 뜨는 곡 하나.
/// - 키 칸이 비어 있다(덱이 구한 주 조성을 키 제안으로).
/// - rekordbox 오토게인이 −12dB라 DJCrate가 잰 음량과 크게 다르다(게인 제안).
/// - 음원은 128 BPM인데 rekordbox 그리드는 126 BPM이다(그리드 제안).
/// `DJC_SUGGESTION_FIXTURE=<폴더> swift test --filter SuggestionBarFixtureCapture` → `DJC_REKORDBOX_DIR=<폴더>`, `--db <폴더>/master.db --select 1`
struct SuggestionBarFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_SUGGESTION_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_SUGGESTION_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        let root = URL(filePath: path)
        let first = 0.35, seconds = 90.0
        let audio = try EditLayoutFixtureCapture.song(bpm: 128, first: first, seconds: seconds,
                                                      to: fixture.audio.appending(path: "suggestion-bar.wav"))
        var track = TrackSpec(id: "1")
        track.title = "제안 줄 시험"
        track.folderPath = root.appending(path: "audio/\(audio.lastPathComponent)").path
        track.fileType = 11
        track.length = Int(seconds)
        track.analysisDataPath = "/PIONEER/USBANLZ/suggest1/ANLZ0000.DAT"
        track.gain = (high: 0x3E80, low: 0)   // 0.25 = −12dB
        track.cues = [CueSpec(kind: 1, inMsec: Int(first * 1000))]
        try fixture.add(track)
        let beats = AnlzBuilder.beats(bpm: 126, first: first * 1000, count: Int((seconds - first) * 126 / 60) + 1)
        try fixture.putAnalysis(for: track, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }

    /// 제안 줄만 덱 가운데 열 폭으로 그려 PNG로 남긴다(덱이 스크롤돼 줄이 가려지는 좁은 창·큰 글자 배율 확인용).
    /// `DJC_SUGGESTION_BAR_CAPTURE=<폴더> swift test --filter SuggestionBarFixtureCapture`
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_SUGGESTION_BAR_CAPTURE"] != nil))
    func bar() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_SUGGESTION_BAR_CAPTURE"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let items: [DeckSuggestion] = [
            .gain(0.2, rekordbox: -12.0, mismatch: 14.4),
            .grid(bpm: 128, phaseMilliseconds: 2, isConfident: false),
            .key("11B", fromFileTag: false),
        ]
        let layout = DeckSuggestionBarLayoutTests.self
        let cases: [(name: String, width: Double, scale: Double, dismissed: Set<DeckSuggestion.Kind>)] = [
            ("wide-1x", layout.column(detailWidth: 1192, scale: 1), 1, []),
            ("wide-1x-ignored", layout.column(detailWidth: 1192, scale: 1), 1, [.key]),
            ("min-window-1.5x", layout.column(detailWidth: layout.minimumWindowDetail, scale: 1.5), 1.5, [.key]),
            ("min-detail-1x", layout.narrowestColumn, 1, []),
        ]
        for item in cases {
            let content = DeckSuggestionBarContent(list: DeckSuggestionList(items, dismissed: item.dismissed), gridStatus: nil, isLocked: false)
                .environment(\.textScale, item.scale)
                .frame(width: item.width, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .windowBackgroundColor))
            let controller = NSHostingController(rootView: content)
            let window = MemoryCueLimitCapture.UnconstrainedWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.setContentSize(controller.sizeThatFits(in: CGSize(width: item.width + 16, height: 2000)))
            window.orderBack(nil)
            defer { window.close() }
            window.contentView?.layoutSubtreeIfNeeded()
            let view = try #require(window.contentView)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appending(path: "\(item.name).png"))
        }
    }
}
