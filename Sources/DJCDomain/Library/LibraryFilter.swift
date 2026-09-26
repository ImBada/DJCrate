/// 앱과 CLI가 공유하는 컬렉션 필터. 표시 이름과 기존 판정은 그대로 둔다.
public enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case emptyComment = "빈 코멘트 전체"
    case offConvention = "규칙 밖 코멘트"
    case noCues = "큐 없음"
    case played = "재생한 곡"
    case streaming = "스트리밍"
    case noBPM = "BPM·그리드 없음"
    case tempoChange = "변속 곡"
    case all = "전체"

    public var id: String { rawValue }

    public var cliName: String {
        switch self {
        case .emptyComment: "empty-comment"
        case .offConvention: "off-convention"
        case .noCues: "no-cues"
        case .played: "played"
        case .streaming: "streaming"
        case .noBPM: "no-bpm"
        case .tempoChange: "tempo-change"
        case .all: "all"
        }
    }

    public func includes(track: Track, commentClass: CommentClass, hasCues: Bool, playCount: Int, tempoChanges: [Double]) -> Bool {
        switch self {
        case .emptyComment: commentClass == .empty
        case .offConvention: [.legacy, .residue, .credit, .other].contains(commentClass)
        case .noCues: !hasCues
        case .played: playCount > 0
        case .streaming: track.isStreaming
        case .noBPM: !track.isStreaming && (track.bpm ?? 0) <= 0
        case .tempoChange: !tempoChanges.isEmpty
        case .all: true
        }
    }
}
