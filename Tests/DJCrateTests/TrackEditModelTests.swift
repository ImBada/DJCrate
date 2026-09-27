@testable import DJCrate
import AVFoundation
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import Testing

/// 소리를 내지 않는 편집 창 재생기. 들린 시간(`elapsed`)은 시험이 정한다.
@MainActor
final class FakeEditAudio: EditAudio {
    var isReady = true
    var sampleRate = 44_100.0
    var isPlaying = false
    var elapsed = 0.0
    var plays: [(items: [EditPlaybackItem], frame: Int64)] = []
    var closed = false

    func prepare(url: URL, done: @escaping @MainActor (Bool) -> Void) { done(isReady) }

    func play(_ items: [EditPlaybackItem], from frame: Int64, volume: Float) -> Bool {
        plays.append((items, frame))
        isPlaying = true
        elapsed = 0
        return true
    }

    func stop() { isPlaying = false }
    func close() { closed = true }
}

/// 덱(가짜 오디오·메모리 저장소)에 합성 WAV 곡을 올리고 편집 창 모델을 만든다.
@MainActor
struct EditHarness {
    let deck: DeckModel
    let audio = FakeDeckAudio()
    let drafts = MemoryDrafts()
    let player = FakeEditAudio()
    let home: URL
    let source: URL

    /// 120 BPM, 첫 다운비트 0.5초, 20.5초 = 0마디 + 10마디
    init(seconds: Double = 20.5, grid: [GridSegment]? = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)],
         cues: [EditableCue] = []) throws {
        home = FileManager.default.temporaryDirectory.appending(path: "djc-edit-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        source = try AudioFixture.wav(seconds: seconds, in: home, name: "원곡.wav")
        audio.trackLength = seconds
        let track = Track(id: "7", uuid: "edit-src", title: "시험 곡", artist: "아티스트", album: nil, albumArtist: nil, genre: "House",
                          composer: nil, releaseYear: 2025, trackNumber: nil, key: "8A", bpm: 120, lengthSeconds: Int(seconds),
                          folderPath: source.path, comment: "코멘트", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
        if let grid { drafts.save(GridDraft(trackUUID: track.uuid, base: [], segments: grid)) }
        if !cues.isEmpty {
            var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: [])
            for cue in cues { draft.place(cue) }
            drafts.save(draft)
        }
        deck = DeckModel(audio: audio, storage: .memory(drafts), runsAnalysis: false)
        deck.load(TrackRow(track: track, cues: [], playCount: 0))
    }

    func loaded() async throws -> TrackEditModel {
        for _ in 0..<200 where deck.draft == nil { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(TrackEditModel(deck: deck, audio: player, home: home))
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

/// 조건이 맞을 때까지(최대 5초) 기다린다.
@MainActor
func until(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    if !condition() { throw FixtureError("5초 안에 끝나지 않음") }
}

func frames(_ url: URL) throws -> Int64 { try AVAudioFile(forReading: url).length }

@MainActor
@Suite("곡 편집 창 모델")
struct TrackEditModelTests {
    @Test func 원곡에서_끌어_고른_구간을_결과에_넣는다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = try await h.loaded()
        #expect(model.blockedReason == nil && model.layout?.count == 10 && model.isAudioReady)
        #expect(model.title == "시험 곡 (Edit)")

        // 곡 머리 쪽에서 4.4초까지 끌면 가까운 마디 줄에 붙어 곡 머리 + 1~2마디. 결과가 비었으니 곡 머리까지 넣는다.
        model.select(from: 0.2, to: 4.4)
        #expect(model.selection == BarRange(0, 2) && model.focus == .source)
        model.finishSelection()
        #expect(model.position(.source) == 0)
        model.addSelection()
        #expect(model.entries.map(\.range) == [BarRange(0, 2)] && model.selectedClip == model.entries[0].id)
        // 고른 클립 뒤에 넣으면 곡 머리는 뺀다(0마디는 맨 앞에만)
        model.select(from: 0.1, to: 2.4)
        model.addSelection()
        #expect(model.entries.map(\.range) == [BarRange(0, 2), BarRange(1, 1)] && model.selectedIndex == 1)
        // 고른 클립이 가운데면 그 뒤에 끼운다
        model.selectedClip = model.entries[0].id
        model.select(from: 12.5, to: 16.5)
        model.addSelection()
        #expect(model.entries.map(\.range) == [BarRange(0, 2), BarRange(7, 8), BarRange(1, 1)])
        // 곡 머리뿐인 구간은 뒤에 넣을 수 없다고 알린다
        model.selectedClip = nil
        model.select(from: 0, to: 0.2)
        #expect(model.selection == BarRange(0, 0))
        model.addSelection()
        #expect(model.entries.count == 3 && model.message?.kind == .warning)
        let edit = try #require(model.edit)
        #expect(model.planError == nil && edit.barCount == 5 && abs(edit.duration - 10.5) < 1e-9 && model.canRender)
        // Esc: 고른 클립 → 고른 구간 순서로 놓는다
        model.selectedClip = model.entries[1].id
        #expect(model.clearSelection() && model.selectedClip == nil && model.selection != nil)
        #expect(model.clearSelection() && model.selection == nil && !model.clearSelection())
    }

    @Test func 창_재생기로_원곡을_재생하고_멈추고_시킹한다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = try await h.loaded()
        // 덱이 재생 중이면 멈추고 창에서 재생한다(두 소리가 겹치지 않게)
        h.deck.togglePlay()
        model.seek(.source, to: 4.5)
        model.play(.source)
        #expect(model.playing == .source && !h.deck.isPlaying)
        // 원곡 그대로 한 칸(인코더 지연 없음), 재생선 프레임부터
        #expect(h.player.plays.last?.items == [EditPlaybackItem(outputFrame: 0, frameCount: 904_050, sourceFrame: 0)])
        #expect(h.player.plays.last?.frame == 198_450)
        h.player.elapsed = 1
        #expect(model.position(.source) == 5.5)
        model.pause()
        #expect(model.playing == nil && !h.player.isPlaying && model.position(.source) == 5.5)
        // 스페이스바는 마지막으로 누른 줄을 재생선부터
        model.togglePlay()
        #expect(model.playing == .source && h.player.plays.last?.frame == 242_550)
        // 재생 중 시킹은 그 자리에서 잇는다
        model.seek(.source, to: 10)
        #expect(model.playing == .source && h.player.plays.count == 3 && h.player.plays.last?.frame == 441_000)
        // 재생선을 끄는 동안은 멈췄다가 손을 떼면 그 자리에서 잇는다
        model.scrub(.source, to: 12)
        #expect(model.playing == nil && model.position(.source) == 12)
        model.endScrub()
        #expect(model.playing == .source && h.player.plays.last?.frame == 529_200)
        // ←→는 마디 줄로(1마디 2초, 첫 다운비트 0.5초)
        model.step(bars: 1)
        #expect(model.position(.source) == 12.5 && h.player.plays.last?.frame == 551_250)
        model.pause()
        model.step(bars: -4)
        #expect(model.position(.source) == 4.5)
        model.jump(toEnd: true)
        #expect(model.position(.source) == 20.5)
        // 끝에서 재생하면 처음부터
        model.play(.source)
        #expect(h.player.plays.last?.frame == 0)
        model.close()
        #expect(h.player.closed && model.playing == nil)
    }

    @Test func 결과를_어디서든_렌더하지_않고_재생한다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = try await h.loaded()
        #expect(!model.canPlay(.output))
        model.entries = [BarRange(1, 2), BarRange(1, 2)].map { TrackEditModel.Entry(range: $0) }
        let edit = try #require(model.edit)
        model.seek(.output, to: 3)
        model.play(.output)
        // 렌더러와 같은 예약표(조각·이음새 섞기)를 결과 3초 프레임부터
        #expect(h.player.plays.last?.items == TrackEdit.playbackItems(edit.frames(sampleRate: 44_100, sourceOffset: 0)))
        #expect(h.player.plays.last?.frame == 132_300 && model.focus == .output)
        // 끝까지 들으면 멈추고 재생선은 끝에
        h.player.elapsed = 6
        try await until { model.playing == nil }
        #expect(model.position(.output) == 8 && !h.player.isPlaying)
        // 결과를 고치면 재생을 멈춘다(바뀐 결과를 다시 재생)
        model.play(.output)
        #expect(h.player.plays.last?.frame == 0)
        model.entries.append(TrackEditModel.Entry(range: BarRange(9, 10)))
        #expect(model.playing == nil && !h.player.isPlaying)
    }

    @Test func 이음새_앞뒤_2마디를_듣고_멈춘다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = try await h.loaded()
        model.entries = [BarRange(1, 4), BarRange(1, 4)].map { TrackEditModel.Entry(range: $0) }
        model.auditionSeam(1)
        // 이음새 8초: 4초부터 12초까지
        #expect(model.playing == .output && model.auditioning == 1 && h.player.plays.last?.frame == 176_400)
        h.player.elapsed = 8.5
        try await until { model.playing == nil }
        #expect(model.position(.output) == 12 && model.auditioning == nil)
        // 조각이 2마디보다 짧으면 그 조각 안에서
        model.entries = [BarRange(1, 1), BarRange(5, 5)].map { TrackEditModel.Entry(range: $0) }
        model.auditionSeam(1)
        #expect(h.player.plays.last?.frame == 0)
        h.player.elapsed = 5
        try await until { model.playing == nil }
        #expect(model.position(.output) == 4)
        // 덱을 재생하면 창의 재생은 멈춘다(뷰가 pause를 부른다)
        model.auditionSeam(9)
        #expect(model.playing == nil)
    }

    @Test func 자르고_복제하고_옮기고_지우고_실행_취소한다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = try await h.loaded()
        let undo = UndoManager()
        model.undoManager = undo
        model.entries = [TrackEditModel.Entry(range: BarRange(1, 8))]
        #expect(!model.canUndo)

        // 재생선 5.2초 → 가장 가까운 마디 줄(6초, 4마디)에서 자르고 오른쪽을 고른다
        model.seek(.output, to: 5.2)
        model.splitAtPlayhead()
        #expect(model.entries.map(\.range) == [BarRange(1, 3), BarRange(4, 8)] && model.selectedIndex == 1)
        #expect(model.position(.output) == 6 && model.canUndo && undo.undoActionName == "자르기")
        // 클립 끝이 더 가까우면 자르지 않고 알린다
        model.seek(.output, to: 5.9)
        model.splitAtPlayhead()
        #expect(model.entries.count == 2 && model.message?.kind == .warning)

        model.duplicateSelected()
        #expect(model.entries.map(\.range) == [BarRange(1, 3), BarRange(4, 8), BarRange(4, 8)] && model.selectedIndex == 2)
        let copy = try #require(model.selectedClip)
        // 끌어서 맨 앞으로(놓을 자리 = 앞 클립 수)
        model.moveClip(copy, toOffset: 0)
        #expect(model.entries.map(\.range) == [BarRange(4, 8), BarRange(1, 3), BarRange(4, 8)] && model.selectedIndex == 0)
        model.removeSelected()
        #expect(model.entries.map(\.range) == [BarRange(1, 3), BarRange(4, 8)] && model.selectedIndex == 0)
        // 앞뒤 단추·마디 칸
        model.move(model.entries[0].id, by: 1)
        #expect(model.entries.map(\.range) == [BarRange(4, 8), BarRange(1, 3)])
        model.setLast(model.entries[0].id, 99)
        #expect(model.entries[0].range == BarRange(4, 10))

        // 실행 취소 6번(마디·앞뒤·지우기·옮기기·복제·자르기) → 처음, 실행 복귀 → 자른 모양
        for _ in 0..<6 { undo.undo() }
        #expect(model.entries.map(\.range) == [BarRange(1, 8)] && !model.canUndo && model.canRedo)
        undo.redo()
        #expect(model.entries.map(\.range) == [BarRange(1, 3), BarRange(4, 8)] && model.selectedIndex == 1)
        // 창을 닫으면 이 창의 실행 취소를 비운다
        model.close()
        #expect(!undo.canUndo && !undo.canRedo)
    }

    @Test func 규칙에_맞지_않는_목록도_타임라인에_그려_고칠_수_있다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = try await h.loaded()
        model.entries = [BarRange(1, 2), BarRange(0, 2)].map { TrackEditModel.Entry(range: $0) }
        #expect(model.edit == nil && model.planError?.contains("0마디") == true && !model.canRender && !model.canPlay(.output))
        #expect(model.clipLayout.count == 2)
        model.moveClip(model.entries[1].id, toOffset: 0)
        #expect(model.planError == nil && model.edit != nil)
    }

    @Test func 원곡_줄_누르기와_끌기() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = try await h.loaded()
        var pointer = EditPointer()
        // 파형을 조금만 움직였다 떼면 누르기: 재생선만 옮긴다
        pointer.source(model, from: 8.7, to: 8.8, inRuler: false, moved: 2)
        pointer.endSource(model, at: 8.8)
        #expect(model.position(.source) == 8.8 && model.selection == nil && model.focus == .source)
        // 끌면 마디 구간을 고르고, 떼면 재생선을 구간 처음에
        pointer.source(model, from: 4.4, to: 5, inRuler: false, moved: 3)
        pointer.source(model, from: 4.4, to: 8.6, inRuler: false, moved: 40)
        #expect(model.selection == BarRange(3, 4))
        pointer.source(model, from: 4.4, to: 10.4, inRuler: false, moved: 60)
        pointer.endSource(model, at: 10.4)
        #expect(model.selection == BarRange(3, 5) && model.position(.source) == 4.5)
        // 눈금을 끌면 재생 중에는 멈췄다가 손을 떼면 그 자리에서 잇는다
        model.play(.source)
        pointer.source(model, from: 12, to: 12, inRuler: true, moved: 0)
        pointer.source(model, from: 12, to: 14, inRuler: true, moved: 20)
        #expect(model.playing == nil && model.position(.source) == 14 && model.selection == BarRange(3, 5))
        pointer.endSource(model, at: 14)
        #expect(model.playing == .source && h.player.plays.last?.frame == 617_400)
    }

    @Test func 결과_줄_누르기와_클립_끌기() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = try await h.loaded()
        model.entries = [BarRange(1, 2), BarRange(5, 6), BarRange(9, 10)].map { TrackEditModel.Entry(range: $0) }
        let ids = model.entries.map(\.id)
        var pointer = EditPointer()
        // 클립을 누르면 고르고 재생선을 그 자리로
        pointer.output(model, from: 5, to: 5, inRuler: false, moved: 0)
        pointer.endOutput(model, at: 5)
        #expect(model.selectedClip == ids[1] && model.position(.output) == 5 && model.focus == .output)
        // 세 번째 클립(8~12초)을 맨 앞(가운데 2초 앞)으로 끌어 놓는다. 끄는 동안 놓을 자리를 보여 준다.
        pointer.output(model, from: 10, to: 9.5, inRuler: false, moved: 3)
        #expect(pointer.dragging == nil)
        pointer.output(model, from: 10, to: 1, inRuler: false, moved: 90)
        #expect(pointer.dragging == ids[2] && pointer.dropOffset == 0)
        pointer.endOutput(model, at: 1)
        #expect(model.entries.map(\.id) == [ids[2], ids[0], ids[1]] && model.selectedClip == ids[2] && pointer.dragging == nil)
        // 빈 곳(결과 밖)을 누르면 고른 클립을 놓는다
        pointer.output(model, from: 30, to: 30, inRuler: false, moved: 0)
        pointer.endOutput(model, at: 30)
        #expect(model.selectedClip == nil)
        // 눈금은 재생선만
        pointer.output(model, from: 3, to: 7, inRuler: true, moved: 40)
        pointer.endOutput(model, at: 7)
        #expect(model.position(.output) == 7 && model.entries.map(\.id) == [ids[2], ids[0], ids[1]])
    }

    @Test func 편집_창_단축키는_키_위치로_정한다() async throws {
        #expect(TrackEditCommand(keyCode: 49, modifiers: []) == .togglePlay)
        #expect(TrackEditCommand(keyCode: 124, modifiers: [.numericPad, .function]) == .step(1))
        #expect(TrackEditCommand(keyCode: 123, modifiers: .shift) == .step(-4))
        #expect(TrackEditCommand(keyCode: 11, modifiers: .command) == .split && TrackEditCommand(keyCode: 11, modifiers: []) == nil)
        #expect(TrackEditCommand(keyCode: 2, modifiers: .command) == .duplicateClip)
        #expect(TrackEditCommand(keyCode: 51, modifiers: []) == .removeClip && TrackEditCommand(keyCode: 36, modifiers: []) == .addSelection)
        // ⌘Z는 편집 메뉴(창의 실행 취소)에 맡긴다
        #expect(TrackEditCommand(keyCode: 6, modifiers: .command) == nil)

        let h = try EditHarness()
        defer { h.remove() }
        let model = try await h.loaded()
        // 고른 것이 없으면 키를 넘긴다(다른 곳에서 경고음·기본 동작)
        #expect(!TrackEditCommand.removeClip.perform(on: model) && !TrackEditCommand.addSelection.perform(on: model))
        #expect(!TrackEditCommand.split.perform(on: model) && !TrackEditCommand.clearSelection.perform(on: model))
        #expect(TrackEditCommand.togglePlay.perform(on: model) && model.playing == .source)
    }

    @Test func 변속_곡과_그리드_없는_곡은_이유와_할_일을_보여_주고_막는다() async throws {
        let tempo = try EditHarness(grid: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1),
                                           GridSegment(start: 10.5, bpm: 124, firstBeatNumber: 1)])
        defer { tempo.remove() }
        let changing = try await tempo.loaded()
        #expect(changing.blockedReason?.contains("템포 구간 2개") == true && changing.layout == nil)
        changing.select(from: 4.6, to: 8.6)
        changing.addSelection()
        #expect(changing.entries.isEmpty && !changing.canRender && !changing.canPlay(.source))

        let bare = try EditHarness(grid: nil)
        defer { bare.remove() }
        let none = try await bare.loaded()
        #expect(none.blockedReason == "그리드가 없습니다. 덱에서 추정 그리드를 적용하거나 rekordbox에서 트랙 분석을 한 뒤 편집하세요")
    }

    @Test func 렌더해서_추가한_곡에_넣는다() async throws {
        let h = try EditHarness(cues: [EditableCue(kind: .memory, time: 0.5), EditableCue(kind: .hot(0), time: 2.5, name: "A"),
                                       EditableCue(kind: .hot(1), time: 12.5, name: "빠짐")])
        defer { h.remove() }
        let model = try await h.loaded()
        model.entries = [BarRange(0, 4), BarRange(1, 4)].map { TrackEditModel.Entry(range: $0) }
        #expect(model.carry?.placed.count == 2 && model.carry?.dropped.count == 1)
        model.title = "시험 곡 (Extended)"
        var reported: [StagedTrack] = []
        model.onStaged = { reported.append($0) }
        model.render()
        #expect(model.renderProgress != nil)
        try await until { model.staged != nil }
        #expect(model.renderProgress == nil && model.message?.kind == .success)

        // 결과 파일은 DJCrate 데이터 폴더의 edits 아래, 원본 길이 그대로(0.5 + 16초)
        let staged = try #require(model.staged)
        let output = h.home.appending(path: "edits/시험 곡 (Extended).wav")
        #expect(staged.path == output.path.precomposedStringWithCanonicalMapping && reported == [staged])
        #expect(try frames(output) == Int64((16.5 * 44_100).rounded()))
        #expect(StagingStore.load(url: h.home.appending(path: "staged.json")).map(\.uuid) == [staged.uuid])
        // 변환한 그리드·옮긴 큐·원곡 태그 초안
        let grid = try #require(GridDraftStore.load(trackUUID: staged.uuid, directory: h.home.appending(path: "grid-drafts")))
        #expect(grid.segments == [try #require(model.edit).outputGrid])
        let cues = try #require(CueDraftStore.load(trackUUID: staged.uuid, directory: h.home.appending(path: "cue-drafts")))
        #expect(cues.cues.map(\.time) == [0.5, 2.5] && cues.cues.map(\.kind) == [.memory, .hot(0)])
        let tags = try #require(TagDraftStore.load(trackUUID: staged.uuid, directory: h.home.appending(path: "tag-drafts")))
        #expect(tags.fields.title == "시험 곡 (Extended)" && tags.fields.artist == "아티스트" && tags.fields.genre == "House")
        // 원본은 그대로
        #expect(try frames(h.source) == Int64(20.5 * 44_100))

        // 같은 제목으로 또 렌더하면 파일 이름에 번호를 붙인다
        model.render()
        try await until { model.staged?.uuid != staged.uuid && model.renderProgress == nil }
        #expect(model.staged?.path.hasSuffix("edits/시험 곡 (Extended) 2.wav") == true)
    }

    @Test func 렌더를_취소하면_파일을_남기지_않는다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = try await h.loaded()
        model.entries = [BarRange(1, 10), BarRange(1, 10)].map { TrackEditModel.Entry(range: $0) }
        model.render()
        model.cancelRender()
        try await until { model.renderProgress == nil }
        #expect(model.staged == nil && model.message?.kind == .warning)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: h.home.appending(path: "edits").path)) ?? []
        #expect(left.isEmpty && !FileManager.default.fileExists(atPath: h.home.appending(path: "staged.json").path))
    }

    @Test func 파일_이름에_못_쓰는_글자는_바꾼다() {
        #expect(TrackEditModel.fileName(for: "A/B: C (Edit)") == "A-B- C (Edit)")
        #expect(TrackEditModel.fileName(for: "  ") == "Edit")
        #expect(TrackEditModel.fileName(for: ".숨김") == "숨김")
    }
}
