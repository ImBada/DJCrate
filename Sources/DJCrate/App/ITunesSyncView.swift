import AppKit
import DJCDomain
import DJCStorage
import SwiftUI

struct ITunesSyncView: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    private var model: ITunesSyncModel { store.iTunesSync }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(.ui("iTunes 동기화")).font(.title2.bold())
            Text(.ui("동기화할 폴더와 플레이리스트를 선택하세요. 폴더를 선택하면 하위 목록도 포함됩니다."))
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(verbatim: "iTunes").font(.headline)
                        Spacer()
                        Button(.ui("전체 선택")) { model.selection = ITunesSyncSelection(selectedIDs: Set(model.nodes.map(\.id))) }
                        Button(.ui("선택 해제")) { model.selection = ITunesSyncSelection() }
                    }
                    List {
                        OutlineGroup(model.tree, children: \.children) { node in
                            let id = String(node.id.dropFirst("itunes:".count))
                            HStack {
                                Label(node.name, systemImage: node.isFolder ? "folder" : "music.note.list")
                                    .lineLimit(1).help(node.name)
                                Spacer(minLength: 8)
                                ITunesSyncCheckbox(name: node.name, id: id, state: model.selection.state(of: id, in: model.nodes)) {
                                    model.selection.setSelected(model.selection.state(of: id, in: model.nodes) != .on,
                                                                id: id, in: model.nodes)
                                }
                                .frame(width: 18, height: 18)
                            }
                        }
                    }
                    .overlay {
                        if model.isLoading { ProgressView() }
                        else if model.tree.isEmpty { Text(.ui("읽을 수 있는 iTunes 목록이 없습니다")).foregroundStyle(.secondary) }
                    }
                }
                Image(systemName: "arrow.right").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(.ui("DJCrate 동기화 목록")).font(.headline)
                        Spacer()
                        Text(.ui("목록 \(model.preview.playlistCount)개")).foregroundStyle(.secondary)
                    }.frame(height: 24)
                    List {
                        OutlineGroup(model.preview.tree, children: \.children) { node in
                            Label(node.name, systemImage: node.isFolder ? "folder" : "music.note.list")
                                .lineLimit(1).help(node.name)
                        }
                    }
                    .overlay {
                        if model.preview.tree.isEmpty {
                            Text(.ui("동기화할 목록을 선택하세요")).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .disabled(model.isLoading || model.source.status != .ready)
            if let message = model.error ?? model.source.status.message {
                Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(.ui("선택한 목록은 DJCrate에 저장됩니다. 목록의 곡 구성은 Music에서 편집하세요."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(.ui("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(.ui("동기화")) {
                    if model.sync(store: store) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSync || store.isLoading || store.isWritingRekordbox)
                .accessibilityIdentifier("itunes-sync-apply")
            }
        }
        .padding(24)
        .frame(width: 860, height: 560)
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
