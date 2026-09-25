import AppKit
import SwiftUI

@main
struct AnicueApp: App {
    @State private var store = LibraryStore()
    @State private var deck = DeckModel()

    init() {
        // SwiftPM 실행 파일은 번들이 없어서 Dock·메뉴 막대에 올리려면 직접 지정해야 한다.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        // 단일 창: ⌘N 새 창이 같은 상태를 공유하며 라이브러리를 다시 읽는 문제를 막는다.
        Window("anicue", id: "main") {
            ContentView(store: store, deck: deck)
                .frame(minWidth: 1100, minHeight: 700)
                .task {
                    NSApplication.shared.activate()
                    await store.loadInitial()
                }
        }
        .defaultSize(width: 1440, height: 900)
        // 이전 창 상태 복원이 가끔 500×500 흰 창을 만든다. 항상 새 창으로 시작한다.
        .restorationBehavior(.disabled)
    }
}
