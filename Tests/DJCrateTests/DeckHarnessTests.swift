@testable import DJCrate
import Foundation
import Testing

@Suite("덱 테스트 재료")
@MainActor
struct DeckHarnessTests {
    @Test func DB_없이_독립된_합성_음원을_준비하고_정리한다() async throws {
        var first: DeckHarness? = try DeckHarness()
        let second = try DeckHarness()
        try await first?.loaded()
        try await second.loaded()
        let firstAudio = URL(fileURLWithPath: try #require(first?.deck.row).track.folderPath)
        let secondAudio = URL(fileURLWithPath: try #require(second.deck.row).track.folderPath)
        let firstRoot = firstAudio.deletingLastPathComponent().deletingLastPathComponent()
        let secondRoot = secondAudio.deletingLastPathComponent().deletingLastPathComponent()
        #expect(firstRoot != secondRoot)
        #expect(FileManager.default.fileExists(atPath: firstAudio.path))
        #expect(!FileManager.default.fileExists(atPath: firstRoot.appending(path: "master.db").path))

        first = nil
        #expect(!FileManager.default.fileExists(atPath: firstRoot.path))
        #expect(FileManager.default.fileExists(atPath: secondAudio.path))
    }
}
