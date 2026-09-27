import DJCDomain
import DJCStorage
import RekordboxKit
import SwiftUI

/// iTunes 목록은 구성 편집·드롭 메뉴를 달지 않는다. 반복 곡의 행은 구분하고 편집은 기존 곡에 연결한다.
struct ITunesPlaylistSection: View {
    let store: LibraryStore
    @State private var isExpanded = true

    var body: some View {
        @Bindable var store = store
        Section(isExpanded: $isExpanded) {
            if let message = store.iTunesLibrary.status.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if store.iTunesLibrary.tree.isEmpty {
                Text(.ui("동기화한 iTunes 목록이 없습니다")).foregroundStyle(.secondary)
            }
            if store.iTunesLibrary.unavailablePlaylistCount > 0 {
                Text(.ui("원본에서 찾지 못한 목록 \(store.iTunesLibrary.unavailablePlaylistCount)개 · 동기화 선택을 확인하세요"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            OutlineGroup(store.iTunesLibrary.tree, children: \.children) { node in
                Label(node.name, systemImage: node.isFolder ? "folder" : "music.note.list")
                    .badge(node.trackIDs.count)
                    .lineLimit(1)
                    .help(node.name)
                    .tag(SidebarItem.itunesPlaylist(node.id))
            }
        } header: {
            HStack {
                Text(.ui("iTunes 동기화 목록"))
                Spacer(minLength: 0)
                Button {
                    store.presentITunesSync()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .disabled(store.isLoading || store.isWritingRekordbox || store.snapshotURL == nil)
                .help(.ui("iTunes 동기화…"))
                .accessibilityLabel(.ui("iTunes 동기화…"))
                Button {
                    Task { await store.refreshITunesPlaylists() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(store.isLoading || store.isWritingRekordbox)
                .help(.ui("iTunes 동기화 목록 새로고침"))
                .accessibilityLabel(.ui("iTunes 동기화 목록 새로고침"))
            }
        }
        .sheet(isPresented: $store.showingITunesSync) { ITunesSyncView(store: store) }
    }
}
