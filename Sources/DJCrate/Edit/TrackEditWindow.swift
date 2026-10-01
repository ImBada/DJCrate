import AppKit
import DJCDomain
import DJCStorage
import SwiftUI

/// 곡 편집 창 하나를 띄우고 닫는다. 창 안에 자체 재생기가 있어 덱과 따로 듣고 고친다.
///
/// 메뉴(덱 › 곡 편집…)와 덱의 편집 버튼이 부른다. 렌더해 넣으면 창을 닫고 추가한 곡에서 그 곡을 고른다.
/// 단축키(`TrackEditCommand`)는 이 창이 앞에 있을 때만 받는다. 덱 단축키는 `KeyRouter`가 이 창을 빼고 받는다.
/// 실행 취소는 이 창의 `undoManager`(편집 › 실행 취소 ⌘Z)에 쌓는다.
@MainActor
final class TrackEditWindow: NSObject, NSWindowDelegate {
    static let shared = TrackEditWindow()

    private(set) weak var deck: DeckModel?
    private(set) weak var store: LibraryStore?
    /// 자가 테스트도 이 창을 쓴다(제목은 언어마다 달라 제목으로 찾지 않는다).
    private(set) var window: NSWindow?
    private var host: NSHostingController<TrackEditView>?
    private(set) var model: TrackEditModel?
    private var monitors: [Any] = []

    func attach(deck: DeckModel, store: LibraryStore) {
        self.deck = deck
        self.store = store
        #if DEBUG
        runLayoutCaptureIfRequested()
        #endif
    }

    /// 아직 편집을 시작할 수 없던 창만 다시 판정한다. 열린 편집의 출력 구간은 건드리지 않는다.
    func draftRecovered(_ uuid: String) {
        guard model?.row.track.uuid == uuid, model?.blockedReason != nil else { return }
        open()
    }

    /// 덱에 올린 곡으로 연다. 같은 곡을 다시 열면 고른 구간을 이어 쓴다(그리드·큐는 덱에서 새로 읽는다).
    func open(entries: [BarRange]? = nil) {
        guard let deck, TrackEditModel.canOpen(deck) else { return }
        let kept = model?.row.id == deck.row?.id ? model?.entries.map(\.range) ?? [] : []
        model?.close()
        guard let model = TrackEditModel(deck: deck, entries: entries ?? kept, edits: DJCPaths.editOutput) else { return }
        model.onStaged = { [weak self] staged in self?.finish(staged) }
        self.model = model
        let root = TrackEditView(model: model, deck: deck, store: store)
        if let host {
            host.rootView = root
        } else {
            let host = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 980, height: 700))
            window.contentMinSize = NSSize(width: 760, height: 600)
            window.center()
            window.setFrameAutosaveName("TrackEditWindow")
            self.host = host
            self.window = window
        }
        window?.title = String(ui: "곡 편집 — \(model.row.title)")
        model.undoManager = window?.undoManager
        installMonitors()
        window?.makeKeyAndOrderFront(nil)
        // SwiftUI가 첫 글자 칸(제목)에 포커스를 주면 스페이스바가 글자로 들어간다. 창 본문에서 시작한다.
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }) { monitors.append(keys) }
        // 제목·마디 칸에서 파형을 누르면 글자 입력에서 빠져나온다(스페이스바가 다시 재생으로). 덱 창의 `KeyRouter`와 같다.
        if let clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            self?.releaseTextFocus(event)
            return event
        }) { monitors.append(clicks) }
    }

    private func releaseTextFocus(_ event: NSEvent) {
        guard let window, event.window === window, window.firstResponder is NSText,
              let hit = window.contentView?.superview?.hitTest(event.locationInWindow) else { return }
        var view: NSView? = hit
        while let current = view {
            if current is NSTextView || current is NSControl { return }
            view = current.superview
        }
        window.makeFirstResponder(nil)
    }

    /// 이 창에 온 키를 편집 명령으로. 글자를 입력하는 중(제목·마디 칸)이나 시트·모달이 떠 있으면 넘긴다.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window.firstResponder is NSText), let model, model.blockedReason == nil,
              let command = TrackEditCommand(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return false }
        return command.perform(on: model)
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

/// 편집 창 단축키. 키 위치(키 코드)로 정한다(입력기와 상관없이 같은 키).
enum TrackEditCommand: Equatable {
    /// 스페이스: 마지막으로 누른 줄 재생·일시정지
    case togglePlay
    /// ←→(⇧는 4마디): 재생선을 앞뒤 마디 줄로
    case step(Int)
    /// Home·End
    case jump(toEnd: Bool)
    /// ⏎: 원곡에서 고른 구간을 결과에 넣기
    case addSelection
    /// ⌫: 고른 클립 지우기
    case removeClip
    /// ⌘D: 고른 클립 복제
    case duplicateClip
    /// ⌘B: 결과 재생선에서 자르기
    case split
    /// Esc: 고른 클립·구간 놓기
    case clearSelection
    /// = 확대, − 축소(마지막으로 누른 줄). ⌘+/−는 보기 › 글자 크기 메뉴다.
    case zoom(in: Bool)
    /// 0: 줄 전체 보기
    case fit

    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let keys = modifiers.intersection([.command, .control, .option, .shift])
        switch (keyCode, keys) {
        case (49, []): self = .togglePlay
        case (123, []): self = .step(-1)
        case (124, []): self = .step(1)
        case (123, [.shift]): self = .step(-4)
        case (124, [.shift]): self = .step(4)
        case (115, []): self = .jump(toEnd: false)
        case (119, []): self = .jump(toEnd: true)
        case (36, []), (76, []): self = .addSelection
        case (51, []), (117, []): self = .removeClip
        case (2, [.command]): self = .duplicateClip
        case (11, [.command]): self = .split
        case (53, []): self = .clearSelection
        // = 키(⇧를 누르면 +)와 숫자 패드 +, − 키와 숫자 패드 −, 0과 숫자 패드 0
        case (24, []), (24, [.shift]), (69, []), (69, [.shift]): self = .zoom(in: true)
        case (27, []), (78, []): self = .zoom(in: false)
        case (29, []), (82, []): self = .fit
        default: return nil
        }
    }

    /// 할 일이 없으면(고른 것 없음 등) false: 키를 다른 곳(컨트롤·메뉴)에 넘긴다.
    @MainActor
    func perform(on model: TrackEditModel) -> Bool {
        switch self {
        case .togglePlay:
            model.togglePlay()
        case .step(let bars):
            model.step(bars: bars)
        case .jump(let toEnd):
            model.jump(toEnd: toEnd)
        case .addSelection:
            guard model.selection != nil else { return false }
            model.addSelection()
        case .removeClip:
            guard model.selectedClip != nil else { return false }
            model.removeSelected()
        case .duplicateClip:
            guard model.selectedClip != nil else { return false }
            model.duplicateSelected()
        case .split:
            guard model.edit != nil else { return false }
            model.splitAtPlayhead()
        case .clearSelection:
            return model.clearSelection()
        case .zoom(let zoomIn):
            guard model.extent(model.focus) > 0 else { return false }
            model.zoom(model.focus, by: zoomIn ? 2 : 0.5)
        case .fit:
            guard model.extent(model.focus) > 0 else { return false }
            model.fit(model.focus)
        }
        return true
    }
}

/// 확대 파형 오른쪽의 세로 편집 버튼.
struct TrackEditButton: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel

    var body: some View {
        Button {
            TrackEditWindow.shared.open()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "scissors")
                    .font(.scaled(.callout, textScale))
                Text(LocalizedStringResource("deck.editButton", defaultValue: "편집", bundle: UIStrings.bundle))
                    .font(.scaled(.caption2, textScale))
            }
            .foregroundStyle(.white)
            .frame(width: TextScale.length(46, scale: textScale),
                   height: TextScale.length(54, scale: textScale))
            .background(Palette.well.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .disabled(!TrackEditModel.canOpen(deck))
        .help(.ui("마디 단위로 잘라 이은 편집본(인트로 늘이기·짧은 버전)을 만듭니다. 원곡은 그대로 두고 새 곡으로 추가한 곡에 넣습니다"))
    }
}

extension LibraryStore {
    /// 렌더해 넣은 편집본을 추가한 곡 목록에서 고르고 덱에 올린다(덱의 곡을 편집한 결과라 이어서 확인한다).
    /// 초안은 편집 창이 파일로 써 두었다.
    func showStagedEdit(_ track: StagedTrack) {
        loadStaged()
        // 넣기가 손상된 추가 목록을 옮겼으면(옛 목록은 보관만 된다) 알린다. 새로 읽은 목록은 비어 있지 않아 저장 알림 규칙을 쓰지 않는다.
        applyMovedDrafts(DamagedDrafts.take(home: draftHome ?? DJCPaths.userData))
        refreshExternalDrafts()
        draftChanged(trackUUID: track.uuid, kind: .grid, exists: true)
        search = ""
        sidebar = .staged
        selection = [track.id]
        loadToDeck(rowsByID[track.id])
        stagingMessage = AppMessage(kind: .success, text: String(ui: "편집본 ‘\(track.title)’을 추가한 곡에 넣었습니다. rekordbox에 바로 넣기나 XML로 넘기세요"))
    }
}
