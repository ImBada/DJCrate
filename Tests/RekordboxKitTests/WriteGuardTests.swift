import DJCDomain
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// 라이브 rekordbox에 쓰기 전 안전장치와 DB 구조 검사.
@Suite("쓰기 안전장치")
struct WriteGuardTests {
    /// 이 사본을 "라이브"로 보는 가짜 환경
    func liveGuard(running: Bool = false, version: String? = "7.2.18") -> RekordboxWriteGuard {
        RekordboxWriteGuard(isLive: { _ in true }, isRekordboxRunning: { running }, appVersion: { version })
    }

    func draft(_ track: TrackSpec) -> CueDraft {
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: [])
        draft.place(EditableCue(kind: .memory, time: 10))
        return draft
    }

    func write(_ fixture: RekordboxFixture, _ track: TrackSpec, guard writeGuard: RekordboxWriteGuard) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: [draft(track)], to: fixture.database, dryRun: false, backups: fixture.backups,
                                  shareRoot: fixture.shareRoot, guard: writeGuard)
    }

    func refusal(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let DJCError.writeRefused(reason) { return reason } catch { return "\(error)" }
    }

    @Test func rekordbox가_켜져_있으면_쓰지_않는다() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        #expect(refusal { _ = try write(fixture, track, guard: liveGuard(running: true)) }?.contains("켜져") == true)
        #expect(try fixture.rows("SELECT * FROM djmdCue").isEmpty)
    }

    @Test func WAL이_남아_있으면_쓰지_않는다() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        try Data([1, 2, 3]).write(to: URL(filePath: fixture.database.path + "-wal"))
        #expect(refusal { _ = try write(fixture, track, guard: liveGuard()) }?.contains("WAL") == true)
    }

    @Test func 확인하지_않은_rekordbox_버전이면_쓰지_않는다() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        #expect(refusal { _ = try write(fixture, track, guard: liveGuard(version: "7.3.0")) }?.contains("7.3.0") == true)
        // 같은 부 버전(7.2.x)과 설치를 못 찾은 경우는 쓴다
        #expect(try write(fixture, track, guard: liveGuard(version: "7.2.20")).written.count == 1)
    }

    @Test func 설치_버전을_못_찾아도_쓴다() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        #expect(try write(fixture, track, guard: liveGuard(version: nil)).written.count == 1)
    }

    @Test func 큐_표에_모르는_칸이_생기면_쓰지_않는다() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        try fixture.execute("ALTER TABLE djmdCue ADD COLUMN NewLoopMode INTEGER DEFAULT NULL")
        let reason = refusal { _ = try write(fixture, track, guard: .system) }
        #expect(reason?.contains("djmdCue") == true && reason?.contains("NewLoopMode") == true)
    }

    @Test func 쓰는_칸이_없어지면_쓰지_않는다() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        try fixture.execute("ALTER TABLE djmdSongHistory DROP COLUMN TrackNo")
        #expect(refusal { _ = try write(fixture, track, guard: .system) }?.contains("djmdSongHistory.TrackNo") == true)
    }

    /// 곡 빼기·합치기(#196)가 이력 행의 상태를 고치고 지운 표시를 읽으며, 추천 좋아요가 어느 곡을 가리키는지 읽는다. 칸이 없으면 쓰는 도중 SQL이 실패하므로
    /// 백업을 뜨기 전에 막는다. 인덱스가 걸린 칸이라 이름을 바꿔 없앤다(`DROP COLUMN`은 인덱스 칸을 못 없앤다).
    @Test(arguments: [("djmdSongHistory", "rb_data_status"), ("djmdSongHistory", "rb_local_deleted"),
                      ("djmdRecommendLike", "ContentID1"), ("djmdRecommendLike", "ContentID2")])
    func 곡_빼기가_읽고_고치는_칸이_없어지면_백업_전에_막는다(_ column: (table: String, name: String)) throws {
        #expect(RekordboxCompatibility.requiredColumns[column.table]?.contains(column.name) == true)
        let (fixture, a, _) = try RekordboxTrackWriterTests().deleteFixture()
        try fixture.execute("ALTER TABLE \(column.table) RENAME COLUMN \(column.name) TO \(column.name)_renamed")
        let reason = refusal {
            _ = try RekordboxTrackWriter.delete(contentIDs: [a.id], from: fixture.database, shareRoot: fixture.shareRoot, dryRun: false,
                                                backups: fixture.backups)
        }
        #expect(reason?.contains("\(column.table).\(column.name)") == true, "\(reason ?? "")")
        #expect(try fixture.rows("SELECT ID FROM djmdContent WHERE ID = ?", [.text(a.id)]).count == 1)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: fixture.backups.path)) ?? []).isEmpty, "막힐 쓰기는 백업도 뜨지 않는다")
        #expect(try fixture.localUpdateCount() == 2000)
    }

    @Test func 재생_목록_표의_칸이_달라지면_쓰지_않는다() throws {
        // 재생 목록 쓰기가 목록·곡 항목·클라우드 거울 행을 새로 넣으므로 칸이 정확히 같아야 한다
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        try fixture.execute("ALTER TABLE djmdSongPlaylist DROP COLUMN TrackNo")
        try fixture.execute("ALTER TABLE djmdPlaylist ADD COLUMN NewSort INTEGER DEFAULT NULL")
        try fixture.execute("ALTER TABLE djmdCloudFilterPlaylist ADD COLUMN NewFilter INTEGER DEFAULT NULL")
        let reason = refusal { _ = try write(fixture, track, guard: .system) }
        #expect(reason?.contains("djmdSongPlaylist에 없는 칸(TrackNo)") == true && reason?.contains("djmdPlaylist에 모르는 칸(NewSort)") == true
                && reason?.contains("djmdCloudFilterPlaylist에 모르는 칸(NewFilter)") == true, "\(reason ?? "")")
    }

    @Test func 행을_넣는_파일_표_오토게인_표의_칸이_달라지면_쓰지_않는다() throws {
        // 곡 넣기(분석 포함)·분석 붙이기가 contentFile·djmdMixerParam에 새 행을 넣으므로 칸이 정확히 같아야 한다
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        try fixture.execute("ALTER TABLE contentFile DROP COLUMN Hash")
        try fixture.execute("ALTER TABLE djmdMixerParam ADD COLUMN NewGain INTEGER DEFAULT NULL")
        let reason = refusal { _ = try write(fixture, track, guard: .system) }
        #expect(reason?.contains("contentFile에 없는 칸(Hash)") == true && reason?.contains("djmdMixerParam에 모르는 칸(NewGain)") == true,
                "\(reason ?? "")")
    }

    @Test func DB_버전이_다르면_쓰지_않는다() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        try fixture.execute("UPDATE djmdProperty SET DBVersion = '7000'")
        #expect(refusal { _ = try write(fixture, track, guard: .system) }?.contains("7000") == true)
    }

    @Test func 로컬_카운터가_클라우드_동기화_카운터보다_작으면_쓰지_않는다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 1000)
        let track = try fixture.add(TrackSpec())
        try fixture.insert("agentRegistry", ["registry_id": .text("lastUpdateCount"), "int_1": .int(5000)])
        #expect(refusal { _ = try write(fixture, track, guard: .system) }?.contains("클라우드") == true)
        #expect(try fixture.localUpdateCount() == 1000, "카운터도 그대로")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: fixture.backups.path)) ?? []).isEmpty, "막힐 쓰기는 백업도 뜨지 않는다")
        // 동기화 카운터가 더 작으면(보통) 쓴다
        try fixture.execute("UPDATE agentRegistry SET int_1 = 10 WHERE registry_id = 'lastUpdateCount'")
        #expect(try write(fixture, track, guard: .system).written.count == 1)
    }

    @Test func 지금_rekordbox_구조는_통과한다() throws {
        let fixture = try RekordboxFixture()
        let db = try CipherDatabase(path: fixture.database.path, key: RekordboxKey.derive())
        defer { db.close() }
        try RekordboxCompatibility.checkSchema(db)
        try RekordboxCompatibility.checkApp(version: "7.2.18")
    }
}
