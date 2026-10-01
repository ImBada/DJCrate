#if DEBUG
import AppKit
import SwiftUI

extension DevSelfTests {
    /// 앱을 활성화하거나 입력을 보내지 않고 이 PID의 합성 화면만 캡처한다.
    static func runBlockedReasonsCaptureIfRequested(store: LibraryStore, deck: DeckModel) {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--blocked-reasons-capture=") }),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil,
              ProcessInfo.processInfo.environment["DJC_REKORDBOX_DIR"] != nil else { return }
        let directory = String(argument.dropFirst("--blocked-reasons-capture=".count))
        Task {
            for _ in 0..<200 {
                if case .loaded = store.phase { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard store.rows.count == 3, store.rows.allSatisfy({ $0.title.hasPrefix("합성 곡 ·") }),
                  !NSApp.isActive,
                  let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else { exit(2) }
            FileHandle.standardError.write(Data("[막힘 안내 화면] 앱 비활성 상태 확인\n".utf8))
            window.setContentSize(NSSize(width: 1440, height: 1000))
            var failures = 0
            func capture(_ window: NSWindow, _ name: String) {
                let process = Process()
                process.executableURL = URL(filePath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l", String(window.windowNumber), "\(directory)/\(name).png"]
                do { try process.run(); process.waitUntilExit() } catch { failures += 1; return }
                if process.terminationStatus != 0 { failures += 1 }
            }
            for id in ["1", "2"] {
                guard let row = store.rows.first(where: { $0.track.id == id }) else { exit(2) }
                store.selection = [row.id]
                store.loadToDeck(row)
                for _ in 0..<200 where deck.draft?.trackUUID != row.track.uuid {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? await Task.sleep(for: .seconds(2))
                capture(window, id == "1" ? "grid-missing" : "grid-unreadable")
            }
            guard let row = store.rows.first(where: { $0.track.id == "3" }) else { exit(2) }
            store.selection = [row.id]
            let host = NSHostingController(rootView: TagInspector(store: store))
            let tags = NSWindow(contentViewController: host)
            tags.styleMask = [.titled, .closable]
            tags.title = "DJCrate"
            tags.setContentSize(NSSize(width: 560, height: 820))
            tags.orderBack(nil)
            try? await Task.sleep(for: .seconds(2))
            capture(tags, "tags-streaming")
            FileHandle.standardError.write(Data("[막힘 안내 화면] \(failures == 0 ? "통과" : "실패") · 캡처 실패 \(failures)건\n".utf8))
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
