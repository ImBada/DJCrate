import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import SwiftUI

/// Mp3tag처럼 여러 곡을 한꺼번에 편집하는 인스펙터. 초안에 저장하고 반영 때 rekordbox 곡 정보에 쓴다(음원 파일에는 쓰지 않는다).
struct TagInspector: View {
    @Environment(\.textScale) private var textScale
    @Bindable var store: LibraryStore

    var body: some View {
        let rows = store.selectedRows
        Form {
            if rows.isEmpty {
                Text(.ui("목록에서 곡을 선택하세요. 여러 곡을 고르면 한꺼번에 편집합니다."))
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    HStack {
                        Text(rows.count == 1 ? rows[0].title : String(ui: "\(rows.count)곡 선택")).font(.scaled(.headline, textScale)).lineLimit(1)
                        Spacer()
                        let changed = rows.filter { store.tagDrafts[$0.track.uuid] != nil }.count
                        if changed > 0 {
                            Text(.ui("초안 \(changed)곡")).font(.scaled(.caption, textScale).bold()).foregroundStyle(UIColors.draft.color)
                        }
                    }
                }
                Section(.ui("곡 정보")) {
                    ForEach(TagFields.Key.allCases.filter { $0 != .comment }) { key in
                        field(key, rows: rows)
                    }
                }
                Section(.ui("코멘트")) {
                    field(.comment, rows: rows, axis: .vertical)
                    let comment = store.tagValue(.comment, rows: rows)
                    if !comment.mixed, let rule = store.commentPreset.rule {
                        CommentPreview(result: rule.evaluate(comment.value))
                    }
                }
                Section {
                    let issues = rows.compactMap { store.tagDrafts[$0.track.uuid] }.flatMap(\.issues)
                    if !issues.isEmpty {
                        Label(Set(issues).sorted().joined(separator: " · "), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(UIColors.warning.color).font(.scaled(.caption, textScale))
                    }
                    Button(.ui("되돌리기")) { store.revertTags(rows: rows) }
                    // 반영(⌘⇧E)하면 rekordbox 곡 정보에 쓴다. 음원 파일은 읽기만 한다(#1 결정).
                    Text(.ui("rekordbox 반영 때 라이브러리에만 씁니다. 음원 파일의 태그는 바뀌지 않습니다."))
                        .font(.scaled(.caption, textScale)).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .font(.scaled(.body, textScale))
    }

    private func field(_ key: TagFields.Key, rows: [TrackRow], axis: Axis = .horizontal) -> some View {
        let current = store.tagValue(key, rows: rows)
        let edited = rows.contains { store.isTagEdited($0, key) }
        return CommitTextField(label: key.label, value: current.value, mixed: current.mixed, edited: edited, axis: axis) { text in
            store.setTag(key, text, rows: rows)
        }
        .id("\(key.rawValue)-\(store.selection.hashValue)")
    }
}

/// 입력 중에는 로컬로만 바꾸고, Enter를 치거나 칸을 벗어날 때 한 번 반영한다.
/// (여러 곡 선택 시 글자마다 전 곡을 고치고 저장하던 비용과, 글자마다 쌓이던 되돌리기 단계를 없앤다.)
private struct CommitTextField: View {
    let label: String
    let value: String
    let mixed: Bool
    let edited: Bool
    let axis: Axis
    let commit: (String) -> Void
    @State private var text = ""
    @State private var dirty = false
    @FocusState private var focused: Bool

    var body: some View {
        // 초안이면 칸 이름 옆에 연필 표식을 붙이고 VoiceOver 이름에도 "초안"을 더한다(색만으로 알리지 않는다).
        // 값(accessibilityValue)을 덮으면 칸에 적힌 글자를 못 읽으므로 이름에 붙인다.
        TextField(text: $text, prompt: Text(mixed ? String(ui: "(여러 값 — 입력하면 모두 바뀜)") : ""), axis: axis) {
            HStack(spacing: 4) {
                Text(label)
                if edited {
                    Image(systemName: DraftMark.symbol)
                        .foregroundStyle(UIColors.draft.color)
                        .help(DraftMark.help)
                }
            }
        }
            .accessibilityLabel(edited ? "\(label), \(DraftMark.spoken)" : label)
            .focused($focused)
            .foregroundStyle(edited ? UIColors.draft.color : .primary)
            .onAppear { text = value }
            .onChange(of: value) { if !focused { text = value } }
            .onChange(of: text) { dirty = text != value }
            .onSubmit(apply)
            .onChange(of: focused) { if !focused { apply() } }
    }

    private func apply() {
        guard dirty else { return }
        dirty = false
        commit(text)
    }
}

/// 고른 프리셋의 분류와 설명만 보여 준다.
private struct CommentPreview: View {
    @Environment(\.textScale) private var textScale
    let result: CommentEvaluation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(result.displayName).font(.scaled(.caption, textScale).bold()).foregroundStyle(result.tone.tint)
            if !result.summary.isEmpty {
                Text(result.summary).font(.scaled(.caption, textScale)).foregroundStyle(.secondary)
            }
        }
    }
}
