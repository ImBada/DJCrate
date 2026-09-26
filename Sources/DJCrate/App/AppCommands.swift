import DJCDomain
import SwiftUI

struct AppCommandContext {
    var store: LibraryStore
    var deck: DeckModel
    var showTagEditor: Binding<Bool>
    var waveformHeight: WaveformHeightControl?
}

private struct AppCommandContextKey: FocusedValueKey {
    typealias Value = AppCommandContext
}

extension FocusedValues {
    var appCommands: AppCommandContext? {
        get { self[AppCommandContextKey.self] }
        set { self[AppCommandContextKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.appCommands) private var context
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingKeys.sheetMode.name) private var sheetMode = SettingKeys.sheetMode.defaultValue

    var body: some Commands {
        SidebarCommands()
        InspectorCommands()
        ToolbarCommands()
        CommandGroup(replacing: .newItem) {
            ForEach(LibraryMenuAction.fileActions, id: \.self) { libraryButton($0) }
        }
        CommandGroup(before: .sidebar) {
            Toggle("목록", isOn: Binding(get: { !sheetMode }, set: { if $0 { sheetMode = false } }))
                .keyboardShortcut("1", modifiers: .command)
                .disabled(context?.store.writeLockPolicy.allowsLibraryInteraction != true)
            Toggle("태그 시트", isOn: Binding(get: { sheetMode }, set: { if $0 { sheetMode = true } }))
                .keyboardShortcut("2", modifiers: .command)
                .disabled(context?.store.writeLockPolicy.allowsLibraryInteraction != true)
            Divider()
            Toggle("태그 편집", isOn: context?.showTagEditor ?? .constant(false))
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!canEditTags)
            Divider()
            // 덱·목록 사이 핸들을 끌지 않고 키보드·VoiceOver로 파형 높이를 바꾼다.
            Button("파형 크게") { context?.waveformHeight?.grow() }
                .disabled(context?.waveformHeight?.canGrow != true)
            Button("파형 작게") { context?.waveformHeight?.shrink() }
                .disabled(context?.waveformHeight?.canShrink != true)
        }
        CommandMenu("rekordbox") {
            ForEach(LibraryMenuAction.rekordboxActions, id: \.self) { libraryButton($0) }
        }
        CommandMenu("덱") {
            ForEach(DeckAction.Group.allCases, id: \.self) { group in
                if group != .transport { Divider() }
                if group == .hotCues {
                    Menu(group.title) {
                        ForEach(DeckMenuCommand.actions(in: group), id: \.self) { action in
                            Menu(action.title) {
                                deckButton(.action(action))
                                if let slot = action.hotCueSlot {
                                    deckButton(.moveHotCue(slot))
                                    deckButton(.deleteHotCue(slot))
                                }
                            }
                        }
                    }
                } else {
                    ForEach(DeckMenuCommand.actions(in: group), id: \.self) { action in
                        deckButton(.action(action))
                        ForEach(DeckMenuCommand.variants(after: action), id: \.self) { deckButton($0) }
                    }
                }
            }
        }
        CommandGroup(replacing: .help) {
            Button("DJCrate 단축키") { openWindow(id: "shortcuts") }
                .keyboardShortcut("?", modifiers: .command)
        }
    }

    private var canEditTags: Bool {
        guard let store = context?.store, case .loaded = store.phase else { return false }
        return store.writeLockPolicy.allowsLibraryInteraction
    }

    private func libraryButton(_ action: LibraryMenuAction) -> some View {
        Button(action.title) {
            if let store = context?.store { action.perform(in: store) }
        }
        .keyboardShortcut(action.shortcut)
        .disabled(context.map { !action.isEnabled(in: $0.store) } ?? true)
    }

    private func deckButton(_ command: DeckMenuCommand) -> some View {
        let keys = command.keyLabel(shortcuts: context?.deck.shortcuts ?? .standard)
        return Button(keys.isEmpty ? command.title : "\(command.title)    \(keys)") {
            if let deck = context?.deck { command.perform(on: deck) }
        }
        // keyboardShortcut를 달면 글자 입력 중에도 메뉴가 덱 키를 가로챈다.
        .disabled(context.map { !command.isEnabled(on: $0.deck) } ?? true)
    }
}
