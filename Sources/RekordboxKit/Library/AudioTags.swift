import AVFoundation
import Foundation

/// 음원 파일 태그(ID3·iTunes·Vorbis). rekordbox가 곡을 컬렉션에 넣을 때 읽는 칸만 모은다.
public struct AudioTags: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var composer: String?
    public var comment: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var isrc: String?
    public var lyricist: String?
    /// AVFoundation이 잰 길이(초). 인코더 지연은 빠진 값.
    public var duration: Double
    /// 내장 아트워크(ID3 APIC·iTunes covr·FLAC PICTURE) 원본 바이트. 여럿이면 첫 그림.
    public var artwork: Data?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil, genre: String? = nil,
                composer: String? = nil, comment: String? = nil, year: Int? = nil, trackNumber: Int? = nil, discNumber: Int? = nil,
                isrc: String? = nil, lyricist: String? = nil, duration: Double = 0, artwork: Data? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.albumArtist = albumArtist; self.genre = genre
        self.composer = composer; self.comment = comment; self.year = year; self.trackNumber = trackNumber
        self.discNumber = discNumber; self.isrc = isrc; self.lyricist = lyricist; self.duration = duration
        self.artwork = artwork
    }

    // 칸마다 찾아볼 태그(앞이 먼저). ID3 · iTunes(M4A) · Vorbis(FLAC)
    static let fields: [String: [String]] = [
        "title": ["id3/TIT2", "itsk/%A9nam", "vorb/TITLE"],
        "artist": ["id3/TPE1", "itsk/%A9ART", "vorb/ARTIST"],
        "album": ["id3/TALB", "itsk/%A9alb", "vorb/ALBUM"],
        "albumArtist": ["id3/TPE2", "itsk/aART", "vorb/ALBUMARTIST", "vorb/ALBUM%20ARTIST"],
        "genre": ["id3/TCON", "itsk/%A9gen", "vorb/GENRE"],
        "composer": ["id3/TCOM", "itsk/%A9wrt", "vorb/COMPOSER"],
        "comment": ["id3/COMM", "itsk/%A9cmt", "vorb/COMMENT", "vorb/DESCRIPTION"],
        "date": ["id3/TDRC", "id3/TYER", "itsk/%A9day", "vorb/DATE", "vorb/YEAR"],
        "track": ["id3/TRCK", "vorb/TRACKNUMBER"],
        "disc": ["id3/TPOS", "vorb/DISCNUMBER"],
        "isrc": ["id3/TSRC", "vorb/ISRC"],
        "lyricist": ["id3/TEXT", "vorb/LYRICIST"],
    ]

    /// - Parameter includeArtwork: false면 내장 그림 바이트를 읽지 않는다(폴더를 훑으며 제목·길이만 볼 때).
    public static func read(url: URL, includeArtwork: Bool = true) async throws -> AudioTags {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let items = (try? await asset.load(.metadata)) ?? []
        func string(_ key: String) async -> String? {
            for raw in fields[key] ?? [] {
                for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: AVMetadataIdentifier(rawValue: raw)) {
                    // 설명이 붙은 ID3 코멘트(iTunNORM·iTunSMPB 등 iTunes 내부값)는 rekordbox가 읽지 않는다.
                    if raw == "id3/COMM", let extra = try? await item.load(.extraAttributes),
                       let info = extra[AVMetadataExtraAttributeKey.info] as? String, !info.isEmpty { continue }
                    if let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                        return value
                    }
                }
            }
            return nil
        }
        /// iTunes 번호 칸(trkn·disk)은 8바이트: 0,0,번호(2바이트),총수(2바이트),0,0
        func iTunesNumber(_ raw: String) async -> Int? {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: AVMetadataIdentifier(rawValue: raw)).first,
                  let data = try? await item.load(.dataValue), data.count >= 4 else { return nil }
            let bytes = [UInt8](data)
            let number = Int(bytes[2]) << 8 | Int(bytes[3])
            return number > 0 ? number : nil
        }
        func leadingNumber(_ text: String?) -> Int? { text.flatMap { Int($0.split(separator: "/").first ?? "") } }
        var tags = AudioTags(duration: duration.isFinite ? duration : 0)
        tags.title = await string("title")
        tags.artist = await string("artist")
        tags.album = await string("album")
        tags.albumArtist = await string("albumArtist")
        tags.genre = await string("genre")
        tags.composer = await string("composer")
        tags.comment = await string("comment")
        tags.year = await string("date").flatMap { Int($0.prefix(4)) }
        tags.trackNumber = leadingNumber(await string("track"))
        if tags.trackNumber == nil { tags.trackNumber = await iTunesNumber("itsk/trkn") }
        tags.discNumber = leadingNumber(await string("disc"))
        if tags.discNumber == nil { tags.discNumber = await iTunesNumber("itsk/disk") }
        tags.isrc = await string("isrc")
        if tags.isrc == nil, let xid = await iTunesText(items, "itsk/xid%20") {
            // iTunes xid: "레이블:isrc:JPCO02206960"
            let parts = xid.components(separatedBy: ":")
            if let i = parts.firstIndex(where: { $0.lowercased() == "isrc" }), i + 1 < parts.count { tags.isrc = parts[i + 1] }
        }
        tags.lyricist = await string("lyricist")
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork) where includeArtwork {
            if let data = try? await item.load(.dataValue), !data.isEmpty { tags.artwork = data; break }
        }
        return tags
    }

    static func iTunesText(_ items: [AVMetadataItem], _ raw: String) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: AVMetadataIdentifier(rawValue: raw)).first else { return nil }
        return try? await item.load(.stringValue)
    }
}
