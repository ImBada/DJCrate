import CryptoKit
import DJCDomain
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// 곡을 넣을 때 음원 내장 아트워크도 넣기(#4). 기대값은 rekordbox 7.2.18 라이브러리 조사(2026-09-26, 읽기 전용):
/// `ImagePath` = `/PIONEER/Artwork/<UUID 앞 3자>/<나머지>/artwork.jpg`, 파일 행은 `artwork.jpg` 하나(분석 파일 행과 같은 칸),
/// 앨범 행 `ImagePath`는 NULL 그대로, 빼면 파일 셋을 지우고 폴더는 남긴다.
@Suite("rekordbox 곡 넣기 아트워크")
struct RekordboxTrackArtworkTests {
    /// 2026-09-25 12:00:00.000 UTC
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    let stamp = "2026-09-25 12:00:00.000 +00:00"
    let names = ["artwork.jpg", "artwork_m.jpg", "artwork_s.jpg"]

    /// 1000x500 앞표지가 든 MP3의 곡 넣기 계획
    func plan(_ fixture: RekordboxFixture, name: String = "artwork.mp3") async throws -> TrackAddPlan {
        let url = try AudioFixture.mp3(try TestResources.url("mp3-notag-cbr.mp3"), artwork: ImageFixture.image(width: 1000, height: 500),
                                       in: fixture.audio, name: name)
        return try TrackAddPlan.make(url: url, tags: try await AudioTags.read(url: url), now: now)
    }

    func add(_ fixture: RekordboxFixture, _ plans: [TrackAddPlan], analyses: [String: RekordboxTrackWriter.Analysis] = [:],
             shareRoot: Bool = true, enabled: Bool = true) throws -> RekordboxTrackWriter.Report {
        try RekordboxTrackWriter.add(plans, analyses: analyses, to: fixture.database, shareRoot: shareRoot ? fixture.shareRoot : nil,
                                     dryRun: false, now: now, backups: fixture.backups, writesArtwork: enabled)
    }

    func content(_ fixture: RekordboxFixture, _ report: RekordboxTrackWriter.Report) throws -> [String: String] {
        let id = try #require(report.added.first?.contentID)
        return try #require(try fixture.rows("SELECT * FROM djmdContent WHERE ID = ?", [.text(id)]).first)
    }

    func folder(_ fixture: RekordboxFixture, uuid: String) -> URL {
        fixture.shareRoot.appending(path: "PIONEER/Artwork/\(uuid.prefix(3))/\(uuid.dropFirst(3))")
    }

    @Test func 아트워크가_든_곡을_넣으면_파일_셋과_ImagePath와_파일_행을_만든다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 4000)
        try fixture.add(TrackSpec())
        let report = try add(fixture, [try await plan(fixture)])
        let r = try content(fixture, report)
        let uuid = try #require(r["UUID"]), id = try #require(r["ID"])
        let path = "/PIONEER/Artwork/\(uuid.prefix(3))/\(uuid.dropFirst(3))/artwork.jpg"
        #expect(r["ImagePath"] == path)
        // 파일 셋: 긴 변 800, 240·80 정사각
        let base = folder(fixture, uuid: uuid)
        let sizes = try names.map { name in
            try ImageFixture.pixels(Data(contentsOf: base.appending(path: name))).map { "\($0.width)x\($0.height)" }
        }
        #expect(sizes == ["800x400", "240x240", "80x80"])
        #expect(Set(report.createdFiles) == Set(names.map { base.appending(path: $0).path }), "되돌릴 때 지울 파일")
        // 파일 행은 artwork.jpg 하나
        let files = try fixture.rows("SELECT * FROM contentFile WHERE ContentID = ?", [.text(id)])
        #expect(files.count == 1)
        let file = try #require(files.first)
        let data = try Data(contentsOf: base.appending(path: "artwork.jpg"))
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(file["ID"] == "\(uuid)_%2FPIONEER%2FArtwork%2F\(uuid.prefix(3))%2F\(uuid.dropFirst(3))%2Fartwork.jpg")
        #expect(file["Path"] == path && file["Hash"] == md5 && file["Size"] == String(data.count))
        #expect(file["rb_local_path"] == base.appending(path: "artwork.jpg").path && file["rb_priority"] == "50")
        #expect(file["rb_insync_hash"] == "NULL" && file["rb_insync_local_usn"] == "NULL" && file["rb_temp_path"] == "NULL")
        #expect(file["rb_file_hash_dirty"] == "0" && file["rb_local_file_status"] == "0" && file["rb_in_progress"] == "0")
        #expect(file["rb_process_type"] == "0" && file["rb_file_size_dirty"] == "0" && file["UUID"]?.count == 36)
        #expect(file["rb_data_status"] == "0" && file["rb_local_deleted"] == "0" && file["usn"] == "NULL")
        #expect(file["created_at"] == stamp && file["updated_at"] == stamp)
        // 분석 전 곡이라 오토게인 행은 없고, 앨범 행 ImagePath는 건드리지 않는다
        #expect(try fixture.rows("SELECT * FROM djmdMixerParam WHERE ContentID = ?", [.text(id)]).isEmpty)
        #expect(r["Analysed"] == "0" && r["AnalysisDataPath"] == "")
    }

    @Test func 분석과_함께_넣으면_분석_파일_행_셋과_아트워크_행() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 4000)
        try fixture.add(TrackSpec())
        let p = try await plan(fixture)
        let analysis = RekordboxTrackWriter.Analysis(segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], loudness: -8, peak: 0.9)
        let report = try add(fixture, [p], analyses: [p.path: analysis])
        let r = try content(fixture, report)
        let uuid = try #require(r["UUID"])
        #expect(r["Analysed"] == "105" && r["ImagePath"] == "/PIONEER/Artwork/\(uuid.prefix(3))/\(uuid.dropFirst(3))/artwork.jpg")
        let files = try fixture.rows("SELECT Path FROM contentFile WHERE ContentID = ? ORDER BY Path", [.text(r["ID"] ?? "")])
        #expect(files.map { $0["Path"]!.components(separatedBy: "/").last! } == ["artwork.jpg", "ANLZ0000.2EX", "ANLZ0000.DAT", "ANLZ0000.EXT"])
        #expect(report.createdFiles.count == 6)
    }

    @Test func 아트워크가_없거나_쓰기가_닫혀_있거나_share가_없으면_ImagePath는_빈_값() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let closed = try add(fixture, [try await plan(fixture, name: "closed.mp3")], enabled: false)
        let noShare = try add(fixture, [try await plan(fixture, name: "noshare.mp3")], shareRoot: false)
        let bare = try TestResources.url("mp3-notag-cbr.mp3")
        let none = try add(fixture, [try TrackAddPlan.make(url: bare, tags: try await AudioTags.read(url: bare), now: now)])
        for report in [closed, noShare, none] {
            #expect(report.added.first?.written == true)
            #expect(try content(fixture, report)["ImagePath"] == "")
            #expect(report.createdFiles.isEmpty)
        }
        #expect(try fixture.rows("SELECT * FROM contentFile").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/Artwork").path))
    }

    @Test func 시험_실행은_파일을_만들지_않는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let report = try RekordboxTrackWriter.add([try await plan(fixture)], to: fixture.database, shareRoot: fixture.shareRoot,
                                                  dryRun: true, now: now, backups: fixture.backups, writesArtwork: true)
        #expect(report.added.first?.written == true && report.createdFiles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/Artwork").path))
        #expect(try fixture.rows("SELECT * FROM djmdContent").count == 1)
    }

    @Test func 넣은_곡을_되돌리면_아트워크_파일과_빈_폴더가_사라진다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 3000)
        try fixture.add(TrackSpec())
        let report = try add(fixture, [try await plan(fixture)])
        let uuid = try #require(report.added.first?.uuid)
        let base = folder(fixture, uuid: uuid)
        #expect(names.allSatisfy { FileManager.default.fileExists(atPath: base.appending(path: $0).path) })
        let saved = try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database, backups: fixture.backups)
        #expect(!FileManager.default.fileExists(atPath: base.path), "만든 폴더까지 지운다")
        #expect(try fixture.rows("SELECT * FROM contentFile").isEmpty)
        // 되돌리기 직전 백업으로 다시 되돌리면 살아난다
        _ = try RekordboxWriter.restore(saved, to: fixture.database, backups: fixture.backups)
        #expect(names.allSatisfy { FileManager.default.fileExists(atPath: base.appending(path: $0).path) })
    }

    @Test func 아트워크를_넣은_곡을_빼면_파일은_지우고_폴더는_남기고_되돌리면_살아난다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 3000)
        try fixture.add(TrackSpec())
        let added = try add(fixture, [try await plan(fixture)])
        let id = try #require(added.added.first?.contentID), uuid = try #require(added.added.first?.uuid)
        let base = folder(fixture, uuid: uuid)
        let original = try names.map { try Data(contentsOf: base.appending(path: $0)) }
        let deleted = try RekordboxTrackWriter.delete(contentIDs: [id], from: fixture.database, shareRoot: fixture.shareRoot, dryRun: false,
                                                      now: now.addingTimeInterval(60), backups: fixture.backups)
        #expect(deleted.deleted.first?.written == true)
        #expect(FileManager.default.fileExists(atPath: base.path), "rekordbox처럼 아트워크 폴더는 남긴다")
        #expect(names.allSatisfy { !FileManager.default.fileExists(atPath: base.appending(path: $0).path) })
        #expect(try fixture.rows("SELECT * FROM contentFile").isEmpty)
        _ = try RekordboxWriter.restore(URL(filePath: try #require(deleted.backup)), to: fixture.database, backups: fixture.backups)
        #expect(try names.map { try Data(contentsOf: base.appending(path: $0)) } == original)
        #expect(try fixture.rows("SELECT * FROM contentFile WHERE ContentID = ?", [.text(id)]).count == 1)
    }
}
