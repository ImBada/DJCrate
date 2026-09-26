import DJCDomain

/// 창·포커스 상태만으로 덱 단축키를 받아도 되는지 정한다. 덱 키가 무엇인지는 단축키 표(설정)를 따른다.
enum KeyRoutingPolicy {
    enum Focus {
        case deck, trackList, table, sheet, textInput, control
    }

    struct Context {
        var isMainWindow = true
        var hasModalWindow = false
        var hasAttachedSheet = false
        var hasShortcutModifiers = false
        var focus: Focus = .deck
    }

    static func accepts(_ keyCode: UInt16, in context: Context, shortcuts: DeckShortcuts = .standard) -> Bool {
        guard context.isMainWindow, !context.hasModalWindow, !context.hasAttachedSheet,
              !context.hasShortcutModifiers else { return false }
        switch context.focus {
        case .deck:
            return true
        case .trackList:
            // 곡 목록에서는 덱 키를 받고 나머지는 표에 맡긴다. ←→⌫⌦는 목록에서 할 일이 없어 경고음이 나지 않게 받는다.
            return shortcuts.action(for: keyCode) != nil || [123, 124, 51, 117].contains(keyCode)
        case .sheet:
            return keyCode == 49
        case .textInput, .control, .table:
            return false
        }
    }
}
