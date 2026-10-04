import DJCDomain
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// 동기화 상태 곡 빼기·합치기 막기(#196).
/// rekordbox 7.2.18은 동기화한 곡을 지울 때 행을 지우지 않고 삭제 표시(`rb_local_deleted` 1, 상태 258 → 클라우드 처리 뒤 262)로 남긴다.
/// 곡 빼기·합치기 규칙은 상태 0 시험 곡으로만 실험했으므로, 상태가 0이 아닌 곡·행이 걸리면 묶음 3 실험(세션 D3)으로 규칙을 확인하기 전까지 막는다.
@Suite("동기화 상태 곡 빼기·합치기 막기")
struct SyncedTrackRemovalTests {
    let writer = RekordboxTrackWriterTests()
    let merge = DuplicateMergeWriterTests()

    static let tables = ["djmdContent", "djmdCue", "contentCue", "contentFile", "djmdMixerParam", "djmdSongPlaylist", "djmdSongHistory",
                         "djmdArtist", "djmdAlbum", "djmdPlaylist"]

    func snapshot(_ fixture: RekordboxFixture) throws -> [[[String: String]]] {
        try Self.tables.map { try fixture.rows("SELECT * FROM \($0) ORDER BY ID") }
    }

    func setStatus(_ fixture: RekordboxFixture, _ table: String, _ column: String, _ id: String, _ status: Int) throws {
        try fixture.execute("UPDATE \(table) SET rb_data_status = ? WHERE \(column) = ?", [.int(status), .text(id)])
    }

    // MARK: 곡 빼기

    @Test(arguments: [256, 257, 258, 262])
    func 동기화_상태_곡은_빼지_않고_행도_파일도_번호도_그대로_둔다(_ status: Int) throws {
        let (fixture, a, _) = try writer.deleteFixture()
        try setStatus(fixture, "djmdContent", "ID", a.id, status)
        let before = try snapshot(fixture)
        let report = try writer.delete(fixture, [a.id])
        let outcome = try #require(report.deleted.first)
        #expect(outcome.written == false && outcome.reason == RekordboxTrackWriter.syncedTrackReason)
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 2000)
        #expect(report.removedFiles.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/USBANLZ/aaa/00000-0000-4000-8000-000000000001/ANLZ0000.DAT").path))
        #expect(FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/Artwork/aaa/00000-0000-4000-8000-000000000001/artwork.jpg").path))
    }

    /// 한 요청에 섞여 있어도 곡마다 막는다. 막힌 곡이 먼저여도 변경 번호는 지운 곡 몫만 쓴다(단독 삭제 골든과 같은 수치).
    @Test func 같은_요청의_상태_0_곡은_그대로_지운다() throws {
        let (fixture, a, b) = try writer.deleteFixture()
        let bBefore = try fixture.rows("SELECT * FROM djmdContent WHERE ID = ?", [.text(b.id)])
        let report = try writer.delete(fixture, [b.id, a.id])
        #expect(report.deleted.map(\.written) == [false, true])
        #expect(report.deleted.first?.reason == RekordboxTrackWriter.syncedTrackReason)
        #expect(try fixture.rows("SELECT ID FROM djmdContent ORDER BY ID").map { $0["ID"] } == [b.id])
        #expect(try fixture.rows("SELECT * FROM djmdContent WHERE ID = ?", [.text(b.id)]) == bBefore)
        for table in ["djmdSongPlaylist", "djmdSongHistory"] {
            let entry = try #require(try fixture.rows("SELECT TrackNo, rb_local_usn, updated_at FROM \(table) WHERE ContentID = ?", [.text(b.id)]).first)
            #expect(entry == ["TrackNo": "1", "rb_local_usn": "2001", "updated_at": writer.stamp], "\(table)")
        }
        #expect(try fixture.localUpdateCount() == 2001)
        #expect(report.finalUpdateCount == 2001)
        #expect(report.removedFiles.count == 3)
    }

    @Test func 미리_보기도_같은_이유로_막고_아무것도_바꾸지_않는다() throws {
        let (fixture, a, b) = try writer.deleteFixture()
        let before = try snapshot(fixture)
        let report = try RekordboxTrackWriter.delete(contentIDs: [b.id, a.id], from: fixture.database, shareRoot: fixture.shareRoot,
                                                     dryRun: true, now: writer.now, backups: fixture.backups)
        #expect(report.deleted.map(\.written) == [false, true])
        #expect(report.deleted[0].reason == RekordboxTrackWriter.syncedTrackReason && report.deleted[0].contentID == b.id)
        #expect(report.backup == nil && report.removedFiles.isEmpty)
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 2000)
    }

    @Test(arguments: ["djmdCue", "contentCue", "contentFile", "djmdMixerParam", "djmdSongPlaylist", "djmdSongHistory"])
    func 상태_0_곡도_딸린_행이_동기화_상태면_막는다(_ table: String) throws {
        let (fixture, a, _) = try writer.deleteFixture()
        try setStatus(fixture, table, "ContentID", a.id, 256)
        let before = try snapshot(fixture)
        let report = try writer.delete(fixture, [a.id])
        #expect(report.deleted.first?.written == false && report.deleted.first?.reason == RekordboxTrackWriter.syncedRowsReason)
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 2000)
    }

    /// 지우는 앨범·아티스트 행이 동기화 상태이면(상태 0 곡이 동기화된 기존 아티스트·앨범을 쓰는 건 흔하다) 곡도 막는다.
    @Test(arguments: [("djmdAlbum", "10"), ("djmdArtist", "1"), ("djmdArtist", "3")], [256, 257])
    func 이_곡만_쓰던_앨범_아티스트_행이_동기화_상태면_막는다(_ row: (table: String, id: String), _ status: Int) throws {
        let (fixture, a, _) = try writer.deleteFixture()
        try setStatus(fixture, row.table, "ID", row.id, status)
        let before = try snapshot(fixture)
        let report = try writer.delete(fixture, [a.id])
        #expect(report.deleted.first?.written == false && report.deleted.first?.reason == RekordboxTrackWriter.syncedOrphanReason)
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 2000)
    }

    @Test func 다른_곡이_쓰는_동기화_아티스트는_지우지_않으니_막지_않는다() throws {
        let (fixture, a, _) = try writer.deleteFixture()
        try setStatus(fixture, "djmdArtist", "ID", "2", 256)
        let shared = try fixture.rows("SELECT * FROM djmdArtist WHERE ID = '2'")
        let report = try writer.delete(fixture, [a.id])
        #expect(report.deleted.first?.written == true)
        #expect(try fixture.rows("SELECT * FROM djmdArtist WHERE ID = '2'") == shared)
    }

    /// 앨범은 남는 곡이 쓰면 지우지 않는다. 그 앨범이 동기화 행이어도 막을 이유가 없다.
    @Test func 남는_곡이_같은_동기화_앨범을_쓰면_막지_않는다() throws {
        let (fixture, a, b) = try writer.deleteFixture()
        try setStatus(fixture, "djmdAlbum", "ID", "10", 256)
        try fixture.execute("UPDATE djmdContent SET AlbumID = '10' WHERE ID = ?", [.text(b.id)])
        let report = try writer.delete(fixture, [a.id])
        #expect(report.deleted.first?.written == true)
        #expect(try fixture.rows("SELECT ID, rb_data_status FROM djmdAlbum") == [["ID": "10", "rb_data_status": "256"]])
    }

    // MARK: 합치기

    @Test func 동기화_상태_원본이_있으면_합치기_초안을_만들지_않는다() throws {
        let fixture = try merge.fixture(statuses: ["200": 256])
        do {
            _ = try merge.draft(fixture)
            Issue.record("막혀야 합니다")
        } catch let blocked as DuplicateMerge.Blocked {
            #expect(blocked.reason == RekordboxTrackWriter.syncedTrackReason)
        }
    }

    @Test(arguments: [256, 257])
    func 초안을_만든_뒤_원본이_동기화되면_쓰기에서_막고_아무것도_바꾸지_않는다(_ status: Int) throws {
        let fixture = try merge.fixture()
        let draft = try merge.draft(fixture)
        try setStatus(fixture, "djmdContent", "ID", "200", status)
        let before = try snapshot(fixture)
        let report = try merge.write(fixture, draft)
        #expect(report.mergeWritten.isEmpty && report.mergeBlocked.count == 1)
        #expect(report.mergeBlocked[0].reason == RekordboxTrackWriter.syncedTrackReason)
        #expect(report.backup == nil)
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 1000)
    }

    /// 남는 곡이 동기화 곡이어도 합칠 수 있다: 큐·재생 목록 편집은 동기화 상태를 256 → 257로 올리는 검증된 쓰기 경로를 쓴다.
    @Test func 남는_곡이_동기화_상태여도_합치고_남는_곡은_257이_된다() throws {
        let fixture = try merge.fixture(statuses: ["100": 256])
        let report = try merge.write(fixture, try merge.draft(fixture))
        #expect(report.mergeWritten.count == 1)
        #expect(try fixture.rows("SELECT ID FROM djmdContent ORDER BY ID").map { $0["ID"] } == ["100", "300"])
        #expect(try fixture.rows("SELECT rb_data_status FROM djmdContent WHERE ID = '100'") == [["rb_data_status": "257"]])
        #expect(try fixture.rows("SELECT Kind, InMsec FROM djmdCue WHERE ContentID = '100' ORDER BY InMsec").count == 2)
    }

    @Test func 원본만_쓰던_동기화_아티스트가_있으면_합치기_초안을_만들지_않는다() throws {
        let fixture = try merge.fixture()
        try fixture.insert("djmdArtist", ["ID": .text("1"), "Name": .text("동기화"), "UUID": .text("a1"), "rb_local_deleted": .int(0), "rb_data_status": .int(256)])
        try fixture.execute("UPDATE djmdContent SET ArtistID = '1' WHERE ID = '200'")
        do {
            _ = try merge.draft(fixture)
            Issue.record("막혀야 합니다")
        } catch let blocked as DuplicateMerge.Blocked {
            #expect(blocked.reason == RekordboxTrackWriter.syncedOrphanReason)
        }
        // 남는 곡도 그 아티스트를 쓰면 아티스트 행은 지우지 않으니 막지 않는다
        try fixture.execute("UPDATE djmdContent SET ArtistID = '1' WHERE ID = '100'")
        _ = try merge.draft(fixture)
    }

    /// 원본 둘이 함께 쓰던 동기화 아티스트는 둘 다 빠지면 아무도 안 쓴다. 곡 하나씩 보면 놓치므로 함께 빠지는 곡을 같이 센다.
    @Test func 원본_둘이_함께_쓰던_동기화_아티스트도_합치기_초안에서_막는다() throws {
        let fixture = try merge.fixture()
        try fixture.insert("djmdArtist", ["ID": .text("1"), "Name": .text("동기화"), "UUID": .text("a1"), "rb_local_deleted": .int(0), "rb_data_status": .int(257)])
        try fixture.execute("UPDATE djmdContent SET ArtistID = '1' WHERE ID IN ('200', '300')")
        #expect(throws: DuplicateMerge.Blocked.self) {
            try RekordboxWriter.prepareMerge(keeping: "100", removing: ["200", "300"], snapshot: fixture.database)
        }
    }

    /// 원본 목록 항목은 검증된 목록 경로로 먼저 빠지므로 합치기는 목록 항목 상태로 막지 않는다. 그 밖의 딸린 행(여기서는 파일 행)이
    /// 동기화 상태이면 지우는 자리에서 막고, 앞서 쓴 큐·목록 편집과 변경 번호까지 되돌린다.
    @Test func 원본의_다른_딸린_행이_동기화_상태이면_쓰기_중에_막고_모두_되돌린다() throws {
        let fixture = try merge.fixture()
        var source = TrackSpec(id: "200")
        source.dataStatus = 256
        try fixture.addContentFile(for: source, hash: "h", size: 1)
        let draft = try merge.draft(fixture)
        let before = try snapshot(fixture)
        let report = try merge.write(fixture, draft)
        #expect(report.mergeWritten.isEmpty && report.mergeBlocked.count == 1)
        #expect(report.mergeBlocked[0].reason == RekordboxTrackWriter.syncedRowsReason)
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 1000)
    }
}
