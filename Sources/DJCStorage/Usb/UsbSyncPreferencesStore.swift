import DJCDomain
import Foundation
import RekordboxKit

/// 마지막 동기화로 연결한 로컬 목록과 USB 목록. 경로는 USB에서 이름·부모가 바뀌었는지 확인할 때 쓴다.
public struct UsbSyncPlaylistBinding: Codable, Equatable, Sendable {
    public var usbID: Int
    public var path: [String]
    public var isFolder: Bool

    public init(usbID: Int, path: [String], isFolder: Bool) {
        self.usbID = usbID
        self.path = path
        self.isFolder = isFolder
    }
}

/// USB마다 기억하는 동기화 선택. 다른 로컬 라이브러리에서는 DBID를 확인한 뒤 선택을 다시 만든다.
public struct UsbSyncPreferences: Codable, Equatable, Sendable {
    public var volumeKey: String
    public var localDBID: Int64
    public var selection: ITunesSyncSelection
    public var syncPlaylists: Bool
    public var bindings: [String: UsbSyncPlaylistBinding]
    /// USB 선택 파일을 읽은 때의 의미 지문. 같을 때만 아직 쓰지 않은 앱 선택을 이어 쓴다.
    public var nativeSelectionFingerprint: String?

    public init(volumeKey: String, localDBID: Int64, selection: ITunesSyncSelection = ITunesSyncSelection(),
                syncPlaylists: Bool = true, bindings: [String: UsbSyncPlaylistBinding] = [:],
                nativeSelectionFingerprint: String? = nil) {
        self.volumeKey = volumeKey
        self.localDBID = localDBID
        self.selection = selection
        self.syncPlaylists = syncPlaylists
        self.bindings = bindings
        self.nativeSelectionFingerprint = nativeSelectionFingerprint
    }
}

/// USB 동기화 선택(`usb-sync-selections/<볼륨키>.json`). 손상 파일은 오류로 알리고 그대로 보존한다.
public final class UsbSyncPreferencesStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(volumeKey: String) throws -> UsbSyncPreferences? {
        let url = try file(volumeKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let preferences = try JSONDecoder().decode(UsbSyncPreferences.self, from: Data(contentsOf: url))
        guard preferences.volumeKey == volumeKey else {
            throw UsbError.readFailed(detail: "sync preferences volume key mismatch")
        }
        return preferences
    }

    public func save(_ preferences: UsbSyncPreferences) throws {
        let url = try file(preferences.volumeKey)
        // 새 선택으로 손상 파일을 덮지 않게, 기존 선택을 읽을 수 있는지 먼저 확인한다.
        _ = try load(volumeKey: preferences.volumeKey)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try UsbDurableFile.write(encoder.encode(preferences), to: url)
    }

    private func file(_ volumeKey: String) throws -> URL {
        guard !volumeKey.isEmpty, volumeKey != ".", volumeKey != "..", !volumeKey.contains("/"), !volumeKey.contains("\0") else {
            throw UsbError.readFailed(detail: "bad volume key")
        }
        return directory.appending(path: volumeKey + ".json")
    }
}
