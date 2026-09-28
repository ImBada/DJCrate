@testable import DJCrate
import AppKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import SwiftUI
import Testing

/// 곡 편집 창 화면 확인용(#134): 합성 곡(128 BPM, 3분, 구간마다 악기가 달라 파형에 모양이 난다)을 가짜 오디오 덱에 올리고
/// 편집 창을 테스트 프로세스의 실제 창으로 띄워 그대로 그려 PNG로 남긴다. 오디오 장치와 화면 기록 권한 없이 찍는다. 실데이터는 쓰지 않는다.
/// `DJC_EDIT_TIMELINE_CAPTURE=<폴더> swift test --filter EditTimelineCapture` → `<폴더>/<light|dark>-<상태>.png`
@MainActor @Suite(.serialized)
struct EditTimelineCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_EDIT_TIMELINE_CAPTURE"] != nil), arguments: ["light", "dark"])
    func capture(_ appearance: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_EDIT_TIMELINE_CAPTURE"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let scene = try await EditCaptureScene()
        defer { scene.remove() }
        let model = scene.model, bars = scene.bars
        model.entries = [BarRange(0, 16), BarRange(1, 16), BarRange(17, 48), BarRange(81, 96)].map { TrackEditModel.Entry(range: $0) }
        // 원곡에서 49~64마디를 고르고, 결과의 세 번째 클립을 고른 상태(#128 캡처와 같다)
        model.select(from: bars.start(ofBar: 49), to: bars.start(ofBar: 65))
        model.finishSelection()
        model.selectedClip = model.entries[2].id
        model.seek(.output, to: (model.edit?.clips[2].outputStart ?? 0) + 6 * bars.barLength)

        let window = scene.window(appearance: appearance)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(1200))
        try Self.save(window, to: folder.appending(path: "\(appearance)-overview.png"))

        // 확대(#134): 원곡은 57마디 둘레를 8배, 결과는 세 번째 클립 끝(17-48 → 81-96 이음새) 둘레를 6배
        let clip = try #require(model.edit?.clips[2])
        model.zoom(.source, by: 8, around: bars.start(ofBar: 57))
        model.zoom(.output, by: 6, around: clip.outputEnd)
        try await Task.sleep(for: .milliseconds(600))
        try Self.save(window, to: folder.appending(path: "\(appearance)-zoomed.png"))

        // 가장자리 다듬기: 세 번째 클립 끝을 잡아 오른쪽으로 2마디 끄는 중(놓기 전). 앱이 앞에 없는 테스트 프로세스에서는
        // 합성 마우스 이벤트가 SwiftUI 제스처에 닿지 않아, 포인터 규칙(`EditPointer`)을 그대로 돌린 상태를 처음 상태로 준다.
        let outputWidth = try #require(window.contentView).bounds.width - 32
        let outputScale = EditLaneScale(model, .output, width: outputWidth)
        let barPoints = outputScale.x(bars.barLength) - outputScale.x(0)
        var trim = EditPointer()
        let edge = clip.outputEnd - 2 * outputScale.secondsPerPoint
        trim.output(model, from: edge, to: edge, inRuler: false, moved: 0, secondsPerPoint: outputScale.secondsPerPoint)
        trim.output(model, from: edge, to: edge + 2.1 * bars.barLength, inRuler: false, moved: 2.1 * barPoints,
                    secondsPerPoint: outputScale.secondsPerPoint)
        #expect(trim.trimming?.range == BarRange(17, 50))
        let trimming = scene.window(appearance: appearance, outputPointer: trim)
        try await Task.sleep(for: .milliseconds(1000))
        try Self.save(trimming, to: folder.appending(path: "\(appearance)-trim.png"))
        trimming.close()
        trim.endOutput(model, at: edge + 2.1 * bars.barLength)
        #expect(model.entries.map(\.range) == [BarRange(0, 16), BarRange(1, 16), BarRange(17, 50), BarRange(81, 96)])

        // 끌어 넣기: 원곡(확대)에서 고른 49-64 안을 눌러 아래 결과 줄(전체)의 두 번째 클립 앞쪽 반으로 끄는 중(놓기 전)
        model.fit(.output)
        model.scroll(.source, to: bars.start(ofBar: 50))
        let second = try #require(model.edit?.clips[1])
        var carry = EditPointer()
        let grab = bars.start(ofBar: 55)
        carry.source(model, from: grab, to: grab, inRuler: false, moved: 0, rise: 6)
        carry.source(model, from: grab, to: grab, inRuler: false, moved: 3, rise: 160, output: second.outputStart + 3 * bars.barLength)
        #expect(carry.mode == .carry && model.insertPreview == EditInsertion(offset: 1, range: BarRange(49, 64)))
        let inserting = scene.window(appearance: appearance, sourcePointer: carry)
        try await Task.sleep(for: .milliseconds(1000))
        try Self.save(inserting, to: folder.appending(path: "\(appearance)-insert.png"))
        inserting.close()
        carry.endSource(model, at: grab)
        #expect(model.entries.map(\.range) == [BarRange(0, 16), BarRange(49, 64), BarRange(1, 16), BarRange(17, 50), BarRange(81, 96)])
        // 편집 메뉴 실행 취소 두 번 → 처음 목록
        for _ in 0..<2 { _ = (window.firstResponder ?? window).tryToPerform(Selector(("undo:")), with: nil) }
        #expect(model.entries.map(\.range) == [BarRange(0, 16), BarRange(1, 16), BarRange(17, 48), BarRange(81, 96)])
    }

    static func save(_ window: NSWindow, to url: URL) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(window.contentView?.superview ?? window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

/// 합성 곡을 가짜 오디오 덱에 올리고(파형은 합성 곡에서 분석) 편집 창 모델을 만든다.
@MainActor
struct EditCaptureScene {
    let home: URL
    let deck: DeckModel
    let model: TrackEditModel
    let bars: BarLayout

    init() async throws {
        home = FileManager.default.temporaryDirectory.appending(path: "djc-edit-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let bpm = 128.0, first = 0.35, seconds = 180.0
        let song = try EditLayoutFixtureCapture.song(bpm: bpm, first: first, seconds: seconds, to: home.appending(path: "편집 화면 시험.wav"))
        let audio = FakeDeckAudio()
        audio.trackLength = seconds
        let drafts = MemoryDrafts()
        let track = Track(id: "1", uuid: "edit-capture", title: "편집 화면 시험", artist: "합성", album: nil, albumArtist: nil,
                          genre: "House", composer: nil, releaseYear: 2025, trackNumber: nil, key: "8A", bpm: bpm,
                          lengthSeconds: Int(seconds), folderPath: song.path, comment: "", importedOn: nil,
                          analysisDataPath: nil, imagePath: nil, isDeleted: false)
        drafts.save(GridDraft(trackUUID: track.uuid, base: [], segments: [GridSegment(start: first, bpm: bpm, firstBeatNumber: 1)]))
        let bar = { (n: Int) in first + Double(n - 1) * 240 / bpm }
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: [])
        for cue in [EditableCue(kind: .hot(0), time: bar(1), name: "A"), EditableCue(kind: .hot(1), time: bar(33), name: "B"),
                    EditableCue(kind: .hot(2), time: bar(73), name: "C"), EditableCue(kind: .memory, time: bar(17))] {
            draft.place(cue)
        }
        drafts.save(draft)
        deck = DeckModel(audio: audio, storage: .memory(drafts), runsAnalysis: false)
        deck.load(TrackRow(track: track, cues: [], playCount: 0))
        for _ in 0..<300 where deck.draft == nil { try await Task.sleep(for: .milliseconds(10)) }
        deck.waveform = try WaveformAnalyzer.analyze(fileAt: song)
        model = try #require(TrackEditModel(deck: deck, audio: FakeEditAudio(), home: home))
        bars = try #require(model.layout)
    }

    func window(appearance: String, sourcePointer: EditPointer = EditPointer(), outputPointer: EditPointer = EditPointer()) -> NSWindow {
        let controller = NSHostingController(rootView: TrackEditView(model: model, deck: deck, sourcePointer: sourcePointer,
                                                                     outputPointer: outputPointer))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "곡 편집 — 편집 화면 시험"
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 980, height: 700))
        // 끄는 중 모습을 따로 띄운 창도 첫 창의 실행 취소(편집 메뉴)에 쌓는다.
        if model.undoManager == nil { model.undoManager = window.undoManager }
        window.orderFront(nil)
        return window
    }

    func remove() {
        model.close()
        try? FileManager.default.removeItem(at: home)
    }
}
