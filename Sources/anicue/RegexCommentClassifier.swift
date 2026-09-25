import AnicueCore
import Foundation

enum RegexCommentClassifier {
    // Regex는 Sendable이 아니지만 생성 후 바뀌지 않는 값이다.
    nonisolated(unsafe) static let residuePatterns: [Regex<Substring>] = [
        /JASRAC/, /(?i)uploaded by/, /(?i)ripped by/, /(?i)encoded by/, /(?i)tagged by/,
        /(?i)brought to you/, /ExactAudioCopy/, /\bEAC\b/, /(?i)https?:\/\//, /(?i)www\./,
        /(?i)\.(?:com|net|info|org)\b/, /NIPPONSEI/, /SoftWarez/, /(?i)recorded using/,
    ]

    static func classify(_ raw: String) -> CommentClass {
        let text = CommentText.normalize(raw)
        if text.isEmpty { return .empty }
        if RegexConventionParser.prefix(of: text) != nil { return .convention }
        if residuePatterns.contains(where: { text.contains($0) }) { return .residue }
        if text.contains(";"), text.contains(":") { return .credit }
        if text.contains(/(?i)(lyrics|arranged|composed)\s*:/) { return .credit }
        if text.contains(","),
           text.contains(/(?:^|\s)(OP|ED|IN)(?:\s*\d+)?(?:,|\s|$)|\[CS\]|[가-힣]/) {
            return .legacy
        }
        return .other
    }
}
