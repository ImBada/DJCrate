import DJCDomain
import Foundation

public enum DuplicateMergeDraftStore {
    public static var url: URL { DJCPaths.userData.appending(path: "merge-drafts.json") }

    public static func load(url: URL = url) -> [DuplicateMergeDraft] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DuplicateMergeDraft].self, from: data)) ?? []
    }

    public static func save(_ drafts: [DuplicateMergeDraft], url: URL = url) throws {
        if drafts.isEmpty {
            do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(drafts).write(to: url, options: .atomic)
        }
    }
}
