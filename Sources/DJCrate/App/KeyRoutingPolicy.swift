/// 창·포커스 상태만으로 덱 단축키를 받아도 되는지 정한다.
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

    static func accepts(_ keyCode: UInt16, in context: Context) -> Bool {
        guard context.isMainWindow, !context.hasModalWindow, !context.hasAttachedSheet,
              !context.hasShortcutModifiers else { return false }
        switch context.focus {
        case .deck:
            return true
        case .trackList:
            // 곡 목록에서는 기존 덱 키를 유지하고 나머지는 표에 맡긴다.
            return keyCode == 49 || KeyRouter.hotCueSlot(for: keyCode) != nil
                || !KeyRouter.shortcutName(for: keyCode).isEmpty
                || [123, 124, 51, 117].contains(keyCode)
        case .sheet:
            return keyCode == 49
        case .textInput, .control, .table:
            return false
        }
    }
}
