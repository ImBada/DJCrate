import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import Testing

/// 그림 초안 저장소(#66): 초안(JSON)과 고른 그림의 사본(`.image`)을 곡마다 둔다. 원본 그림이 옮겨져도 초안이 남는다.
/// 읽지 못한 초안·사본이 없거나 바뀐 초안은 지우지 않고 사본과 함께 `damaged-drafts`로 옮긴다(#174와 같은 규칙).
@Suite("그림 초안 저장소", .serialized)
struct ArtworkDraftStoreTests {
    func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-artwork-drafts-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    let image = ImageFixture.image(width: 64, height: 64)
    let base = ArtworkBase(imagePath: "")

    @Test func 그림을_고른_초안은_사본과_함께_저장하고_다시_읽는다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appending(path: "artwork-drafts")
        let edit = ArtworkDraftStore.edit(trackUUID: "곡-1", base: base, image: image, imageName: "표지.jpg")
        #expect(edit.draft.change == .set && edit.draft.imageName == "표지.jpg" && edit.draft.imageSHA256?.count == 64)
        try ArtworkDraftStore.save(edit, directory: directory)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "곡-1.image").path))
        #expect(try ArtworkDraftStore.load(trackUUID: "곡-1", directory: directory) == edit)
        #expect(ArtworkDraftStore.uuids(directory: directory) == ["곡-1"])
        #expect(ArtworkDraftStore.all(directory: directory) == ["곡-1": edit.draft])
    }

    @Test func 지우기_초안으로_바꾸면_사본도_지우고_초안을_버리면_둘_다_지운다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appending(path: "artwork-drafts")
        try ArtworkDraftStore.save(ArtworkDraftStore.edit(trackUUID: "곡-1", base: base, image: image, imageName: nil), directory: directory)
        let delete = ArtworkEdit(draft: ArtworkDraft(trackUUID: "곡-1", change: .delete, base: ArtworkBase(imagePath: "/PIONEER/Artwork/x/artwork.jpg")),
                                 image: nil)
        try ArtworkDraftStore.save(delete, directory: directory)
        #expect(try ArtworkDraftStore.load(trackUUID: "곡-1", directory: directory) == delete)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "곡-1.image").path))
        try ArtworkDraftStore.remove(trackUUID: "곡-1", directory: directory)
        #expect(try ArtworkDraftStore.load(trackUUID: "곡-1", directory: directory) == nil && ArtworkDraftStore.uuids(directory: directory).isEmpty)
        try ArtworkDraftStore.remove(trackUUID: "없는 곡", directory: directory)
    }

    @Test(arguments: ["깨진 JSON", "사본 없음", "사본이 다름", "다른 곡의 초안"])
    func 읽지_못한_초안은_사본과_함께_옮겨_보관한다(damage: String) throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appending(path: "artwork-drafts")
        try ArtworkDraftStore.save(ArtworkDraftStore.edit(trackUUID: "곡-1", base: base, image: image, imageName: nil), directory: directory)
        let json = directory.appending(path: "곡-1.json"), copy = directory.appending(path: "곡-1.image")
        switch damage {
        case "깨진 JSON": try Data("{\"깨진".utf8).write(to: json)
        case "사본 없음": try FileManager.default.removeItem(at: copy)
        case "사본이 다름": try Data("다른 그림".utf8).write(to: copy)
        default: try FileManager.default.moveItem(at: json, to: directory.appending(path: "곡-2.json"))
        }
        let uuid = damage == "다른 곡의 초안" ? "곡-2" : "곡-1"
        #expect(throws: DraftFileDamaged.self) { try ArtworkDraftStore.load(trackUUID: uuid, directory: directory) }
        #expect(ArtworkDraftStore.all(directory: directory).isEmpty, "목록에는 읽은 초안만")
        DamagedDrafts.preserveAll(home: home)
        let moved = DamagedDrafts.take(home: home)
        #expect(moved.map(\.trackUUID) == [uuid] && moved.first?.name == "artwork-drafts/\(uuid).json")
        #expect(ArtworkDraftStore.uuids(directory: directory).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: copy.path), "사본도 함께 옮긴다")
        let kept = FileManager.default.enumerator(at: home.appending(path: DamagedDrafts.folderName), includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        #expect(kept.contains { $0.hasPrefix(uuid) && $0.hasSuffix(".json") })
        if damage != "사본 없음" { #expect(kept.contains { $0.hasSuffix(".image") }) }
    }

    @Test func 손상된_초안_위에_저장하면_옮겨_보관한_뒤_새_초안을_쓴다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appending(path: "artwork-drafts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"깨진".utf8).write(to: directory.appending(path: "곡-1.json"))
        let edit = ArtworkDraftStore.edit(trackUUID: "곡-1", base: base, image: image, imageName: nil)
        try ArtworkDraftStore.save(edit, directory: directory)
        #expect(try ArtworkDraftStore.load(trackUUID: "곡-1", directory: directory) == edit)
        #expect(DamagedDrafts.take(home: home).map(\.name) == ["artwork-drafts/곡-1.json"])
    }
}
