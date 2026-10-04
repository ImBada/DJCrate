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
    /// - Parameter saveTagDrafts: 태그 초안 저장(기본은 메모리만). 다시 읽기가 디스크의 태그 초안을 읽으므로 앱처럼 저장해야 하는 시험만 바꾼다.
    func makeStore(_ fixture: RekordboxFixture, saveTagDrafts: @escaping ([TagDraft]) -> Void = { _ in }) -> LibraryStore {
        let store = LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.trackwrite.\(UUID())")!, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: saveTagDrafts, backupDirectory: fixture.backups,
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

    func loadedStore(_ fixture: RekordboxFixture, saveTagDrafts: @escaping ([TagDraft]) -> Void = { _ in }) async -> LibraryStore {
        let store = makeStore(fixture, saveTagDrafts: saveTagDrafts)
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
        var spec = TrackSpec()
        spec.dataStatus = 0  // 곡 빼기 규칙은 동기화하지 않은 곡으로만 확인했다(#196)
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

    /// 앱의 빼기 미리 보기도 동기화 상태 곡을 이유와 함께 막고 라이브러리를 그대로 둔다(#196).
    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 곡_빼기_미리_보기는_동기화_곡을_이유와_함께_막는다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let store = await loadedStore(fixture)
        let row = try #require(store.rowsByUUID[spec.uuid])
        let preview = try await store.previewTrackDelete(rows: [row])
        let outcome = try #require(preview.report.deleted.first)
        #expect(outcome.written == false && outcome.reason == RekordboxTrackWriter.syncedTrackReason)
        #expect(preview.report.deleted.filter(\.written).isEmpty)
        #expect(try fixture.rows("SELECT ID FROM djmdContent").map { $0["ID"] } == [spec.id])
        #expect(RekordboxWriter.backups(in: fixture.backups).isEmpty)
    }

    /// 합치기 초안을 만들지 못한 알림은 남길 곡이 아니라 지울 원본의 이름으로 이유를 알린다(#196 리뷰: 남길 곡을 빼야 하는 것처럼 읽혔다).
    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 합치기_초안_알림은_지울_원본의_이름으로_막은_이유를_알린다() async throws {
        let fixture = try RekordboxFixture()
        for (id, title, status) in [("100", "남길 곡", 0), ("200", "뺄 곡", 256)] {
            var spec = TrackSpec(id: id, uuid: "u" + id)
            spec.title = title; spec.dataStatus = status; spec.fileType = 11; spec.length = 30
            spec.folderPath = try AudioFixture.wav(seconds: 30, in: fixture.audio, name: id + ".wav").path
            try fixture.add(spec)
        }
        let store = await loadedStore(fixture)
        let prompter = ScriptedPrompter()
        await store.prepareMerge(keeping: "100", removing: ["200"], prompter: prompter)
        let prompt = try #require(prompter.shown.first)
        #expect(prompt.title == "합치기 초안을 만들지 않았습니다" && prompt.confirm == nil)
        #expect(prompt.text == RekordboxWriter.mergeSourceReason(RekordboxTrackWriter.syncedTrackReason, title: "뺄 곡"))
        #expect(prompt.text.contains("‘뺄 곡’") && !prompt.text.contains("남길 곡"))
        #expect(store.mergeDrafts.isEmpty)
    }

    // MARK: - 곡 넣기 + 키 (#5)

    /// 이 시험이 `DJC_HOME`에 남긴 태그 초안을 지운다(변경 없는 초안을 저장하면 파일을 지운다). 다른 시험의 초안은 건드리지 않는다.
    func clearTagDrafts(_ store: LibraryStore) {
        DraftWriter.save(store.tagDrafts.keys.map { TagDraft(trackUUID: $0, base: TagFields()) })
        DraftWriter.flush()
    }

    /// 합성 라이브러리(공통값 곡 하나 + 8A 키 줄)와 키를 고른 추가한 곡. 태그 초안은 앱처럼 `DJC_HOME` 아래에 저장한다(다시 읽기가 디스크를 읽는다).
    func keyedStaged(_ fixture: RekordboxFixture, key: String) async throws -> (store: LibraryStore, staged: StagedTrack, row: TrackRow) {
        try fixture.add(TrackSpec())
        try fixture.insert("djmdKey", ["ID": .text("1486464042"), "ScaleName": .text("8A"), "Seq": .int(1), "UUID": .text("k-8a"),
                                       "rb_data_status": .int(256), "rb_local_deleted": .int(0), "rb_local_usn": .int(1)])
        let store = await loadedStore(fixture, saveTagDrafts: { DraftWriter.save($0) })
        let staged = try stagedTrack(path: try TestResources.url("mp3-notag-cbr.mp3").path)
        store.staged = [staged]
        let row = TrackRow(track: staged.track, cues: [], playCount: 0)
        store.setTag(.musicalKey, key, rows: [row])
        return (store, staged, row)
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 키를_고른_추가한_곡은_넣을_때_키도_쓰고_되돌리면_추가_목록과_키_초안이_돌아온다() async throws {
        let fixture = try RekordboxFixture()
        let (store, staged, row) = try await keyedStaged(fixture, key: "8A")
        defer { clearTagDrafts(store) }
        let preview = try await store.previewTrackAdd(rows: [row])
        let report = try await store.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        let outcome = try #require(report.added.first)
        #expect(outcome.written && outcome.keyWritten == "8A" && outcome.keyReason == nil)
        let id = try #require(outcome.contentID), uuid = try #require(outcome.uuid)
        let stored = try #require(try fixture.rows("SELECT KeyID, TrackInfoUpdated FROM djmdContent WHERE ID = ?", [.text(id)]).first)
        #expect(stored == ["KeyID": "1486464042", "TrackInfoUpdated": "1"])
        // 다시 읽은 목록: 넣은 곡의 키가 8A이고, 새 곡에는 키 초안이 없다(이미 썼다)
        #expect(store.rowsByUUID[uuid]?.track.key == "8A" && store.tagDrafts[uuid] == nil)
        #expect(store.staged.isEmpty)
        let lines = WriteResult.tracks(report, preview: preview.report, adding: true, withoutAnalysis: preview.withoutAnalysis).text
        #expect(lines.contains("키 8A"), "\(lines)")

        // 쓰기 전으로 복원: 곡이 빠지고 추가 목록에 돌아오며, 키를 고른 초안도 그대로 남아 다시 넣을 수 있다
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        try await store.restoreRekordbox(backup, keepingCurrentDrafts: true)
        #expect(try fixture.rows("SELECT ID FROM djmdContent WHERE ID = ?", [.text(id)]).isEmpty)
        #expect(store.staged.map(\.uuid) == [staged.uuid] && store.confirmedStagedKey(uuid: staged.uuid) == "8A")
        #expect(store.tagDrafts[uuid] == nil)
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 키가_막히면_곡만_넣고_고른_키는_새_곡의_쓰기_대기로_옮긴다() async throws {
        // 따로 쓸 때처럼 키만 막힌다(키 줄 없음). 사용자가 고른 키가 조용히 사라지지 않게 새 곡의 키 초안으로 남긴다(막힌 큐를 옮기는 것과 같다).
        let fixture = try RekordboxFixture()
        let (store, _, row) = try await keyedStaged(fixture, key: "12B")
        defer { clearTagDrafts(store) }
        let preview = try await store.previewTrackAdd(rows: [row])
        let report = try await store.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        let outcome = try #require(report.added.first)
        #expect(outcome.written && outcome.keyWritten == nil && outcome.keyReason?.contains("12B") == true)
        let uuid = try #require(outcome.uuid)
        let moved = try #require(store.tagDrafts[uuid])
        #expect(moved.changedKeys == [.musicalKey] && moved.fields.musicalKey == "12B" && moved.base.musicalKey == "")
        #expect(moved.base == store.rowsByUUID[uuid]?.tagFields, "새 곡의 지금 값이 기준이라 쓰기에서 기준 어긋남으로 막히지 않는다")
        let result = WriteResult.tracks(report, preview: preview.report, adding: true, withoutAnalysis: preview.withoutAnalysis)
        #expect(result.kind == .warning && result.text.contains("키는 쓰기 대기"), "\(result.text)")
        // 되돌리면 새 곡으로 옮긴 키 초안도 지운다(곡이 사라진다)
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        try await store.restoreRekordbox(backup, keepingCurrentDrafts: true)
        #expect(store.tagDrafts[uuid] == nil)
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
