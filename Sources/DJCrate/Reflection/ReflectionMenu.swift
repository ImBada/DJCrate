import DJCDomain
import SwiftUI

/// 반영 대기가 없어도 마지막 쓰기 결과와 되돌리기를 열 수 있다.
struct ReflectionMenu: View {
    let store: LibraryStore

    var body: some View {
        if store.pendingLibraryCount > 0 {
            menu.buttonStyle(.borderedProminent)
        } else {
            menu.buttonStyle(.bordered)
        }
    }

    private var menu: some View {
        Menu {
            Button(LibraryMenuAction.restore.title) { LibraryMenuAction.restore.perform(in: store) }
                .disabled(!LibraryMenuAction.restore.isEnabled(in: store))
            Button(LibraryMenuAction.writeResult.title) { LibraryMenuAction.writeResult.perform(in: store) }
                .disabled(!LibraryMenuAction.writeResult.isEnabled(in: store))
        } label: {
            Label(.ui("rekordbox에 쓰기"), systemImage: "square.and.arrow.up.on.square")
        } primaryAction: {
            LibraryMenuAction.reflect.perform(in: store)
        }
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(.ui("rekordbox에 쓰기"))
        .disabled(!store.writeLockPolicy.allowsLibraryInteraction)
        // ⇧⌘E는 AppCommands가 맡아 툴바·사이드바를 숨겨도 한 번만 실행한다.
        .help(.ui("초안을 확인한 뒤 rekordbox에 씁니다(⇧⌘E). 대상 \(store.reflectionTargets.count.formatted())곡"))
    }
}
