import AnicueDomain
import Foundation
import RekordboxKit

/// 반영 계획 묶음(내보낸 XML마다 하나). 가져온 뒤 검증에 쓴다.
public enum ReflectionStore {
    public struct Batch: Codable, Sendable {
        public var createdAt: String
        public var xmlPath: String
        public var plans: [Reflection.Plan]
        public var checks: [String: Reflection.Check]

        public init(createdAt: String, xmlPath: String, plans: [Reflection.Plan], checks: [String: Reflection.Check]) {
            self.createdAt = createdAt
            self.xmlPath = xmlPath
            self.plans = plans
            self.checks = checks
        }
    }

    public static var url: URL { AnicuePaths.userData.appending(path: "reflection.json") }

    public static func load() -> Batch? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Batch.self, from: data)
    }

    public static func save(_ batch: Batch?) throws {
        guard let batch else { try? FileManager.default.removeItem(at: url); return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(batch).write(to: url, options: .atomic)
    }
}
