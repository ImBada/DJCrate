import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import SwiftUI

/// Mp3tag처럼 여러 곡을 한꺼번에 편집하는 인스펙터. 초안에만 저장되고 파일에는 쓰지 않는다.
struct TagInspector: View {
    @Bindable var store: LibraryStore

    var body: some View {
        let rows = store.selectedRows
        Form {
            if rows.isEmpty {
                Text("목록에서 곡을 선택하세요. 여러 곡을 고르면 한꺼번에 편집합니다.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    HStack {
                        Text(rows.count == 1 ? rows[0].title : "\(rows.count)곡 선택").font(.headline).lineLimit(1)
                        Spacer()
                        let changed = rows.filter { store.tagDrafts[$0.track.uuid] != nil }.count
                        if changed > 0 {
                            Text("초안 \(changed)곡").font(.caption.bold()).foregroundStyle(Palette.mid)
                        }
                    }
                }
                Section("곡 정보") {
                    ForEach(TagFields.Key.allCases.filter { $0 != .comment }) { key in
                        field(key, rows: rows)
                    }
                }
                Section("코멘트") {
                    field(.comment, rows: rows, axis: .vertical)
                    let comment = store.tagValue(.comment, rows: rows)
                    if !comment.mixed {
                        CommentPreview(comment: comment.value)
                    }
                }
                Section {
                    let issues = rows.compactMap { store.tagDrafts[$0.track.uuid] }.flatMap(\.issues)
                    if !issues.isEmpty {
                        Label(Set(issues).sorted().joined(separator: " · "), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.caption)
                    }
                    HStack {
                        Button("되돌리기") { store.revertTags(rows: rows) }
                        Spacer()
                        Button("파일에 쓰기…") {}
                            .disabled(true)
                            .help("안전 쓰기(태그 프레임만 교체 + 검증) 구현과 rekordbox Reload Tag 검증 전까지 잠겨 있습니다.")
                    }
                    Text("편집은 DJCrate 초안에만 저장됩니다. 음원 파일과 rekordbox는 바뀌지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
        TextField(label, text: $text, prompt: Text(mixed ? "(여러 값 — 입력하면 모두 바뀜)" : ""), axis: axis)
            .focused($focused)
            .foregroundStyle(edited ? Palette.mid : .primary)
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

/// 코멘트를 사용자 규칙으로 파싱한 결과를 보여 준다.
private struct CommentPreview: View {
    let comment: String

    var body: some View {
        let cls = CommentClassifier.classify(comment)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(cls.displayName).font(.caption.bold()).foregroundStyle(cls.tint)
            if let parsed = ConventionParser.parse(comment) {
                Text(summary(parsed)).font(.caption).foregroundStyle(.secondary)
            } else if cls != .empty {
                Text("규칙(분류 접두어 + 작품명 + 용도)에 맞지 않습니다").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ c: ConventionComment) -> String {
        var parts = [c.prefix.rawValue, c.workName]
        if let season = c.season { parts.append("\(season)기") }
        if !c.abbreviations.isEmpty { parts.append("약칭 " + c.abbreviations.joined(separator: ", ")) }
        parts += c.usages.map { $0.kind.rawValue + ($0.numbers.isEmpty ? "" : " " + $0.numbers.map(String.init).joined(separator: ",")) }
        if c.isCharacterSong { parts.append("CS") }
        if c.isTVSize { parts.append("TVSIZE") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
