import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing
@testable import djc

/// `djc xml-export`(#72): 인자·출력 자리 거부·요약 줄. 라이브러리는 합성 사본이다.
@Suite("XML 전체 내보내기 명령")
struct XMLExportCommandTests {
    func library() throws -> RekordboxFixture {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec(id: "101")
        spec.title = "시험 곡"
        spec.folderPath = "/Music/시험.mp3"
        spec.analysisDataPath = "/PIONEER/USBANLZ/P001/0000ABCD/ANLZ0000.DAT"
        spec.cues = [CueSpec(id: "c1", kind: 1, inMsec: 20_000), CueSpec(id: "c2", kind: 4, inMsec: 9000)]
        try fixture.add(spec)
        try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: AnlzBuilder.beats(bpm: 128, first: 50, count: 100)), ext: nil)
        var streaming = TrackSpec(id: "102")
        streaming.folderPath = "apple-music:track:1"
        try fixture.add(streaming)
        try fixture.insert("djmdPlaylist", ["ID": .text("p1"), "Name": .text("셋"), "ParentID": .text("root"), "Attribute": .int(0), "Seq": .int(1)])
        for (id, content, no) in [("s1", "101", 1), ("s2", "102", 2)] {
            try fixture.insert("djmdSongPlaylist", ["ID": .text(id), "PlaylistID": .text("p1"), "ContentID": .text(content), "TrackNo": .int(no)])
        }
        return fixture
    }

    @Test func 인자는_db와_out이_필수이고_옵션을_엄격히_받는다() throws {
        let request = try XMLExportCommand.request(["xml-export", "--db", "/tmp/a.db", "--out", "/tmp/o.xml", "--share", "/tmp/s",
                                                    "--overwrite", "--dry-run"])
        #expect(request == XMLExportCommand.Request(database: URL(filePath: "/tmp/a.db"), out: URL(filePath: "/tmp/o.xml"),
                                                     share: URL(filePath: "/tmp/s"), overwrite: true, dryRun: true))
        let minimal = try XMLExportCommand.request(["xml-export", "--db", "/tmp/a.db", "--out", "/tmp/o.xml"])
        #expect(minimal.share == nil && !minimal.overwrite && !minimal.dryRun)
        for bad in [["xml-export"], ["xml-export", "--db", "/tmp/a.db"], ["xml-export", "--out", "/tmp/o.xml"],
                    ["xml-export", "--db", "/tmp/a.db", "--out"], ["xml-export", "--db", "/tmp/a.db", "--out", "/tmp/o.xml", "--live"],
                    ["xml-export", "--db", "/tmp/a.db", "--db", "/tmp/b.db", "--out", "/tmp/o.xml"],
                    ["xml-export", "--db", "/tmp/a.db", "--out", "/tmp/o.xml", "extra"]] {
            #expect(throws: UsageError.self) { _ = try XMLExportCommand.request(bad) }
        }
    }

    @Test func 내보내면_파일을_쓰고_센_것과_뺀_것을_알린다() throws {
        let fixture = try library()
        let out = fixture.root.appending(path: "out.xml")
        let lines = try XMLExportCommand.execute(.init(database: fixture.database, out: out, share: nil, overwrite: false, dryRun: false))
        let xml = try String(contentsOf: out, encoding: .utf8)
        #expect(xml.contains(#"<COLLECTION Entries="1">"#) && xml.contains("<TEMPO ") && xml.contains("<POSITION_MARK "))
        let text = lines.joined(separator: "\n")
        #expect(text.contains(out.path))
        #expect(text.contains("곡 1") && text.contains("큐·루프 1") && text.contains("그리드 있는 곡 1") && text.contains("스트리밍 곡 1"))
        #expect(text.contains("쓰지 않은 초안은 넣지 않았습니다"))
    }

    @Test func share를_안_주면_사본_DB_옆_share에서_분석_파일을_읽는다() throws {
        let fixture = try library()
        let other = fixture.root.appending(path: "empty-share")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let out = fixture.root.appending(path: "no-grid.xml")
        _ = try XMLExportCommand.execute(.init(database: fixture.database, out: out, share: other, overwrite: false, dryRun: false))
        #expect(try !String(contentsOf: out, encoding: .utf8).contains("<TEMPO "), "--share로 바꾼 뿌리에는 분석 파일이 없다")
    }

    @Test func 이미_있는_파일은_덮어쓰기를_줘야_바꾼다() throws {
        let fixture = try library()
        let out = fixture.root.appending(path: "out.xml")
        try Data("기존".utf8).write(to: out)
        #expect(throws: RekordboxLibraryXML.OutputError.self) {
            _ = try XMLExportCommand.execute(.init(database: fixture.database, out: out, share: nil, overwrite: false, dryRun: false))
        }
        #expect(try String(contentsOf: out, encoding: .utf8) == "기존")
        _ = try XMLExportCommand.execute(.init(database: fixture.database, out: out, share: nil, overwrite: true, dryRun: false))
        #expect(try String(contentsOf: out, encoding: .utf8).hasPrefix("<?xml"))
    }

    @Test func 드라이_런은_파일을_만들지_않는다() throws {
        let fixture = try library()
        let out = fixture.root.appending(path: "out.xml")
        let lines = try XMLExportCommand.execute(.init(database: fixture.database, out: out, share: nil, overwrite: false, dryRun: true))
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(lines.joined(separator: "\n").contains("곡 1") && lines.joined(separator: "\n").contains("미리 보기"))
    }

    @Test func rekordbox_폴더와_연동_파일_자리는_DB를_열기_전에_거부한다() throws {
        let fixture = try library()
        let real = LibrarySnapshot.realRekordboxDirectory
        for out in [real.appending(path: "library.xml"), DJCIdentity.linkedXMLFile, fixture.root.appending(path: "master.db")] {
            #expect(throws: RekordboxLibraryXML.OutputError.self) {
                _ = try XMLExportCommand.execute(.init(database: fixture.database, out: out, share: nil, overwrite: true, dryRun: false))
            }
        }
        // 라이브 master.db는 입력으로도 열지 않는다(경로만 보고 거부)
        #expect(throws: ReadFailure.self) {
            _ = try XMLExportCommand.execute(.init(database: real.appending(path: "master.db"), out: fixture.root.appending(path: "o.xml"),
                                                   share: nil, overwrite: false, dryRun: false))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "o.xml").path))
    }
}
