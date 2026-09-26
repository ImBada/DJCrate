import AnicueDomain
import Foundation

/// 곡별 rekordbox 오토게인 초안(dB). rekordbox에 반영하면 지운다.
public enum GainDraftStore {
    public static var url: URL { AnicuePaths.userData.appending(path: "gain-drafts.json") }

    public static func all() -> [String: Double] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
    }

    public static func load(trackUUID: String) -> Double? { all()[trackUUID] }

    public static func uuids() -> Set<String> { Set(all().keys) }

    public static func save(_ gainDB: Double?, trackUUID: String) {
        var drafts = all()
        drafts[trackUUID] = gainDB
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(drafts).write(to: url, options: .atomic)
    }

    public static func remove(trackUUID: String) { save(nil, trackUUID: trackUUID) }
}
