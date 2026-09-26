import DJCDomain
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// 커밋 뒤 확인·분석 파일 쓰기가 실패했을 때: 백업으로 되돌렸는지, 되돌리지도 못했는지를 다른 오류로 알린다.
/// 쓰기 코드는 그대로 두고 실패는 밖에서 일으킨다(변경 카운터를 올릴 때 도는 트리거, 잠근 폴더).
@Suite("rekordbox 쓰기 실패 뒤 복원")
struct RekordboxRestoreFailureTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)

    /// 트랜잭션 안 검증이 끝난 뒤(변경 카운터를 올리는 순간) `sql`을 돈다. 커밋 뒤 다시 읽으면 쓴 것과 달라져 있다.
    func tamperOnCommit(_ fixture: RekordboxFixture, _ sql: String) throws {
        try fixture.execute("CREATE TRIGGER djc_test_tamper AFTER UPDATE OF int_1 ON agentRegistry BEGIN \(sql); END")
    }

    /// 폴더를 잠근다(안에 쓰거나 지울 수 없게). 끝나면 `unlock`으로 풀어야 픽스처가 지워진다.
    func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
    }

    func unlock(_ fixture: RekordboxFixture) {
        let fm = FileManager.default
        let all = [fixture.root] + (fm.enumerator(at: fixture.root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
        for url in all where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// 복원이 임시로 쓰는 자리(`master.db.djc-restore`)에 지울 수 없는 폴더를 두어 백업 복원을 막는다.
    func blockRestore(_ fixture: RekordboxFixture) throws {
        let blocker = URL(filePath: fixture.database.path + ".djc-restore")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker.appending(path: "keep"))
        try lock(blocker)
    }

    /// 쓰기가 건드리는 표
    func state(_ fixture: RekordboxFixture) throws -> [[String: String]] {
        try ["djmdContent", "djmdCue", "contentCue", "contentFile", "djmdMixerParam", "agentRegistry"]
            .flatMap { try fixture.rows("SELECT * FROM \($0) ORDER BY 1") }
    }

    func cueDraft(_ fixture: RekordboxFixture) throws -> CueDraft {
        let track = try fixture.add(TrackSpec())
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: [])
        draft.place(EditableCue(kind: .memory, time: 30))
        return draft
    }

    func writeCue(_ fixture: RekordboxFixture, _ draft: CueDraft) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: [draft], to: fixture.database, dryRun: false, now: now, backups: fixture.backups)
    }

    // MARK: 큐 쓰기

    @Test func 커밋_전에_확인이_실패하면_쓰지_않았다고_알린다() throws {
        let fixture = try RekordboxFixture()
        let draft = try cueDraft(fixture)
        // 카운터를 올린 직전에 한 번 더 올려 두면 트랜잭션 안에서 카운터가 맞지 않는다
        try tamperOnCommit(fixture, "UPDATE agentRegistry SET int_1 = int_1 + 1 WHERE registry_id = 'localUpdateCount'")
        let before = try state(fixture)
        let error = try #require(throws: DJCError.self) { try writeCue(fixture, draft) }
        guard case let .writeVerificationFailed(reason) = error else { Issue.record("커밋 전 실패가 아님: \(error)"); return }
        #expect(reason == "변경 카운터가 맞지 않습니다")
        #expect(error.description == "쓴 결과가 의도와 달라 rekordbox에 쓰지 않았습니다: 변경 카운터가 맞지 않습니다")
        #expect(try state(fixture) == before)
    }

    @Test func 커밋_뒤_확인이_실패하면_백업으로_되돌리고_그렇게_알린다() throws {
        let fixture = try RekordboxFixture()
        let draft = try cueDraft(fixture)
        try tamperOnCommit(fixture, "UPDATE contentCue SET rb_cue_count = rb_cue_count + 100")
        let before = try state(fixture)
        let error = try #require(throws: DJCError.self) { try writeCue(fixture, draft) }
        guard case let .writeRolledBack(reason) = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(reason.hasPrefix("큐 기록의 개수·변경 번호가 다릅니다"), "머리말 없이 사유만")
        #expect(error.description.hasPrefix("쓴 결과를 확인하지 못해 쓰기 전 백업으로 되돌렸습니다: 큐 기록의"))
        #expect(try state(fixture) == before)
    }

    @Test func 커밋_뒤_확인도_복원도_실패하면_복원_실패로_알리고_되돌릴_명령을_준다() throws {
        let fixture = try RekordboxFixture()
        defer { unlock(fixture) }
        let draft = try cueDraft(fixture)
        try tamperOnCommit(fixture, "UPDATE contentCue SET rb_cue_count = rb_cue_count + 100")
        let before = try state(fixture)
        try blockRestore(fixture)
        let error = try #require(throws: DJCError.self) { try writeCue(fixture, draft) }
        guard case let .restoreFailed(reason, restoreError, backup, database) = error else {
            Issue.record("복원 실패 오류가 아님: \(error)")
            return
        }
        #expect(reason.hasPrefix("큐 기록의 개수·변경 번호가 다릅니다") && !restoreError.isEmpty)
        #expect(database == fixture.database.path, "사본 DB는 --db로 되돌린다")
        #expect(FileManager.default.fileExists(atPath: URL(filePath: backup).appending(path: "master.db").path))
        #expect(error.description.contains("rekordbox를 켜지 말고"))
        #expect(error.description.contains("djc rekordbox-restore --backup '\(backup)' --db '\(fixture.database.path)'"))
        #expect(try state(fixture) != before, "복원하지 못했으니 쓴 상태 그대로")

        // 안내한 대로 백업으로 되돌리면 쓰기 전으로 돌아온다
        unlock(fixture)
        _ = try RekordboxWriter.restore(URL(filePath: backup), to: fixture.database, now: now.addingTimeInterval(60), backups: fixture.backups)
        #expect(try state(fixture) == before)
    }

    // MARK: 그리드 파일

    func gridDraft(_ fixture: RekordboxFixture) throws -> (GridDraft, TrackSpec) {
        let (track, _) = try RekordboxGridWriterTests().makeTrack(fixture)
        var grid = GridDraft(trackUUID: track.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: track)))
        grid.setBPM(130, at: 0)
        return (grid, track)
    }

    func writeGrid(_ fixture: RekordboxFixture, _ grid: GridDraft) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: [], grids: [grid], to: fixture.database, dryRun: false, now: now,
                                  backups: fixture.backups, shareRoot: fixture.shareRoot)
    }

    @Test func 그리드_파일을_못_쓰면_큐_없이_DB만_바꾼_쓰기도_되돌린다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        defer { unlock(fixture) }
        let (grid, track) = try gridDraft(fixture)
        let before = try state(fixture)
        let dat = try Data(contentsOf: fixture.analysisURL(for: track))
        try lock(fixture.analysisURL(for: track).deletingLastPathComponent())
        let error = try #require(throws: DJCError.self) { try writeGrid(fixture, grid) }
        guard case .writeRolledBack = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(try state(fixture) == before, "곡 BPM·파일 행도 쓰기 전으로")
        #expect(try Data(contentsOf: fixture.analysisURL(for: track)) == dat)
    }

    @Test func 그리드_파일도_DB도_되돌리지_못하면_복원_실패() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        defer { unlock(fixture) }
        let (grid, track) = try gridDraft(fixture)
        try lock(fixture.analysisURL(for: track).deletingLastPathComponent())
        try blockRestore(fixture)
        let error = try #require(throws: DJCError.self) { try writeGrid(fixture, grid) }
        guard case let .restoreFailed(_, restoreError, backup, _) = error else { Issue.record("복원 실패 오류가 아님: \(error)"); return }
        #expect(restoreError.contains("master.db"))
        #expect(FileManager.default.fileExists(atPath: URL(filePath: backup).appending(path: "anlz/manifest.json").path),
                "분석 파일 원본도 백업에 있어 명령 하나로 되돌린다")
    }

    // MARK: 곡 넣기

    func addWithAnalysis(_ fixture: RekordboxFixture, now: Date) async throws -> RekordboxTrackWriter.Report {
        let p = try await RekordboxTrackWriterTests().plan("mp3-tagged.mp3")
        let analysis = RekordboxTrackWriter.Analysis(segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], loudness: -8, peak: 0.9)
        return try RekordboxTrackWriter.add([p], analyses: [p.path: analysis], to: fixture.database, shareRoot: fixture.shareRoot,
                                            dryRun: false, now: now, backups: fixture.backups)
    }

    @Test func 곡을_넣은_뒤_분석_파일을_못_쓰면_되돌리고_복원도_못하면_따로_알린다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 3000)
        defer { unlock(fixture) }
        try fixture.add(TrackSpec())
        let usbanlz = fixture.shareRoot.appending(path: "PIONEER/USBANLZ")
        try FileManager.default.createDirectory(at: usbanlz, withIntermediateDirectories: true)
        try lock(usbanlz)
        let before = try state(fixture)

        let rolledBack = await #expect(throws: DJCError.self) { try await addWithAnalysis(fixture, now: now) }
        guard case .writeRolledBack? = rolledBack else { Issue.record("되돌림 오류가 아님: \(String(describing: rolledBack))"); return }
        #expect(try state(fixture) == before)

        try blockRestore(fixture)
        let failed = await #expect(throws: DJCError.self) { try await addWithAnalysis(fixture, now: now.addingTimeInterval(1)) }
        guard case let .restoreFailed(_, _, backup, database)? = failed else { Issue.record("복원 실패 오류가 아님: \(String(describing: failed))"); return }
        #expect(backup.hasSuffix("-add"))
        #expect(database == fixture.database.path)
    }

    @Test func 곡을_넣은_뒤_다시_읽기가_실패해도_복원_성공과_실패를_가른다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 3000)
        defer { unlock(fixture) }
        try fixture.add(TrackSpec())   // 라이브러리 기기 정보를 읽을 곡
        try tamperOnCommit(fixture, "UPDATE djmdContent SET Title = Title || ' (바뀜)'")
        let p = try await RekordboxTrackWriterTests().plan("mp3-tagged.mp3")
        let before = try state(fixture)
        let add = { (at: Date) in try RekordboxTrackWriter.add([p], to: fixture.database, dryRun: false, now: at, backups: fixture.backups) }

        let rolledBack = try #require(throws: DJCError.self) { try add(now) }
        guard case let .writeRolledBack(reason) = rolledBack else { Issue.record("되돌림 오류가 아님: \(rolledBack)"); return }
        #expect(reason.contains("행이 넣은 값과 다릅니다"))
        #expect(try state(fixture) == before)

        try blockRestore(fixture)
        let failed = try #require(throws: DJCError.self) { try add(now.addingTimeInterval(1)) }
        guard case .restoreFailed = failed else { Issue.record("복원 실패 오류가 아님: \(failed)"); return }
    }

    // MARK: 문구

    @Test func 복원_실패_문구는_라이브_DB면_live로_되돌리게_한다() {
        let error = DJCError.restoreFailed(reason: "무결성 검사 실패: x", restoreError: "master.db: 권한 없음",
                                           backup: "/Users/a/Application Support/DJCrate/rekordbox-backups/2026-09-26T120000-write", database: nil)
        let lines = error.description.components(separatedBy: "\n")
        #expect(lines.first == "쓴 결과를 확인하지 못했고 백업으로 자동 복원도 하지 못했습니다. rekordbox 라이브러리(master.db)와 분석 파일이 어떤 상태인지 알 수 없습니다.")
        #expect(lines.contains("rekordbox를 켜지 말고 먼저 쓰기 전 백업으로 되돌리세요: "
                               + "djc rekordbox-restore --backup '/Users/a/Application Support/DJCrate/rekordbox-backups/2026-09-26T120000-write' --live"))
        #expect(lines.contains("확인 실패: 무결성 검사 실패: x") && lines.contains("복원 실패: master.db: 권한 없음"))
        #expect(DJCError.restoreCommand(backup: "/b/it's", database: "/c d/master.db") == #"djc rekordbox-restore --backup '/b/it'\''s' --db '/c d/master.db'"#)
    }

    @Test func 사유만_넘겨_머리말이_두_번_붙지_않는다() {
        #expect(DJCError.reason(of: DJCError.writeVerificationFailed("곡의 변경 번호가 다릅니다")) == "곡의 변경 번호가 다릅니다")
        #expect(DJCError.reason(of: DJCError.writeRolledBack("무결성 검사 실패")) == "무결성 검사 실패")
        #expect(DJCError.reason(of: DJCError.writeRefused("rekordbox가 켜져 있습니다")) == "rekordbox에 쓰지 않았습니다: rekordbox가 켜져 있습니다")
        let file = DJCError.reason(of: CocoaError(.fileWriteNoPermission))
        #expect(!file.isEmpty && !file.contains("NSCocoaErrorDomain"), "파일 오류는 UserInfo 덤프가 아니라 문장으로")
    }
}
