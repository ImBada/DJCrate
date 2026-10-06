@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import Testing

/// Flip 결과 창 모델: 렌더 → 추가한 곡에 넣기, 버리기 전 확인. 덱은 가짜 오디오·메모리 저장소(`EditHarness`, 20.5초 120 BPM).
@MainActor
@Suite("Flip 결과 창 모델")
struct FlipModelTests {
    func span(_ start: Double, _ end: Double) -> PlayedSpan { PlayedSpan(start: start, end: end) }

    /// 8.5초(1박)에서 4.5초(1박)로 한 번 점프: 출력 8.5 + 16 = 24.5초
    func recording() -> FlipRecording {
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(0, 8.5), span(4.5, 12)], continuing: false))
        return recording
    }

    func model(_ h: EditHarness) async throws -> FlipModel {
        for _ in 0..<200 where h.deck.draft == nil { try await Task.sleep(for: .milliseconds(10)) }
        return try FlipModel(deck: h.deck, recording: recording(), audio: h.player, home: h.home)
    }

    @Test func 렌더해서_그리드·큐·태그_초안과_함께_추가한_곡에_넣는다() async throws {
        let h = try EditHarness(cues: [EditableCue(kind: .hot(0), time: 6.5, name: "드롭")])
        defer { h.remove() }
        let model = try await model(h)
        // 박 줄·번호가 이어지는 점프라 원곡 그리드 한 구간(곡 처음 0초 = 4박)
        #expect(model.grid == [GridSegment(start: 0, bpm: 120, firstBeatNumber: 4)] && model.gridNotice == nil)
        var reported: [StagedTrack] = []
        model.onStaged = { reported.append($0) }
        model.render()
        #expect(model.renderProgress != nil && !model.canRender)
        try await until { model.staged != nil }
        #expect(model.renderProgress == nil && model.message?.kind == .success)
        let staged = try #require(model.staged)
        #expect(reported == [staged])
        let output = h.home.appending(path: "edits/시험 곡 (Flip).wav")
        #expect(staged.path == output.path.precomposedStringWithCanonicalMapping)
        #expect(try frames(output) == Int64((24.5 * 44_100).rounded()))
        #expect(StagingStore.load(url: h.home.appending(path: "staged.json")).map(\.uuid) == [staged.uuid])
        #expect(staged.bpm == 120 && staged.gridConfident == true)
        let grid = try #require(GridDraftStore.load(trackUUID: staged.uuid, directory: h.home.appending(path: "grid-drafts")))
        #expect(grid.segments == model.grid)
        // 6.5초 핫큐는 첫 조각(0~8.5초)에서 먼저 나온다
        let cues = try #require(CueDraftStore.load(trackUUID: staged.uuid, directory: h.home.appending(path: "cue-drafts")))
        #expect(cues.cues.map(\.time) == [6.5] && cues.cues.map(\.kind) == [.hot(0)])
        let tags = try #require(TagDraftStore.load(trackUUID: staged.uuid, directory: h.home.appending(path: "tag-drafts")))
        #expect(tags.fields.title == "시험 곡 (Flip)" && tags.fields.artist == "아티스트")
    }

    @Test func 원곡에_그리드가_없으면_그리드_초안_없이_넣는다() async throws {
        let h = try EditHarness(grid: nil)
        defer { h.remove() }
        let model = try await model(h)
        #expect(model.grid.isEmpty && model.gridNotice != nil)
        model.render()
        try await until { model.staged != nil }
        let staged = try #require(model.staged)
        #expect(staged.gridConfident != true)
        #expect(GridDraftStore.load(trackUUID: staged.uuid, directory: h.home.appending(path: "grid-drafts")) == nil)
        #expect(StagingStore.load(url: h.home.appending(path: "staged.json")).map(\.uuid) == [staged.uuid])
    }

    @Test func 넣기_전에_버리면_묻고_넣은_뒤에는_묻지_않는다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = try await model(h)
        let prompter = ScriptedPrompter()
        prompter.answer = false
        #expect(!model.confirmDiscard(prompter))
        #expect(prompter.shown.count == 1)
        let prompt = try #require(prompter.shown.first)
        #expect(prompt.destructive && prompt.confirm?.hasSuffix("…") == false, "최종 버튼에는 말줄임표를 붙이지 않는다")
        prompter.answer = true
        #expect(model.confirmDiscard(prompter))
        model.render()
        try await until { model.staged != nil }
        #expect(model.confirmDiscard(prompter))
        #expect(prompter.shown.count == 2, "넣은 결과는 버려도 잃는 것이 없다")
    }
}

/// 렌더해 넣은 편집본을 추가한 곡에서 보여 줄 때: 그리드 초안을 넣지 않은 Flip은 그리드 초안 표시를 켜지 않는다.
@MainActor
@Suite("편집본 보여 주기")
struct ShowStagedEditTests {
    func store(home: URL) -> LibraryStore {
        let stagedURL = home.appending(path: StagingStore.fileName)
        let store = LibraryStore(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: home.appending(path: "backups"), playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { try StagingStore.save($0, url: stagedURL) })
        store.draftHome = home
        return store
    }

    @Test func 그리드_없는_편집본은_그리드_초안으로_표시하지_않는다() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-show-staged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let plain = try await EditStaging.stage(fileAt: try AudioFixture.wav(seconds: 2, in: home, name: "그리드 없음.wav"), grid: [],
                                                cues: [], source: nil, title: "그리드 없음", home: home)
        let gridded = try await EditStaging.stage(fileAt: try AudioFixture.wav(seconds: 2, in: home, name: "그리드 있음.wav"),
                                                  grid: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)],
                                                  cues: [], source: nil, title: "그리드 있음", home: home)
        let store = store(home: home)
        var loaded: [String?] = []
        store.onLoadToDeck = { loaded.append($0?.id) }
        store.showStagedEdit(plain, hasGrid: false)
        #expect(!store.hasDraft(.grid, trackUUID: plain.uuid))
        #expect(store.selection == [plain.id] && loaded == [plain.id])
        store.showStagedEdit(gridded, hasGrid: true)
        #expect(store.hasDraft(.grid, trackUUID: gridded.uuid))
        #expect(!store.hasDraft(.grid, trackUUID: plain.uuid))
        #expect(loaded == [plain.id, gridded.id])
    }
}
