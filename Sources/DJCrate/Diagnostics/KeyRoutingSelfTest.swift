#if DEBUG
import AppKit
import DJCDomain
import DJCStorage
import Foundation

extension DevSelfTests {
    /// 앱 큐에만 키를 넣는다. 앱 활성화·CGEvent 전송·화면 좌표 입력은 사용하지 않는다.
    static func runKeyRoutingSelfTestIfRequested(store: LibraryStore, deck: DeckModel) {
        guard ProcessInfo.processInfo.arguments.contains("--key-routing-selftest"),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil,
              ProcessInfo.processInfo.environment["DJC_REKORDBOX_DIR"] != nil else { return }
        Task {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            var checks = 0, failures = 0
            @MainActor func check(_ condition: Bool, _ name: String) {
                checks += 1
                if !condition { failures += 1 }
                FileHandle.standardError.write(Data("[키 전달] \(name): \(condition ? "통과" : "실패")\n".utf8))
            }
            @MainActor func waitUntil(_ condition: () -> Bool) async {
                for _ in 0..<100 {
                    if condition() { return }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            @MainActor func send(_ window: NSWindow, code: UInt16, text: String) async {
                for type: NSEvent.EventType in [.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: text, charactersIgnoringModifiers: text,
                                                    isARepeat: false, keyCode: code) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            @MainActor func find<T: NSView>(_ type: T.Type, in root: NSView?) -> T? {
                guard let root else { return nil }
                if let found = root as? T { return found }
                for child in root.subviews {
                    if let found = find(type, in: child) { return found }
                }
                return nil
            }
            await waitUntil { if case .loaded = store.phase { true } else { false } }
            guard store.rows.count == 2, store.rows.allSatisfy({ $0.title.hasPrefix("합성 곡 ·") }),
                  !NSApp.isActive, let row = store.rowsByID["1"],
                  let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else { exit(2) }
            deck.shortcuts = .standard
            store.settings.set(SettingKeys.sheetMode, false)
            store.loadToDeck(row)
            await deck.loadTask?.value
            deck.gridDraft = GridDraft(trackUUID: row.track.uuid, base: [], segments: [.init(start: 0, bpm: 120, firstBeatNumber: 1)])
            deck.refreshGrid()
            window.makeMain()
            window.makeKey()
            FileHandle.standardError.write(Data("[키 전달] 내부 상태: key=\(window.isKeyWindow), main=\(NSApp.mainWindow === window), active=\(NSApp.isActive)\n".utf8))
            check(!NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "외부 앱 포커스 보존(시작)")
            check(window.isKeyWindow && NSApp.mainWindow === window && !NSApp.isActive, "앱 비활성 상태의 내부 키 창")
            guard failures == 0 else {
                FileHandle.standardError.write(Data("[키 전달] 미검증: 내부 키 창을 만들지 못해 키 이벤트를 보내지 않음 · 종료 코드 2\n".utf8))
                exit(2)
            }

            // 덱 포커스와 실제 곡 목록의 단축키가 같은 덱에 도착한다.
            deck.zoomSeconds = 10
            window.makeFirstResponder(nil)
            let zoom = deck.zoomSeconds
            await send(window, code: 24, text: "=")
            check(deck.zoomSeconds < zoom, "덱 확대 키")
            await waitUntil { find(TrackListTableView.self, in: window.contentView) != nil }
            if let table = find(TrackListTableView.self, in: window.contentView) {
                window.makeFirstResponder(table)
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                await send(window, code: 125, text: "\u{f701}")
                check(table.selectedRow == 1, "곡 목록 탐색 키")
                let before = deck.zoomSeconds
                await send(window, code: 24, text: "=")
                check(deck.zoomSeconds < before, "곡 목록의 덱 확대 키")
            } else { check(false, "실제 곡 목록 찾기") }

            // 실제 검색칸의 필드 에디터가 글자 키를 받으며 덱은 그대로다.
            let search = window.toolbar?.items.compactMap { ($0 as? NSSearchToolbarItem)?.searchField }.first
                ?? find(NSSearchField.self, in: window.contentView?.superview)
            if let search {
                store.search = ""
                search.stringValue = ""
                window.makeFirstResponder(search)
                let before = deck.memoryCueCount
                await send(window, code: 46, text: "m")
                check(search.currentEditor()?.string == "m" && deck.memoryCueCount == before, "글자 입력은 덱 키를 가로채지 않음")
                window.makeFirstResponder(nil)
                store.search = ""
            } else { check(false, "실제 검색칸 찾기") }

            // 태그 시트의 방향키는 셀로 전달한다.
            store.settings.set(SettingKeys.sheetMode, true)
            await waitUntil { find(SheetTableView.self, in: window.contentView) != nil }
            if let sheet = find(SheetTableView.self, in: window.contentView), let coordinator = sheet.coordinator {
                window.makeFirstResponder(sheet)
                coordinator.select(.init(row: 0, column: 1), extend: false)
                let before = deck.playhead
                await send(window, code: 124, text: "\u{f703}")
                check(coordinator.cursor == .init(row: 0, column: 2) && deck.playhead == before, "태그 시트 방향키")
            } else { check(false, "실제 태그 시트 찾기") }

            // AppKit의 실제 부착 시트·모달 세션 안 글자 입력은 덱을 바꾸지 않는다.
            for modal in [false, true] {
                let alert = NSAlert()
                alert.messageText = "합성 키 전달 시험"
                let input = NSTextField(string: "")
                input.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
                alert.accessoryView = input
                alert.addButton(withTitle: "확인")
                alert.layout()
                let before = deck.zoomSeconds
                if modal {
                    let session = NSApp.beginModalSession(for: alert.window)
                    _ = NSApp.runModalSession(session)
                    alert.window.makeFirstResponder(input)
                    await send(alert.window, code: 24, text: "=")
                    check(NSApp.modalWindow === alert.window && input.currentEditor()?.string == "=" && deck.zoomSeconds == before, "모달의 글자 키")
                    NSApp.endModalSession(session)
                    alert.window.orderOut(nil)
                } else {
                    window.beginSheet(alert.window, completionHandler: { _ in })
                    alert.window.makeFirstResponder(input)
                    await send(alert.window, code: 24, text: "=")
                    check(window.attachedSheet === alert.window && input.currentEditor()?.string == "=" && deck.zoomSeconds == before, "부착 시트의 글자 키")
                    window.endSheet(alert.window)
                    alert.window.orderOut(nil)
                }
            }

            // 제품의 곡 편집 창에 온 확대 키는 편집 창만 바꾼다.
            TrackEditWindow.shared.open()
            if let editWindow = TrackEditWindow.shared.window, let model = TrackEditWindow.shared.model {
                editWindow.makeFirstResponder(nil)
                let before = model.sourceView, deckZoom = deck.zoomSeconds
                await send(editWindow, code: 24, text: "=")
                check(model.sourceView != before && deck.zoomSeconds == deckZoom, "곡 편집 창 확대 키")
                editWindow.close()
            } else { check(false, "곡 편집 창 열기") }
            check(!NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "외부 앱 포커스 보존")
            FileHandle.standardError.write(Data("[키 전달] 결과: \(checks - failures)/\(checks) 통과 · 앱 안 이벤트 · 소리 재생 없음\n".utf8))
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
