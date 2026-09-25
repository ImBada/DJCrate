import Foundation
import AnicueCore

/// 컨벤션 코멘트 파서.
///
/// 작품명 안에 숫자·기호가 섞일 수 있어서(`…게이트 0`, `22/7`) 뒤에서부터 구조 토큰을 떼어 낸다.
/// 토큰 순서가 흔들려도(`ED CS`, `IN 3 TVSIZE`, `(약칭) 1기`) 같은 구조로 흡수한다.
enum RegexConventionParser {
    static func prefix(of text: String) -> ConventionComment.Prefix? {
        guard let match = text.prefixMatch(of: /(TVA|OVA|MV|GM|PC Game|VT|VD|NT|ADV)(?=\s|$)/) else { return nil }
        return ConventionComment.Prefix(rawValue: String(match.1))
    }

    static func parse(_ raw: String) -> ConventionComment? {
        let text = CommentText.normalize(raw)
        guard let prefix = prefix(of: text) else { return nil }
        var result = ConventionComment(prefix: prefix)
        var rest = String(text.dropFirst(prefix.rawValue.count)).trimmingCharacters(in: .whitespaces)

        stripTrailingTokens(&rest, into: &result)
        parseWorkRef(rest, into: &result)
        return result
    }

    // MARK: - 뒤쪽 구조 토큰

    private static func stripTrailingTokens(_ rest: inout String, into result: inout ConventionComment) {
        var tail = ConventionComment.Tail()
        var boombox: [Int] = []
        var usages: [ConventionComment.Usage] = []
        var episodes: [Int] = []
        var variants: [String] = []

        var progressed = true
        while progressed, !rest.isEmpty {
            progressed = false

            // 툴 꼬리: BBnn(반복) / 구형 BB13,19
            if let m = strip(&rest, /(?:^|\s)BB(\d+(?:,\d+)*)$/) {
                boombox.insert(contentsOf: numbers(m.1), at: 0)
                progressed = true; continue
            }
            if let m = strip(&rest, /(?:^|\s)(\d{4}) ([1-4])분기$/) {
                tail.airingYear = Int(m.1)
                tail.airingQuarter = Int(m.2)
                progressed = true; continue
            }
            if let m = strip(&rest, /(?:^|\s)(\d{4}) 영화$/) {
                tail.movieYear = Int(m.1)
                progressed = true; continue
            }

            // 플래그
            if strip(&rest, /(?:^|\s)(?:TVSIZE|TV SIZE|TVISZE|TVIZE)$/) != nil {
                result.isTVSize = true
                progressed = true; continue
            }
            if strip(&rest, /(?:^|\s)(?:\[CS\]|CS)$/) != nil {
                result.isCharacterSong = true
                progressed = true; continue
            }
            if strip(&rest, /\s*\(한국\)$/) != nil {
                variants.insert("(한국)", at: 0)
                progressed = true; continue
            }
            if let m = strip(&rest, /(?:^|\s)(CV|RM|MX|MIX|AR|PV|Short|레뷰)$/) {
                variants.insert(String(m.1), at: 0)
                progressed = true; continue
            }

            // 회차: `3화`, `3화, 5화`, `EP 12`
            if let m = strip(&rest, /(?:^|\s)(\d+화(?:,\s*\d+화)*)$/) {
                episodes.insert(contentsOf: numbers(m.1), at: 0)
                progressed = true; continue
            }
            if let m = strip(&rest, /(?:^|\s)EP\s?(\d+)$/) {
                episodes.insert(contentsOf: numbers(m.1), at: 0)
                progressed = true; continue
            }

            // 용도: `OP`, `ED 1`, `IN9`, `IN 3 7 11 23`, `IN 8, 10`
            if let m = strip(&rest, /(?:^|\s)(OP|ED|IN)(?:\s?(\d+(?:(?:,\s*|\s)\d+)*))?$/) {
                let kind = ConventionComment.UsageKind(rawValue: String(m.1))!
                usages.insert(.init(kind: kind, numbers: m.2.map(numbers) ?? []), at: 0)
                progressed = true; continue
            }
        }

        tail.boomboxVolumes = boombox
        result.tail = tail
        result.usages = usages
        result.episodes = episodes
        result.variants = variants
    }

    // MARK: - work_ref (작품명 + 기수 + 약칭)

    private static func parseWorkRef(_ ref: String, into result: inout ConventionComment) {
        result.workRef = ref
        var rest = ref

        if strip(&rest, /\s*\(구\)$/) != nil { result.isFormerAffiliation = true }

        // 기수와 약칭 순서가 흔들리므로 두 번까지 번갈아 뗀다.
        for _ in 0..<2 {
            if result.season == nil {
                if let m = strip(&rest, /\s*\((\d+)기\)$/) {
                    result.season = Int(m.1); result.seasonStyle = .parenthesized; continue
                }
                if let m = strip(&rest, /\s(\d+)기$/) {
                    result.season = Int(m.1); result.seasonStyle = .plain; continue
                }
                if let m = strip(&rest, /\s시즌\s?(\d+)$/) {
                    result.season = Int(m.1); result.seasonStyle = .season; continue
                }
            }
            if result.abbreviations.isEmpty, let m = strip(&rest, /\s*\(([^()]+)\)$/) {
                result.abbreviations = m.1
                    .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                continue
            }
            break
        }
        result.workName = rest
    }

    // MARK: - helpers

    /// 문자열 끝에 붙은 매치를 떼어 내고 매치를 돌려준다.
    @discardableResult
    private static func strip<Output>(_ text: inout String, _ regex: Regex<Output>) -> Output? {
        guard let match = text.firstMatch(of: regex), match.range.upperBound == text.endIndex else { return nil }
        text = String(text[..<match.range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return match.output
    }

    private static func numbers(_ text: Substring) -> [Int] {
        text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}
