import DJCDomain
import Foundation

/// 재생 목록 초안(#39·#40). 편집이 서로 기대므로(새로 만든 목록에 곡 넣기 등) 파일 하나에 순서대로 둔다.
/// 반영하면 쓴 편집을 빼고, 비면 파일을 지운다.
public enum PlaylistDraftStore {
    public static var url: URL { DJCPaths.userData.appending(path: "playlist-drafts.json") }

    /// 없거나 읽지 못하면 빈 초안
    public static func load(url: URL = url) -> PlaylistDraft {
        guard let data = try? Data(contentsOf: url) else { return PlaylistDraft() }
        return (try? JSONDecoder().decode(PlaylistDraft.self, from: data)) ?? PlaylistDraft()
    }

    public static func save(_ draft: PlaylistDraft, url: URL = url) throws {
        guard !draft.isEmpty else {
            do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(draft).write(to: url, options: .atomic)
    }
}
