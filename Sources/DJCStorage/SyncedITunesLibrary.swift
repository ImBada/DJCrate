import DJCDomain
import Foundation

/// 목록 편집용 PlaylistLayout과 분리해 iTunes ID가 rekordbox 쓰기 대상으로 들어가지 않게 한다.
public struct SyncedITunesLibrary: Sendable {
    public struct Node: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let children: [Node]?
        public let trackIDs: [String]
        /// 연결된 곡의 원래 목록 순번. 누락된 곡의 자리는 건너뛴다.
        public let trackNumbers: [Int]
        public let unavailableTrackCount: Int
        public var isFolder: Bool { children != nil }
    }

    public var tree: [Node] = []
    public var index: [String: Node] = [:]
    /// 읽기 전 처음 상태는 `.loading`. 읽기가 끝난 뒤의 `.notCaptured`와 구분한다.
    public var status: ITunesLibrarySnapshot.Status = .loading
    public var unavailablePlaylistCount = 0
    public var playlistCount: Int { index.values.filter { !$0.isFolder }.count }
    public init() {}

    public init(snapshot: ITunesLibrarySnapshot, tracks: [Track]) {
        status = snapshot.status
        unavailablePlaylistCount = snapshot.unavailablePlaylistCount
        guard status == .ready || status == .stale else { return }
        do { try ITunesLibrarySnapshot.validate(snapshot.playlists) }
        catch { status = .unavailable; return }
        let byPath = Dictionary(grouping: tracks.filter { !$0.isDeleted && !$0.isStreaming }, by: { Self.pathKey($0.folderPath) })
        let byParent = Dictionary(grouping: snapshot.playlists, by: { $0.parentID ?? "0" })
        func unique(_ ids: [String]) -> [String] {
            var seen = Set<String>()
            return ids.filter { seen.insert($0).inserted }
        }
        func build(_ parent: String) -> [Node] {
            (byParent[parent] ?? []).map { playlist in
                if playlist.isFolder {
                    let children = build(playlist.id)
                    let ids = unique(children.flatMap(\.trackIDs))
                    return Node(id: "itunes:\(playlist.id)", name: playlist.name, children: children,
                                trackIDs: ids, trackNumbers: Array(ids.indices.map { $0 + 1 }),
                                unavailableTrackCount: children.reduce(0) { $0 + $1.unavailableTrackCount })
                }
                var missing = 0
                let entries = playlist.paths.enumerated().compactMap { position, path -> (String, Int)? in
                    guard let path, let matches = byPath[Self.pathKey(path)], matches.count == 1 else { missing += 1; return nil }
                    return (matches[0].id, position + 1)
                }
                return Node(id: "itunes:\(playlist.id)", name: playlist.name, children: nil,
                            trackIDs: entries.map(\.0), trackNumbers: entries.map(\.1), unavailableTrackCount: missing)
            }
        }
        tree = build("0")
        func walk(_ nodes: [Node]) {
            for node in nodes { index[node.id] = node; walk(node.children ?? []) }
        }
        walk(tree)
    }

    private static func pathKey(_ path: String) -> String {
        URL(filePath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }
}
