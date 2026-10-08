import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing
@testable import djc

/// `djc xml-diff`(#72 가져오기): 인자·라이브 DB 거부·요약 줄·JSON. 라이브러리는 합성 사본, XML은 그 사본을 내보내 고친 것이다.
@Suite("XML 가져오기 차이 명령")
struct XMLDiffCommandTests {
    func library() throws -> RekordboxFixture { try XMLExportCommandTests().library() }

    /// 사본을 내보낸 XML에 `edit`을 적용해 파일로 둔다.
    func xml(_ fixture: RekordboxFixture, edit: (String) -> String = { $0 }) throws -> URL {
        let collection = try RekordboxLibraryXML.load(snapshot: fixture.database, shareRoot: fixture.shareRoot)
        let url = fixture.root.appending(path: "in-\(UUID().uuidString).xml")
        try Data(edit(RekordboxLibraryXML.document(collection)).utf8).write(to: url)
        return url
    }

    @Test func 인자는_db와_xml이_필수이고_옵션을_엄격히_받는다() throws {
        let request = try XMLDiffCommand.request(["xml-diff", "--db", "/tmp/a.db", "--xml", "/tmp/i.xml", "--share", "/tmp/s", "--json"])
        #expect(request == XMLDiffCommand.Request(database: URL(filePath: "/tmp/a.db"), xml: URL(filePath: "/tmp/i.xml"),
                                                   share: URL(filePath: "/tmp/s"), noAnalysis: false, json: true))
        let minimal = try XMLDiffCommand.request(["xml-diff", "--db", "/tmp/a.db", "--xml", "/tmp/i.xml"])
        #expect(minimal.share == nil && !minimal.json && !minimal.noAnalysis && minimal.limit == 50)
        #expect(try XMLDiffCommand.request(["xml-diff", "--db", "/a", "--xml", "/b", "--limit", "0"]).limit == 0)
        for bad in [["xml-diff"], ["xml-diff", "--db", "/tmp/a.db"], ["xml-diff", "--xml", "/tmp/i.xml"],
                    ["xml-diff", "--db", "/tmp/a.db", "--xml"], ["xml-diff", "--db", "/a", "--xml", "/b", "--live"],
                    ["xml-diff", "--db", "/a", "--xml", "/b", "--no-analysis", "--share", "/s"],
                    ["xml-diff", "--db", "/a", "--xml", "/b", "--limit", "-1"],
                    ["xml-diff", "--db", "/a", "--xml", "/b", "extra"]] {
            #expect(throws: UsageError.self) { _ = try XMLDiffCommand.request(bad) }
        }
    }

    @Test func 내보낸_XML과_비교하면_차이가_없다() throws {
        let fixture = try library()
        let report = try XMLDiffCommand.report(.init(database: fixture.database, xml: try xml(fixture), share: nil))
        #expect(report.diff.isEmpty && report.diff.matching.matched == 1)
        let text = XMLDiffCommand.lines(report, limit: 50).joined(separator: "\n")
        #expect(text.contains("XML 곡 1 · 맞춘 곡 1 · 라이브러리에 없는 곡 0 · 여러 곡에 맞는 곡 0"))
        #expect(text.contains("차이가 없습니다"))
    }

    @Test func 차이를_종류별로_세고_곡마다_요약한다() throws {
        let fixture = try library()
        let url = try xml(fixture) {
            $0.replacingOccurrences(of: #"Name="시험 곡""#, with: #"Name="새 제목""#)
                .replacingOccurrences(of: #"Start="20.000" Num="0""#, with: #"Start="22.000" Num="0""#)
                .replacingOccurrences(of: #"<NODE Name="셋""#, with: #"<NODE Name="새 셋""#)
        }
        let report = try XMLDiffCommand.report(.init(database: fixture.database, xml: url, share: nil))
        let text = XMLDiffCommand.lines(report, limit: 50).joined(separator: "\n")
        #expect(text.contains("큐가 다른 곡 1 · 그리드가 다른 곡 0 · 태그가 다른 곡 1"))
        #expect(text.contains("없는 재생 목록 1 · 곡이 다른 재생 목록 0"))
        #expect(text.contains("/Music/시험.mp3") && text.contains("큐 +1 −1") && text.contains("제목"))
        #expect(text.contains("새 셋"))
        // 목록을 줄이면 남은 수를 알린다
        let short = XMLDiffCommand.lines(report, limit: 0).joined(separator: "\n")
        #expect(!short.contains("/Music/시험.mp3") && short.contains("곡 1개는 줄였습니다"))
    }

    @Test func JSON은_종류별_개수와_곡별_차이를_담는다() throws {
        let fixture = try library()
        let url = try xml(fixture) { $0.replacingOccurrences(of: #"Name="시험 곡""#, with: #"Name="새 제목""#) }
        let report = try XMLDiffCommand.report(.init(database: fixture.database, xml: url, share: nil, json: true))
        let data = try XMLDiffCommand.json(report)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["command"] as? String == "xml-diff")
        let body = try #require(object["data"] as? [String: Any])
        let counts = try #require(body["counts"] as? [String: Int])
        #expect(counts["tagTracks"] == 1 && counts["cueTracks"] == 0)
        let matching = try #require(body["matching"] as? [String: Int])
        #expect(matching["matched"] == 1)
        let tracks = try #require(body["tracks"] as? [[String: Any]])
        #expect(tracks.first?["libraryID"] as? String == "101")
        let tags = try #require(tracks.first?["tags"] as? [[String: String]])
        #expect(tags == [["key": "title", "library": "시험 곡", "xml": "새 제목"]])
    }

    @Test func 라이브_master_db는_열지_않는다() throws {
        let fixture = try library()
        let live = LibrarySnapshot.realRekordboxDirectory.appending(path: "master.db")
        #expect(throws: ReadFailure.self) {
            _ = try XMLDiffCommand.report(.init(database: live, xml: try xml(fixture), share: nil))
        }
    }

    @Test func 읽을_수_없는_XML은_이유와_함께_막는다() throws {
        let fixture = try library()
        let bad = fixture.root.appending(path: "bad.xml")
        try Data("<plist/>".utf8).write(to: bad)
        #expect(throws: RekordboxXMLReader.ReadError.self) {
            _ = try XMLDiffCommand.report(.init(database: fixture.database, xml: bad, share: nil))
        }
        let error = try #require(throws: ReadFailure.self) {
            _ = try XMLDiffCommand.report(.init(database: fixture.database, xml: fixture.root.appending(path: "없음.xml"), share: nil))
        }
        #expect(error.code == "missing_xml")
    }

    @Test func 사본_옆에_share가_없으면_share나_no_analysis를_줘야_한다() throws {
        let fixture = try library()
        let url = try xml(fixture)
        try FileManager.default.removeItem(at: fixture.shareRoot)
        #expect(throws: ReadFailure.self) { _ = try XMLDiffCommand.report(.init(database: fixture.database, xml: url, share: nil)) }
        let report = try XMLDiffCommand.report(.init(database: fixture.database, xml: url, share: nil, noAnalysis: true))
        #expect(report.diff.isEmpty, "그리드를 읽지 않으면 그리드를 비교하지 않는다")
        #expect(XMLDiffCommand.lines(report, limit: 50).joined(separator: "\n").contains("그리드는 비교하지 않았습니다"))
    }
}
