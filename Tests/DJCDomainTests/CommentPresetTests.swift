import DJCDomain
import Testing

@Suite("코멘트 프리셋")
struct CommentPresetTests {
    @Test func 기본은_꺼짐이고_규칙_필터를_숨긴다() {
        #expect(SettingKeys.commentPreset.defaultValue == "none")
        #expect(SettingKeys.commentPreset.value(from: "unknown") == "none")
        #expect(CommentPreset.none.rule == nil)
        #expect(!LibraryFilter.visible(commentPreset: .none).contains(.emptyComment))
        #expect(!LibraryFilter.visible(commentPreset: .none).contains(.offConvention))
        #expect(LibraryFilter.visible(commentPreset: .anisong) == LibraryFilter.allCases)
    }

    @Test func 애니송은_기존_분류와_표시를_유지한다() throws {
        let rule = try #require(CommentPreset.anisong.rule)
        let result = rule.evaluate(" TVA  시험(약칭) 2기 OP 1 TVSIZE ")
        #expect(result.classification == "convention")
        #expect(result.displayName == "규칙")
        #expect(result.isMatch)
        #expect(result.prefix == "TVA")
        #expect(result.usages == ["OP"])
        #expect(result.summary == "TVA · 시험 · 2기 · 약칭 약칭 · OP 1 · TVSIZE")
        #expect(rule.evaluate("").isEmpty)
        #expect(rule.evaluate("JASRAC / Lantis").classification == "residue")
        #expect(!rule.evaluate("자유 메모").isMatch)
    }
}
