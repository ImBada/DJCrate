import DJCDomain
import Foundation

/// 곡 추가 계획: rekordbox 7.2.18이 파일을 컬렉션에 넣을 때(자동 분석을 끈 상태) 만드는 `djmdContent` 행의 칸 값.
///
/// 2026-09-26 실험(O-Ku-Ri-Mo-No Sunday! 분석 전 추가, 6곡 분석 추가)에서 확인한 규칙:
/// - 제목은 태그, 없으면 확장자를 뺀 파일 이름. 경로·파일 이름은 NFC.
/// - 아티스트·앨범·장르·작곡가는 이름으로 찾고 없으면 새 행(작곡가도 `djmdArtist`).
/// - 분석 칸(BPM·BitRate·BitDepth·SampleRate·KeyID·AnalysisDataPath)은 0이나 빈 값, `Analysed` 0, `ContentLink` 14.
/// - 길이는 초 반올림(분석 뒤에는 rekordbox가 다시 적는다).
/// - `rb_file_id`는 파일 inode, `DateCreated`는 파일을 만든 날, `StockDate`는 넣은 날(둘 다 이 컴퓨터 시간대 날짜).
public struct TrackAddPlan: Sendable, Codable, Equatable {
    public var path: String
    public var fileName: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var composer: String?
    public var comment: String
    public var year: Int
    public var trackNumber: Int
    public var discNumber: Int
    public var isrc: String
    public var lyricist: String
    public var fileType: Int
    public var fileSize: Int
    public var fileID: String
    public var length: Int
    /// AVFoundation이 잰 길이(초). 분석을 붙이면 rekordbox처럼 버림해 적는다.
    public var duration: Double
    public var dateCreated: String
    public var stockDate: String
    /// 내장 아트워크 원본(태그). 분석까지 붙여 넣을 때 rekordbox처럼 아트워크 파일 셋을 만든다(`TrackArtwork`).
    public var artwork: Data?

    /// rekordbox 파일 형식 번호(라이브러리 7천 곡에서 확인). 다른 형식은 아직 넣지 않는다.
    public static let fileTypes: [String: Int] = ["mp3": 1, "mp4": 3, "m4a": 4, "flac": 5, "wav": 11]

    public static func dateText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 파일과 태그로 계획을 만든다. 형식을 모르거나 파일을 읽지 못하면 이유와 함께 던진다.
    public static func make(url: URL, tags: AudioTags, now: Date = .now) throws -> TrackAddPlan {
        let path = url.path.precomposedStringWithCanonicalMapping
        let fileName = url.lastPathComponent.precomposedStringWithCanonicalMapping
        guard let fileType = fileTypes[url.pathExtension.lowercased()] else {
            throw DJCError.writeRefused(String(ui: "\(fileName): 이 형식은 아직 rekordbox에 직접 넣지 않습니다"))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? Int, let inode = attributes[.systemFileNumber] as? Int else {
            throw DJCError.writeRefused(String(ui: "\(fileName): 파일 정보를 읽지 못했습니다"))
        }
        let created = attributes[.creationDate] as? Date ?? now
        return TrackAddPlan(
            path: path, fileName: fileName,
            title: tags.title ?? url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping,
            artist: tags.artist, album: tags.album, albumArtist: tags.albumArtist, genre: tags.genre, composer: tags.composer,
            comment: tags.comment ?? "", year: tags.year ?? 0, trackNumber: tags.trackNumber ?? 0, discNumber: tags.discNumber ?? 0,
            isrc: tags.isrc ?? "", lyricist: tags.lyricist ?? "", fileType: fileType, fileSize: size, fileID: String(inode),
            length: Int(tags.duration.rounded()), duration: tags.duration, dateCreated: dateText(created), stockDate: dateText(now),
            artwork: tags.artwork)
    }
}
