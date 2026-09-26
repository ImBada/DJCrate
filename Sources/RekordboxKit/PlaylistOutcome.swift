import DJCDomain
import Foundation

/// 재생 목록 편집 한 건의 결과
public struct PlaylistOutcome: Codable, Hashable, Sendable {
    public var edit: PlaylistEdit
    /// 쓴 목록 ID(만들기면 새 ID). 찾지 못했으면 nil.
    public var playlistID: String?
    /// 목록 이름(쓴 뒤 이름)
    public var name: String
    public var status: RekordboxWriter.Outcome.Status
    public var reason: String?
}
