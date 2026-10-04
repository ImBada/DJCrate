import AVFoundation
import AppKit
import Foundation
import ImageIO
import RekordboxKit

/// rekordbox가 만들어 둔 아트워크(`share/PIONEER/Artwork`)를 우선 쓰고, 없으면 파일 내장 이미지를 읽는다.
enum ArtworkCache {
    /// 덱 커버: 전체 크기 JPEG를 그대로 쓰지 않고 작게 디코딩한다(메모리·메인 스레드 절약).
    nonisolated static func downsampled(imagePath: String?, maxPixels: Int) -> Thumbnails.Box? {
        for size in [RekordboxShare.ArtworkSize.full, .medium] {
            guard let url = RekordboxShare.artworkURL(imagePath, size: size),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  ] as CFDictionary)
            else { continue }
            return Thumbnails.Box(image: image)
        }
        return nil
    }

    static func embeddedArtwork(url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first,
              let data = try? await item.load(.dataValue)
        else { return nil }
        return NSImage(data: data)
    }
}

/// rekordbox에 그림을 쓰거나 되돌린 곡(ContentID)마다 올리는 번호(#66). 그림 바꾸기는 `ImagePath`가 그대로라 ContentID만 열쇠로 쓰면
/// 목록 썸네일 캐시가 옛 그림(그림이 없던 곡이면 "없음")을 계속 보인다. 열쇠에 번호를 붙여 새로 읽게 한다.
@MainActor
enum ArtworkRevisions {
    private(set) static var values: [String: Int] = [:]

    static func bump(_ contentIDs: some Sequence<String>) {
        for id in contentIDs { values[id, default: 0] += 1 }
    }

    /// 썸네일 캐시·셀 재사용 열쇠
    static func key(_ contentID: String) -> String { values[contentID].map { "\(contentID)#\($0)" } ?? contentID }
}

/// 목록 썸네일: 메인 스레드 밖에서 작게 디코딩해 캐시한다. 스크롤로 지나친 요청은 건너뛴다.
actor Thumbnails {
    static let shared = Thumbnails()

    struct Box: @unchecked Sendable { let image: CGImage }
    private final class Entry { let box: Box?; init(_ box: Box?) { self.box = box } }
    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 3000
        return cache
    }()

    func image(imagePath: String?, key: String) -> Box? {
        if let hit = cache.object(forKey: key as NSString) { return hit.box }
        guard !Task.isCancelled else { return nil }
        var box: Box?
        if let url = RekordboxShare.artworkURL(imagePath, size: .small),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 64,
           ] as CFDictionary) {
            box = Box(image: image)
        }
        // 아트워크가 없는 곡도 기억해 파일을 다시 열지 않는다.
        cache.setObject(Entry(box), forKey: key as NSString)
        return box
    }
}
