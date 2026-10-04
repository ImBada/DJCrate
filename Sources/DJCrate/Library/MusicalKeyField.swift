import DJCDomain
import SwiftUI

/// 태그 인스펙터의 키 고르기(#5): rekordbox 키 목록의 Camelot 이름(1A~12B)과 "없음"에서 고른다. 글자를 쓰지 않는다.
/// DJCrate가 추정한 키가 있으면 "추정 키" 제안으로만 보이고, 사용자가 눌러야 초안에 들어간다(자동으로 채우지 않는다).
/// 추가한 곡은 추가 목록의 키(음원 태그, 없으면 DJCrate 추정)를 같은 방식으로 제안하고, 고른 키는 곡을 넣을 때 함께 쓴다.
/// 값은 고르는 순간에만 초안에 넣는다(보이는 값이 바뀔 때마다 쓰지 않는다: 읽은 키가 옛 표기여도 건드리지 않는다).
struct MusicalKeyField: View {
    @Environment(\.textScale) private var textScale
    @Bindable var store: LibraryStore
    let rows: [TrackRow]
    @State private var loader = KeyEstimateLoader()

    private var key: TagFields.Key { .musicalKey }

    var body: some View {
        let current = store.tagValue(key, rows: rows)
        let edited = rows.contains { store.isTagEdited($0, key) }
        let editable = KeyPicker.isEditable(rows)
        let suggestion = KeyPicker.suggestion(estimate: KeyPicker.estimate(of: loader, for: rows), rows: rows, current: current)
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: Binding(get: { current.mixed ? KeyPicker.mixedTag : current.value }, set: { choose($0) })) {
                if current.mixed { Text(String(ui: "(여러 값)")).tag(KeyPicker.mixedTag) }
                Text(String(ui: "없음")).tag("")
                ForEach(KeyPicker.choices(current: current.mixed ? "" : current.value), id: \.self) { Text($0).tag($0) }
            } label: {
                // 초안이면 칸 이름 옆에 연필 표식을 붙이고 VoiceOver 이름에도 "초안"을 더한다(색만으로 알리지 않는다).
                HStack(spacing: 4) {
                    Text(key.label)
                    if edited {
                        Image(systemName: DraftMark.symbol).foregroundStyle(UIColors.draft.color).help(DraftMark.help)
                    }
                }
            }
            .accessibilityLabel(edited ? "\(key.label), \(DraftMark.spoken)" : key.label)
            .foregroundStyle(edited ? UIColors.draft.color : .primary)
            .disabled(!editable)
            .help(rows.compactMap(KeyPicker.unavailableReason).first ?? key.label)
            if editable, let reason = rows.compactMap(KeyPicker.unavailableReason).first {
                // 고른 곡 가운데 일부만 못 고칠 때: 그 곡은 빼고 쓴다는 것을 알린다
                Label(reason, systemImage: "lock").font(.scaled(.caption, textScale)).foregroundStyle(UIColors.warning.color)
            }
            if let suggestion {
                let fromTag = KeyPicker.suggestionSource(rows) == .fileTag
                Button { choose(suggestion) } label: {
                    Label(fromTag ? String(ui: "음원 태그 키 \(suggestion) 고르기") : String(ui: "추정 키 \(suggestion) 고르기"), systemImage: "lightbulb")
                        .font(.scaled(.caption, textScale)).foregroundStyle(UIColors.suggestion.color)
                }
                .buttonStyle(.link)
                .help(fromTag
                    ? String(ui: "음원 파일 태그에 적힌 키입니다. 누르면 이 키로 초안을 만들고, 곡을 rekordbox에 넣을 때 함께 씁니다. 음원 파일은 바꾸지 않습니다.")
                    : String(ui: "DJCrate가 곡을 분석해 추정한 키입니다. 누르면 이 키로 초안을 만들고, rekordbox에는 쓰기 전까지 들어가지 않습니다."))
            }
            TagConflictView(store: store, rows: rows, key: key)
        }
        // 곡이 바뀌면 추정을 다시 구한다. 크로마 캐시를 읽을 뿐 곡을 분석하지 않는다(화면 그리기에서 돌리지 않는다).
        // 앞 곡의 늦은 결과가 뒤 곡을 덮지 않게 불러오기가 곡을 맞춰 본다(`KeyEstimateLoader`).
        .task(id: KeyPicker.suggestionTarget(rows: rows)) {
            await loader.load(KeyPicker.suggestionTarget(rows: rows))
        }
    }

    /// 사용자가 고른 값만 초안에 넣는다(여러 값 표식은 값이 아니다).
    private func choose(_ value: String) {
        guard value != KeyPicker.mixedTag else { return }
        store.setTag(key, value, rows: KeyPicker.targets(rows))
    }
}

/// 현재 rekordbox 값과 내 초안이 부딪친 칸 하나를 고르게 한다(곡 하나를 골랐을 때).
struct TagConflictView: View {
    @Bindable var store: LibraryStore
    let rows: [TrackRow]
    let key: TagFields.Key

    var body: some View {
        if rows.count == 1, let row = rows.first, let draft = store.tagDrafts[row.track.uuid],
           draft.conflictingKeys(with: row.tagFields).contains(key) {
            Text(String(ui: "현재 rekordbox: \(row.tagFields[key])"))
                .textSelection(.enabled)
            Text(String(ui: "내 초안: \(draft.fields[key])")).textSelection(.enabled)
            HStack {
                Button(.ui("내 초안 유지")) { store.resolveTagConflict(key, keepingDraft: true, rows: rows) }
                Button(.ui("rekordbox 값 사용")) { store.resolveTagConflict(key, keepingDraft: false, rows: rows) }
            }
        }
    }
}
