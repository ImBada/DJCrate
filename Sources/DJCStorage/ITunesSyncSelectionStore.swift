import DJCDomain
import Foundation

/// DJCrate의 동기화 선택만 보관한다. rekordbox의 playlists3.sync에는 쓰지 않는다.
public enum ITunesSyncSelectionStore {
    public static var url: URL { DJCPaths.userData.appending(path: "itunes-sync-selection.json") }

    public static func load(url: URL = url) throws -> ITunesSyncSelection? {
        do { return try JSONDecoder().decode(ITunesSyncSelection.self, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    public static func save(_ selection: ITunesSyncSelection, url: URL = url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(selection).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
