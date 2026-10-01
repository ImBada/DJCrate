@testable import DJCrate
import DJCAnalysis
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Synchronization
import Testing

/// #168·#169·#170 통합 검토에서 찾은 빈틈: 복잡한 그리드 복구, 추정 그리드 적용, 저장 실패 확인 경로, 덱 다시 저장.
@MainActor
@Suite("초안 안전 후속", .serialized)
struct DraftSafetyFollowupTests {
    func makeStore(_ fixture: RekordboxFixture) -> LibraryStore {
        LibraryStore(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, backupDirectory: fixture.backups,
                     playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
    }

    func evenGrid(_ count: Int = 40, shifted index: Int? = nil) -> BeatGrid {
        BeatGrid(beats: (0..<count).map { i in
            .init(number: i % 4 + 1, bpm: 120, time: 0.5 + Double(i) * 0.5 + (i == index ? 0.004 : 0))
        })
    }

    func suggestion(bpm: Double = 125) throws -> GridEstimator.Estimate {
        var estimate = try #require(GridEstimator.estimate(beats: (0..<40).map { 0.5 + Double($0) * 0.5 }, bars: [0.5, 2.5, 4.5], duration: 20))
        estimate.segments[0].bpm = bpm
        return estimate
    }

    // MARK: - 그리드 복구

    @Test func 복잡한_현재그리드에는_승인없는_내편집을_재적용하지_않는다() async throws {
        let fixture = try RekordboxFixture(), store = makeStore(fixture)
        var spec = TrackSpec(); spec.length = 60; spec.fileType = 11
        spec.folderPath = try AudioFixture.wav(seconds: 60, in: fixture.audio).path
        spec.analysisDataPath = "/PIONEER/USBANLZ/followup/ANLZ0000.DAT"
        try fixture.add(spec)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(spec.id)])
        let simple = AnlzBuilder.beats(bpm: 120, first: 500, count: 120)
        try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: simple), ext: AnlzBuilder.ext(beats: simple))
        var draft = GridDraft(trackUUID: spec.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: spec)))
        draft.segments[0].bpm = 121
        let directory = fixture.root.appending(path: "grid-drafts")
        try GridDraftStore.save(draft, directory: directory)
        // rekordbox에서 BPM이 바뀌고 한 박이 3ms 어긋났다: 구간은 하나지만 균일한 그리드로 다시 만들 수 없다.
        var complex = AnlzBuilder.beats(bpm: 125, first: 500, count: 125)
        complex[2].time += 3
        try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: complex), ext: AnlzBuilder.ext(beats: complex))
        let current = try BeatGrid.load(anlz: fixture.analysisURL(for: spec))
        #expect(GridEditEligibility.reconstructionErrorMilliseconds(of: current, duration: 60) > 2)
        store.launchArguments = ["test", "--db", fixture.database.path]
        store.launchEnvironment = ["DJC_REKORDBOX_DIR": fixture.root.path]
        await store.load(snapshot: fixture.database, arguments: store.launchArguments, environment: store.launchEnvironment)
        let row = try #require(store.rowsByUUID[spec.uuid])
        let review = try await store.prepareDraftRecovery(row: row, kind: .grid, home: fixture.root)
        // 비교 창은 미리 "내 편집 유지"를 빼고 이유를 보인다.
        let refusal = try #require(review.keepRefusal)
        #expect(ReflectionCoordinator.recoveryConfirmation(review, canKeep: false, keepRefusal: refusal).details.contains(refusal))
        await #expect(throws: DJCError.self) { try await store.applyDraftRecovery(review, choice: .keepEditing, home: fixture.root) }
        #expect(GridDraftStore.load(trackUUID: spec.uuid, directory: directory) == draft)
        // 현재값 사용은 그대로 된다(초안을 정리한다).
        try await store.applyDraftRecovery(review, choice: .useCurrent, home: fixture.root)
        #expect(GridDraftStore.load(trackUUID: spec.uuid, directory: directory) == nil)
    }

    // MARK: - 추정 그리드 적용

    @Test func 단순한_원본에는_추정을_대체승인없이_적용하고_변속지점도_더한다() async throws {
        let h = try DeckHarness(grid: nil)
        try await h.loaded()
        let original = evenGrid()
        h.deck.originalGrid = original
        h.deck.gridDraft = GridDraft(trackUUID: "track-1", grid: original)
        var multi = try suggestion()
        multi.segments.append(GridSegment(start: 10.5, bpm: 128, firstBeatNumber: 1))
        h.deck.gridSuggestion = multi
        h.deck.applyGridSuggestion()
        let applied = try #require(h.deck.gridDraft)
        #expect(applied.segments.count == 2 && applied.replacementSource == nil)
        #expect(h.deck.canEditGrid && h.deck.toast == nil)
        h.deck.gridSuggestion = try suggestion()
        h.deck.applyGridSuggestion()
        #expect(h.deck.gridDraft?.segments.count == 1 && h.deck.gridDraft?.replacementSource == nil)
        // 변속 지점을 더해도 단순한 원본의 편집은 막히지 않는다.
        h.deck.mutateGrid { $0.segments.append(GridSegment(start: 10.5, bpm: 128, firstBeatNumber: 1)) }
        #expect(h.deck.gridDraft?.segments.count == 2 && h.deck.canEditGrid && h.deck.gridEditBlockedReason == nil)
    }

    @Test func 복잡한_원본에는_여러구간_추정을_정확한_이유로_거절한다() async throws {
        let h = try DeckHarness(grid: nil)
        try await h.loaded()
        let original = evenGrid(shifted: 10)
        h.deck.originalGrid = original
        h.deck.gridDraft = GridDraft(trackUUID: "track-1", grid: original)
        h.deck.gridEditBlockedReason = "합성 재생성 오차"
        var multi = try suggestion()
        multi.segments.append(GridSegment(start: 10.5, bpm: 128, firstBeatNumber: 1))
        h.deck.gridSuggestion = multi
        h.deck.applyGridSuggestion()
        #expect(h.deck.gridDraft?.hasChanges == false)
        let message = try #require(h.deck.toast?.text)
        #expect(message.contains(String(ui: "템포 구간이 하나인 추정 그리드")))
        #expect(!message.contains(String(ui: "rekordbox에서 그리드가 바뀌었습니다")))
    }

    @Test func 대체한_초안은_지원밖_편집을_거절하고_막혀도_버릴수_있다() async throws {
        let h = try DeckHarness(grid: nil)
        try await h.loaded()
        let original = evenGrid(shifted: 10)
        h.deck.originalGrid = original
        h.deck.gridDraft = GridDraft(trackUUID: "track-1", grid: original)
        h.deck.gridEditBlockedReason = "합성 재생성 오차"
        h.deck.gridSuggestion = try suggestion()
        h.deck.applyGridSuggestion()
        let approved = try #require(h.deck.gridDraft)
        #expect(approved.replacementSource != nil && h.deck.canEditGrid)
        // 구간 하나로만 대체를 승인했으므로 변속 지점을 더하는 편집은 받지 않고 이유를 알린다.
        h.deck.mutateGrid { $0.segments.append(GridSegment(start: 10.5, bpm: 128, firstBeatNumber: 1)) }
        #expect(h.deck.gridDraft == approved && h.deck.canEditGrid)
        #expect(h.deck.toast?.text.contains(String(ui: "템포 구간을 하나로만")) == true)
        // 그 뒤 rekordbox 원본이 바뀌어 막힌 대체 초안도 버릴 수 있다.
        h.deck.originalGrid = evenGrid(shifted: 20)
        h.deck.gridEditBlockedReason = "합성 원본 변경"
        #expect(!h.deck.canEditGrid && h.deck.canDiscardGridDraft)
        h.deck.revertGrid()
        #expect(h.deck.gridDraft?.hasChanges == false && h.deck.gridDraft?.replacementSource == nil)
        #expect(h.drafts.grid("track-1")?.hasChanges == false)
    }

    // MARK: - 저장 실패 확인 경로

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func XML과_곡넣기는_저장에_실패한_초안을_쓰지_않는다() async throws {
        let fixture = try RekordboxFixture(), store = makeStore(fixture)
        let spec = TrackSpec()
        try fixture.add(spec)
        store.launchArguments = ["test", "--db", fixture.database.path]
        await store.load(snapshot: fixture.database, arguments: store.launchArguments, environment: [:])
        let row = try #require(store.rowsByUUID[spec.uuid])
        var old = CueDraft(trackUUID: spec.uuid, rekordboxCues: []); old.place(EditableCue(kind: .memory, time: 1))
        var latest = old; latest.place(EditableCue(kind: .memory, time: 2))
        DraftWriter.save(old)
        DraftWriter.flush()
        DraftWriter.save(latest, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let failure = try #require(DraftWriter.flush().first { $0.trackUUID == spec.uuid })
        defer {
            DraftWriter.save(CueDraft(trackUUID: spec.uuid, rekordboxCues: []))
            DraftWriter.flush()
        }
        store.draftChanged(trackUUID: spec.uuid, kind: .cue, exists: true)
        let xml = fixture.root.appending(path: "reflection.xml")
        #expect { try store.exportReflection(rows: [row], to: xml) } throws: { $0.localizedDescription.contains(failure.message) }
        #expect(!FileManager.default.fileExists(atPath: xml.path))

        // 추가한 곡: 저장에 실패한 그리드 초안이 있으면 XML도 곡 넣기 미리 보기도 하지 않는다.
        let stagedUUID = UUID().uuidString
        let staged = try JSONDecoder().decode(StagedTrack.self, from: Data("""
            {"uuid":"\(stagedUUID)","path":"/private/tmp/djc-followup-staged.mp3","title":"합성 추가 곡","comment":"","duration":30,"addedOn":"2026-10-01"}
            """.utf8))
        store.staged = [staged]
        let grid = GridDraft(trackUUID: stagedUUID, base: [], segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)])
        DraftWriter.save(grid, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let gridFailure = try #require(DraftWriter.flush().first { $0.trackUUID == stagedUUID })
        defer {
            DraftWriter.removeGrid(trackUUID: stagedUUID)
            DraftWriter.flush()
        }
        let stagedXML = fixture.root.appending(path: "staged.xml")
        #expect { try store.exportStaged(to: stagedXML) } throws: { $0.localizedDescription.contains(gridFailure.message) }
        #expect(!FileManager.default.fileExists(atPath: stagedXML.path))
        let stagedRow = TrackRow(track: staged.track, cues: [], playCount: 0)
        await #expect { _ = try await store.previewTrackAdd(rows: [stagedRow]) } throws: { $0.localizedDescription.contains(gridFailure.message) }
    }

    // MARK: - 덱 다시 저장

    @Test func 덱_다시저장은_곡을_읽는_중에도_기록된_입력을_다시_저장한다() async throws {
        let retried = Mutex<[DraftWriter.Kind]>([]), removed = Mutex(0)
        var storage = DeckStorage.memory(MemoryDrafts())
        storage.removeGridDraft = { _, _ in removed.withLock { $0 += 1 } }
        storage.retryDraftSave = { kind, _, _ in retried.withLock { $0.append(kind) } }
        let deck = DeckModel(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)
        let row = ReflectionCoordinatorTests.row("retry-loading")
        // 초안을 아직 읽지 않은 덱(draft·gridDraft가 비어 있음)
        deck.row = row
        deck.draftSaveFailures = [
            DraftWriter.Failure(kind: .cue, trackUUID: row.track.uuid, revision: 1, reason: "합성 큐 실패"),
            DraftWriter.Failure(kind: .grid, trackUUID: row.track.uuid, revision: 2, reason: "합성 그리드 실패"),
        ]
        deck.retryDraftSaves()
        #expect(removed.withLock { $0 } == 0)
        #expect(Set(retried.withLock { $0 }) == [.cue, .grid])
    }

    @Test func 덱_밖에서_해소된_저장실패는_덱에_남지_않는다() async throws {
        let resolved = Mutex(false)
        var storage = DeckStorage.memory(MemoryDrafts())
        storage.draftSaveResolved = { _ in resolved.withLock { $0 } }
        let deck = DeckModel(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)
        let row = ReflectionCoordinatorTests.row("resolved-elsewhere")
        deck.row = row
        var draft = CueDraft(trackUUID: row.track.uuid, rekordboxCues: []); draft.place(EditableCue(kind: .memory, time: 1))
        deck.draft = draft
        deck.draftSaveFailures = [DraftWriter.Failure(kind: .cue, trackUUID: row.track.uuid, revision: 1, reason: "합성 큐 실패")]
        #expect(deck.currentDraftSaveFailures.count == 1)
        resolved.withLock { $0 = true }
        #expect(deck.currentDraftSaveFailures.isEmpty)
        // 해소된 뒤에는 외부에서 바뀐 초안을 다시 읽는다.
        var external = draft; external.place(EditableCue(kind: .memory, time: 5))
        deck.reloadExternalCueDraft(external)
        #expect(deck.draft?.cues.map(\.time) == [1, 5])
    }

    @Test func DraftWriter_종류별_재시도는_기록된_입력을_완료와_함께_다시_저장한다() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-followup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = UUID().uuidString
        let grid = GridDraft(trackUUID: uuid, base: [], segments: [GridSegment(start: 1, bpm: 120, firstBeatNumber: 1)])
        let fail = Mutex(true)
        DraftWriter.save(grid, directory: root, write: { draft, directory in
            if fail.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
            try GridDraftStore.save(draft, directory: directory)
        })
        let failure = try #require(DraftWriter.flush().first { $0.trackUUID == uuid })
        #expect(!DraftWriter.isResolved(failure, directory: root))
        fail.withLock { $0 = false }
        let completed = Mutex<DraftWriter.Failure??>(nil)
        let started = DraftWriter.retry(.grid, trackUUID: uuid, directory: root, completion: { result in completed.withLock { $0 = .some(result) } })
        #expect(started)
        DraftWriter.flush()
        #expect(completed.withLock { $0 } == .some(nil))
        #expect(GridDraftStore.load(trackUUID: uuid, directory: root) == grid)
        #expect(DraftWriter.isResolved(failure, directory: root))
        // 이미 저장된 기록은 다시 저장하지 않는다.
        #expect(!DraftWriter.retry(.grid, trackUUID: uuid, directory: root))
    }
}
