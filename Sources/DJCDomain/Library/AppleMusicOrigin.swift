import Foundation

/// 재생 목록을 쓰는 기능이 생길 때까지 원래 소속과 순서를 추가한 곡에 보관한다.
public struct AppleMusicOrigin: Codable, Sendable, Hashable {
    public var libraryID: String?
    public var trackID: Int
    public var playlists: [Playlist]

    public struct Playlist: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var parentID: String?
        /// XML의 원래 순서(0부터). 누락·제외된 곡 자리도 센다.
        public var position: Int

        public init(id: String, name: String, parentID: String?, position: Int) {
            self.id = id; self.name = name; self.parentID = parentID; self.position = position
        }
    }

    public init(libraryID: String?, trackID: Int, playlists: [Playlist]) {
        self.libraryID = libraryID; self.trackID = trackID; self.playlists = playlists
    }
}

public extension StagedTrack {
    mutating func rememberAppleMusicOrigins(_ origins: [AppleMusicOrigin]) {
        guard !origins.isEmpty else { return }
        var saved = appleMusicOrigins ?? []
        for origin in origins {
            if let index = saved.firstIndex(where: { $0.libraryID == origin.libraryID && $0.trackID == origin.trackID }) {
                saved[index] = origin
            } else {
                saved.append(origin)
            }
        }
        appleMusicOrigins = saved
    }
}
