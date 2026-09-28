import DJCDomain
import Foundation
import RekordboxKit

/// 한 USB에 쌓은 편집 초안. 반영(`djc usb-edit --draft`) 때 한 번에 쓴다
public struct UsbDraft: Codable, Sendable, Equatable {
    /// 볼륨 UUID(대문자)
    public var volumeKey: String
    /// 초안을 만든 때의 USB DB 지문. 쓸 때 지금 지문과 다르면 지금 USB 상태로 다시 계획한다
    public var base: UsbFingerprint
    /// 적힌 순서대로 쓴다
    public var edits: [UsbLibraryEdit]
    public var createdAt: Date

    public init(volumeKey: String, base: UsbFingerprint, edits: [UsbLibraryEdit], createdAt: Date = Date()) {
        self.volumeKey = volumeKey
        self.base = base
        self.edits = edits
        self.createdAt = createdAt
    }
}

/// USB 초안 파일(`usb-drafts/<볼륨키>.json`). 쓰기는 모두 내구 쓰기(임시 파일 → fsync → rename)라 끊겨도 옛것 또는 새것만 남는다
public final class UsbDraftStore {
    let directory: URL
    let fileSystem: any UsbFileSystem

    public init(directory: URL = DJCPaths.usbDrafts, fileSystem: any UsbFileSystem = PosixUsbFileSystem()) {
        self.directory = directory
        self.fileSystem = fileSystem
    }

    /// 그 볼륨의 초안(없으면 nil)
    public func load(volumeKey: String) throws -> UsbDraft? {
        let url = try file(volumeKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UsbDraft.self, from: Data(contentsOf: url))
    }

    public func save(_ draft: UsbDraft) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try UsbDurableFile.write(encoder.encode(draft), to: file(draft.volumeKey), fileSystem: fileSystem)
    }

    /// 편집 하나를 끝에 더한다. 초안이 없으면 이 base로 새로 만든다(있으면 처음 base를 그대로 둔다)
    public func append(_ edit: UsbLibraryEdit, volumeKey: String, base: UsbFingerprint) throws {
        var draft = try load(volumeKey: volumeKey) ?? UsbDraft(volumeKey: volumeKey, base: base, edits: [])
        draft.edits.append(edit)
        try save(draft)
    }

    /// 초안을 지운다(없으면 아무것도 하지 않는다)
    public func discard(volumeKey: String) throws {
        let url = try file(volumeKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// 볼륨 키는 파일 이름 한 성분이어야 한다(다른 폴더를 가리키지 않게)
    func file(_ volumeKey: String) throws -> URL {
        guard !volumeKey.isEmpty, volumeKey != ".", volumeKey != "..", !volumeKey.contains("/"), !volumeKey.contains("\0") else {
            throw UsbError.readFailed(detail: "bad volume key")
        }
        return directory.appending(path: volumeKey + ".json")
    }
}
