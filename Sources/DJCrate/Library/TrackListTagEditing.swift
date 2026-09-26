import DJCDomain

/// 곡 목록에서 바로 태그를 고치는 규칙(#88). 표(AppKit)와 나눠 시험한다.
///
/// - 시작: 태그 칸 더블클릭, 또는 곡을 고른 채 Return(Finder 이름 바꾸기처럼)으로 보이는 첫 태그 칸
/// - Tab·⇧Tab: 확정하고 보이는 옆 태그 칸으로(끝이면 편집을 마친다) / Return: 확정 / Esc: 취소
/// - 고른 곡 안에서 고치면 고른 곡 모두에 적용한다(인스펙터 여러 곡 편집과 같다).
///   값이 서로 다르면 빈 칸으로 시작하고, 비운 채 나오면 그대로 둔다.
/// - 스트리밍 곡(파일 태그 없음)은 고치지 않는다. 저장은 `LibraryStore.setTag`(초안·되돌리기 한 단위)로만 한다.
enum TrackListTagEditing {
    /// 칸 하나를 고치는 동안 들고 있는 값. 대상 곡과 시작 값은 편집을 시작할 때 정한다.
    struct Session: Equatable {
        let key: TagFields.Key
        /// 초안을 만들 곡(중복·스트리밍 제외, 표 순서)
        let targets: [TrackRow]
        /// 칸에 넣고 시작한 값. 여러 값이면 빈 칸.
        let original: String
        let mixed: Bool

        init?(key: TagFields.Key, targets: [TrackRow], value: (TrackRow) -> String) {
            guard let first = targets.first else { return nil }
            let firstValue = value(first)
            let mixed = targets.dropFirst().contains { value($0) != firstValue }
            self.key = key
            self.targets = targets
            original = mixed ? "" : firstValue
            self.mixed = mixed
        }
    }

    /// 목록 칸 이름은 태그 키 이름과 같다. 태그가 아닌 칸(BPM·키·분류 등)은 nil.
    static func key(forColumn id: String) -> TagFields.Key? {
        TagFields.Key(rawValue: id)
    }

    /// Return으로 편집을 시작할 칸: 보이는 칸 순서에서 첫 태그 칸.
    static func firstColumn(in visibleColumns: [String]) -> String? {
        visibleColumns.first { key(forColumn: $0) != nil }
    }

    /// Tab(앞)·⇧Tab(뒤)으로 옮겨 갈 보이는 옆 태그 칸. 끝이면 nil(편집을 마친다).
    static func column(after id: String, forward: Bool, in visibleColumns: [String]) -> String? {
        let editable = visibleColumns.filter { key(forColumn: $0) != nil }
        guard let index = editable.firstIndex(of: id) else { return nil }
        let next = index + (forward ? 1 : -1)
        return editable.indices.contains(next) ? editable[next] : nil
    }

    /// 고칠 곡: 누른 줄이 고른 줄 안이면 고른 곡 모두, 밖이면 그 줄만.
    /// 누른 곡이 스트리밍이면 편집하지 않는다(빈 배열).
    static func targets(anchor: TrackRow, selection: [TrackRow]) -> [TrackRow] {
        guard !anchor.track.isStreaming else { return [] }
        let candidates = selection.contains { $0.id == anchor.id } ? selection : [anchor]
        var seen = Set<String>()
        return candidates.filter { !$0.track.isStreaming && seen.insert($0.track.id).inserted }
    }

    /// 확정할 때 바꿀 곡. 시작 값 그대로면(여러 값 칸을 비운 채 나오면 포함) 아무 곡도 바꾸지 않는다.
    static func changes(_ session: Session, committing text: String) -> [TrackRow] {
        text == session.original ? [] : session.targets
    }

    /// 목록 칸 글자와 초안 여부: 태그 초안이 있으면 초안 값(태그 시트와 같다), 없으면 rekordbox 값.
    /// 제목·아티스트가 암호화된 스트리밍 곡은 지금 목록 표시를 그대로 쓴다.
    static func text(_ row: TrackRow, _ key: TagFields.Key, draft: TagDraft?) -> (text: String, edited: Bool) {
        if let draft { return (draft.fields[key], draft.base[key] != draft.fields[key]) }
        if row.isEncrypted {
            switch key {
            case .title: return (row.title, false)
            case .artist, .album, .albumArtist: return ("", false)
            default: break
            }
        }
        return (TagFields(track: row.track)[key], false)
    }

    /// 분류 칸: 코멘트 초안이 있으면 초안 코멘트로 다시 가른다(인스펙터 미리 보기와 같다). 필터·정렬은 rekordbox 값 그대로다.
    static func commentEvaluation(_ row: TrackRow, draft: TagDraft?, rule: (any CommentRule)?) -> CommentEvaluation? {
        guard let draft, draft.base.comment != draft.fields.comment else { return row.commentEvaluation }
        return rule?.evaluate(draft.fields.comment)
    }
}
