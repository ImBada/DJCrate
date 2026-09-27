import Foundation

/// USB 곡을 다시 쓸 때 고를 수 있는 부분
public enum UsbRefreshPart: String, Codable, CaseIterable, Sendable {
    case info, cues, grid, artwork
}

/// 이미 내보낸 USB 라이브러리 편집 한 건. 초안 파일과 `usb-edit` 편집 파일에 JSON으로 적는다.
/// 모양은 합성 Codable 그대로다: `{"addTracks":{"localContentIDs":[…],"playlist":…}}`, `{"removeTracks":{"usbContentIDs":[…]}}`,
/// `{"refreshTracks":{"usbContentIDs":[…],"parts":[…]}}`, `{"playlist":{"edit":<PlaylistEdit>}}`.
public enum UsbLibraryEdit: Codable, Hashable, Sendable {
    /// 로컬 곡을 USB에 더한다. playlist가 있으면 그 USB 목록 끝에도 넣는다.
    case addTracks(localContentIDs: [String], playlist: PlaylistRef?)
    case removeTracks(usbContentIDs: [Int])
    case refreshTracks(usbContentIDs: [Int], parts: Set<UsbRefreshPart>)
    /// USB 목록 편집. `PlaylistRef.id`는 USB 목록 ID, 곡은 USB content_id 문자열이다.
    /// 라벨(`edit:`)이 있어야 JSON 키가 "_0"이 아니라 "edit"이 된다.
    case playlist(edit: PlaylistEdit)

    /// 이 편집이 필요로 하는 확인 안 된 규칙
    public var requiredRules: Set<UsbProvisionalRule> {
        switch self {
        case .addTracks: [.editAddTracks]
        case .removeTracks: [.editRemoveTracks, .trackRemovalFiles]
        case .refreshTracks: [.editRefreshTracks]
        case .playlist: [.editPlaylists]
        }
    }
}
