import AppKit
import DJCDomain
import DJCStorage
import SwiftUI

/// 곡 편집 창 하나를 띄우고 닫는다. 따로 된 창이라 편집하는 동안에도 덱에서 곡을 들으며 위치를 고를 수 있다.
///
/// 메뉴(덱 › 곡 편집…)와 덱의 편집 버튼이 부른다. 렌더해 넣으면 창을 닫고 추가한 곡에서 그 곡을 고른다.
@MainActor
final class TrackEditWindow: NSObject, NSWindowDelegate {
    static let shared = TrackEditWindow()

    private(set) weak var deck: DeckModel?
    private(set) weak var store: LibraryStore?
    private var window: NSWindow?
    private var host: NSHostingController<TrackEditView>?
    private(set) var model: TrackEditModel?

    func attach(deck: DeckModel, store: LibraryStore) {
        self.deck = deck
        self.store = store
        #if DEBUG
        runLayoutCaptureIfRequested()
        #endif
    }

    /// 덱에 올린 곡으로 연다. 같은 곡을 다시 열면 고른 구간을 이어 쓴다(그리드·큐는 덱에서 새로 읽는다).
    func open(entries: [BarRange]? = nil) {
        guard let deck, TrackEditModel.canOpen(deck) else { return }
        let kept = model?.row.id == deck.row?.id ? model?.entries.map(\.range) ?? [] : []
        model?.close()
        guard let model = TrackEditModel(deck: deck, entries: entries ?? kept, edits: DJCPaths.editOutput) else { return }
        model.onStaged = { [weak self] staged in self?.finish(staged) }
        self.model = model
        let root = TrackEditView(model: model, deck: deck)
        if let host {
            host.rootView = root
        } else {
            let host = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 980, height: 700))
            window.contentMinSize = NSSize(width: 760, height: 560)
            window.center()
            window.setFrameAutosaveName("TrackEditWindow")
            self.host = host
            self.window = window
        }
        window?.title = "곡 편집 — \(model.row.title)"
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish(_ staged: StagedTrack) {
        store?.showStagedEdit(staged)
        window?.close()
        model = nil
    }

    func windowWillClose(_ notification: Notification) {
        model?.close()
    }
}

/// 덱의 편집 버튼
struct TrackEditButton: View {
    let deck: DeckModel

    var body: some View {
        Button {
            TrackEditWindow.shared.open()
        } label: {
            Label("편집…", systemImage: "scissors")
        }
        .disabled(!TrackEditModel.canOpen(deck))
        .help("마디 단위로 잘라 이은 편집본(인트로 늘이기·짧은 버전)을 만듭니다. 원곡은 그대로 두고 새 곡으로 추가한 곡에 넣습니다")
    }
}

extension LibraryStore {
    /// 렌더해 넣은 편집본을 추가한 곡 목록에서 고른다(덱에 올라간다). 초안은 편집 창이 파일로 써 두었다.
    func showStagedEdit(_ track: StagedTrack) {
        loadStaged()
        refreshExternalDrafts()
        draftChanged(trackUUID: track.uuid, kind: .grid, exists: true)
        search = ""
        sidebar = .staged
        selection = [track.id]
        stagingMessage = AppMessage(kind: .success, text: "편집본 ‘\(track.title)’을 추가한 곡에 넣었습니다. rekordbox에 바로 넣기나 XML로 넘기세요")
    }
}
