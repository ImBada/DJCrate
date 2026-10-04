import CryptoKit
import DJCDomain
import Foundation

/// 곡 그림 초안(#66). 곡마다 `<UUID>.json`(초안)과 `<UUID>.image`(고른 그림의 사본)를 둔다. 원본 그림 파일을 옮기거나 지워도 초안은 남는다.
/// rekordbox에 쓰면 지운다(쓴 초안과 사본은 그 쓰기의 백업 `artwork-drafts/`에 남아 되돌리면 다시 살린다).
/// 읽지 못한 초안, 사본이 없거나 SHA-256이 다른 초안은 지우지 않고 사본과 함께 `damaged-drafts`로 옮긴다(#174).
public enum ArtworkDraftStore {
    public static let folderName = "artwork-drafts"

    public static var directory: URL { DJCPaths.userData.appending(path: folderName) }

    /// 그림 파일 바이트로 넣기·바꾸기 초안을 만든다(사본의 SHA-256을 함께 둔다).
    public static func edit(trackUUID: String, base: ArtworkBase, image: Data, imageName: String?) -> ArtworkEdit {
        ArtworkEdit(draft: ArtworkDraft(trackUUID: trackUUID, change: .set, base: base, imageName: imageName, imageSHA256: sha256(image)),
                    image: image)
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// 없으면 nil. 초안을 해석하지 못하거나 사본이 맞지 않으면 `DraftFileDamaged`, 읽지 못하면 그 오류를 던진다.
    public static func load(trackUUID: String, directory: URL = directory) throws -> ArtworkEdit? {
        let url = directory.appending(path: "\(trackUUID).json")
        guard let draft = try DamagedDrafts.read(ArtworkDraft.self, at: url) else { return nil }
        guard draft.trackUUID == trackUUID else { throw DraftFileDamaged(file: url) }
        guard draft.change == .set else { return ArtworkEdit(draft: draft, image: nil) }
        guard let sha = draft.imageSHA256, let image = try? Data(contentsOf: directory.appending(path: "\(trackUUID).image")),
              sha256(image) == sha else { throw DraftFileDamaged(file: url) }
        return ArtworkEdit(draft: draft, image: image)
    }

    /// 읽을 수 있는 초안(그림 바이트 없이). 목록 표시용이라 읽지 못한 초안은 뺀다.
    public static func all(directory: URL = directory) -> [String: ArtworkDraft] {
        var drafts: [String: ArtworkDraft] = [:]
        for uuid in uuids(directory: directory) {
            if let edit = try? load(trackUUID: uuid, directory: directory) { drafts[uuid] = edit.draft }
        }
        return drafts
    }

    public static func uuids(directory: URL = directory) -> Set<String> { DraftFiles.uuids(in: directory) }

    /// 사본을 먼저 쓰고 초안을 쓴다(초안이 가리키는 사본이 늘 있게). 지우기 초안이면 옛 사본을 지운다.
    public static func save(_ edit: ArtworkEdit, directory: URL = directory) throws {
        let uuid = edit.trackUUID
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try preserveIfDamaged(trackUUID: uuid, directory: directory)
        let copy = directory.appending(path: "\(uuid).image")
        if edit.draft.change == .set {
            guard let image = edit.image else { throw CocoaError(.fileWriteUnknown) }
            try image.write(to: copy, options: .atomic)
        }
        try JSONEncoder().encode(edit.draft).write(to: directory.appending(path: "\(uuid).json"), options: .atomic)
        if edit.draft.change == .delete { try removeIfPresent(copy) }
    }

    /// 초안과 사본을 지운다(없으면 그대로). 손상된 초안은 지우지 않고 옮겨 보관한다.
    public static func remove(trackUUID: String, directory: URL = directory) throws {
        try preserveIfDamaged(trackUUID: trackUUID, directory: directory)
        try removeIfPresent(directory.appending(path: "\(trackUUID).json"))
        try removeIfPresent(directory.appending(path: "\(trackUUID).image"))
    }

    private static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { }
    }

    /// 읽지 못한 초안이면 사본과 함께 `damaged-drafts/artwork-drafts/`로 옮긴다.
    static func preserveIfDamaged(trackUUID: String, directory: URL) throws {
        do { _ = try load(trackUUID: trackUUID, directory: directory) }
        catch is DraftFileDamaged {
            let home = directory.deletingLastPathComponent()
            try DamagedDrafts.preserve(directory.appending(path: "\(trackUUID).json"), home: home, trackUUID: trackUUID)
            let copy = directory.appending(path: "\(trackUUID).image")
            if FileManager.default.fileExists(atPath: copy.path) {
                try DamagedDrafts.preserve(copy, home: home, trackUUID: trackUUID, logged: false)
            }
        }
    }
}
