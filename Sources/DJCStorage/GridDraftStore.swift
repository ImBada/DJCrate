import DJCDomain
import Foundation

public enum GridDraftStore {
    /// rekordbox에 반영이 확인된 곡의 초안을 지운다(이제 rekordbox 값이 원본이다).
    public static func remove(trackUUID: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: "\(trackUUID).json"))
    }

    public static var directory: URL {
        DJCPaths.userData.appending(path: "grid-drafts")
    }

    public static func load(trackUUID: String) -> GridDraft? {
        guard let data = try? Data(contentsOf: directory.appending(path: "\(trackUUID).json")) else { return nil }
        return try? JSONDecoder().decode(GridDraft.self, from: data)
    }

    public static func save(_ draft: GridDraft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(draft.trackUUID).json")
        if draft.hasChanges {
            try JSONEncoder().encode(draft).write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static func uuids() -> Set<String> { DraftFiles.uuids(in: directory) }
}

enum DraftFiles {
    static func uuids(in directory: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }
}

public extension CueDraftStore {
    static func uuids() -> Set<String> { DraftFiles.uuids(in: directory) }
}
