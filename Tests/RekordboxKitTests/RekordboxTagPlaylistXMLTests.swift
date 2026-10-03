import DJCDomain
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// 곡 정보를 쓰면 그 곡이 든 재생 목록의 `masterPlaylists6.xml` Timestamp도 고친다(#173, 2026-10-04 rekordbox 7.2.18).
/// S1 X1(아티스트)·S2 U11(제목, 256)·U12(제목, 상태 0)·X4(같은 값 저장)·S3 V07(장르): 그 저장에서 곡이 든 살아 있는 목록마다
/// Timestamp를 저장 시각(UTC epoch ms)으로 바꿨다. 부모 폴더·다른 목록·DB 재생 목록 표는 그대로였다. 그림 저장은 바꾸지 않는다(#66 범위).
/// 확인한 칸(제목·아티스트·장르)을 쓴 초안만 고치고, 나머지 칸만 쓴 초안은 XML을 읽지도 고치지도 않는다.
/// XML은 쓰는 DB 옆 파일만 고친다(사본이면 사본 옆, 없으면 DB만).
extension RekordboxTagWriterTests {
    var nowMS: Int64 { 1_790_337_600_000 }

    /// 재생 목록을 넣고 DB 옆에 그 NODE가 든 XML(Timestamp 1000)을 둔다.
    @discardableResult
    func withPlaylists(_ fixture: RekordboxFixture, _ playlists: [PlaylistSpec]) throws -> URL {
        var xml = MasterPlaylistsXML(text: MasterPlaylistsXMLTests.empty)
        for playlist in playlists {
            try fixture.add(playlist)
            try xml.append(id: playlist.id, parentID: playlist.parentID, isFolder: playlist.isFolder, timestamp: 1_000)
        }
        let url = fixture.root.appending(path: "masterPlaylists6.xml")
        try xml.text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func timestamps(_ url: URL) throws -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: try MasterPlaylistsXML(contentsOf: url).nodes.map { ($0.id, $0.timestamp) })
    }

    @Test(arguments: [(0, TagFields.Key.title), (256, .genre), (257, .artist)])
    func 곡_정보를_쓰면_곡이_든_재생_목록의_Timestamp만_쓴_시각으로_고친다(state: Int, key: TagFields.Key) throws {
        let (fixture, track) = try library()
        try fixture.execute("UPDATE djmdContent SET rb_data_status = ? WHERE ID = '500'", [.int(state)])
        let url = try withPlaylists(fixture, [
            PlaylistSpec(id: "100", name: "폴더", seq: 1, isFolder: true),
            PlaylistSpec(id: "201", name: "곡이 든 목록", parentID: "100", seq: 1, contentIDs: ["501", "500"]),
            PlaylistSpec(id: "202", name: "두 번 든 목록", seq: 2, contentIDs: ["500", "500"]),
            PlaylistSpec(id: "203", name: "다른 곡 목록", seq: 3, contentIDs: ["501"]),
            PlaylistSpec(id: "204", name: "지운 목록", seq: 4, contentIDs: ["500"]),
            PlaylistSpec(id: "205", name: "지운 항목", seq: 5, contentIDs: ["500"]),
        ])
        try fixture.execute("UPDATE djmdPlaylist SET rb_local_deleted = 1 WHERE ID = '204'")
        try fixture.execute("UPDATE djmdSongPlaylist SET rb_local_deleted = 1 WHERE PlaylistID = '205'")
        let tables = try fixture.rows("SELECT * FROM djmdPlaylist ORDER BY ID") + fixture.rows("SELECT * FROM djmdSongPlaylist ORDER BY ID")
        let before = try Data(contentsOf: url)
        let tags = try draft(fixture, track) { $0[key] = "DJC 173 값" }

        // 미리 보기와 막힌 초안은 XML을 건드리지 않는다
        #expect(try write(fixture, tags: [tags], dryRun: true).tagWritten.count == 1)
        #expect(try write(fixture, tags: [tags], keys: []).tagBlocked.count == 1)
        #expect(try Data(contentsOf: url) == before)

        #expect(try write(fixture, tags: [tags]).tagWritten.count == 1)
        let hex = { (id: String) in MasterPlaylistsXML.hex(id) ?? "" }
        let after = try timestamps(url)
        #expect(after[hex("201")] == nowMS && after[hex("202")] == nowMS)
        for id in ["100", "203", "204", "205"] { #expect(after[hex(id)] == 1_000, "\(id)") }
        // 고친 줄 말고는 바이트 그대로, DB 재생 목록 표도 그대로
        let lines = { (data: Data) in String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n") }
        let written = try Data(contentsOf: url)
        let changed = zip(lines(before), lines(written)).filter { $0 != $1 }
        #expect(changed.count == 2 && lines(before).count == lines(written).count)
        #expect(try fixture.rows("SELECT * FROM djmdPlaylist ORDER BY ID") + fixture.rows("SELECT * FROM djmdSongPlaylist ORDER BY ID") == tables)
    }

    @Test func 확인하지_않은_칸만_바꾸면_XML은_그대로다() throws {
        // XML Timestamp는 제목·아티스트·장르 저장에서만 확인했다(#173). 연도·트랙 번호·코멘트·작곡가·앨범·앨범 아티스트는 [미확인]이라
        // 그 칸만 바꾼 초안은 XML을 고치지 않는다. 확인한 칸이 하나라도 있으면 고친다.
        let (fixture, track) = try library(shared: false)
        let url = try withPlaylists(fixture, [PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["500"])])
        let before = try Data(contentsOf: url)
        let edits: [(inout TagFields) -> Void] = [
            { $0.year = "2020" }, { $0.trackNumber = "9" }, { $0.comment = "DJC 173 코멘트" }, { $0.composer = "DJC 173 작곡가" },
            { $0.albumArtist = "DJC 173 앨범 아티스트" }, { $0.album = "DJC 173 앨범" },
        ]
        for edit in edits {
            #expect(try write(fixture, tags: [try draft(fixture, track, edit)]).tagWritten.count == 1)
            #expect(try Data(contentsOf: url) == before)
        }
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.year = "2021"; $0.title = "DJC 173 제목" }]).tagWritten.count == 1)
        #expect(try timestamps(url)[MasterPlaylistsXML.hex("201") ?? ""] == nowMS)
    }

    @Test func 확인하지_않은_칸만_쓰면_XML을_읽지_않는다() throws {
        // XML을 고치지 않는 쓰기는 예전처럼 XML이 망가져 있어도 막지 않는다.
        let (fixture, track) = try library()
        let url = fixture.root.appending(path: "masterPlaylists6.xml")
        try Data("망가짐".utf8).write(to: url)
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.comment = "DJC 173 코멘트" }]).tagWritten.count == 1)
        #expect(throws: DJCError.self) { try write(fixture, tags: [try draft(fixture, track) { $0.title = "DJC 173 제목" }]) }
        #expect(try Data(contentsOf: url) == Data("망가짐".utf8))
    }

    @Test func 곡_정보의_XML은_쓰는_DB_옆_파일만_고치고_없으면_DB만_쓴다() throws {
        // 안전: 사본 DB에 쓰면 사본 옆 XML만 고친다. 다른 폴더(같은 NODE가 든 미끼)·rekordbox 폴더(DJC_REKORDBOX_DIR)의 XML은 그대로다.
        let (fixture, track) = try library()
        let url = try withPlaylists(fixture, [PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["500"])])
        let (decoy, _) = try library()
        let decoyURL = try withPlaylists(decoy, [PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["500"])])
        let decoyBefore = try Data(contentsOf: decoyURL)
        let rekordboxXML = LibrarySnapshot.rekordboxDirectory.appending(path: "masterPlaylists6.xml")
        let rekordboxBefore = try? Data(contentsOf: rekordboxXML)

        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.title = "DJC 173 제목" }]).tagWritten.count == 1)
        #expect(try timestamps(url)[MasterPlaylistsXML.hex("201") ?? ""] == nowMS)
        #expect(try Data(contentsOf: decoyURL) == decoyBefore)
        #expect((try? Data(contentsOf: rekordboxXML)) == rekordboxBefore)

        // DB 옆에 XML이 없으면 DB만 쓰고 XML을 만들지 않는다
        try FileManager.default.removeItem(at: url)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.title = "DJC 173 제목 2" }])
        #expect(try report.tagWritten.count == 1 && content(fixture)["Title"] == "DJC 173 제목 2")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: decoyURL) == decoyBefore)
        #expect((try? Data(contentsOf: rekordboxXML)) == rekordboxBefore)
    }

    @Test(arguments: [false, true]) func 사본_옆_XML이_라이브_XML에_이어져_있으면_백업_전에_막는다(hardLink: Bool) throws {
        // 사본 DB 옆 XML이 라이브 폴더 XML의 링크면 쓰지 않는다(라이브는 합성 폴더로 주입한다).
        let (fixture, track) = try library()
        let live = fixture.root.appending(path: "live")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.database, to: live.appending(path: "master.db"))
        let liveXML = try withPlaylists(fixture, [PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["500"])])
        try FileManager.default.moveItem(at: liveXML, to: live.appending(path: "masterPlaylists6.xml"))
        if hardLink {
            try FileManager.default.linkItem(at: live.appending(path: "masterPlaylists6.xml"), to: liveXML)
        } else {
            try FileManager.default.createSymbolicLink(at: liveXML, withDestinationURL: live.appending(path: "masterPlaylists6.xml"))
        }
        let liveBefore = try Data(contentsOf: live.appending(path: "masterPlaylists6.xml"))
        let before = try content(fixture)
        let guardian = RekordboxWriteGuard(isRekordboxRunning: { false }, appVersion: { nil }, liveDirectories: [live])
        #expect(throws: DJCError.self) {
            try RekordboxWriter.write(drafts: [], grids: [], gains: [:], tags: [try draft(fixture, track) { $0.title = "DJC 173 제목" }],
                                      analysisInputs: [:], to: fixture.database, dryRun: false, now: now, backups: fixture.backups,
                                      shareRoot: fixture.shareRoot, guard: guardian, attachesAnalysis: false)
        }
        #expect(try Data(contentsOf: live.appending(path: "masterPlaylists6.xml")) == liveBefore)
        #expect(try content(fixture) == before && RekordboxWriter.backups(in: fixture.backups).isEmpty)
    }
}
