@testable import DJCrate
import AVFoundation
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import Testing

/// 소리를 내지 않는 미리 듣기 재생기
@MainActor
final class FakePreviewPlayer: EditPreviewPlayer {
    var played: [URL] = []
    var isPlaying = false
    var currentTime = 0.0

    func play(_ url: URL, volume: Float) throws {
        played.append(url)
        isPlaying = true
    }

    func stop() { isPlaying = false }
}

/// 덱(가짜 오디오·메모리 저장소)에 합성 WAV 곡을 올리고 편집 창 모델을 만든다.
@MainActor
struct EditHarness {
    let deck: DeckModel
    let audio = FakeDeckAudio()
    let drafts = MemoryDrafts()
    let player = FakePreviewPlayer()
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
        return try #require(TrackEditModel(deck: deck, player: player, home: home))
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
    @Test func 덱_재생_위치에서_N마디를_쌓고_출력을_센다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = try await h.loaded()
        #expect(model.blockedReason == nil && model.layout?.count == 10)
        #expect(model.title == "시험 곡 (Edit)")

        // 첫 다운비트 앞: 목록이 비었으니 곡 머리까지
        model.barsToAdd = 2
        h.deck.seek(0.2)
        model.addHere()
        // 3마디 안(4.6초) → 3~4마디: 앞 구간과 원본에서 이어져 이음새가 아니다
        h.deck.seek(4.6)
        model.addHere()
        // 다시 1마디부터: 이음새 하나
        h.deck.seek(0.6)
        model.addHere()
        #expect(model.entries.map(\.range) == [BarRange(0, 2), BarRange(3, 4), BarRange(1, 2)])
        #expect(model.seams == [EditSeam(index: 2, preview: [BarRange(3, 4), BarRange(1, 2)])])
        let edit = try #require(model.edit)
        #expect(model.planError == nil && edit.barCount == 6 && abs(edit.duration - 12.5) < 1e-9)
        #expect(model.canRender)

        // 곡 끝에서는 고를 마디가 없다고 알린다
        h.deck.seek(20.5)
        model.addHere()
        #expect(model.entries.count == 3 && model.message?.kind == .warning)
    }

    @Test func 덱에_다른_곡이_있으면_창에서_찍은_위치를_쓴다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = try await h.loaded()
        model.place(at: 8.7)
        // 같은 곡이면 덱도 그 자리로
        #expect(h.deck.playhead == 8.7)
        h.deck.load(nil)
        model.place(at: 12.6)
        model.barsToAdd = 1
        model.addHere()
        #expect(model.entries.map(\.range) == [BarRange(7, 7)])
    }

    @Test func 구간_순서를_바꾸고_지우고_마디를_고친다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = try await h.loaded()
        model.entries = [BarRange(1, 2), BarRange(5, 6), BarRange(9, 10)].map { TrackEditModel.Entry(range: $0) }
        let ids = model.entries.map(\.id)
        model.move(ids[2], by: -1)
        #expect(model.entries.map(\.range) == [BarRange(1, 2), BarRange(9, 10), BarRange(5, 6)])
        // 끝에서 더 옮기면 그대로
        model.move(ids[0], by: -1)
        #expect(model.entries.map(\.id) == [ids[0], ids[2], ids[1]])
        model.remove(ids[0])
        model.duplicate(ids[1])
        #expect(model.entries.map(\.range) == [BarRange(9, 10), BarRange(5, 6), BarRange(5, 6)])
        #expect(model.entries[1].id == ids[1] && model.entries[2].id != ids[1])

        // 시작·끝 마디는 곡 안, 시작 ≤ 끝으로만 고쳐진다
        model.setFirst(ids[2], 3)
        model.setLast(ids[2], 99)
        #expect(model.entries[0].range == BarRange(3, 10))
        model.setFirst(ids[2], 12)
        #expect(model.entries[0].range == BarRange(10, 10))
        model.setLast(ids[2], 4)
        #expect(model.entries[0].range == BarRange(10, 10))

        // 0마디(곡 머리)는 맨 앞에만: 가운데 두면 이유를 보여 주고 렌더를 막는다
        model.setFirst(ids[1], 0)
        #expect(model.entries[1].range == BarRange(0, 6))
        #expect(model.edit == nil && model.planError?.contains("0마디") == true && !model.canRender)
        model.remove(model.entries[0].id)
        #expect(model.planError == nil && model.edit?.barCount == 8)
        // 다 지우면 렌더할 것이 없다
        for entry in model.entries { model.remove(entry.id) }
        #expect(model.edit == nil && model.planError == nil && !model.canRender)
    }

    @Test func 변속_곡과_그리드_없는_곡은_이유와_할_일을_보여_주고_막는다() async throws {
        let tempo = try EditHarness(grid: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1),
                                           GridSegment(start: 10.5, bpm: 124, firstBeatNumber: 1)])
        defer { tempo.remove() }
        let changing = try await tempo.loaded()
        #expect(changing.blockedReason?.contains("템포 구간 2개") == true && changing.layout == nil)
        tempo.deck.seek(4.6)
        changing.addHere()
        #expect(changing.entries.isEmpty && !changing.canRender)

        let bare = try EditHarness(grid: nil)
        defer { bare.remove() }
        let none = try await bare.loaded()
        #expect(none.blockedReason == "그리드가 없습니다. 덱에서 추정 그리드를 적용하거나 rekordbox에서 트랙 분석을 한 뒤 편집하세요")
    }

    @Test func 이음새와_전체를_짧게_렌더해_미리_듣는다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = try await h.loaded()
        model.entries = [BarRange(1, 4), BarRange(1, 4)].map { TrackEditModel.Entry(range: $0) }
        // 덱이 재생 중이면 멈추고 듣는다
        h.deck.togglePlay()
        #expect(h.deck.isPlaying)
        model.previewSeam(1)
        #expect(model.preview == .seam(1) && !h.deck.isPlaying)
        try await until { !h.player.played.isEmpty }
        // 이음새 앞 2마디 + 뒤 2마디 = 8초, DJCrate 데이터 폴더 아래 임시 파일
        let seam = try #require(h.player.played.last)
        #expect(seam.path.hasPrefix(h.home.appending(path: "edit-previews").path))
        #expect(try frames(seam) == 8 * 44_100 && !model.isPreparingPreview)
        model.stopPreview()
        #expect(model.preview == nil && !h.player.isPlaying)

        model.previewAll()
        try await until { h.player.played.count == 2 }
        #expect(try frames(h.player.played[1]) == 16 * 44_100 && model.preview == .all)
        // 같은 편집을 다시 들으면 렌더한 파일을 다시 쓴다
        model.previewAll()
        try await until { h.player.played.count == 3 }
        #expect(h.player.played[2] == h.player.played[1])
        // 끝까지 들으면 미리 듣기 표시를 끈다
        h.player.isPlaying = false
        try await until { model.preview == nil }
        // 구간을 바꿔 다시 전체를 들으면 이전 전체 미리 듣기 파일은 지운다(긴 WAV가 쌓이지 않게)
        let oldAll = h.player.played[1]
        model.entries.append(TrackEditModel.Entry(range: BarRange(9, 10)))
        model.previewAll()
        try await until { h.player.played.count == 4 }
        #expect(try frames(h.player.played[3]) == 20 * 44_100)
        #expect(!FileManager.default.fileExists(atPath: oldAll.path) && FileManager.default.fileExists(atPath: seam.path))
        model.stopPreview()

        // 창을 닫으면 임시 파일을 지운다
        model.close()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: h.home.appending(path: "edit-previews").path)) ?? []
        #expect(left.isEmpty)
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
