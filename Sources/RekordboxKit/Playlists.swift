import AnicueDomain
import Foundation

/// rekordbox 플레이리스트·폴더(djmdPlaylist / djmdSongPlaylist). 읽기 전용.
public struct RekordboxPlaylist: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let parentID: String
    public let seq: Int
    /// Attribute 1 = 폴더, 0 = 플레이리스트 (스마트 플레이리스트 4는 현재 라이브러리에 없음)
    public let isFolder: Bool
    /// TrackNo 순서의 ContentID
    public let trackIDs: [String]
}

/// 사이드바 트리 노드. `children`이 nil이면 잎(플레이리스트)이다.
public struct PlaylistNode: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let isFolder: Bool
    public let children: [PlaylistNode]?
    /// 폴더면 하위 플레이리스트 곡을 순서대로 모은 것(중복 제거).
    public let trackIDs: [String]

    public static func tree(_ playlists: [RekordboxPlaylist]) -> [PlaylistNode] {
        let byParent = Dictionary(grouping: playlists, by: \.parentID)
        func build(_ parent: String) -> [PlaylistNode] {
            (byParent[parent] ?? []).sorted { $0.seq < $1.seq }.map { playlist in
                if playlist.isFolder {
                    let children = build(playlist.id)
                    var seen = Set<String>()
                    let tracks = children.flatMap(\.trackIDs).filter { seen.insert($0).inserted }
                    return PlaylistNode(id: playlist.id, name: playlist.name, isFolder: true,
                                        children: children, trackIDs: tracks)
                }
                // rekordbox는 같은 곡을 한 플레이리스트에 여러 번 넣을 수 있다(실데이터 19건).
                // 표 선택은 곡 ID가 유일해야 하므로 첫 등장만 남긴다.
                var seen = Set<String>()
                return PlaylistNode(id: playlist.id, name: playlist.name, isFolder: false,
                                    children: nil, trackIDs: playlist.trackIDs.filter { seen.insert($0).inserted })
            }
        }
        return build("root")
    }

    public func find(_ id: String) -> PlaylistNode? {
        if self.id == id { return self }
        for child in children ?? [] {
            if let hit = child.find(id) { return hit }
        }
        return nil
    }
}

extension RekordboxLibrary {
    static func loadPlaylists(_ db: CipherDatabase) throws -> [RekordboxPlaylist] {
        var tracks: [String: [String]] = [:]
        try db.query("""
            SELECT PlaylistID, ContentID FROM djmdSongPlaylist
            WHERE rb_local_deleted = 0 ORDER BY PlaylistID, TrackNo
            """) { row in
            if let playlist = row.string(0), let content = row.string(1) {
                tracks[playlist, default: []].append(content)
            }
        }
        var playlists: [RekordboxPlaylist] = []
        try db.query("""
            SELECT ID, Seq, Name, Attribute, ParentID FROM djmdPlaylist WHERE rb_local_deleted = 0
            """) { row in
            let id = row.string(0) ?? ""
            playlists.append(RekordboxPlaylist(
                id: id,
                name: row.string(2) ?? "",
                parentID: row.string(4) ?? "root",
                seq: row.int(1) ?? 0,
                isFolder: row.int(3) == 1,
                trackIDs: tracks[id] ?? []
            ))
        }
        return playlists
    }
}
