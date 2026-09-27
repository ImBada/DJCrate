import AppKit
import DJCDomain
import DJCStorage
import SwiftUI

struct ITunesSyncView: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    private var model: ITunesSyncModel { store.iTunesSync }

    var body: some View {
        let tree = model.tree
        let preview = model.preview
        let nodes = model.nodes
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(.ui("iTunes 동기화")).font(.title2.bold())
                Spacer()
                Button {
                    Task { await model.load(store: store, forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoading || model.isSyncing || store.isLoading || store.isWritingRekordbox)
                .help(.ui("iTunes 동기화 목록 새로고침"))
                .accessibilityLabel(.ui("iTunes 동기화 목록 새로고침"))
                .accessibilityIdentifier("itunes-sync-refresh")
            }
            Text(.ui("동기화할 폴더와 플레이리스트를 선택하세요. 폴더를 선택하면 하위 목록도 포함됩니다."))
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(verbatim: "iTunes").font(.headline)
                        Spacer()
                        Button(.ui("전체 선택")) { model.selection = ITunesSyncSelection(selectedIDs: ["0"]) }
                        Button(.ui("선택 해제")) { model.selection = ITunesSyncSelection() }
                    }
                    List {
                        OutlineGroup(tree, children: \.children) { node in
                            let id = String(node.id.dropFirst("itunes:".count))
                            HStack {
                                Label(node.name, systemImage: node.isFolder ? "folder" : "music.note.list")
                                    .lineLimit(1).help(node.name)
                                Spacer(minLength: 8)
                                ITunesSyncCheckbox(name: node.name, id: id, state: model.selection.state(of: id, in: nodes)) {
                                    let currentNodes = model.nodes
                                    model.selection.setSelected(model.selection.state(of: id, in: currentNodes) != .on,
                                                                id: id, in: currentNodes)
                                }
                                .frame(width: 18, height: 18)
                            }
                        }
                    }
                    .overlay {
                        if model.isLoading { ProgressView() }
                        else if tree.isEmpty { Text(.ui("읽을 수 있는 iTunes 목록이 없습니다")).foregroundStyle(.secondary) }
                    }
                }
                Image(systemName: "arrow.right").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(.ui("rekordbox 동기화 목록")).font(.headline)
                        Spacer()
                        Text(.ui("목록 \(preview.playlistCount)개")).foregroundStyle(.secondary)
                    }.frame(height: 24)
                    List {
                        OutlineGroup(preview.tree, children: \.children) { node in
                            Label(node.name, systemImage: node.isFolder ? "folder" : "music.note.list")
                                .lineLimit(1).help(node.name)
                        }
                    }
                    .overlay {
                        if preview.tree.isEmpty {
                            Text(.ui("동기화할 목록을 선택하세요")).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .disabled(model.isLoading || model.isSyncing || model.source.status != .ready)
            if let message = model.error ?? model.source.status.message {
                Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(.ui("선택한 목록을 rekordbox와 DJCrate에 동일하게 반영합니다. 먼저 rekordbox를 종료하세요."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(.ui("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(model.isSyncing)
                Button(.ui("동기화")) {
                    Task { if await model.sync(store: store) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSync || store.isLoading || store.isWritingRekordbox)
                .accessibilityIdentifier("itunes-sync-apply")
            }
        }
        .padding(24)
        .frame(width: 860, height: 560)
        .interactiveDismissDisabled(model.isSyncing)
        .task { await model.load(store: store) }
    }
}

/// AppKit 체크박스의 부분 선택 표시와 키보드·접근성을 그대로 쓴다.
private struct ITunesSyncCheckbox: NSViewRepresentable {
    let name: String
    let id: String
    let state: ITunesSyncSelection.State
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.toggle))
        button.allowsMixedState = true
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
        button.state = switch state { case .off: .off; case .mixed: .mixed; case .on: .on }
        button.setAccessibilityLabel(name)
        button.identifier = NSUserInterfaceItemIdentifier("itunes-sync-\(id)")
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func toggle() { action() }
    }
}
