import Foundation

public enum CommentText {
    /// P0 전처리: NFC → 제어문자(U+0000–U+001F) 제거 → trim → 연속 공백을 한 칸으로.
    public static func normalize(_ raw: String) -> String {
        let nfc = raw.precomposedStringWithCanonicalMapping
        let scalars = nfc.unicodeScalars.filter { $0.value > 0x1F }
        let cleaned = String(String.UnicodeScalarView(scalars))
        return cleaned
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// R11 비교 키: NFKC, 소문자, 공백·기호 제거. (`귀여울 리가` == `귀여울리가`)
    public static func matchKey(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .filter { $0.isLetter || $0.isNumber })
    }
}

public enum CommentClass: String, Sendable, CaseIterable {
    /// 분류 접두어로 시작하는 사용자 컨벤션.
    case convention
    /// `神様のメモ帳 OP, 하느님의 메모장, 카미메모` 같은 구형 콤마 스타일.
    case legacy
    /// 리핑·업로더·레이블 태그 잔재.
    case residue
    /// `가수 (…): 캐릭터 (…); …` 형태의 크레딧 문자열.
    case credit
    case empty
    case other
}

public enum CommentClassifier {
    public static func classify(_ raw: String) -> CommentClass {
        classify(normalized: CommentText.normalize(raw))
    }

    /// 정규식 없이 분류한다(7천 곡 로딩에서 정규식이 병목이었다).
    public static func classify(normalized text: String) -> CommentClass {
        if text.isEmpty { return .empty }
        if ConventionParser.prefix(of: text) != nil { return .convention }
        if isResidue(text) { return .residue }
        if text.contains(";"), text.contains(":") { return .credit }
        let lower = text.lowercased()
        if ["lyrics", "arranged", "composed"].contains(where: { keywordFollowedByColon(lower, $0) }) { return .credit }
        if text.contains(","), hasLegacyHint(text) { return .legacy }
        return .other
    }

    /// 리핑·업로더·레이블 태그 잔재.
    static func isResidue(_ text: String) -> Bool {
        if ["JASRAC", "ExactAudioCopy", "NIPPONSEI", "SoftWarez"].contains(where: text.contains) { return true }
        let lower = text.lowercased()
        if ["uploaded by", "ripped by", "encoded by", "tagged by", "brought to you", "recorded using",
            "http://", "https://", "www."].contains(where: lower.contains) { return true }
        if words(text).contains("EAC") { return true }
        for tld in [".com", ".net", ".info", ".org"] {
            var search = lower.startIndex..<lower.endIndex
            while let range = lower.range(of: tld, range: search) {
                let next = range.upperBound < lower.endIndex ? lower[range.upperBound] : nil
                if next == nil || !(next!.isLetter || next!.isNumber || next! == "_") { return true }
                search = range.upperBound..<lower.endIndex
            }
        }
        return false
    }

    /// `OP` · `ED 1,` · `IN3` 같은 용도 토큰, `[CS]`, 또는 한글이 있으면 구형 콤마 스타일로 본다.
    static func hasLegacyHint(_ text: String) -> Bool {
        if text.contains("[CS]") { return true }
        if text.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) { return true }
        let tokens = text.split(whereSeparator: \.isWhitespace)
        for (i, token) in tokens.enumerated() {
            for kind in ["OP", "ED", "IN"] where token.hasPrefix(kind) {
                var rest = token.dropFirst(kind.count)
                // `OP` 다음 토큰이 숫자인 경우(`OP 3,`)도 OP 자체가 공백 앞이라 이미 성립한다.
                rest = rest.drop(while: { $0.wholeNumberValue != nil })
                if rest.isEmpty || rest.first == "," { return true }
                _ = i
            }
        }
        return false
    }

    private static func keywordFollowedByColon(_ lower: String, _ keyword: String) -> Bool {
        var search = lower.startIndex..<lower.endIndex
        while let range = lower.range(of: keyword, range: search) {
            let after = lower[range.upperBound...].drop(while: \.isWhitespace)
            if after.first == ":" { return true }
            search = range.upperBound..<lower.endIndex
        }
        return false
    }

    /// 영숫자 단어 경계로 나눈 단어들(`\bEAC\b` 대체).
    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
    }
}
