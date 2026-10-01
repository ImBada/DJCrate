@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// #182: 앱의 복원은 저장소가 쓰는 그 DB로만 되돌린다. 기본 라이브 DB로 새면 시험이 실제 라이브러리를 덮는다.
@MainActor
@Suite("복원 대상", .serialized)
struct RestoreTargetTests {
    func makeStore(_ fixture: RekordboxFixture) async -> LibraryStore {
        let store = LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.restore-target.\(UUID())")!, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { DraftWriter.save($0) }, backupDirectory: fixture.backups,
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
        let database = fixture.database
        store.takeLiveSnapshot = { _ in database }
        store.launchArguments = ["test"]
        store.launchEnvironment = [:]
        store.draftHome = FileManager.default.temporaryDirectory.appending(path: "djc-restore-target-\(UUID())")
        store.rekordboxDatabase = fixture.database
        store.rekordboxShareRoot = fixture.shareRoot
        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        return store
    }

    func cueCount(_ fixture: RekordboxFixture) throws -> Int {
        Int(try fixture.rows("SELECT count(*) AS n FROM djmdCue WHERE rb_local_deleted = 0").first?["n"] ?? "") ?? -1
    }

    @Test func 복원은_쓴_사본으로_되돌리고_기본_라이브_자리는_건드리지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let spec = try fixture.add(TrackSpec())
        let store = await makeStore(fixture)
        var draft = CueDraft(trackUUID: spec.uuid, rekordboxCues: [])
        draft.place(EditableCue(kind: .memory, time: 4))
        DraftWriter.save(draft)
        DraftWriter.flush()
        defer {
            DraftWriter.removeCue(trackUUID: spec.uuid)
            DraftWriter.flush()
        }
        _ = try await store.writeToRekordbox([draft])
        #expect(try cueCount(fixture) == 1)
        let backup = try #require(try RekordboxWriter.backups(in: fixture.backups).first(where: \.isWrite))
        try await store.restoreRekordbox(backup, keepingCurrentDrafts: true)
        #expect(try cueCount(fixture) == 0)
        #expect(!FileManager.default.fileExists(atPath: RekordboxWriter.liveDatabase.path))
    }
}
