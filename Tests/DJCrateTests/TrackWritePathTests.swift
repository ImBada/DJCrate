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

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 키가_막힌_채_넣은_직후_다시_읽기가_실패해도_새_곡의_키_초안을_남긴다() async throws {
        // #197: 결과 창은 "키는 쓰기 대기"라고 알린다. 다시 읽기(그 사이 rekordbox를 켬 등)가 실패해 새 곡 행이 없어도
        // 초안은 만들어져야 하고(기준은 쓰기 결과에서 온다), 다음에 읽어 새 곡이 보이면 그 행의 값과 맞아 쓸 수 있어야 한다.
        let fixture = try RekordboxFixture()
        let (store, _, row) = try await keyedStaged(fixture, key: "12B")
        defer { clearTagDrafts(store) }
        let preview = try await store.previewTrackAdd(rows: [row])
        let database = fixture.database
        store.takeLiveSnapshot = { _ in throw CocoaError(.fileReadNoPermission) }
        let report = try await store.addTracksToRekordbox(preview, to: database, shareRoot: fixture.shareRoot)
        let outcome = try #require(report.added.first)
        #expect(outcome.written && outcome.keyWritten == nil && outcome.keyReason != nil)
        let uuid = try #require(outcome.uuid)
        #expect(store.rowsByUUID[uuid] == nil && store.lastError != nil, "다시 읽기가 실패해 새 곡 행이 아직 없다")
        let moved = try #require(store.tagDrafts[uuid], "결과 창이 알린 대로 키 초안이 있어야 한다")
        #expect(moved.changedKeys == [.musicalKey] && moved.fields.musicalKey == "12B")
        #expect(TagDraftStore.load(trackUUID: uuid)?.fields.musicalKey == "12B", "디스크에도 저장했다")
        let result = WriteResult.tracks(report, preview: preview.report, adding: true, withoutAnalysis: preview.withoutAnalysis)
        #expect(result.text.contains("키는 쓰기 대기"), "\(result.text)")

        // 나중에 읽으면 새 곡이 보이고, 초안의 기준은 그 곡의 값이라 쓰기에서 기준 어긋남으로 막히지 않는다
        store.takeLiveSnapshot = { _ in database }
        await store.takeSnapshot(quiet: true, refreshITunes: false)
        let reloaded = try #require(store.rowsByUUID[uuid])
        let draft = try #require(store.tagDrafts[uuid])
        #expect(draft.fields.musicalKey == "12B" && draft.base == reloaded.tagFields)
        // 이제 키 줄이 생겼다고 하고(막힌 이유 해소) 쓰기 시험: 기준이 어긋나 있으면 여기서 막힌다
        try fixture.insert("djmdKey", ["ID": .text("1486464043"), "ScaleName": .text("12B"), "Seq": .int(2), "UUID": .text("k-12b"),
                                       "rb_data_status": .int(256), "rb_local_deleted": .int(0), "rb_local_usn": .int(1)])
        let dry = try RekordboxWriter.write(drafts: [], tags: [draft], to: database, dryRun: true, backups: fixture.backups,
                                            shareRoot: fixture.shareRoot)
        #expect(dry.tagWritten.count == 1 && dry.tagBlocked.isEmpty, "\(dry.tagBlocked)")
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 넣기_백업에_추가한_곡의_초안이_담겨_연결_안_된_초안을_버린_뒤에도_복원이_되살린다() async throws {
        // #197: 넣은 뒤 추가 목록 곡 UUID의 초안은 어느 곡에도 이어지지 않아(연결 안 된 초안) 쓰기 대기 목록에서 버릴 수 있다.
        // 넣기 백업이 그 초안(태그·큐)을 담고 있으면 "쓰기 전으로 복원…"이 버린 뒤에도 곡과 함께 되살린다.
        let fixture = try RekordboxFixture()
        let (store, staged, row) = try await keyedStaged(fixture, key: "8A")
        let original = cue(staged.uuid, time: 1)
        DraftWriter.save(original)
        DraftWriter.flush()
        defer {
            clearTagDrafts(store)
            clearDrafts(staged.uuid)
        }
        let preview = try await store.previewTrackAdd(rows: [row])
        let report = try await store.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        #expect(report.added.first?.keyWritten == "8A" && report.added.first?.cuesWritten == 1)
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        #expect(RekordboxWriter.tagDrafts(in: backup.url).map(\.trackUUID) == [staged.uuid], "백업에 추가한 곡의 태그 초안")
        #expect(RekordboxWriter.contents(of: backup.url).drafts.map(\.trackUUID) == [staged.uuid], "백업에 추가한 곡의 큐 초안")

        // 넣은 뒤 연결 안 된 초안이 된 것을 사용자가 버린다
        #expect(store.unlinkedDraftUUIDs.contains(staged.uuid))
        #expect(store.discardUnlinkedDrafts([staged.uuid]) == nil)
        DraftWriter.flush()
        #expect(store.tagDrafts[staged.uuid] == nil && CueDraftStore.load(trackUUID: staged.uuid) == nil)

        try await store.restoreRekordbox(backup, keepingCurrentDrafts: true)
        DraftWriter.flush()
        #expect(store.staged.map(\.uuid) == [staged.uuid])
        #expect(store.confirmedStagedKey(uuid: staged.uuid) == "8A", "고른 키가 다시 넣을 수 있게 돌아온다")
        #expect(CueDraftStore.load(trackUUID: staged.uuid) == original, "큐 초안도 돌아온다")
        #expect(!store.unlinkedDraftUUIDs.contains(staged.uuid), "되돌린 곡이 추가 목록에 있어 이어진 초안이다")
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated), arguments: ["12B", "8A"])
    func 곡_넣기를_되돌려도_넣은_뒤_새_곡에_만든_태그_초안은_지우지_않고_알린다(key: String) async throws {
        // #197: 되돌리면 새 곡이 사라지지만, 넣은 뒤 사용자가 그 곡에 만든 태그 초안(막힌 키를 옮긴 초안에 더한 것 포함)을 알림 없이 지우지 않는다.
        // 연결 안 된 초안으로 남기고(쓰기 대기 목록에서 버릴 수 있다) 복원 결과가 알린다. 옮겨 둔 키만 있는 초안은 지운다(추가 목록 곡에 돌아온 키 초안과 같다).
        let fixture = try RekordboxFixture()
        let (store, staged, row) = try await keyedStaged(fixture, key: key)
        defer { clearTagDrafts(store) }
        let preview = try await store.previewTrackAdd(rows: [row])
        let report = try await store.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        let uuid = try #require(report.added.first?.uuid)
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        let added = try #require(store.rowsByUUID[uuid])
        store.setTag(.comment, "넣은 뒤 고친 코멘트", rows: [added])
        DraftWriter.flush()
        #expect(store.tagDrafts[uuid]?.fields.comment == "넣은 뒤 고친 코멘트")

        try await store.restoreRekordbox(backup, keepingCurrentDrafts: true)
        DraftWriter.flush()
        #expect(store.staged.map(\.uuid) == [staged.uuid] && store.confirmedStagedKey(uuid: staged.uuid) == key)
        let kept = try #require(store.tagDrafts[uuid], "사용자가 만든 초안은 지우지 않는다")
        #expect(kept.fields.comment == "넣은 뒤 고친 코멘트")
        #expect(TagDraftStore.load(trackUUID: uuid)?.fields.comment == "넣은 뒤 고친 코멘트", "디스크에도 남아 있다")
        #expect(store.unlinkedDraftUUIDs.contains(uuid), "연결 안 된 초안으로 남아 쓰기 대기 목록에서 버릴 수 있다")
        #expect(store.writeFollowUp.contains { $0.contains("연결되지 않은 초안") }, "\(store.writeFollowUp)")
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 곡_넣기를_되돌릴_때_옮겨_둔_키만_있는_초안은_지우고_알리지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let (store, staged, row) = try await keyedStaged(fixture, key: "12B")
        defer { clearTagDrafts(store) }
        let preview = try await store.previewTrackAdd(rows: [row])
        let report = try await store.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        let uuid = try #require(report.added.first?.uuid)
        #expect(store.tagDrafts[uuid]?.changedKeys == [.musicalKey])
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        try await store.restoreRekordbox(backup, keepingCurrentDrafts: true)
        DraftWriter.flush()
        #expect(store.tagDrafts[uuid] == nil && TagDraftStore.load(trackUUID: uuid) == nil)
        #expect(store.confirmedStagedKey(uuid: staged.uuid) == "12B")
        #expect(!store.unlinkedDraftUUIDs.contains(uuid) && !store.writeFollowUp.contains { $0.contains("연결되지 않은 초안") })
    }

    /// 키가 막혀 새 곡으로 옮겨 둔 키 초안이 있는 채 넣은 뒤, 옛 백업처럼 그 백업에서 추가한 곡의 초안(`tag-drafts`·`cue-drafts`)을 빼고
    /// 사용자가 연결 안 된 초안(추가 목록 곡 UUID의 키 초안)을 버린 상태를 만든다. 돌려주는 값: 새 곡 UUID와 되돌릴 백업.
    func blockedKeyAddWithoutStagedDrafts(_ store: LibraryStore, _ fixture: RekordboxFixture, _ staged: StagedTrack, _ row: TrackRow)
        async throws -> (uuid: String, backup: RekordboxWriter.Backup) {
        let preview = try await store.previewTrackAdd(rows: [row])
        let report = try await store.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        let uuid = try #require(report.added.first?.uuid)
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        for folder in ["tag-drafts", "cue-drafts", "grid-drafts"] {
            try? FileManager.default.removeItem(at: backup.url.appending(path: folder))
        }
        #expect(RekordboxWriter.tagDrafts(in: backup.url).isEmpty)
        #expect(store.discardUnlinkedDrafts([staged.uuid]) == nil)
        DraftWriter.flush()
        #expect(store.confirmedStagedKey(uuid: staged.uuid) == nil, "버려서 추가 목록 곡에 고른 키가 남아 있지 않다")
        return (uuid, backup)
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 초안이_없는_옛_넣기_백업을_되돌려도_옮겨_둔_키_초안을_새_곡에_만든_초안이라고_알리지_않는다() async throws {
        // #197: 옛 넣기 백업에는 추가한 곡의 초안이 없어, 연결 안 된 키 초안을 버린 뒤에는 옮겨 둔 키 초안인지 사용자가 넣은 뒤 고른 키인지 알 수 없다.
        // 모르면 지우지 않고(고른 키를 잃지 않는다) 연결 안 된 초안으로 남기며, 알림은 누가 만들었는지 단정하지 않는다.
        let fixture = try RekordboxFixture()
        let (store, staged, row) = try await keyedStaged(fixture, key: "12B")
        defer { clearTagDrafts(store) }
        let (uuid, backup) = try await blockedKeyAddWithoutStagedDrafts(store, fixture, staged, row)
        #expect(store.tagDrafts[uuid]?.changedKeys == [.musicalKey])

        try await store.restoreRekordbox(backup, keepingCurrentDrafts: true)
        DraftWriter.flush()
        #expect(store.staged.map(\.uuid) == [staged.uuid])
        let kept = try #require(store.tagDrafts[uuid], "누가 만들었는지 모르면 지우지 않는다")
        #expect(kept.changedKeys == [.musicalKey] && kept.fields.musicalKey == "12B")
        #expect(store.unlinkedDraftUUIDs.contains(uuid), "연결 안 된 초안으로 남아 쓰기 대기 목록에서 버릴 수 있다")
        #expect(store.writeFollowUp == [LibraryStore.keptNewTrackDraftsText(1)].compactMap { $0 }, "\(store.writeFollowUp)")
        let notice = try #require(store.writeFollowUp.first)
        #expect(notice.contains("연결되지 않은 초안") && !notice.contains("새 곡에 만든"), "\(notice)")
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 넣기_백업의_추가_목록_저장이_빠졌어도_새_곡에_남은_초안을_알림_없이_지우지_않는다() async throws {
        // #197: 백업에 `djc-staged.json`이 없으면(저장 실패) 곡이 추가 목록으로 돌아오지 못하고 옮겨 둔 키가 돌아갈 곳도 없다.
        // 키 초안을 지우지 않고 남기며, 새 곡에 만든 초안이라고 단정하지 않는 알림을 보인다. 추가 목록이 비는 것은 그대로다(이 시험은 알림만 고정).
        let fixture = try RekordboxFixture()
        let (store, staged, row) = try await keyedStaged(fixture, key: "12B")
        defer { clearTagDrafts(store) }
        let (uuid, backup) = try await blockedKeyAddWithoutStagedDrafts(store, fixture, staged, row)
        try FileManager.default.removeItem(at: backup.url.appending(path: LibraryStore.stagedBackupName))

        try await store.restoreRekordbox(backup, keepingCurrentDrafts: true)
        DraftWriter.flush()
        #expect(store.staged.isEmpty, "추가 목록을 알 수 없어 곡을 되돌리지 못한다")
        let kept = try #require(store.tagDrafts[uuid])
        #expect(kept.changedKeys == [.musicalKey] && kept.fields.musicalKey == "12B")
        #expect(store.unlinkedDraftUUIDs.contains(uuid))
        let notice = try #require(store.writeFollowUp.first { $0.contains("연결되지 않은 초안") })
        #expect(!notice.contains("새 곡에 만든"), "\(notice)")
    }

    // MARK: - 복원 확인 창의 곡 이름

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 복원_확인_창은_넣기_백업의_충돌을_넣은_곡의_제목으로_보인다() async throws {
        // #197: 넣기 백업에는 쓰기 보고서가 없고, 넣은 추가 목록 곡은 더는 목록의 곡 행이 아니다. 제목을 못 찾으면 UUID가 보였다.
        // 넣은 뒤 그 곡의 연결 안 된 큐 초안을 새로 편집한 채 그 백업으로 되돌리려는 경우다(넣기 → 되돌리기 → 큐 고침 → 다시 넣기 → 첫 백업으로 되돌리기와 같다).
        let fixture = try RekordboxFixture()
        let (store, staged, row) = try await keyedStaged(fixture, key: "8A")
        DraftWriter.save(cue(staged.uuid, time: 1))
        DraftWriter.flush()
        defer {
            clearTagDrafts(store)
            clearDrafts(staged.uuid)
        }
        let preview = try await store.previewTrackAdd(rows: [row])
        _ = try await store.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        #expect(backup.report == nil && backup.trackReport != nil && store.rowsByUUID[staged.uuid] == nil)
        #expect(store.restoreDraftConflictDetails(backup).isEmpty)

        DraftWriter.save(cue(staged.uuid, time: 9))
        DraftWriter.flush()
        let line = try #require(store.restoreDraftConflictDetails(backup).first)
        #expect(store.restoreDraftConflictDetails(backup).count == 1)
        #expect(line == "• \(staged.title) — 큐", "\(line)")
        #expect(!line.contains(staged.uuid))
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
