@testable import AnicueCore
import Foundation
import Testing

@Suite("rekordbox 직접 쓰기")
struct RekordboxWriteTests {
    @Test func JSON은_읽은_칸_순서_그대로_다시_쓴다() throws {
        // 옛 rekordbox 형식: ContentUUID가 Color 뒤에 있다.
        let text = #"[{"ID":"1","ContentID":"2","InMsec":988,"Kind":0,"Color":-1,"ContentUUID":"u","UUID":"x","created_at":"2023-09-16T13:54:04.920+00:00"}]"#
        let objects = try CueJSON.parse(text)
        #expect(CueJSON.serialize(objects) == text)
        #expect(objects[0]["InMsec"] == .int(988) && objects[0]["ContentUUID"] == .string("u"))
    }

    @Test func null_칸은_빠지고_이스케이프는_rekordbox처럼() throws {
        let objects = try CueJSON.parse(#"[{"ID":"1","Comment":null,"Kind":1}]"#)
        #expect(CueJSON.serialize(objects) == #"[{"ID":"1","Kind":1}]"#)
        let named = CueJSON.newObject([("Comment", .string("따옴표\"·역슬래시\\·줄\n")), ("ID", .string("9")), ("Kind", .int(0)), ("Color", nil)])
        let written = CueJSON.serialize([named])
        #expect(written == #"[{"ID":"9","Kind":0,"Comment":"따옴표\"·역슬래시\\·줄\n"}]"#)
        #expect(try CueJSON.parse(written) == [named])
        #expect(try CueJSON.parse("[]").isEmpty)
    }

    @Test func 새_큐_칸_순서는_rekordbox_7과_같다() {
        let object = CueJSON.newObject([
            ("UUID", .string("u")), ("Kind", .int(1)), ("ID", .string("7")), ("ContentID", .string("3")),
            ("ContentUUID", .string("c")), ("InMsec", .int(4385)), ("InFrame", .int(657)), ("Color", .int(-1)),
            ("created_at", .string("t")), ("updated_at", .string("t")), ("ColorTableIndex", nil),
        ])
        #expect(object.fields.map(\.key) == ["ID", "ContentID", "ContentUUID", "InMsec", "InFrame", "Kind", "Color", "UUID", "created_at", "updated_at"])
    }

    @Test func 시각_형식() {
        let date = Date(timeIntervalSince1970: 1_790_354_341.005)
        let stamp = CueJSON.timestamps(date)
        #expect(stamp.db.hasSuffix(".005 +00:00") && stamp.json.hasSuffix(".005+00:00") && stamp.json.contains("T"))
    }

    @Test func 편집_큐_종류를_rekordbox_Kind로() {
        #expect(RekordboxWriter.kind(for: .memory) == 0)
        #expect((0..<8).map { RekordboxWriter.kind(for: .hot($0)) } == [1, 2, 3, 5, 6, 7, 8, 9])
    }

    @Test func 마디_박_표시는_박을_0부터() {
        let grid = BeatGrid(beats: (0..<12).map { .init(number: ($0 + 3) % 4 + 1, bpm: 120, time: 1 + Double($0) * 0.5) })
        // 첫 박은 4박(마디 전), 둘째 박부터 1마디
        #expect(grid.position(at: 0.5) == nil)
        #expect(grid.positionText(at: 1.0) == "0.3")
        #expect(grid.positionText(at: 1.5) == "1.0")
        #expect(grid.positionText(at: 2.2) == "1.1")
        #expect(grid.positionText(at: 3.5) == "2.0")
        #expect(grid.positionText(at: 3.4999) == "2.0", "1ms 안쪽은 다음 박으로 본다")
    }
}
