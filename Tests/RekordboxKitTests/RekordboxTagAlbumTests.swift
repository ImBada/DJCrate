import DJCDomain
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// 2026-09-27 태그 2단계: DJC 실험곡 1~5·DJC 실험 태그 날짜·중복 A/B, rekordbox 7.2.18.
/// 사본 S0~S5에서 확인한 칸만 연다. 공유 값 변경·동명 앨범 선택·상태가 0이 아닌 앨범은 닫아 둔다(곡 상태 256·257은 코멘트만, #171).
extension RekordboxTagWriterTests {
    @Test(arguments: [false, true]) func 아티스트를_비우면_빈_문자열이고_미참조_행만_지운다(shared: Bool) throws {
        // S2 실험곡 2(미참조 삭제), S5 실험곡 1(공유 이름 보존).
        let (fixture, track) = try library(shared: shared)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "" }])
        #expect(report.tagWritten.count == 1)
        #expect(try content(fixture)["ArtistID"] == "" && content(fixture)["TrackInfoUpdated"] == "4")
        #expect(try fixture.rows("SELECT ID FROM djmdArtist WHERE ID = '11'").count == (shared ? 1 : 0))
        #expect(try fixture.rows("SELECT ID FROM djmdArtist WHERE Name = ''").isEmpty)
        #expect(try fixture.rows("SELECT AlbumArtistID, rb_local_usn FROM djmdAlbum WHERE ID = '31'").first
            == ["AlbumArtistID": "", "rb_local_usn": "2001"])
    }

    @Test(arguments: [false, true]) func 새_앨범의_빈_아티스트는_NULL이_아니고_현재_아티스트를_보존한다(hasArtist: Bool) throws {
        // S1 실험곡 3·S2 실험곡 1(빈 값), S4 실험곡 5·S5 실험곡 4(아티스트 있음).
        let (fixture, track) = try library()
        if hasArtist { try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = '11' WHERE ID = '31'") }
        let original = try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = '31'")
        let tags = try draft(fixture, track) { $0.album = "DJC 태그2 새 앨범" }
        #expect(try write(fixture, tags: [tags]).tagWritten.count == 1)
        let album = try #require(fixture.rows("SELECT * FROM djmdAlbum WHERE Name = 'DJC 태그2 새 앨범'").first)
        #expect(album["AlbumArtistID"] == (hasArtist ? "11" : ""))
        #expect(album["Compilation"] == "0" && album["ImagePath"] == "NULL" && album["SearchStr"] == "NULL")
        #expect(album["rb_data_status"] == "0" && album["rb_local_usn"] == "2001" && album["updated_at"] == stamp)
        #expect(try content(fixture)["AlbumID"] == album["ID"] && content(fixture)["TrackInfoUpdated"] == "4")
        #expect(try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = '31'") == original)
    }

    @Test(arguments: [false, true]) func 기존_앨범을_붙이면_같은_행을_저장한다(hasArtist: Bool) throws {
        // S1 실험곡 4: 실험곡 3이 만든 앨범에 붙임. 같은 이름이 하나이며 앨범 아티스트가 같을 때만 연다.
        let (fixture, track) = try library()
        if hasArtist { try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = '11' WHERE ID = '31'") }
        try fixture.insert("djmdAlbum", ["ID": .text("32"), "Name": .text("있는 앨범"), "AlbumArtistID": hasArtist ? .text("11") : .null])
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.album = "있는 앨범" }]).tagWritten.count == 1)
        #expect(try content(fixture)["AlbumID"] == "32")
        #expect(try fixture.rows("SELECT AlbumArtistID, rb_local_usn, updated_at FROM djmdAlbum WHERE ID = '32'").first
            == ["AlbumArtistID": hasArtist ? "11" : "", "rb_local_usn": "2001", "updated_at": stamp])
    }

    @Test func 단독_앨범_아티스트는_같은_행에서_바꾸고_미참조_이름을_지운다() throws {
        // S2·S3 실험곡 3에서 같은 행 수정·미참조 아티스트 삭제, S5에서 남은 한 곡도 같은 규칙.
        let (fixture, track) = try library(shared: false)
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.albumArtist = "새 앨범 아티스트" }]).tagWritten.count == 1)
        let artist = try #require(fixture.rows("SELECT ID FROM djmdArtist WHERE Name = '새 앨범 아티스트'").first?["ID"])
        #expect(try content(fixture)["AlbumID"] == "31" && content(fixture)["TrackInfoUpdated"] == "4")
        #expect(try fixture.rows("SELECT AlbumArtistID, rb_local_usn FROM djmdAlbum WHERE ID = '31'").first
            == ["AlbumArtistID": artist, "rb_local_usn": "2002"])
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.albumArtist = "" }]).tagWritten.count == 1)
        #expect(try fixture.rows("SELECT AlbumArtistID FROM djmdAlbum WHERE ID = '31'").first?["AlbumArtistID"] == "")
        #expect(try fixture.rows("SELECT ID FROM djmdArtist WHERE ID = ?", [.text(artist)]).isEmpty)
    }

    @Test func 다른_앨범이_쓰는_앨범_아티스트는_비워도_지우지_않는다() throws {
        // S5 실험곡 3: 실험곡 4의 다른 앨범이 공유 B를 계속 참조한다.
        let (fixture, track) = try library(shared: false)
        try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = '11' WHERE ID = '31'")
        try fixture.insert("djmdAlbum", ["ID": .text("32"), "Name": .text("다른 앨범"), "AlbumArtistID": .text("11")])
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.albumArtist = "" }]).tagWritten.count == 1)
        #expect(try fixture.rows("SELECT ID FROM djmdArtist WHERE ID = '11'").count == 1)
    }

    @Test func 공유_앨범_아티스트는_막고_다른_곡도_보존한다() throws {
        let (fixture, track) = try library()
        let before = try fixture.rows("SELECT * FROM djmdAlbum")
        for value in ["새 아티스트", ""] {
            try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = '11' WHERE ID = '31'")
            let tags = try draft(fixture, track) { $0.albumArtist = value }
            let report = try write(fixture, tags: [tags])
            #expect(report.tagBlocked.first?.reason?.contains("여러 곡") == true && report.backup == nil)
        }
        #expect(try content(fixture, "501")["TrackInfoUpdated"] == "1")
        #expect(try fixture.rows("SELECT rb_local_usn FROM djmdAlbum").first?["rb_local_usn"] == before.first?["rb_local_usn"])
    }

    @Test func 동명_앨범과_다른_앨범_아티스트에_붙이기는_막는다() throws {
        let (fixture, track) = try library(shared: false)
        try fixture.insert("djmdAlbum", ["ID": .text("32"), "Name": .text("있는 앨범"), "AlbumArtistID": .text("11")])
        let mismatch = try draft(fixture, track) { $0.album = "있는 앨범" }
        #expect(try write(fixture, tags: [mismatch]).tagBlocked.first?.reason?.contains("앨범 아티스트") == true)
        try fixture.insert("djmdAlbum", ["ID": .text("33"), "Name": .text("있는 앨범"), "AlbumArtistID": .text("")])
        #expect(try write(fixture, tags: [mismatch]).tagBlocked.first?.reason?.contains("같은 이름") == true)
        try fixture.insert("djmdAlbum", ["ID": .text("34"), "Name": .text("옛 앨범"), "AlbumArtistID": .text("")])
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.albumArtist = "새 아티스트" }]).tagBlocked.count == 1)
        let orphan = try draft(fixture, track) { $0.album = ""; $0.albumArtist = "새 아티스트" }
        #expect(try write(fixture, tags: [orphan]).tagBlocked.count == 1)
        let combined = try draft(fixture, track) { $0.album = "새 앨범"; $0.albumArtist = "새 아티스트" }
        #expect(try write(fixture, tags: [combined]).tagBlocked.count == 1)
        #expect(try fixture.localUpdateCount() == 2000)
    }

    @Test func 실험하지_않은_곡과_앨범_상태는_백업_전에_막는다() throws {
        let (fixture, track) = try library()
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 256 WHERE ID = '500'")
        // 동기화 상태(256)에서 확인한 칸은 코멘트뿐이다(#171, RekordboxTagSyncedTests)
        let title = try write(fixture, tags: [try draft(fixture, track) { $0.title = "새 제목" }]).tagBlocked.first?.reason
        #expect(title?.contains("동기화 상태") == true && title?.contains("제목") == true)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = '500'")
        try fixture.execute("UPDATE djmdAlbum SET rb_data_status = 256 WHERE ID = '31'")
        for key in [TagFields.Key.artist, .album, .albumArtist] {
            let tags = try draft(fixture, track) { $0[key] = "새 값" }
            #expect(try write(fixture, tags: [tags]).tagBlocked.first?.reason?.contains("상태") == true)
        }
        #expect(try fixture.localUpdateCount() == 2000)
    }

    @Test func 여러_곡에_같은_앨범을_붙여도_마지막_앨범_번호로_검증한다() throws {
        let (fixture, track) = try library()
        let neighbor = TrackSpec(id: "501", uuid: "track-uuid-501")
        let drafts = try [track, neighbor].map { item in try draft(fixture, item) { $0.album = "새 앨범" } }
        let report = try write(fixture, tags: drafts)
        #expect(report.tagWritten.count == 2)
        #expect(try content(fixture)["AlbumID"] == content(fixture, "501")["AlbumID"])
        #expect(try fixture.rows("SELECT ID FROM djmdAlbum WHERE ID = '31'").isEmpty)
    }

    @Test func 아티스트와_앨범을_함께_바꿔_옛_앨범이_지워져도_검증한다() throws {
        let (fixture, track) = try library(shared: false)
        let tags = try draft(fixture, track) { $0.artist = "새 아티스트"; $0.album = "새 앨범" }
        #expect(try write(fixture, tags: [tags]).tagWritten.count == 1)
        #expect(try fixture.rows("SELECT ID FROM djmdAlbum WHERE ID = '31'").isEmpty)
    }
    @Test func 막힌_태그만_있어도_재생_목록_초안은_반영한다() throws {
        let (fixture, track) = try library()
        let tags = try draft(fixture, track) { $0.albumArtist = "공유 앨범 변경" }
        var playlists = PlaylistDraft()
        try playlists.append(.create(key: "new", name: "새 목록", isFolder: false, parent: .root), rekordbox: PlaylistLayout())
        let report = try RekordboxWriter.write(drafts: [], tags: [tags], playlistDraft: playlists, to: fixture.database,
                                               dryRun: false, now: now, backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.tagBlocked.count == 1 && report.playlistWritten.count == 1)
        #expect(try fixture.rows("SELECT ID FROM djmdPlaylist WHERE Name = '새 목록'").count == 1)
    }

    @Test func 막힌_태그와_변경_없는_큐의_결과를_함께_남긴다() throws {
        let (fixture, track) = try library()
        let tags = try draft(fixture, track) { $0.albumArtist = "공유 앨범 변경" }
        let cue = CueDraft(trackUUID: track.uuid, rekordboxCues: [])
        let report = try write(fixture, tags: [tags], drafts: [cue])
        #expect(report.tagBlocked.count == 1 && report.outcomes.first?.status == .unchanged)
        #expect(report.backup == nil)
    }

    @Test func 앨범_상태가_NULL이어도_검증된_상태로_보지_않는다() throws {
        let (fixture, track) = try library()
        try fixture.execute("UPDATE djmdAlbum SET rb_data_status = NULL WHERE ID = '31'")
        let tags = try draft(fixture, track) { $0.artist = "새 아티스트" }
        #expect(try write(fixture, tags: [tags]).tagBlocked.first?.reason?.contains("상태") == true)
    }

}
