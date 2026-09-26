import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: LibraryStore?
    var inform: (String) -> Void = { message in
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store?.writeLockPolicy.allowsTermination == false else { return .terminateNow }
        inform(WriteLockPolicy.terminationMessage)
        return .terminateCancel
    }
}
