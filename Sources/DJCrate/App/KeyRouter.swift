import AppKit

/// 창 전체 단축키와 검색창 포커스 정리.
///
/// SwiftUI `onKeyPress`는 그 뷰에 포커스가 있어야 동작해서, 파형(제스처가 클릭을 먹는다)이나 목록을
/// 누른 뒤에는 스페이스·CUE가 먹히지 않았다. 덱·곡 목록에서만 덱 단축키를 받고,
/// 다른 창이나 글자 입력·컨트롤 포커스에는 끼어들지 않는다.
/// 검색창은 Esc·Return, 또는 글자 칸이 아닌 곳을 클릭하면 빠져나온다.
@MainActor
@Observable
final class KeyRouter {
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private weak var deck: DeckModel?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var cueKeyIsDown = false

    func install(deck: DeckModel) {
        self.deck = deck
        guard monitors.isEmpty else { return }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp], handler: { [weak self] event in
            // `self?.route(event) ?? event`로 쓰면 처리했다는 nil까지 원래 이벤트로 바뀌어 새어 나간다.
            guard let self else { return event }
            return self.route(event)
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            self?.releaseFocusIfNeeded(event)
            return event
        }) { monitors.append(monitor) }
        // CUE를 누른 채 다른 앱으로 넘어가면 keyUp이 오지 않는다. 미리 듣기를 끝낸다.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deck?.cueUp()
                self?.cueKeyIsDown = false
            }
        }
    }

    // MARK: - 키

    /// nil을 돌려주면 이벤트를 삼킨다(다른 곳으로 가지 않는다).
    private func route(_ event: NSEvent) -> NSEvent? {
        guard let deck else { return event }
        // C를 누른 뒤 포커스가 바뀌어도 이미 시작한 미리 듣기는 끝내되, 키는 새 대상에 넘긴다.
        if event.type == .keyUp, Self.shortcutName(for: event.keyCode) == "c", cueKeyIsDown {
            deck.cueUp()
            cueKeyIsDown = false
        }
        guard let window = event.window else { return event }
        let responder = window.firstResponder
        let focus = Self.focus(in: window)
        let context = KeyRoutingPolicy.Context(
            isMainWindow: window === NSApp.mainWindow,
            hasModalWindow: NSApp.modalWindow != nil,
            hasAttachedSheet: window.attachedSheet != nil,
            hasShortcutModifiers: !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            focus: focus)
        guard context.isMainWindow, !context.hasModalWindow, !context.hasAttachedSheet else { return event }
        if let editor = responder as? NSTextView {
            return routeWhileTyping(event, editor: editor, window: window)
        }
        if focus == .control || focus == .table || focus == .textInput { return event }
        // 덱·목록의 쓰기 잠금은 유지한다. 모달·입력 컨트롤에는 위에서 먼저 키를 넘긴다.
        if deck.isWriteLocked { return nil }
        guard KeyRoutingPolicy.accepts(event.keyCode, in: context) else { return event }
        // 글자가 아니라 키 위치로 본다. 한글 입력기가 켜져 있으면 C 키가 "ㅊ"으로 들어와 글자로는 못 알아본다.
        let key = Self.shortcutName(for: event.keyCode)
        let deckFocused = focus == .deck

        if event.type == .keyUp {
            if key == "c" { return nil }
            return event
        }
        if deck.row != nil, event.keyCode == Self.space {
            if !event.isARepeat { deck.togglePlay() }
            return nil
        }
        if focus == .sheet { return event }
        if deck.row != nil, handleDeckKey(event, key: key, deckFocused: deckFocused) { return nil }

        if deckFocused {
            switch event.specialKey {
            case .upArrow?, .downArrow?, .pageUp?, .pageDown?, .home?, .end?:
                // 파형을 누른 뒤에도 ↑↓로 곡을 고를 수 있게 목록으로 넘긴다.
                if let list = focusList(in: window) {
                    list.keyDown(with: event)
                    return nil
                }
            case .tab?, .backTab?:
                return event  // 키보드로 컨트롤 사이를 옮겨 다니는 키
            default:
                break
            }
            // 덱을 보고 있을 때 처리하지 않은 키는 받을 곳이 없어 경고음(뚱)이 난다. 삼킨다.
            return nil
        }
        if !(responder is NSOutlineView) {
            // 곡 목록에서 ←→·Delete는 할 일이 없고, 넘기면 경고음이 난다(사이드바는 ←→로 폴더를 접는다).
            switch event.specialKey {
            case .leftArrow?, .rightArrow?, .delete?, .deleteForward?, .backspace?: return nil
            default: break
            }
        }
        return event
    }

    /// 글자 입력 중에는 단축키를 쓰지 않는다. 대신 입력을 끝내는 키(Return·Esc)에서 포커스를 놓아 준다.
    /// 놓지 않으면 BPM·큐 이름 칸에 Return을 친 뒤에도 스페이스·C가 계속 칸으로 들어가 재생이 안 된다.
    private func routeWhileTyping(_ event: NSEvent, editor: NSTextView, window: NSWindow) -> NSEvent? {
        // 한글 조합 중에는 입력기에 맡긴다.
        guard event.type == .keyDown, !editor.hasMarkedText() else { return event }
        let isReturn = event.keyCode == Self.returnKey || event.keyCode == Self.enter
        let isEscape = event.keyCode == Self.escape
        guard isReturn || isEscape else { return event }
        if editor.delegate is NSSearchField {
            // Esc의 검색어 지우기·Return의 확정을 먼저 처리한 뒤 목록으로 옮긴다.
            Task { @MainActor [weak self] in
                if window.firstResponder === editor { self?.focusList(in: window) }
            }
            return event
        }
        // 태그 시트 셀은 Return으로 확정하고 아래 칸으로 가는 규칙이 따로 있다.
        guard let field = editor.delegate as? NSTextField, !Self.isInSheet(field) else { return event }
        // 확정·취소는 칸에 먼저 보내고 포커스를 놓는다.
        Task { @MainActor in
            if window.firstResponder === editor { window.makeFirstResponder(nil) }
        }
        return event
    }

    private static func isInSheet(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate is SheetTableView { return true }
            current = candidate.superview
        }
        return false
    }

    /// 덱 단축키. 처리했으면 true.
    private func handleDeckKey(_ event: NSEvent, key: String, deckFocused: Bool) -> Bool {
        guard let deck else { return false }
        // 1~8(윗줄·숫자 패드) = 핫큐 A~H. 버튼을 누른 것과 같다(있으면 이동, 없으면 플레이헤드에 찍기).
        if let slot = Self.hotCueSlot(for: event.keyCode) {
            // Shift + 1~8 = 그 핫큐 지우기
            if !event.isARepeat {
                if event.modifierFlags.contains(.shift) { deck.deleteHotCue(slot: slot) } else { deck.pressHotCue(slot: slot) }
            }
            return true
        }
        switch event.specialKey {
        case .leftArrow?: return deckFocused && deck.nudgeSelectedCue(beats: -1)
        case .rightArrow?: return deckFocused && deck.nudgeSelectedCue(beats: 1)
        case .delete?, .deleteForward?, .backspace?: return deckFocused && deck.deleteSelectedCue()
        case .some: return false
        case nil: break
        }
        switch key {
        case "c":
            if !event.isARepeat { deck.cueDown(); cueKeyIsDown = true }
        case "q": if !event.isARepeat { deck.jumpToCue(forward: false) }
        case "e": if !event.isARepeat { deck.jumpToCue(forward: true) }
        case "m":
            // Shift + M(`) = 이 자리 메모리 큐 지우기
            if !event.isARepeat {
                if event.modifierFlags.contains(.shift) { deck.deleteMemoryCue(at: deck.currentTime) } else { deck.addMemoryCueAtPlayhead() }
            }
        case "t": if !event.isARepeat { deck.tapTempo() }
        case "l": if !event.isARepeat { deck.toggleLoop() }
        case "[": deck.resizeLoop(-1)
        case "]": deck.resizeLoop(1)
        case "+", "=": deck.zoom(by: 0.8)
        case "-": deck.zoom(by: 1.25)
        default: return false
        }
        return true
    }

    // MARK: - 목록 포커스

    static let trackListID = NSUserInterfaceItemIdentifier("djc.trackList")
    private weak var list: NSTableView?

    static func focus(in window: NSWindow) -> KeyRoutingPolicy.Focus {
        let responder = window.firstResponder
        if responder is NSTextView || responder is NSTextField { return .textInput }
        if responder is SheetTableView { return .sheet }
        if let table = responder as? NSTableView {
            return table.identifier == trackListID ? .trackList : .table
        }
        // 파형 클릭은 창으로 포커스를 돌린다. SwiftUI의 내부 컨트롤도 기본적으로 보호한다.
        return responder === window ? .deck : .control
    }

    /// 곡 목록(태그 시트 모드면 시트)에 포커스를 준다. 없으면 창 자신에게.
    @discardableResult
    private func focusList(in window: NSWindow) -> NSTableView? {
        let table = (list?.window === window ? list : nil) ?? findList(in: window.contentView)
        list = table
        window.makeFirstResponder(table)
        return table
    }

    private func findList(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView, table is SheetTableView || table.identifier == Self.trackListID {
            return table
        }
        for subview in view.subviews {
            if let found = findList(in: subview) { return found }
        }
        return nil
    }

    // MARK: - 클릭

    /// 글자 칸·표가 아닌 곳(파형·덱 버튼·빈 곳)을 누르면 포커스를 창으로 돌려 단축키가 덱으로 가게 한다.
    /// 검색창에 포커스가 박혀 스페이스가 검색어로 들어가던 문제를 여기서 푼다.
    private func releaseFocusIfNeeded(_ event: NSEvent) {
        guard NSApp.modalWindow == nil, let window = event.window, window === NSApp.mainWindow,
              window.attachedSheet == nil,
              let root = window.contentView?.superview,
              let hit = root.hitTest(event.locationInWindow) else { return }
        var view: NSView? = hit
        while let current = view {
            if current is NSTextView || current is NSControl {
                return
            }
            view = current.superview
        }
        if window.firstResponder !== window { window.makeFirstResponder(nil) }
    }

    /// 키 위치(ANSI 배열 키 코드) → 단축키 이름. 입력기·배열과 무관하게 같은 자리의 키가 같은 기능이다.
    nonisolated static func shortcutName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 8: "c"
        case 46, 50: "m"   // M, `(1 왼쪽 키 — 한글 자판에선 ₩)
        case 17: "t"
        case 37: "l"
        case 33: "["
        case 30: "]"
        case 12: "q"
        case 14: "e"
        case 24: "="
        case 27: "-"
        case 69: "+"   // 숫자 패드 +
        case 78: "-"   // 숫자 패드 −
        default: ""
        }
    }

    /// 숫자 키 위치 → 핫큐 칸(0 = A). 윗줄 1~8과 숫자 패드 1~8.
    nonisolated static func hotCueSlot(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18, 83: 0
        case 19, 84: 1
        case 20, 85: 2
        case 21, 86: 3
        case 23, 87: 4
        case 22, 88: 5
        case 26, 89: 6
        case 28, 91: 7
        default: nil
        }
    }

    private static let space: UInt16 = 49
    private static let escape: UInt16 = 53
    private static let returnKey: UInt16 = 36
    private static let enter: UInt16 = 76
}
