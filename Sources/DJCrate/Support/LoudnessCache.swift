import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation

/// 곡 음량 측정값(파일 경로·크기·수정 시각별). 곡을 다시 열 때 디코딩을 기다리지 않고 바로 오토게인을 건다.
@MainActor
final class LoudnessCache {
    static let shared = LoudnessCache()

    private let url = DJCIdentity.supportDirectory.appending(path: "loudness.json")
    private var values: [String: Loudness] = [:]
    private var saveTask: Task<Void, Never>?

    private init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Loudness].self, from: data) {
            values = decoded
        }
    }

    func value(for file: URL) -> Loudness? {
        key(file).flatMap { values[$0] }
    }

    func store(_ loudness: Loudness, for file: URL) {
        guard let key = key(file), values[key] != loudness else { return }
        values[key] = loudness
        // 곡을 빠르게 넘길 때 매번 쓰지 않도록 모아서 저장한다.
        saveTask?.cancel()
        let snapshot = values, url = url
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 경로 + 크기 + 수정 시각(파일을 바꾸면 다시 잰다)
    private func key(_ file: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(file.path)|\(size)|\(Int(modified.timeIntervalSince1970))"
    }
}
