@testable import DJCrate
import DJCAnalysis
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Synchronization
import Testing

/// #172: 곡 넣기·빼기의 백업은 저장소에 준 폴더로 가고, 초안 파일을 바꾸는 경로는 모두 `DraftWriter`를 거친다.
/// 앱 기본 초안·백업 폴더(`DJCPaths`)를 건드릴 수 있어 `DJC_HOME`이 있을 때만 돈다(사용자 폴더를 지키려고).
@MainActor
@Suite("곡 넣기·빼기와 초안 정리 경로", .serialized)
struct TrackWritePathTests {
    func makeStore(_ fixture: RekordboxFixture) -> LibraryStore {
        let store = LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.trackwrite.\(UUID())")!, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture.backups,
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
        // 미리 보기·쓰고 난 뒤 다시 읽기가 사용자 라이브러리가 아니라 합성 사본을 보게 한다.
        let database = fixture.database
        store.takeLiveSnapshot = { _ in database }
        store.rekordboxDatabase = database
        store.rekordboxShareRoot = fixture.shareRoot
        store.launchArguments = ["test"]
        store.launchEnvironment = [:]
        return store
    }

    func loadedStore(_ fixture: RekordboxFixture) async -> LibraryStore {
        let store = makeStore(fixture)
        await store.load(snapshot: fixture.database, arguments: ["test", "--db", fixture.database.path], environment: [:])
        return store
    }

    func cue(_ uuid: String, time: Double) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid, rekordboxCues: [])
        draft.place(EditableCue(kind: .memory, time: time))
        return draft
    }

    func grid(_ uuid: String, bpm: Double = 120) -> GridDraft {
        GridDraft(trackUUID: uuid, base: [], segments: [GridSegment(start: 1, bpm: bpm, firstBeatNumber: 1)])
    }

    /// 저장에 실패해 디스크에는 옛 초안이, DraftWriter에는 최신 입력이 남은 상태를 만든다.
    func leaveFailedSaves(for uuid: String) {
        DraftWriter.save(cue(uuid, time: 1))
        DraftWriter.save(grid(uuid))
        DraftWriter.flush()
        DraftWriter.save(cue(uuid, time: 2), write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        DraftWriter.save(grid(uuid, bpm: 125), write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        DraftWriter.flush()
    }

    func clearDrafts(_ uuid: String) {
        DraftWriter.removeCue(trackUUID: uuid)
        DraftWriter.removeGrid(trackUUID: uuid)
        DraftWriter.flush()
    }

    func stagedTrack(path: String) throws -> StagedTrack {
        try JSONDecoder().decode(StagedTrack.self, from: Data("""
            {"uuid":"\(UUID().uuidString)","path":"\(path)","title":"합성 추가 곡","comment":"","duration":2,"addedOn":"2026-10-01"}
            """.utf8))
    }

    /// 추가한 곡 하나를 미리 보고 합성 사본에 넣는다.
    func addStagedTrack(to store: LibraryStore, _ fixture: RekordboxFixture) async throws -> (preview: LibraryStore.TrackAddPreview,
                                                                                           report: RekordboxTrackWriter.Report) {
        let staged = try stagedTrack(path: try TestResources.url("mp3-notag-cbr.mp3").path)
        store.staged = [staged]
        let preview = try await store.previewTrackAdd(rows: [TrackRow(track: staged.track, cues: [], playCount: 0)])
        let report = try await store.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        return (preview, report)
    }

    /// 사용자 백업 폴더(앱 기본 폴더)에 이 곡 넣기·빼기의 백업이 생겼는지
    func defaultBackups(containing matches: (RekordboxTrackWriter.Report) -> Bool) -> Bool {
        RekordboxWriter.backups(in: DJCPaths.rekordboxBackups).contains { $0.trackReport.map(matches) == true }
    }

    // MARK: - 곡 넣기·빼기 백업

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 곡_넣기의_백업은_저장소에_준_폴더에_남는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())   // 라이브러리 공통값을 가져올 기존 곡
        let store = await loadedStore(fixture)
        let staged = try stagedTrack(path: try TestResources.url("mp3-notag-cbr.mp3").path)
        store.staged = [staged]
        let preview = try await store.previewTrackAdd(rows: [TrackRow(track: staged.track, cues: [], playCount: 0)])
        #expect(preview.report.added.first?.written == true)
        // 미리 보기는 백업을 뜨지 않는다.
        #expect(RekordboxWriter.backups(in: fixture.backups).isEmpty)
        let report = try await store.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        let path = try #require(report.added.first?.path)
        #expect(report.added.first?.written == true)
        let backups = RekordboxWriter.backups(in: fixture.backups)
        #expect(backups.count == 1 && backups.first?.isWrite == true)
        #expect(backups.first?.trackReport?.added.map(\.path) == [path])
        #expect(report.backup.map { URL(filePath: $0).deletingLastPathComponent().resolvingSymlinksInPath().path }
                == fixture.backups.resolvingSymlinksInPath().path)
        #expect(!defaultBackups { $0.added.contains { $0.path == path } })
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 곡_빼기의_백업은_저장소에_준_폴더에_남는다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let store = await loadedStore(fixture)
        let row = try #require(store.rowsByUUID[spec.uuid])
        let preview = try await store.previewTrackDelete(rows: [row])
        #expect(preview.report.deleted.first?.written == true)
        #expect(RekordboxWriter.backups(in: fixture.backups).isEmpty)
        let report = try await store.deleteTracksFromRekordbox(preview, from: fixture.database, shareRoot: fixture.shareRoot)
        #expect(report.deleted.first?.written == true)
        let backups = RekordboxWriter.backups(in: fixture.backups)
        #expect(backups.count == 1 && backups.first?.isWrite == true)
        #expect(backups.first?.trackReport?.deleted.compactMap(\.contentID) == [spec.id])
        #expect(!defaultBackups { $0.deleted.contains { $0.contentID == spec.id } })
    }

    // MARK: - 반영 확인

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 반영_확인은_저장_실패_기록이_남은_곡의_대기_초안도_정리한다() async throws {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec()
        spec.cues = [CueSpec(kind: 0, inMsec: 4000)]
        try fixture.add(spec)
        let store = await loadedStore(fixture)
        let row = try #require(store.rowsByUUID[spec.uuid])
        // 가져오기 전(큐 없음)의 초안으로 계획을 만든다. 가져온 뒤 rekordbox에는 그 큐가 들어 있다.
        let plan = Reflection.plan(track: row.track, rawCues: [], cueDraft: cue(spec.uuid, time: 4), gridDraft: nil)
        leaveFailedSaves(for: spec.uuid)
        defer { clearDrafts(spec.uuid) }
        #expect(DraftWriter.pendingCue(trackUUID: spec.uuid) != nil && DraftWriter.pendingGrid(trackUUID: spec.uuid) != nil)
        store.reflectionBatch = ReflectionStore.Batch(createdAt: "2026-10-01 00:00:00", xmlPath: "", plans: [plan], checks: [:])
        store.verifyReflection()
        DraftWriter.flush()
        #expect(store.reflectionMessage?.kind == .success)
        // 디스크와 DraftWriter의 기록이 같이 비어야 덱·쓰기 전 확인이 옛 초안을 다시 읽지 않는다.
        #expect(CueDraftStore.load(trackUUID: spec.uuid) == nil && GridDraftStore.load(trackUUID: spec.uuid) == nil)
        #expect(DraftWriter.pendingCue(trackUUID: spec.uuid) == nil && DraftWriter.pendingGrid(trackUUID: spec.uuid) == nil)
        #expect(!DraftWriter.failures().contains { $0.trackUUID == spec.uuid })
        #expect(DraftWriter.unsavedUUIDs().isDisjoint(with: [spec.uuid]))
        #expect(!store.pendingUUIDs.contains(spec.uuid))
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 반영_확인은_초안_파일이_없는_곡을_정리_실패로_알리지_않는다() async throws {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec()
        spec.cues = [CueSpec(kind: 0, inMsec: 4000)]
        try fixture.add(spec)
        let store = await loadedStore(fixture)
        let row = try #require(store.rowsByUUID[spec.uuid])
        let plan = Reflection.plan(track: row.track, rawCues: [], cueDraft: cue(spec.uuid, time: 4), gridDraft: nil)
        defer { clearDrafts(spec.uuid) }
        #expect(CueDraftStore.load(trackUUID: spec.uuid) == nil && GridDraftStore.load(trackUUID: spec.uuid) == nil)
        store.reflectionBatch = ReflectionStore.Batch(createdAt: "2026-10-01 00:00:00", xmlPath: "", plans: [plan], checks: [:])
        store.verifyReflection()
        DraftWriter.flush()
        #expect(store.reflectionMessage?.kind == .success)
        #expect(!DraftWriter.failures().contains { $0.trackUUID == spec.uuid })
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 반영_확인이_초안을_정리하지_못하면_경고로_알린다() async throws {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec()
        spec.cues = [CueSpec(kind: 0, inMsec: 4000)]
        try fixture.add(spec)
        let store = await loadedStore(fixture)
        let row = try #require(store.rowsByUUID[spec.uuid])
        let draft = cue(spec.uuid, time: 4)
        let plan = Reflection.plan(track: row.track, rawCues: [], cueDraft: draft, gridDraft: nil)
        DraftWriter.save(draft)
        DraftWriter.flush()
        // 이 곡의 파일만 잠가 정리(삭제) 실패를 만든다(다른 시험의 초안과 섞이지 않게).
        let file = CueDraftStore.directory.appending(path: "\(spec.uuid).json")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            clearDrafts(spec.uuid)
        }
        store.reflectionBatch = ReflectionStore.Batch(createdAt: "2026-10-01 00:00:00", xmlPath: "", plans: [plan], checks: [:])
        store.verifyReflection()
        #expect(store.reflectionMessage?.kind == .warning)
        #expect(store.reflectionMessage?.text.contains("초안을 정리하지 못했습니다") == true)
        #expect(DraftWriter.failures().contains { $0.trackUUID == spec.uuid && $0.kind == .cue })
    }

    // MARK: - 추가 곡 복원

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 곡_넣기를_되돌리면_새_곡의_저장_실패_기록도_정리한다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = await loadedStore(fixture)
        let (_, report) = try await addStagedTrack(to: store, fixture)
        let newUUID = try #require(report.added.first?.uuid)
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        leaveFailedSaves(for: newUUID)
        defer { clearDrafts(newUUID) }
        #expect(DraftWriter.pendingCue(trackUUID: newUUID) != nil && DraftWriter.pendingGrid(trackUUID: newUUID) != nil)
        _ = store.restoreStaged(from: backup)
        DraftWriter.flush()
        #expect(CueDraftStore.load(trackUUID: newUUID) == nil && GridDraftStore.load(trackUUID: newUUID) == nil)
        #expect(DraftWriter.pendingCue(trackUUID: newUUID) == nil && DraftWriter.pendingGrid(trackUUID: newUUID) == nil)
        #expect(!DraftWriter.failures().contains { $0.trackUUID == newUUID })
        #expect(store.lastError == nil)
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 곡_넣기를_되돌릴_때_초안을_정리하지_못하면_알린다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = await loadedStore(fixture)
        let (_, report) = try await addStagedTrack(to: store, fixture)
        let newUUID = try #require(report.added.first?.uuid)
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        DraftWriter.save(cue(newUUID, time: 3))
        DraftWriter.flush()
        let file = CueDraftStore.directory.appending(path: "\(newUUID).json")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            clearDrafts(newUUID)
        }
        _ = store.restoreStaged(from: backup)
        #expect(store.lastError?.contains("초안을 저장하지 못했습니다") == true)
        #expect(DraftWriter.failures().contains { $0.trackUUID == newUUID && $0.kind == .cue })
    }

    // MARK: - 추가 곡 그리드 추정

    final class Calls: Sendable {
        let count = Mutex(0)
    }

    func estimate(bpm: Double = 125) throws -> GridEstimator.Estimate {
        var estimate = try #require(GridEstimator.estimate(beats: (0..<40).map { 0.5 + Double($0) * 0.5 }, bars: [0.5, 2.5, 4.5], duration: 20))
        estimate.segments[0].bpm = bpm
        return estimate
    }

    func estimatedStore(returning estimate: GridEstimator.Estimate, calls: Calls) throws -> (LibraryStore, GridJobItem, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "djc-estimate-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wav = try AudioFixture.wav(seconds: 1, in: directory)
        let store = LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.estimate.\(UUID())")!, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: directory.appending(path: "backups"),
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
        store.gridEstimator = { _, _ in calls.count.withLock { $0 += 1 }; return estimate }
        return (store, GridJobItem(uuid: UUID().uuidString, path: wav.path, staged: false), directory)
    }

    func runQueue(_ store: LibraryStore, _ item: GridJobItem) async {
        store.enqueueGrid([item])
        await store.gridTask?.value
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 그리드_추정_저장은_DraftWriter_기록과_디스크가_같다() async throws {
        let calls = Calls()
        let (store, item, directory) = try estimatedStore(returning: estimate(), calls: calls)
        defer { try? FileManager.default.removeItem(at: directory); clearDrafts(item.uuid) }
        await runQueue(store, item)
        #expect(calls.count.withLock { $0 } == 1)
        let saved = try #require(GridDraftStore.load(trackUUID: item.uuid))
        let state = try #require(DraftWriter.state(.grid, trackUUID: item.uuid, directory: GridDraftStore.directory))
        #expect(state.savedRevision == state.revision && state.failure == nil)
        #expect(DraftWriter.pendingGrid(trackUUID: item.uuid) == nil && saved.segments.first?.bpm == 125)
        #expect(store.pendingUUIDs.contains(item.uuid) && store.lastError == nil)
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 그리드_추정_저장이_실패하면_기록하고_알린다() async throws {
        let calls = Calls()
        let (store, item, directory) = try estimatedStore(returning: estimate(), calls: calls)
        // 파일 자리에 폴더를 둬 저장 실패를 만든다.
        let blocker = GridDraftStore.directory.appending(path: "\(item.uuid).json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: blocker)
            try? FileManager.default.removeItem(at: directory)
            clearDrafts(item.uuid)
        }
        await runQueue(store, item)
        let failure = try #require(DraftWriter.failures().first { $0.trackUUID == item.uuid && $0.kind == .grid })
        #expect(DraftWriter.pendingGrid(trackUUID: item.uuid)?.segments.first?.bpm == 125)
        #expect(store.lastError == failure.message)
        // 저장에 실패한 초안이 있는 곡은 곡 넣기 전 확인이 막는다(#170).
        #expect { try store.requireDraftSaves(for: [item.uuid]) } throws: { $0.localizedDescription.contains(failure.message) }
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 그리드_추정은_저장_실패로_대기_중인_덱_편집을_덮지_않는다() async throws {
        let calls = Calls()
        let (store, item, directory) = try estimatedStore(returning: estimate(), calls: calls)
        defer { try? FileManager.default.removeItem(at: directory); clearDrafts(item.uuid) }
        // 덱에서 고친 그리드가 저장에 실패해 디스크에는 없고 DraftWriter에만 있다.
        let edited = grid(item.uuid, bpm: 140)
        DraftWriter.save(edited, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        DraftWriter.flush()
        #expect(GridDraftStore.load(trackUUID: item.uuid) == nil && DraftWriter.pendingGrid(trackUUID: item.uuid) == edited)
        await runQueue(store, item)
        #expect(calls.count.withLock { $0 } == 0)
        #expect(DraftWriter.pendingGrid(trackUUID: item.uuid) == edited)
        #expect(GridDraftStore.load(trackUUID: item.uuid) == nil)
    }
}
