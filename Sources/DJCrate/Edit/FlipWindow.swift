import AppKit
import DJCDomain
import DJCStorage
import SwiftUI

/// Flip: 덱의 Flip 단추로 기록을 시작·마치고, 마치면 결과 창 하나를 띄운다. 창 안에 자체 재생기가 있어 덱과 따로 듣는다.
///
/// 렌더해 넣으면 창을 닫고 추가한 곡에서 그 곡을 고른다(곡 편집 창과 같다). 창을 닫으면 그 기록은 버린다.
/// 단축키(스페이스바 재생, Home·End)는 이 창이 앞에 있을 때만 받는다. 덱 단축키는 `KeyRouter`가 이 창을 빼고 받는다.
@MainActor
final class FlipWindow: NSObject, NSWindowDelegate {
    static let shared = FlipWindow()

    private(set) weak var deck: DeckModel?
    private(set) weak var store: LibraryStore?
    private(set) var window: NSWindow?
    private var host: NSHostingController<FlipView>?
    private(set) var model: FlipModel?
    private var monitors: [Any] = []

    func attach(deck: DeckModel, store: LibraryStore) {
        self.deck = deck
        self.store = store
    }

    /// 덱의 Flip 단추·메뉴: 기록 중이 아니면 기록을 시작하고, 기록 중이면 마치고 결과 창을 연다.
    func toggleRecording() {
        guard let deck else { return }
        if deck.isFlipRecording {
            guard let recording = deck.finishFlipRecording() else { return }
            open(recording)
        } else {
            if let reason = deck.flipUnavailableReason {
                deck.showToast(reason)
                return
            }
            if model?.renderProgress != nil {
                deck.showToast(String(ui: "Flip 렌더가 끝나거나 취소한 뒤 다시 기록하세요"))
                return
            }
            // 지난 결과 창은 새 기록과 섞이지 않게 닫는다(그 결과는 버린다).
            window?.close()
            deck.startFlipRecording()
        }
    }

    /// 마친 기록으로 결과 창을 연다. 점프가 없으면 열지 않고 덱에 알린다.
    func open(_ recording: FlipRecording) {
        guard let deck else { return }
        guard !recording.isEmpty else {
            deck.showToast(String(ui: "기록에 점프·루프가 없어 Flip을 만들지 않았습니다. Flip을 누르고 재생하며 핫큐·루프를 쓴 뒤 다시 누르세요"))
            return
        }
        model?.close()
        let model: FlipModel
        do {
            model = try FlipModel(deck: deck, recording: recording, edits: DJCPaths.editOutput)
        } catch {
            self.model = nil
            window?.close()
            deck.showToast(TrackEditModel.reason(error))
            return
        }
        model.onStaged = { [weak self] staged in self?.finish(staged) }
        self.model = model
        let root = FlipView(model: model, deck: deck,
                            onRerecord: { [weak self] in self?.rerecord() },
                            onDiscard: { [weak self] in self?.window?.close() })
        if let host {
            host.rootView = root
        } else {
            let host = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 900, height: 520))
            window.contentMinSize = NSSize(width: 680, height: 460)
            window.center()
            window.setFrameAutosaveName("FlipWindow")
            self.host = host
            self.window = window
        }
        window?.title = String(ui: "Flip — \(model.row.title)")
        installMonitors()
        window?.makeKeyAndOrderFront(nil)
        // SwiftUI가 첫 글자 칸(제목)에 포커스를 주면 스페이스바가 글자로 들어간다. 창 본문에서 시작한다.
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
    }

    /// 이 결과를 버리고 덱에서 다시 기록한다.
    private func rerecord() {
        window?.close()
        deck?.startFlipRecording()
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }) { monitors.append(keys) }
    }

    /// 이 창에 온 키: 스페이스바 재생·일시정지, Home·End. 글자를 입력하는 중(제목 칸)이나 시트·모달이 떠 있으면 넘긴다.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window.firstResponder is NSText), let model,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 49: model.togglePlay()
        case 115: model.seek(to: 0)
        case 119: model.seek(to: model.duration)
        default: return false
        }
        return true
    }

    private func finish(_ staged: StagedTrack) {
        let hasGrid = !(model?.grid.isEmpty ?? true)
        store?.showStagedEdit(staged, hasGrid: hasGrid)
        window?.close()
        model = nil
    }

    func windowWillClose(_ notification: Notification) {
        model?.close()
        model = nil
    }
}
