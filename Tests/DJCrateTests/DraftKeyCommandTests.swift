import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// `djc draft tag --musical-key`(#5): Camelot 이름(1A~12B)만 받고 "8a"는 다듬으며 ''는 키를 지운다.
extension DraftCommandTests {
    /// 곡 101은 키 5A(살아 있는 djmdKey 줄)
    func keyedFixture() throws -> RekordboxFixture {
        let fixture = try fixture()
        try fixture.insert("djmdKey", ["ID": .text("1010000005"), "ScaleName": .text("5A"), "Seq": .int(1), "rb_local_deleted": .int(0)])
        try fixture.execute("UPDATE djmdContent SET KeyID = '1010000005' WHERE ID = '101'")
        return fixture
    }

    @Test(arguments: [("8A", "8A"), ("8a", "8A"), (" 12b ", "12B"), ("", "")])
    func 키_옵션은_Camelot_이름으로_다듬어_초안에_담는다(raw: String, expected: String) throws {
        let fixture = try keyedFixture()
        let output = try run(["tag", "101", "--musical-key", raw], fixture: fixture)
        #expect(output.status == 0)
        let draft = try #require(TagDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "tag")))
        #expect(draft.base.musicalKey == "5A" && draft.fields.musicalKey == expected)
        #expect(draft.changedKeys == [.musicalKey])
    }

    @Test(arguments: ["Am", "C major", "13A", "8"])
    func Camelot_이름이_아니면_거절하고_초안을_만들지_않는다(raw: String) throws {
        let fixture = try keyedFixture()
        let output = try run(["tag", "101", "--musical-key", raw], fixture: fixture)
        #expect(output.status != 0)
        let error = try #require(output.document(error: true)["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_arguments" && (error["message"] as? String)?.contains("1A~12B") == true)
        #expect(TagDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "tag")) == nil)
    }

    @Test func 키_칸이_없던_옛_초안_파일_위에_키를_고쳐도_기준은_곡의_지금_키다() throws {
        let fixture = try keyedFixture()
        let folder = directory(fixture, "tag")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fields = #"{"title":"시험 곡","artist":"","album":"","albumArtist":"","genre":"","composer":"","year":"","trackNumber":"","comment":"옛 코멘트"}"#
        let old = #"{"trackUUID":"track-101","base":{"title":"시험 곡","artist":"","album":"","albumArtist":"","genre":"","composer":"","year":"","trackNumber":"","comment":""},"fields":\#(fields)}"#
        try Data(old.utf8).write(to: folder.appending(path: "track-101.json"))
        let output = try run(["tag", "101", "--musical-key", "8A"], fixture: fixture)
        #expect(output.status == 0)
        let draft = try #require(TagDraftStore.load(trackUUID: "track-101", directory: folder))
        #expect(draft.base.musicalKey == "5A" && draft.fields.musicalKey == "8A" && draft.fields.comment == "옛 코멘트")
        #expect(draft.changedKeys == [.comment, .musicalKey])
    }

    @Test func 키_옵션_없이_옛_초안을_고쳐도_읽지_못한_초안으로_옮기지_않는다() throws {
        let fixture = try keyedFixture()
        let folder = directory(fixture, "tag")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = #"{"trackUUID":"track-101","base":{"title":"시험 곡","artist":"","album":"","albumArtist":"","genre":"","composer":"","year":"","trackNumber":"","comment":""},"fields":{"title":"시험 곡","artist":"","album":"","albumArtist":"","genre":"","composer":"","year":"","trackNumber":"","comment":"옛 코멘트"}}"#
        try Data(old.utf8).write(to: folder.appending(path: "track-101.json"))
        let output = try run(["tag", "101", "--title", "새 제목"], fixture: fixture)
        #expect(output.status == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "home/damaged-drafts").path))
        let draft = try #require(TagDraftStore.load(trackUUID: "track-101", directory: folder))
        #expect(draft.fields.title == "새 제목" && draft.fields.comment == "옛 코멘트" && !draft.changedKeys.contains(.musicalKey))
    }
}
