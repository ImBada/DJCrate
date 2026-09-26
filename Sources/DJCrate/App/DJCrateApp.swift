import AppKit
import DJCStorage
import SwiftUI

@main
struct DJCrateApp: App {
    /// 옛 이름(anicue) 데이터·설정 옮기기. 목록·덱이 설정을 읽기 전에 돌아야 해서 첫 속성으로 둔다.
    private let migrated = LegacyMigration.run()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = LibraryStore()
    @State private var deck = DeckModel()

    init() {
        // SwiftPM 실행 파일은 번들이 없어서 Dock·메뉴 막대에 올리려면 직접 지정해야 한다.
        NSApplication.shared.setActivationPolicy(.regular)
        #if DEBUG
        // 창이 만들어지기 전에 정해야 SwiftUI와 AppKit 목록이 같은 모양새로 시작한다.
        if ProcessInfo.processInfo.arguments.contains("--perf-appearance=light") { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
        if ProcessInfo.processInfo.arguments.contains("--perf-appearance=dark") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        #endif
    }

    var body: some Scene {
        // 단일 창: ⌘N 새 창이 같은 상태를 공유하며 라이브러리를 다시 읽는 문제를 막는다.
        Window("DJCrate", id: "main") {
            ContentView(store: store, deck: deck)
                .frame(minWidth: 1100, minHeight: 700)
                .task {
                    appDelegate.store = store
                    NSApplication.shared.activate()
                    await store.loadInitial()
                }
        }
        .commands {
            AppCommands()
            // 번들 없이 도는 개발 빌드에서도 한국어 "설정…"(⌘,)이 되게 직접 둔다.
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text("설정…") }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .pasteboard) {
                // 표준 편집 명령처럼 현재 응답자가 활성 상태와 실행을 결정한다.
                Button("아래로 채우기") {
                    NSApp.sendAction(#selector(SheetTableView.fillDown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!store.canFillDownTags || store.isWritingRekordbox)
            }
        }
        .defaultSize(width: 1440, height: 900)
        // 이전 창 상태 복원이 가끔 500×500 흰 창을 만든다. 항상 새 창으로 시작한다.
        .restorationBehavior(.disabled)

        Window("단축키", id: "shortcuts") {
            ScrollView {
                ShortcutsList(shortcuts: deck.shortcuts).padding(20)
            }
            .frame(minWidth: 620, minHeight: 420)
            .background(ShortcutsWindow.Tracker())
        }
        .defaultSize(width: 720, height: 660)
        .restorationBehavior(.disabled)

        // 기본 설정·덱 단축키(⌘,). 덱과 같은 모델에 묶여 바꾸면 바로 반영·저장된다.
        Settings {
            SettingsView(store: store, deck: deck)
        }
    }
}
