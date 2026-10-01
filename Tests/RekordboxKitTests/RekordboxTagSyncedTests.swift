import DJCDomain
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// 동기화 상태(256·257)인 곡의 코멘트 쓰기(#171). 2026-10-01 rekordbox 7.2.18, 실험 곡 "カクシタワタシ"(곡·앨범 상태 256):
/// 곡 정보에서 코멘트만 바꿔 저장하고 종료한 전후 사본과, 같은 곡의 코멘트를 한 번 더 저장한 사본을 칸 단위로 비교했다.
/// - 첫 저장: `Commnt`·`TrackInfoUpdated`(+1, 글자)·`rb_data_status` 256 → 257·`rb_local_usn`·`updated_at`만 바뀌었다.
///   클라우드 `usn`·`rb_local_synced`·`rb_local_data_status`와 앨범 행(상태 256)은 그대로였다.
/// - 다시 저장: 상태 257 그대로, `TrackInfoUpdated` +1.
/// 다른 칸과 상태가 0이 아닌 앨범은 확인하지 않았으므로 칸 이름과 함께 막는다.
extension RekordboxTagWriterTests {
    /// 실험 곡과 같은 상태: 곡·앨범 256, `TrackInfoUpdated` '2', 빈 코멘트(''), 클라우드에서 받은 곡이라 `usn`이 있다.
    func syncedLibrary(state: Int = 256) throws -> (RekordboxFixture, TrackSpec) {
        let (fixture, track) = try library()
        try fixture.execute("""
            UPDATE djmdContent SET rb_data_status = ?, TrackInfoUpdated = '2', usn = 363, rb_local_synced = 0, rb_local_data_status = 0
            WHERE ID = '500'
            """, [.int(state)])
        try fixture.execute("UPDATE djmdAlbum SET rb_data_status = 256 WHERE ID = '31'")
        return (fixture, track)
    }

    func changedColumns(_ before: [String: String], _ after: [String: String]) -> Set<String> {
        Set(after.keys.filter { after[$0] != before[$0] })
    }

    @Test func 동기화_상태에서_연_칸은_코멘트뿐이다() {
        #expect(RekordboxWriter.syncedWritableTagKeys == [.comment])
    }

    // MARK: 골든(2026-10-01 カクシタワタシ)

    @Test func 동기화된_곡의_코멘트는_rekordbox_7이_저장한_모양과_같다() throws {
        let (fixture, track) = try syncedLibrary()
        let album = try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = '31'")
        let before = try content(fixture)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.comment = "DJC 코멘트" }], keys: RekordboxWriter.writableTagKeys)
        #expect(report.tagWritten.first?.fields == ["comment"] && report.tagBlocked.isEmpty)

        // 첫 저장: 256 → 257, 곡 정보 변경 횟수 '2' → '3'(글자), 번호·시각. 나머지 칸과 앨범 행은 그대로.
        let after = try content(fixture)
        #expect(changedColumns(before, after) == ["Commnt", "TrackInfoUpdated", "rb_data_status", "rb_local_usn", "updated_at"])
        #expect(after["Commnt"] == "DJC 코멘트" && after["TrackInfoUpdated"] == "3" && after["rb_data_status"] == "257")
        #expect(after["usn"] == "363" && after["rb_local_synced"] == "0" && after["rb_local_data_status"] == "0" && after["updated_at"] == stamp)
        #expect(try fixture.rows("SELECT typeof(TrackInfoUpdated) AS t FROM djmdContent WHERE ID = '500'").first?["t"] == "text")
        #expect(try Int(after["rb_local_usn"] ?? "") == fixture.localUpdateCount() && fixture.localUpdateCount() == 2001)
        #expect(try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = '31'") == album, "앨범 행은 그대로")

        // 다시 저장: 257 그대로, '3' → '4'
        let again = try write(fixture, tags: [try draft(fixture, track) { $0.comment = "DJC 다시" }], keys: RekordboxWriter.writableTagKeys)
        #expect(again.tagWritten.count == 1)
        let repeated = try content(fixture)
        #expect(changedColumns(after, repeated) == ["Commnt", "TrackInfoUpdated", "rb_local_usn"], "같은 시각이라 updated_at은 같은 값")
        #expect(repeated["TrackInfoUpdated"] == "4" && repeated["rb_data_status"] == "257")
        #expect(try Int(repeated["rb_local_usn"] ?? "") == fixture.localUpdateCount() && fixture.localUpdateCount() == 2002)
        #expect(try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = '31'") == album)
    }

    @Test func 상태가_257인_곡의_코멘트도_쓰고_상태는_그대로다() throws {
        let (fixture, track) = try syncedLibrary(state: 257)
        let before = try content(fixture)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.comment = "DJC 코멘트" }], keys: RekordboxWriter.writableTagKeys)
        #expect(report.tagWritten.count == 1)
        let after = try content(fixture)
        #expect(changedColumns(before, after) == ["Commnt", "TrackInfoUpdated", "rb_local_usn", "updated_at"])
        #expect(after["rb_data_status"] == "257" && after["TrackInfoUpdated"] == "3")
    }

    // MARK: 막기

    @Test func 동기화된_곡의_확인하지_않은_칸은_칸_이름과_함께_막는다() throws {
        let (fixture, track) = try syncedLibrary()
        let before = try content(fixture)
        // 코멘트가 없으면 rekordbox에서 직접 고치라고
        let others = try write(fixture, tags: [try draft(fixture, track) { $0.title = "새 제목"; $0.genre = "새 장르" }],
                               keys: RekordboxWriter.writableTagKeys)
        let reason = try #require(others.tagBlocked.first?.reason)
        #expect(reason.contains("제목·장르") && reason.contains("rekordbox에서 직접") && !reason.contains("코멘트"))
        // 코멘트도 고쳤으면 막힌 칸을 되돌리면 코멘트는 쓸 수 있다고
        let mixed = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "새 아티스트"; $0.comment = "새 코멘트" }],
                              keys: RekordboxWriter.writableTagKeys)
        let mixedReason = try #require(mixed.tagBlocked.first?.reason)
        #expect(mixedReason.contains("아티스트") && mixedReason.contains("되돌리면 코멘트"))
        #expect(others.tagWritten.isEmpty && mixed.tagWritten.isEmpty && others.backup == nil && mixed.backup == nil, "백업 전에 막는다")
        #expect(try content(fixture) == before && fixture.localUpdateCount() == 2000)
    }

    @Test(arguments: [1, 2, 258, 512]) func 확인하지_않은_동기화_상태는_코멘트도_막는다(state: Int) throws {
        let (fixture, track) = try syncedLibrary(state: state)
        let before = try content(fixture)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.comment = "새 코멘트" }])
        #expect(report.tagWritten.isEmpty && report.tagBlocked.first?.reason?.contains("동기화 상태") == true)
        #expect(try content(fixture) == before && fixture.localUpdateCount() == 2000)
    }

    @Test func 동기화된_곡에_큐와_코멘트를_함께_써도_상태는_257이고_곡_행이_마지막_번호다() throws {
        // 큐가 먼저 256 → 257로 올려도 트랜잭션 안의 태그 확인은 257로 통과한다.
        let (fixture, _) = try library()
        var track = TrackSpec(id: "600", uuid: "track-uuid-600")
        track.cues = [.autoCue(at: 1024)]
        try fixture.add(track)
        try fixture.execute("UPDATE djmdContent SET Commnt = '' WHERE ID = '600'")
        var cues = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        cues.place(EditableCue(kind: .memory, time: 20.123))
        let tags = try draft(fixture, track) { $0.comment = "큐와 코멘트" }
        let report = try write(fixture, tags: [tags], drafts: [cues], keys: RekordboxWriter.writableTagKeys)
        #expect(report.written.count == 1 && report.tagWritten.count == 1)
        let row = try content(fixture, "600")
        #expect(row["Commnt"] == "큐와 코멘트" && row["rb_data_status"] == "257" && row["TrackInfoUpdated"] == "2")
        #expect(try Int(row["rb_local_usn"] ?? "") == fixture.localUpdateCount(), "곡 행이 마지막 번호")
    }
}
