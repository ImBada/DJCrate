import DJCDomain
import Foundation

public enum TagDraftStore {
    public static var directory: URL {
        DJCPaths.userData.appending(path: "tag-drafts")
    }

    public static func load(trackUUID: String) -> TagDraft? {
        load(trackUUID: trackUUID, directory: directory)
    }

    public static func load(trackUUID: String, directory: URL) -> TagDraft? {
        guard let data = try? Data(contentsOf: directory.appending(path: "\(trackUUID).json")) else { return nil }
        return try? JSONDecoder().decode(TagDraft.self, from: data)
    }

    public static func save(_ draft: TagDraft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(draft.trackUUID).json")
        if draft.hasChanges {
            try JSONEncoder().encode(draft).write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static func uuids(directory: URL = directory) -> Set<String> { DraftFiles.uuids(in: directory) }
}
