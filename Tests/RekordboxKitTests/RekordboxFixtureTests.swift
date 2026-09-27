import DJCTestSupport
import Testing

@Suite("합성 DB 준비")
struct RekordboxFixtureTests {
    @Test func 곡_준비는_큐_삽입에_실패하면_함께_취소한다() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec(id: "1")
        let cue = CueSpec(id: "duplicate", inMsec: 1000)
        track.cues = [cue, cue]
        #expect(throws: (any Error).self) { try fixture.add(track) }
        #expect(try fixture.rows("SELECT ID FROM djmdContent").isEmpty)
        #expect(try fixture.rows("SELECT ID FROM djmdCue").isEmpty)

        track.cues = [cue]
        try fixture.add(track)
        #expect(try fixture.rows("SELECT ID FROM djmdCue").count == 1)
    }

    @Test func 재생_목록_준비는_거울_행에_실패하면_함께_취소한다() throws {
        let fixture = try RekordboxFixture()
        try fixture.execute("""
            CREATE TRIGGER reject_fixture_playlist BEFORE INSERT ON djmdCloudFilterPlaylist
            BEGIN SELECT RAISE(ABORT, '합성 실패'); END
            """)
        let playlist = PlaylistSpec(id: "1", name: "시험 목록", seq: 1, contentIDs: ["track-1"])
        #expect(throws: (any Error).self) { try fixture.add(playlist) }
        #expect(try fixture.rows("SELECT ID FROM djmdPlaylist").isEmpty)
        #expect(try fixture.rows("SELECT ID FROM djmdSongPlaylist").isEmpty)

        try fixture.execute("DROP TRIGGER reject_fixture_playlist")
        try fixture.add(playlist)
        #expect(try fixture.rows("SELECT ContentID FROM djmdSongPlaylist").first?["ContentID"] == "track-1")
    }
}
