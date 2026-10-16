import AppKit
import UniformTypeIdentifiers

/// LINK 플레이어 칸에 놓은 곡(#274). 곡 목록이 덱에 끌 때와 같은 형식(`DeckDragType.track`, rekordbox 곡 ID)을 읽는다.
enum LinkTrackDrop {
    /// 곡 ID를 읽어 메인 액터에서 넘긴다. 곡이 없는 끌기면 false.
    /// 형식이 실제로 있는 제공자만 고른다(macOS 27의 빈 제공자, #255). 여러 곡을 끌었으면 첫 곡만 싣는다(덱과 같다)
    static func read(_ providers: [NSItemProvider], then deliver: @escaping @MainActor (String) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(DeckDragType.track.identifier) }) else {
            return false
        }
        _ = provider.loadDataRepresentation(forTypeIdentifier: DeckDragType.track.identifier) { data, _ in
            guard let id = data.flatMap({ String(data: $0, encoding: .utf8) }), !id.isEmpty else { return }
            Task { @MainActor in deliver(id) }
        }
        return true
    }
}
