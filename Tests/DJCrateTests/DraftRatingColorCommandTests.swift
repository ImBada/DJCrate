import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// `djc draft tag --rating`·`--color`(#65): 평점은 별 수(1~5, 0·빈칸은 지우기), 곡 색은 번호('1'~'8')나 rekordbox 색 이름.
/// 쓰기를 확인한 범위 밖의 곡(동기화 곡, 재생 목록에 든 곡)은 초안을 만들지 않고 이유를 알린다(`TagWriteScope`).
extension DraftCommandTests {
    /// 곡 101: 상태 0, 평점 2, 색 Red('2'), 색 줄 여덟
    func ratedFixture(state: Int = 0) throws -> RekordboxFixture {
        let fixture = try fixture()
        for color in TrackColor.rekordboxDefaults {
            try fixture.insert("djmdColor", ["ID": .text(color.id), "SortKey": .int(Int(color.id) ?? 0), "Commnt": .text(color.name),
                                             "rb_local_deleted": .int(0)])
        }
        try fixture.execute("UPDATE djmdContent SET rb_data_status = ?, Rating = 2, ColorID = '2' WHERE ID = '101'", [.int(state)])
        return fixture
    }

    @Test(arguments: [("4", "4"), ("★★★★★", "5"), ("0", ""), ("", "")])
    func 평점_옵션은_별_수로_다듬어_초안에_담는다(raw: String, expected: String) throws {
        let fixture = try ratedFixture()
        let output = try run(["tag", "101", "--rating", raw], fixture: fixture)
        #expect(output.status == 0)
        let draft = try #require(TagDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "tag")))
        #expect(draft.base.rating == "2" && draft.fields.rating == expected && draft.changedKeys == [.rating])
    }

    @Test(arguments: [("7", "7"), ("blue", "7"), ("Purple", "8"), ("", "")])
    func 색_옵션은_번호나_rekordbox_이름을_받는다(raw: String, expected: String) throws {
        let fixture = try ratedFixture()
        let output = try run(["tag", "101", "--color", raw], fixture: fixture)
        #expect(output.status == 0)
        let draft = try #require(TagDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "tag")))
        #expect(draft.base.color == "2" && draft.fields.color == expected && draft.changedKeys == [.color])
    }

    @Test(arguments: [("--rating", "6"), ("--rating", "세 개"), ("--color", "9"), ("--color", "빨강")])
    func 평점이나_색이_아니면_거절하고_초안을_만들지_않는다(flag: String, raw: String) throws {
        let fixture = try ratedFixture()
        let output = try run(["tag", "101", flag, raw], fixture: fixture)
        #expect(output.status != 0)
        let error = try #require(output.document(error: true)["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_arguments")
        #expect(TagDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "tag")) == nil)
    }

    @Test(arguments: [256, 257]) func 동기화된_곡의_평점과_색은_초안을_만들지_않고_이유를_알린다(state: Int) throws {
        let fixture = try ratedFixture(state: state)
        for args in [["--rating", "4"], ["--color", "7"]] {
            let output = try run(["tag", "101"] + args, fixture: fixture)
            #expect(output.status != 0)
            let error = try #require(output.document(error: true)["error"] as? [String: Any])
            #expect(error["code"] as? String == "unverified_field")
            #expect((error["message"] as? String)?.contains("동기화") == true)
        }
        #expect(TagDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "tag")) == nil)
        // 다른 칸은 예전처럼 초안을 만든다
        #expect(try run(["tag", "101", "--title", "새 제목"], fixture: fixture).status == 0)
    }

    @Test func 재생_목록에_든_곡의_평점은_초안을_만들지_않는다() throws {
        let fixture = try ratedFixture()
        try fixture.add(PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["101"]))
        let output = try run(["tag", "101", "--rating", "4"], fixture: fixture)
        #expect(output.status != 0)
        let error = try #require(output.document(error: true)["error"] as? [String: Any])
        #expect(error["code"] as? String == "unverified_field" && (error["message"] as? String)?.contains("재생 목록") == true)
    }

    @Test func 두_칸이_없던_옛_초안_위에_평점을_고쳐도_기준은_곡의_지금_값이다() throws {
        let fixture = try ratedFixture()
        let folder = directory(fixture, "tag")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = #"{"title":"시험 곡","artist":"","album":"","albumArtist":"","genre":"","composer":"","year":"","trackNumber":"","comment":"","musicalKey":""}"#
        let fields = base.replacingOccurrences(of: #""comment":"""#, with: #""comment":"옛 코멘트""#)
        try Data(#"{"trackUUID":"track-101","base":\#(base),"fields":\#(fields)}"#.utf8).write(to: folder.appending(path: "track-101.json"))
        let output = try run(["tag", "101", "--rating", "5"], fixture: fixture)
        #expect(output.status == 0)
        let draft = try #require(TagDraftStore.load(trackUUID: "track-101", directory: folder))
        #expect(draft.base.rating == "2" && draft.fields.rating == "5" && draft.base.color == "2" && draft.fields.color == "2")
        #expect(draft.changedKeys == [.comment, .rating])
    }
}
