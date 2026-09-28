@testable import DJCrate
import AppKit
import DJCTestSupport
import Foundation
import SwiftUI
import Testing

/// 놓은 뒤 목록 드롭 테두리 확인용(#127): 합성 라이브러리를 읽은 주 창의 곡 목록에 Finder에서처럼 파일(추가할 수 없는 형식)을
/// 끌어다 놓고, 끄는 중과 놓은 뒤를 그대로 그려 PNG로 남긴다. 마우스로 끄는 대신 SwiftUI가 드롭을 받는 뷰에
/// AppKit 순서(draggingEntered → draggingUpdated → prepare → perform → conclude → draggingEnded)대로 가짜 끌기 정보를 보낸다.
/// 오디오 장치(가짜 오디오)와 화면 기록 권한 없이 찍는다. 실데이터는 쓰지 않는다.
/// 고치기 전 모습은 목록·덱 델리게이트를 `a8ba6be^`처럼 Bool 강조로 되돌린 작업 트리에서 같은 시험으로 찍는다.
/// `DJC_DROP_BORDER_CAPTURE=<폴더> swift test --filter DropBorderCapture` → `<폴더>/<light|dark>-{dragging,dropped}.png`
@MainActor @Suite(.serialized)
struct DropBorderCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_DROP_BORDER_CAPTURE"] != nil), arguments: ["light", "dark"])
    func capture(_ appearance: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_DROP_BORDER_CAPTURE"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let fixture = try RekordboxFixture()
        for (index, title) in ["합성 곡 하나", "합성 곡 둘", "합성 곡 셋", "합성 곡 넷", "합성 곡 다섯"].enumerated() {
            var track = TrackSpec(id: String(101 + index))
            track.title = title
            try fixture.add(track)
        }
        // 추가할 수 없는 형식이라 곡 추가는 실패한다(이슈 재현 조건). 추가한 곡 목록은 파일에 저장하지 않는다.
        let dropped = fixture.root.appending(path: "합성 메모.txt")
        try Data("합성".utf8).write(to: dropped)
        let store = LibraryStore(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 stagingSaver: { _ in })
        await store.load(snapshot: fixture.database)
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(1500))

        // 곡 목록 가운데를 덮는 SwiftUI 드롭 받는 뷰(덱·사이드바 행에도 따로 있다)
        let root = try #require(window.contentView)
        let table = try #require(Self.views(in: root).first { $0 is NSTableView && $0.registeredDraggedTypes.contains(PlaylistDragType.pasteboardTracks) })
        let scroll = try #require(table.enclosingScrollView)
        let point = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let destinationView = try #require(Self.views(in: root)
            .filter { !$0.registeredDraggedTypes.isEmpty && String(describing: type(of: $0)).contains("DraggingDestination")
                && $0.convert($0.bounds, to: nil).contains(point) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        let destination: any NSDraggingDestination = destinationView

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("djc-drop-border-capture-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([dropped as NSURL])
        let info = FakeDraggingInfo(window: window, location: point, pasteboard: pasteboard)

        // 끄는 중: 들어와서 움직인다.
        _ = destination.draggingEntered?(info)
        _ = destination.draggingUpdated?(info)
        _ = destination.draggingUpdated?(info)
        try await Task.sleep(for: .milliseconds(500))
        try save(window, to: folder.appending(path: "\(appearance)-dragging.png"))

        // 놓기: AppKit이 마우스를 뗄 때 부르는 순서. 끝난 뒤 dropExited는 오지 않는다.
        _ = destination.prepareForDragOperation?(info)
        _ = destination.performDragOperation?(info)
        destination.concludeDragOperation?(info)
        destination.draggingEnded?(info)
        try await Task.sleep(for: .milliseconds(1500))
        try save(window, to: folder.appending(path: "\(appearance)-dropped.png"))
    }

    private static func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(views(in:))
    }

    private func save(_ window: NSWindow, to url: URL) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(window.contentView?.superview ?? window.contentView)
        // 뷰를 따로 그리면(cacheDisplay) 선택 줄의 효과 레이어(합성 필터)가 검게 나온다(MissingFilesCapture와 같다).
        // 캡처할 때만 그 레이어를 비강조 선택 색으로 칠한다.
        var selection: CGColor?
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            selection = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
        }
        for row in Self.views(in: view).compactMap({ $0 as? NSTableRowView }) where row.isSelected {
            for layer in row.subviews.compactMap({ ($0 as? NSVisualEffectView)?.layer }).flatMap({ $0.sublayers ?? [] }) {
                layer.compositingFilter = nil
                layer.backgroundColor = selection
            }
        }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

/// Finder에서 파일 하나를 끌어 온 것처럼 보이는 끌기 정보. 위치는 창 좌표로 고정한다.
@MainActor
private final class FakeDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard
    var draggingSourceOperationMask: NSDragOperation { [.copy, .link, .generic] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 127 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
        draggingDestinationWindow = window
        draggingLocation = location
        draggingPasteboard = pasteboard
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    /// AppKit이 놓을 때 끌기 정보에 묻는 값(실제 끌기 세션에만 있다). 복사로 받은 것처럼 돌려준다.
    @objc func _lastDragDestinationOperation() -> NSDragOperation { .copy }

    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let objects = draggingPasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []
        var stop: ObjCBool = false
        for (index, object) in objects.enumerated() {
            guard let writer = object as? any NSPasteboardWriting else { continue }
            block(NSDraggingItem(pasteboardWriter: writer), index, &stop)
            if stop.boolValue { break }
        }
    }
}
