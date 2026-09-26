import Foundation

/// 태그 편집기에서 다루는 곡 정보. 반영하면 rekordbox 라이브러리에 쓴다(음원 파일 태그는 그대로 둔다).
public struct TagFields: Codable, Hashable, Sendable {
    public enum Key: String, CaseIterable, Codable, Sendable, Identifiable {
        case title, artist, album, albumArtist, genre, composer, year, trackNumber, comment

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .title: "제목"
            case .artist: "아티스트"
            case .album: "앨범"
            case .albumArtist: "앨범 아티스트"
            case .genre: "장르"
            case .composer: "작곡가"
            case .year: "연도"
            case .trackNumber: "트랙 번호"
            case .comment: "코멘트"
            }
        }
    }

    public var title = ""
    public var artist = ""
    public var album = ""
    public var albumArtist = ""
    public var genre = ""
    public var composer = ""
    public var year = ""
    public var trackNumber = ""
    public var comment = ""

    public init() {}

    /// rekordbox DB 값에서 시작한다. 파일 태그 대조는 writer 단계에서 한다.
    public init(track: Track) {
        title = track.title
        artist = track.artist ?? ""
        album = track.album ?? ""
        albumArtist = track.albumArtist ?? ""
        genre = track.genre ?? ""
        composer = track.composer ?? ""
        year = track.releaseYear.map(String.init) ?? ""
        trackNumber = track.trackNumber.map(String.init) ?? ""
        comment = track.comment
    }

    public subscript(key: Key) -> String {
        get {
            switch key {
            case .title: title
            case .artist: artist
            case .album: album
            case .albumArtist: albumArtist
            case .genre: genre
            case .composer: composer
            case .year: year
            case .trackNumber: trackNumber
            case .comment: comment
            }
        }
        set {
            switch key {
            case .title: title = newValue
            case .artist: artist = newValue
            case .album: album = newValue
            case .albumArtist: albumArtist = newValue
            case .genre: genre = newValue
            case .composer: composer = newValue
            case .year: year = newValue
            case .trackNumber: trackNumber = newValue
            case .comment: comment = newValue
            }
        }
    }
}

public struct TagDraft: Codable, Equatable, Sendable {
    public var trackUUID: String
    public var base: TagFields
    public var fields: TagFields

    public init(track: Track) {
        self.init(trackUUID: track.uuid, base: TagFields(track: track))
    }

    /// base(초안을 만들 때의 rekordbox 값)에서 시작한다.
    public init(trackUUID: String, base: TagFields) {
        self.trackUUID = trackUUID
        self.base = base
        fields = base
    }

    public var changedKeys: [TagFields.Key] { TagFields.Key.allCases.filter { base[$0] != fields[$0] } }
    public var hasChanges: Bool { base != fields }

    /// 쓰기 전 확인할 문제.
    public var issues: [String] {
        var issues: [String] = []
        if !fields.year.isEmpty, Int(fields.year) == nil { issues.append("연도는 숫자여야 합니다") }
        if !fields.trackNumber.isEmpty, Int(fields.trackNumber) == nil { issues.append("트랙 번호는 숫자여야 합니다") }
        if fields.title.trimmingCharacters(in: .whitespaces).isEmpty { issues.append("제목이 비어 있습니다") }
        return issues
    }
}

