import DJCDomain
import AVFoundation
import Foundation

/// 파일에서 추가할 곡 만들기(태그 읽기)·폴더 훑기.
public extension StagedTrack {
    /// rekordbox가 읽을 수 있는 형식(rekordbox 7 기준).
    static let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "mp4", "wav", "aif", "aiff", "flac", "alac"]

    /// 파일 태그로 만든다. 태그가 없으면 파일 이름을 제목으로 쓴다.
    static func make(fileAt url: URL, addedOn: String) async throws -> StagedTrack {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let items = (try? await asset.load(.metadata)) ?? []
        func string(_ identifiers: [AVMetadataIdentifier]) async -> String? {
            for identifier in identifiers {
                for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                    if let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                        return value
                    }
                }
            }
            return nil
        }
        let title = await string([.commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName])
        let artist = await string([.commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist])
        let album = await string([.commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum])
        let genre = await string([.id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre, .commonIdentifierType])
        let composer = await string([.id3MetadataComposer, .iTunesMetadataComposer, .quickTimeMetadataComposer])
        let comment = await string([.id3MetadataComments, .iTunesMetadataUserComment, .quickTimeMetadataComment])
        let yearText = await string([.id3MetadataRecordingTime, .id3MetadataYear, .iTunesMetadataReleaseDate, .commonIdentifierCreationDate])
        var trackText = await string([.id3MetadataTrackNumber])
        // iTunes(M4A) 트랙 번호는 문자열이 아니라 8바이트 데이터다: 0,0,번호(2바이트),총수(2바이트),0,0
        if trackText == nil, let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataTrackNumber).first,
           let data = try? await item.load(.dataValue), data.count >= 4 {
            let bytes = [UInt8](data)
            let number = Int(bytes[2]) << 8 | Int(bytes[3])
            if number > 0 { trackText = String(number) }
        }
        return StagedTrack(path: url.path, title: title ?? url.deletingPathExtension().lastPathComponent,
                           artist: artist, album: album, genre: genre, composer: composer,
                           year: yearText.flatMap { Int($0.prefix(4)) },
                           trackNumber: trackText.flatMap { Int($0.split(separator: "/").first ?? "") },
                           comment: comment ?? "", duration: duration.isFinite ? duration : 0, addedOn: addedOn)
    }

    /// 폴더는 펼치고, rekordbox가 못 읽는 형식은 뺀다.
    static func audioFiles(in urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = enumerator?.nextObject() as? URL {
                    if supportedExtensions.contains(file.pathExtension.lowercased()) { result.append(file) }
                }
            } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// 추가한 곡 목록(Application Support/DJCrate/staged.json).
public enum StagingStore {
    public static var url: URL {
        DJCPaths.userData.appending(path: "staged.json")
    }

    public static func load(url: URL = url) -> [StagedTrack] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([StagedTrack].self, from: data)) ?? []
    }

    public static func save(_ tracks: [StagedTrack], url: URL = url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(tracks).write(to: url, options: .atomic)
    }
}
