import AppKit
import Foundation
import Testing
import DJCTestSupport
import RekordboxKit
@testable import DJCrate

struct PreviewWaveformTests {
    @Test func rendersPeaksAndSilenceInEveryAppearance() throws {
        let preview = try #require(try AnlzPreviewWaveform(file: AnlzFile(data:
            AnlzBuilder.file([AnlzBuilder.pwav([0, 31])]))))
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let image = try #require(PreviewWaveformRenderer.image(preview, mode: .blue, appearance: name.rawValue))
            #expect(image.width == 400)
            #expect(image.height == 40)
            let bitmap = NSBitmapImageRep(cgImage: image)
            #expect(bitmap.colorAt(x: 0, y: 20)?.alphaComponent == 0)
            #expect(bitmap.colorAt(x: 300, y: 20)?.alphaComponent == 1)
            let expected = UIColors.info.variants.resolved(for: name).usingColorSpace(.sRGB)!
            let pixels = try #require(image.dataProvider?.data)
            let bytes = try #require(CFDataGetBytePtr(pixels))
            let offset = 20 * image.bytesPerRow + 300 * 4
            #expect(abs(Double(bytes[offset + 2]) / 255 - expected.blueComponent) < 0.01)
            #expect(abs(Double(bytes[offset]) / 255 - expected.redComponent) < 0.01)
        }
    }

    @Test func cachesImagesAndSeparatesSnapshotRevisions() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "preview.DAT")
        let cache = PreviewWaveformCache()
        let first = PreviewWaveformRequest(url: url, revision: "first", appearance: NSAppearance.Name.aqua.rawValue)
        #expect(await cache.image(for: first) == nil)
        try AnlzBuilder.file([AnlzBuilder.pwav([31, 0, 15])]).write(to: url)
        // 없는 자료도 캐시하되 새 스냅샷을 열면 다시 읽는다.
        #expect(await cache.image(for: first) == nil)
        let second = PreviewWaveformRequest(url: url, revision: "second", appearance: NSAppearance.Name.aqua.rawValue)
        let image = try #require(await cache.image(for: second))
        #expect(await cache.image(for: second) === image)
        let missing = PreviewWaveformRequest(url: nil, revision: "second", appearance: NSAppearance.Name.aqua.rawValue)
        #expect(await cache.image(for: missing) == nil)
    }
}
