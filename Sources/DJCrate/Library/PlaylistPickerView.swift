import DJCDomain
import SwiftUI

/// '재생 목록에 넣기…': 이름(폴더 경로 포함)으로 목록을 찾아 고른 곡을 넣는다. 찾지 않을 때는 최근 목록이 위에 온다.
struct PlaylistPickerView: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    private struct Choice: Identifiable, Hashable {
        var id: String
        var name: String
        var path: String
        var recent: Bool
    }

    private var choices: [Choice] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = store.trackPlaylists.map { Choice(id: $0.item.id, name: $0.item.name, path: $0.path.joined(separator: " › "), recent: false) }
        guard needle.isEmpty else {
            return all.filter { ($0.path + " " + $0.name).lowercased().contains(needle) }
        }
        let recent = store.recentPlaylists.compactMap { item in all.first { $0.id == item.id } }.map { choice in
            var choice = choice
            choice.recent = true
            return choice
        }
        let recentIDs = Set(recent.map(\.id))
        return recent + all.filter { !recentIDs.contains($0.id) }
    }

    var body: some View {
        let choices = choices
        VStack(alignment: .leading, spacing: 12) {
            Text(.ui("재생 목록에 넣기 (\(store.playlistPickerTracks.count)곡)")).font(.headline)
            TextField(text: $query, prompt: Text(.ui("목록·폴더 이름"))) { Text(.ui("찾기")) }
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { add(selection ?? choices.first?.id) }
            List(choices, selection: $selection) { choice in
                HStack(spacing: 6) {
                    Image(systemName: choice.recent ? "clock" : "music.note.list").foregroundStyle(.secondary)
                    Text(verbatim: choice.name).lineLimit(1)
                    if !choice.path.isEmpty {
                        Text(verbatim: choice.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                .tag(choice.id)
                .accessibilityElement(children: .combine)
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in add(ids.first) }
            .overlay {
                if choices.isEmpty { Text(.ui("맞는 재생 목록이 없습니다")).foregroundStyle(.secondary) }
            }
            HStack {
                Text(.ui("넣은 곡은 ‘rekordbox에 쓰기’(⇧⌘E)로 저장합니다.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(.ui("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(.ui("넣기")) { add(selection ?? choices.first?.id) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choices.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 420)
        .onAppear { searchFocused = true }
    }

    private func add(_ id: String?) {
        guard let id else { return }
        store.addTracks(store.playlistPickerTracks, toPlaylist: id)
        dismiss()
    }
}
