@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import SwiftUI
import Testing

/// '폴더에서 찾기…' 화면 확인용(#62). 파일이 없는 곡이 든 합성 사본과 합성 새 폴더(시험이 만든 WAV)로 실제 훑기를 돌려 PNG로 남긴다.
/// 오디오 장치·화면 기록 권한 없이 찍는다. 사용자 라이브러리·음원 폴더는 열지 않는다.
/// `DJC_RELOCATE_CAPTURE=<폴더> DJC_RELOCATE_CAPTURE_STAGE=<before|after> swift test --filter RelocateCapture`
/// → before: `<폴더>/<light|dark>-filter.png`(작업 줄만), after: 거기에 더해 `-review-all`·`-review-ambiguous`·`-review-none`·`-scanning`·`-failed`.
@MainActor
struct RelocateCapture {
    /// 합성 곡 구성. 파일 없는 곡 9곡을 확실 3·애매 4·없음 2로 나누고, 파일이 있는 곡 1곡과 스트리밍 곡 1곡을 섞는다.
    /// 길이는 곡마다 달라(크기도 달라) 서로의 후보가 되지 않는다. 사용자 곡·경로·제목은 쓰지 않는다.
    static func populate(_ fixture: RekordboxFixture, newFolder: URL) throws {
        try fixture.insert("djmdArtist", ["ID": .text("a1"), "Name": .text("합성 아티스트")])
        let fm = FileManager.default
        let albumA = newFolder.appending(path: "합성 앨범 A"), albumB = newFolder.appending(path: "합성 앨범 B")
        let backup = newFolder.appending(path: "합성 백업 사본")
        for dir in [albumA, albumB, backup] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let oldFolder = fixture.root.appending(path: "old-music").path

        func add(_ number: Int, ext: String = "wav", pathRoot: String? = nil, size: Int64? = nil, length: Int? = nil, seconds: Double) throws {
            let name = String(format: "합성 곡 %02d", number)
            var track = TrackSpec(id: String(number))
            track.title = name
            track.artistID = "a1"
            track.fileType = ext == "wav" ? 11 : 5
            track.length = length ?? Int(seconds)
            track.folderPath = "\(pathRoot ?? oldFolder)/\(name).\(ext)"
            try fixture.add(track)
            if let size, size > 0 { try fixture.execute("UPDATE djmdContent SET FileSize = ? WHERE ID = ?", [.int(Int(size)), .text(String(number))]) }
        }
        func wav(_ name: String, in dir: URL, seconds: Double) throws -> Int64 {
            let url = try AudioFixture.wav(seconds: seconds, in: dir, name: name)
            return Int64(try fm.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0)
        }

        // 연결되지 않은 외장 디스크(합성 이름, 이 경로의 볼륨은 만들지 않는다). 3·5·7·8번 곡이 이 디스크에 있었다.
        let disk = "/Volumes/DJ-SSD/Music"
        // 확실: 이름·크기·길이가 같은 파일이 새 폴더에 하나뿐(03은 디스크에 NFD 이름으로 있다)
        for (number, seconds, dir) in [(1, 2.0, albumA), (2, 2.5, albumA), (3, 3.0, albumB)] {
            let size = try wav(String(format: "합성 곡 %02d.wav", number).decomposedStringWithCanonicalMapping, in: dir, seconds: seconds)
            try add(number, pathRoot: number == 3 ? disk : nil, size: size, seconds: seconds)
        }
        // 애매 1: 같은 파일이 두 폴더에 있다
        let size4 = try wav("합성 곡 04.wav", in: albumA, seconds: 3.5)
        _ = try wav("합성 곡 04.wav", in: backup, seconds: 3.5)
        try add(4, size: size4, seconds: 3.5)
        // 애매 2: 곡 행에 길이·크기가 없다(이름만 맞는다)
        _ = try wav("합성 곡 05.wav", in: albumB, seconds: 4.0)
        try add(5, pathRoot: disk, size: nil, length: 0, seconds: 4.0)
        // 애매 3: 파일 이름이 바뀌었다(크기·길이만 맞는다)
        let size6 = try wav("합성 곡 06 (최종).wav", in: albumB, seconds: 4.5)
        try add(6, size: size6, seconds: 4.5)
        // 없음: 어디에도 파일이 없다
        try add(7, pathRoot: disk, size: 1_234_567, seconds: 5.0)
        try add(8, pathRoot: disk, size: 2_345_678, seconds: 5.5)
        // 애매 4: 확장자만 다르다(곡 행은 FLAC, 새 폴더에는 같은 이름의 WAV)
        let size9 = try wav("합성 곡 09.wav", in: albumA, seconds: 6.0)
        try add(9, ext: "flac", size: size9, seconds: 6.0)
        // 파일이 있는 곡과 스트리밍 곡: 목록에 나오지 않아야 한다
        let presentSize = try wav("합성 곡 10.wav", in: fixture.audio, seconds: 1.5)
        var present = TrackSpec(id: "10")
        present.title = "합성 곡 10"
        present.artistID = "a1"
        present.fileType = 11
        present.length = 1
        present.folderPath = fixture.audio.appending(path: "합성 곡 10.wav").path
        try fixture.add(present)
        try fixture.execute("UPDATE djmdContent SET FileSize = ? WHERE ID = '10'", [.int(Int(presentSize))])
        var streaming = TrackSpec(id: "11")
        streaming.title = "합성 스트리밍 곡"
        streaming.artistID = "a1"
        streaming.folderPath = "apple-music:9100011"
        try fixture.add(streaming)
        // 기본 정렬(임포트 최신순)에서 번호 순서대로 보이게 날짜를 하루씩 앞당긴다.
        try fixture.execute("""
            UPDATE djmdContent SET created_at = date('2026-09-20', '-' || (CAST(ID AS INTEGER) - 1) || ' days') || ' 00:00:00.000 +00:00'
            """)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_RELOCATE_CAPTURE"] != nil), .serialized, arguments: ["light", "dark"])
    func capture(_ appearance: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_RELOCATE_CAPTURE"] else { return }
        let stage = ProcessInfo.processInfo.environment["DJC_RELOCATE_CAPTURE_STAGE"] ?? "after"
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let fixture = try RekordboxFixture()
        // 화면에 보이는 폴더 경로가 임시 폴더의 임의 이름이 되지 않게 짧은 합성 경로에 둔다(끝나면 지운다).
        let captureRoot = URL(filePath: "/tmp/djc-synthetic-music")
        try? FileManager.default.removeItem(at: captureRoot)
        defer { try? FileManager.default.removeItem(at: captureRoot) }
        let newFolder = captureRoot.appending(path: "새 음악")
        try Self.populate(fixture, newFolder: newFolder)
        let store = LibraryStore(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }))
        await store.load(snapshot: fixture.database)
        await store.missingFileTask?.value
        let nsAppearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)

        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = nsAppearance
        window.setContentSize(NSSize(width: 1440, height: 900))
        // 사용자 화면에 비치지 않게 화면 밖에 둔다(그려서 비트맵으로 뜨므로 보이지 않아도 된다).
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        defer { window.close() }
        store.sidebar = .filter(.missingFile)
        try await Task.sleep(for: .milliseconds(1500))
        try save(window, to: folder.appending(path: "\(appearance)-filter.png"))
        guard stage == "after" else { return }

        let missing = store.rows.filter(\.fileMissing).map(\.track)
        #expect(missing.count == 9)
        let model = RelocateModel(tracks: missing, snapshot: store.snapshotURL, folder: newFolder)
        model.start()
        let hostWindow = hosted(RelocateView(model: model), appearance: nsAppearance)
        defer { hostWindow.close() }
        try await Task.sleep(for: .milliseconds(150))
        _ = await waitUntil { !model.isScanning }
        #expect(model.phase == .reviewing)
        let counts: [Int] = [model.report.confidentCount, model.report.ambiguousCount, model.report.noneCount]
        #expect(counts == [3, 4, 2])
        // 애매한 곡 하나는 사람이 고른 모양으로 둔다
        if let option = model.report.results.first(where: { $0.id == "4" })?.candidates.first {
            model.choose(option.file.path, for: "4")
        }
        try await Task.sleep(for: .milliseconds(800))
        try save(hostWindow, to: folder.appending(path: "\(appearance)-review-all.png"))
        model.filter = .ambiguous
        try await Task.sleep(for: .milliseconds(500))
        try save(hostWindow, to: folder.appending(path: "\(appearance)-review-ambiguous.png"))
        model.filter = .noCandidate
        try await Task.sleep(for: .milliseconds(500))
        try save(hostWindow, to: folder.appending(path: "\(appearance)-review-none.png"))

        // 훑는 중 화면과 실패 화면: 가짜 입출력으로 상태만 세운다
        let slow = RelocateModel(tracks: missing, snapshot: nil, folder: newFolder, dependencies: RelocateModel.Dependencies(
            loadTargets: { tracks, _ in tracks.map { RelocateTarget(track: $0, fileSize: nil) } },
            scan: { _, _, report in
                report(RelocateScanner.Progress(phase: .reading, audioFiles: 1240, filesToRead: 40, filesRead: 16))
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }))
        slow.start()
        let slowWindow = hosted(RelocateView(model: slow), appearance: nsAppearance)
        defer { slowWindow.close() }
        try await Task.sleep(for: .milliseconds(800))
        try save(slowWindow, to: folder.appending(path: "\(appearance)-scanning.png"))
        slow.cancel()
        let failing = RelocateModel(tracks: missing, snapshot: nil, folder: captureRoot, dependencies: RelocateModel.Dependencies(
            loadTargets: { tracks, _ in tracks.map { RelocateTarget(track: $0, fileSize: nil) } },
            scan: { _, _, _ in throw RelocateScanner.ScanError.protectedFolder }))
        failing.start()
        let failedWindow = hosted(RelocateView(model: failing), appearance: nsAppearance)
        defer { failedWindow.close() }
        try await Task.sleep(for: .milliseconds(500))
        try save(failedWindow, to: folder.appending(path: "\(appearance)-failed.png"))
    }

    private func hosted(_ view: RelocateView, appearance: NSAppearance?) -> NSWindow {
        // 시트처럼 제목 줄 없이 그린다.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 860, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.appearance = appearance
        window.setContentSize(NSSize(width: 860, height: 600))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        return window
    }

    private func save(_ window: NSWindow, to url: URL) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(window.contentView?.superview ?? window.contentView)
        // 뷰를 따로 그리면(cacheDisplay) 선택 줄의 효과 레이어(합성 필터)가 검게 나온다: 캡처할 때만 비강조 선택 색으로 칠한다.
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
