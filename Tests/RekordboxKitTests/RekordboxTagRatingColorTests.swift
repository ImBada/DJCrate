import DJCDomain
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// 평점·곡 색 쓰기(#65, `rating`·`color`): 곡 행 `Rating`(정수)·`ColorID`(글자)만 고친다.
/// 규칙은 rekordbox 7.2.18 실험에서 확인했다(docs/rekordbox-internals.md "평점·곡 색"):
/// - 2026-10-04 묶음 2(자동 분석 끔, 동기화 상태 0 곡, 세션마다 곡당 한 칸):
///   평점 "DJC 시험 02" S1 0 → 3(`TrackInfoUpdated` '1' → '2'), S2 3 → 5('2' → '3'), S3 5 → 0(NULL 아님, 저장 한 번이면 +1).
///   곡 색 "DJC 시험 04" S1 '0' → '2'(Red, '1' → '2'), S2 '2' → '7'(Blue, '2' → '3'), S3 '7' → '0'(글자, ''·NULL 아님, '3' → '4').
///   함께 바뀐 칸은 `TrackInfoUpdated`(+1, 글자)·`rb_local_usn`·`updated_at`뿐이고 `djmdColor`·다른 표·음원은 그대로였다.
/// - 실험 곡은 살아 있는 재생 목록에 없었다(XML Timestamp 미확인). 동기화 곡(256·257)은 사본 재현 전이라 막는다(`TagWriteScope.byKey`).
extension RekordboxTagWriterTests {
    /// 묶음 2 사본의 `djmdColor` 여덟 줄(`ID` 글자, `SortKey`, `Commnt`, `ColorCode` NULL)
    static let colorRows = TrackColor.rekordboxDefaults

    /// 색 줄을 넣은 라이브러리. 곡 500·501은 실험 곡처럼 평점 0·색 '0'·`TrackInfoUpdated` '1'이다.
    func ratingLibrary(state: Int = 0, shared: Bool = true) throws -> (RekordboxFixture, TrackSpec) {
        let (fixture, track) = state == 0 ? try library(shared: shared) : try syncedLibrary(state: state, shared: shared)
        for (index, color) in Self.colorRows.enumerated() {
            try fixture.insert("djmdColor", ["ID": .text(color.id), "ColorCode": .null, "SortKey": .int(index + 1), "Commnt": .text(color.name),
                                             "UUID": .text("c-\(color.id)"), "rb_data_status": .int(256), "rb_local_deleted": .int(0),
                                             "rb_local_usn": .int(1_234)])
        }
        try fixture.execute("UPDATE djmdContent SET Rating = 0, ColorID = '0' WHERE ID IN ('500', '501')")
        if state == 0 { try fixture.execute("UPDATE djmdContent SET TrackInfoUpdated = '1' WHERE ID = '500'") }
        return (fixture, track)
    }

    func raw(_ fixture: RekordboxFixture, _ column: String, _ id: String = "500") throws -> (value: String, type: String) {
        let row = try #require(fixture.rows("SELECT quote(\(column)) AS v, typeof(\(column)) AS t FROM djmdContent WHERE ID = ?", [.text(id)]).first)
        return (row["v"] ?? "", row["t"] ?? "")
    }

    // MARK: 골든 — 상태 0 (묶음 2 S1·S2·S3)

    @Test func 상태_0_곡의_평점_넣기_바꾸기_지우기는_rekordbox_7이_저장한_모양과_같다() throws {
        let (fixture, track) = try ratingLibrary()
        let others = try otherTables(fixture)
        let saved: Set<String> = ["Rating", "TrackInfoUpdated", "rb_local_usn", "updated_at"]

        // S1: 0 → 3, '1' → '2', 상태 0 그대로
        var before = try content(fixture)
        var report = try write(fixture, tags: [try draft(fixture, track) { $0.rating = "3" }])
        #expect(report.tagWritten.first?.fields == ["rating"] && report.tagBlocked.isEmpty)
        var after = try content(fixture)
        #expect(changedColumns(before, after) == saved)
        #expect(try raw(fixture, "Rating") == ("3", "integer") && after["TrackInfoUpdated"] == "2" && after["rb_data_status"] == "0")
        #expect(try after["updated_at"] == stamp && fixture.rows("SELECT typeof(TrackInfoUpdated) AS t FROM djmdContent WHERE ID = '500'").first?["t"] == "text")
        #expect(try Int(after["rb_local_usn"] ?? "") == fixture.localUpdateCount() && fixture.localUpdateCount() == 2001)

        // S2: 3 → 5, '2' → '3'
        before = after
        report = try write(fixture, tags: [try draft(fixture, track) { $0.rating = "5" }])
        #expect(report.tagWritten.count == 1)
        after = try content(fixture)
        #expect(changedColumns(before, after) == ["Rating", "TrackInfoUpdated", "rb_local_usn"], "같은 시각이라 updated_at은 같은 값")
        #expect(try raw(fixture, "Rating") == ("5", "integer") && after["TrackInfoUpdated"] == "3")

        // S3: 5 → 0(정수, NULL 아님), 저장 한 번이면 +1(rekordbox는 이 세션에서 다섯 번 저장해 +5였다)
        before = after
        report = try write(fixture, tags: [try draft(fixture, track) { $0.rating = "" }])
        #expect(report.tagWritten.count == 1)
        after = try content(fixture)
        #expect(changedColumns(before, after) == ["Rating", "TrackInfoUpdated", "rb_local_usn"])
        #expect(try raw(fixture, "Rating") == ("0", "integer") && after["TrackInfoUpdated"] == "4")
        #expect(try fixture.localUpdateCount() == 2003)
        #expect(try otherTables(fixture) == others, "다른 표는 한 줄도 바뀌지 않는다")
    }

    @Test func 상태_0_곡의_곡_색_넣기_바꾸기_지우기는_rekordbox_7이_저장한_모양과_같다() throws {
        let (fixture, track) = try ratingLibrary()
        let colors = try fixture.rows("SELECT * FROM djmdColor ORDER BY ID")
        let others = try otherTables(fixture)

        // S1: '0' → '2'(Red), '1' → '2'
        var before = try content(fixture)
        var report = try write(fixture, tags: [try draft(fixture, track) { $0.color = "2" }])
        #expect(report.tagWritten.first?.fields == ["color"] && report.tagBlocked.isEmpty)
        var after = try content(fixture)
        #expect(changedColumns(before, after) == ["ColorID", "TrackInfoUpdated", "rb_local_usn", "updated_at"])
        #expect(try raw(fixture, "ColorID") == ("'2'", "text") && after["TrackInfoUpdated"] == "2" && after["rb_data_status"] == "0")

        // S2: '2' → '7'(Blue), '2' → '3'
        before = after
        report = try write(fixture, tags: [try draft(fixture, track) { $0.color = "7" }])
        #expect(report.tagWritten.count == 1)
        after = try content(fixture)
        #expect(changedColumns(before, after) == ["ColorID", "TrackInfoUpdated", "rb_local_usn"])
        #expect(try raw(fixture, "ColorID") == ("'7'", "text") && after["TrackInfoUpdated"] == "3")

        // S3: 지우기 → '0'(글자, ''·NULL 아님), '3' → '4'
        before = after
        report = try write(fixture, tags: [try draft(fixture, track) { $0.color = "" }])
        #expect(report.tagWritten.count == 1)
        after = try content(fixture)
        #expect(changedColumns(before, after) == ["ColorID", "TrackInfoUpdated", "rb_local_usn"])
        #expect(try raw(fixture, "ColorID") == ("'0'", "text") && after["TrackInfoUpdated"] == "4")
        #expect(try fixture.localUpdateCount() == 2003)
        #expect(try fixture.rows("SELECT * FROM djmdColor ORDER BY ID") == colors, "djmdColor는 고치지 않는다")
        #expect(try otherTables(fixture) == others)
    }

    @Test func 평점과_곡_색과_다른_칸을_한_번에_쓴_결과는_하나씩_쓴_결과와_같다() throws {
        let edit: (inout TagFields) -> Void = { $0.title = "새 제목"; $0.rating = "4"; $0.color = "5" }
        let (together, track) = try ratingLibrary()
        let (oneByOne, same) = try ratingLibrary()
        let report = try write(together, tags: [try draft(together, track, edit)])
        #expect(report.tagWritten.first?.fields == ["title", "rating", "color"])
        for step: (inout TagFields) -> Void in [{ $0.title = "새 제목" }, { $0.rating = "4" }, { $0.color = "5" }] {
            #expect(try write(oneByOne, tags: [try draft(oneByOne, same, step)]).tagWritten.count == 1)
        }
        let columns = "Title, Rating, ColorID, typeof(Rating) AS rt, typeof(ColorID) AS ct, TrackInfoUpdated, rb_data_status"
        let row = try together.rows("SELECT \(columns) FROM djmdContent WHERE ID = '500'")
        #expect(try row == oneByOne.rows("SELECT \(columns) FROM djmdContent WHERE ID = '500'"))
        #expect(row.first?["TrackInfoUpdated"] == "4", "칸마다 +1")
        #expect(try Int(content(together)["rb_local_usn"] ?? "") == together.localUpdateCount() && together.localUpdateCount() == 2001)
    }

    // MARK: 막기 — 확인한 범위 밖

    @Test(arguments: [256, 257]) func 동기화된_곡의_평점과_곡_색은_할_일과_함께_막는다(state: Int) throws {
        // #173 S1 T11·T12(동기화 256 곡의 평점·색)는 사본 재현 전이라 쓰지 않는다
        let (fixture, track) = try ratingLibrary(state: state)
        let before = try content(fixture)
        for edit: (inout TagFields) -> Void in [{ $0.rating = "3" }, { $0.color = "2" }, { $0.title = "새 제목"; $0.rating = "3" }] {
            let report = try write(fixture, tags: [try draft(fixture, track, edit)])
            #expect(report.tagWritten.isEmpty && report.backup == nil)
            let reason = try #require(report.tagBlocked.first?.reason)
            #expect(reason.contains("동기화") && reason.contains("rekordbox에서"))
        }
        #expect(try content(fixture) == before && fixture.localUpdateCount() == 2000)
        // 다른 칸만 고친 초안은 예전처럼 쓴다
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.title = "새 제목" }]).tagWritten.count == 1)
    }

    @Test func 재생_목록에_든_곡의_평점과_곡_색은_막고_XML을_건드리지_않는다() throws {
        let (fixture, track) = try ratingLibrary()
        let url = try withPlaylists(fixture, [PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["500"])])
        let xml = try Data(contentsOf: url), before = try content(fixture)
        for edit: (inout TagFields) -> Void in [{ $0.rating = "3" }, { $0.color = "2" }] {
            let report = try write(fixture, tags: [try draft(fixture, track, edit)])
            #expect(report.tagWritten.isEmpty && report.backup == nil)
            #expect(report.tagBlocked.first?.reason?.contains("재생 목록") == true)
        }
        #expect(try content(fixture) == before && Data(contentsOf: url) == xml)
        // 지운 목록·지운 항목은 세지 않는다
        try fixture.execute("UPDATE djmdSongPlaylist SET rb_local_deleted = 1 WHERE PlaylistID = '201'")
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.rating = "3" }]).tagWritten.count == 1)
        #expect(try Data(contentsOf: url) == xml, "평점·색은 XML을 고치는 칸이 아니다")
    }

    @Test func 막힌_평점_초안은_같은_쓰기의_다른_곡을_막지_않는다() throws {
        let (fixture, track) = try ratingLibrary()
        let neighbor = TrackSpec(id: "501", uuid: "track-uuid-501")
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 256 WHERE ID = '501'")
        let tags = [try draft(fixture, track) { $0.rating = "2" }, try draft(fixture, neighbor) { $0.rating = "4" }]
        let report = try write(fixture, tags: tags)
        #expect(report.tagWritten.map(\.trackUUID) == [track.uuid] && report.tagBlocked.map(\.trackUUID) == [neighbor.uuid])
        #expect(try raw(fixture, "Rating").value == "2" && raw(fixture, "Rating", "501").value == "0")
    }

    @Test func 트랜잭션_안에서도_범위를_다시_본다() throws {
        // 백업 전 확인 뒤에 곡이 동기화 상태가 되어도(같은 초안 묶음 안의 앞 편집 등) 트랜잭션의 확인이 막는다
        let (fixture, track) = try ratingLibrary()
        let tags = try draft(fixture, track) { $0.color = "2" }
        let db = try fixture.open()
        defer { db.close() }
        #expect(throws: Never.self) { _ = try RekordboxWriter.checkTags(tags, db: db, writable: Self.allKeys) }
        try db.execute("UPDATE djmdContent SET rb_data_status = 257 WHERE ID = '500'")
        #expect(throws: RekordboxWriter.Blocked.self) { _ = try RekordboxWriter.checkTags(tags, db: db, writable: Self.allKeys) }
    }

    @Test func 넓힌_범위는_한_곳에서_받는다() throws {
        // 사본 실험(`djc lab tag-write-test`)은 범위 표를 비워(공통 범위) 동기화 곡에도 쓴다(#173 T11·T12 재현용)
        let (fixture, track) = try ratingLibrary(state: 256)
        let report = try RekordboxWriter.write(drafts: [], grids: [], gains: [:], tags: [try draft(fixture, track) { $0.rating = "3" }],
                                               analysisInputs: [:], to: fixture.database, dryRun: false, now: now, backups: fixture.backups,
                                               shareRoot: fixture.shareRoot, attachesAnalysis: false, tagKeys: Self.allKeys, tagScopes: [:])
        #expect(report.tagWritten.count == 1)
        let row = try content(fixture)
        #expect(row["Rating"] == "3" && row["TrackInfoUpdated"] == "3" && row["rb_data_status"] == "257")
    }

    @Test(arguments: ["9", "0", "Red"]) func 색_번호가_여덟_색이_아니면_막는다(value: String) throws {
        let (fixture, track) = try ratingLibrary()
        let before = try content(fixture)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.color = value }])
        #expect(report.tagWritten.isEmpty && report.backup == nil)
        #expect(report.tagBlocked.first?.reason?.contains("곡 색") == true)
        #expect(try content(fixture) == before)
    }

    @Test func 색_목록에_그_색이_없거나_삭제_표시면_막는다() throws {
        let (fixture, track) = try ratingLibrary()
        try fixture.execute("UPDATE djmdColor SET rb_local_deleted = 1 WHERE ID = '3'")
        try fixture.execute("DELETE FROM djmdColor WHERE ID = '4'")
        let before = try content(fixture)
        for id in ["3", "4"] {
            let report = try write(fixture, tags: [try draft(fixture, track) { $0.color = id }])
            #expect(report.tagWritten.isEmpty && report.backup == nil)
            let reason = try #require(report.tagBlocked.first?.reason)
            #expect(reason.contains("색 목록") && reason.contains("rekordbox에서"), "\(id)")
        }
        #expect(try content(fixture) == before)
        // 지우기('0')는 색 목록과 상관없다
        try fixture.execute("UPDATE djmdContent SET ColorID = '2' WHERE ID = '500'")
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.color = "" }]).tagWritten.count == 1)
        #expect(try raw(fixture, "ColorID").value == "'0'")
    }

    @Test(arguments: ["6", "-1", "★"]) func 평점이_1에서_5가_아니면_막는다(value: String) throws {
        let (fixture, track) = try ratingLibrary()
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.rating = value }])
        #expect(report.tagWritten.isEmpty && report.tagBlocked.first?.reason?.contains("평점") == true)
    }

    // MARK: 기준(base)

    @Test func 읽는_값은_라이브러리_읽기와_같다() throws {
        for (rating, color, expected) in [("0", "'0'", ("", "")), ("3", "'2'", ("3", "2")), ("NULL", "NULL", ("", "")), ("5", "''", ("5", "")),
                                           ("2", "'99'", ("2", "99"))] {
            let (fixture, track) = try ratingLibrary()
            try fixture.execute("UPDATE djmdContent SET Rating = \(rating), ColorID = \(color) WHERE ID = '500'")
            let db = try fixture.open()
            let tags = try #require(try RekordboxWriter.currentTags(db: db, contentID: track.id))
            db.close()
            #expect(tags.rating == expected.0 && tags.color == expected.1, "\(rating) \(color)")
            let loaded = try #require(try RekordboxLibrary.load(snapshot: fixture.database).tracks.first { $0.id == "500" })
            #expect(TagFields(track: loaded) == tags, "\(rating) \(color)")
        }
    }

    @Test func 라이브러리는_색_목록과_동기화_상태를_읽는다() throws {
        let (fixture, _) = try ratingLibrary()
        try fixture.execute("UPDATE djmdColor SET rb_local_deleted = 1 WHERE ID = '8'")
        try fixture.execute("UPDATE djmdColor SET SortKey = 0 WHERE ID = '7'")
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 257 WHERE ID = '501'")
        let library = try RekordboxLibrary.load(snapshot: fixture.database)
        #expect(library.colors.map(\.id) == ["7", "1", "2", "3", "4", "5", "6"], "SortKey 순서, 삭제 표시 줄은 뺀다")
        #expect(library.colors.first?.name == "Blue")
        #expect(library.tracks.first { $0.id == "500" }?.dataStatus == 0 && library.tracks.first { $0.id == "501" }?.dataStatus == 257)
    }

    @Test func 평점과_곡_색을_안_고친_초안은_그_사이_rekordbox에서_바뀌어도_쓴다() throws {
        let (fixture, track) = try ratingLibrary()
        let tags = try draft(fixture, track) { $0.comment = "새 코멘트" }
        try fixture.execute("UPDATE djmdContent SET Rating = 4, ColorID = '6' WHERE ID = '500'")
        #expect(try write(fixture, tags: [tags]).tagWritten.count == 1)
        let row = try content(fixture)
        #expect(row["Commnt"] == "새 코멘트" && row["Rating"] == "4" && row["ColorID"] == "6", "쓰지 않는 칸은 그대로")
    }

    @Test func 평점을_고친_초안은_그_사이_rekordbox에서_평점이_바뀌었으면_쓰지_않는다() throws {
        let (fixture, track) = try ratingLibrary()
        let tags = try draft(fixture, track) { $0.rating = "3" }
        try fixture.execute("UPDATE djmdContent SET Rating = 1 WHERE ID = '500'")
        let report = try write(fixture, tags: [tags])
        #expect(report.tagWritten.isEmpty && report.tagBlocked.first?.reason?.contains("rekordbox에서 곡 정보가 바뀌었습니다") == true)
        #expect(try raw(fixture, "Rating").value == "1")
    }

    @Test func 두_칸이_없던_옛_초안은_평점과_색이_있는_곡에서도_막히지_않고_그대로_둔다() throws {
        let (fixture, _) = try ratingLibrary()
        try fixture.execute("UPDATE djmdContent SET Rating = 4, ColorID = '6' WHERE ID = '500'")
        let tags = try legacyDraft()
        #expect(tags.base.rating == "" && tags.base.color == "" && tags.changedKeys == [.title])
        let report = try write(fixture, tags: [tags])
        #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty, "\(report.tagBlocked.map(\.reason))")
        let row = try content(fixture)
        #expect(row["Title"] == "새 제목" && row["Rating"] == "4" && row["ColorID"] == "6")
    }

    // MARK: 다시 읽기 확인

    @Test func 쓴_뒤_Rating과_ColorID_칸_자체를_다시_읽어_확인한다() throws {
        let (fixture, track) = try ratingLibrary()
        try fixture.execute("UPDATE djmdContent SET Rating = 3, ColorID = '2' WHERE ID = '500'")
        _ = try write(fixture, tags: [try draft(fixture, track) { $0.rating = ""; $0.color = "" }])
        let db = try fixture.open()
        defer { db.close() }
        let usn = try #require(Int(try content(fixture)["rb_local_usn"] ?? ""))
        var expectation = RekordboxWriter.TagExpectation(contentID: "500", fields: try #require(try RekordboxWriter.currentTags(db: db, contentID: "500")),
                                                         trackInfoUpdated: "3", contentUSN: usn, dataStatus: 0)
        expectation.rating = 0
        expectation.colorID = "0"
        try RekordboxWriter.verifyTags(db: db, expectation)
        // 조인으로 읽은 값(빈칸)은 같아도 칸 모양이 다르면 실패한다
        for tampered in ["Rating = NULL", "Rating = 'x'", "ColorID = ''", "ColorID = NULL", "ColorID = X'30'"] {
            try db.execute("UPDATE djmdContent SET \(tampered) WHERE ID = '500'")
            #expect(throws: DJCError.self, "\(tampered)") { try RekordboxWriter.verifyTags(db: db, expectation) }
            try db.execute("UPDATE djmdContent SET Rating = 0, ColorID = '0' WHERE ID = '500'")
        }
        try RekordboxWriter.verifyTags(db: db, expectation)
    }

    // MARK: 미리 보기·되돌리기

    @Test func 미리_보기는_쓰고_되돌리고_되돌리기는_곡과_초안을_살린다() throws {
        let (fixture, track) = try ratingLibrary()
        let before = try content(fixture)
        let tags = try draft(fixture, track) { $0.rating = "5"; $0.color = "7" }
        let preview = try write(fixture, tags: [tags], dryRun: true)
        #expect(preview.tagWritten.first?.fields == ["rating", "color"] && preview.backup == nil)
        #expect(try content(fixture) == before)
        let report = try write(fixture, tags: [tags])
        let backup = URL(filePath: try #require(report.backup))
        #expect(RekordboxWriter.tagDrafts(in: backup) == [tags])
        #expect(try raw(fixture, "Rating").value == "5" && raw(fixture, "ColorID").value == "'7'")
        try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups)
        let restored = try content(fixture)
        #expect(restored["Rating"] == "0" && restored["ColorID"] == "0" && restored["TrackInfoUpdated"] == before["TrackInfoUpdated"])
    }

    // MARK: 호환 확인

    @Test func 쓰기_전_확인은_djmdColor의_세_칸이_있어야_한다() throws {
        #expect(RekordboxCompatibility.requiredColumns["djmdColor"] == ["ID", "Commnt", "rb_local_deleted"])
        let (fixture, track) = try ratingLibrary()
        let before = try content(fixture)
        let tags = try draft(fixture, track) { $0.rating = "3" }
        try fixture.execute("ALTER TABLE djmdColor RENAME COLUMN Commnt TO Commnt2")
        #expect(throws: DJCError.self) { try write(fixture, tags: [tags]) }
        #expect(try content(fixture) == before)
    }

    @Test func 앱은_평점과_곡_색_칸을_열고_XML을_고치는_칸에서는_뺀다() {
        #expect(RekordboxWriter.writableTagKeys.isSuperset(of: [.rating, .color]))
        #expect(!RekordboxWriter.playlistXMLTagKeys.contains(.rating) && !RekordboxWriter.playlistXMLTagKeys.contains(.color))
    }
}
