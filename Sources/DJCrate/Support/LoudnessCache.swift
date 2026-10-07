import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation

/// 곡 음량 측정값(파일 경로·크기·수정 시각별). 곡을 다시 열 때 디코딩을 기다리지 않고 바로 오토게인을 건다.
@MainActor
final class LoudnessCache {
    /// `DJC_HOME`을 주면 그 아래 `loudness.json`(#195)
    static let shared = LoudnessCache(url: DJCCachePaths.current.loudness)

    let url: URL
    private let saveDelay: Duration
    private var values: [String: Loudness] = [:]
    private var saveTask: Task<Void, Never>?

    init(url: URL, saveDelay: Duration = .seconds(2)) {
        self.url = url
        self.saveDelay = saveDelay
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
        let snapshot = values, url = url, delay = saveDelay
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 캐시 비우기(설정 › 저장 공간): 기다리던 저장을 거두고 메모리와 파일을 함께 비운다(나중에 옛 값을 다시 쓰지 않게)
    func clear() {
        saveTask?.cancel()
        saveTask = nil
        values = [:]
        try? FileManager.default.removeItem(at: url)
    }

    /// 경로 + 크기 + 수정 시각(파일을 바꾸면 다시 잰다)
    private func key(_ file: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(file.path)|\(size)|\(Int(modified.timeIntervalSince1970))"
    }
}
