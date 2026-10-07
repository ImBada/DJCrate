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
        Self.key(file).flatMap { values[$0] }
    }

    func store(_ loudness: Loudness, for file: URL) {
        guard let key = Self.key(file), values[key] != loudness else { return }
        values[key] = loudness
        scheduleSave()
    }

    /// 지금 라이브러리에 없는 파일의 항목(옮기거나 다시 인코딩해 쌓인 옛 키 포함)을 지운다(#217). 지운 개수를 돌려준다.
    /// - 라이브러리 경로(`keeping`)가 비어 있으면 읽기 실패와 구분할 수 없어 아무것도 지우지 않는다.
    /// - 파일이 있으면 지금 키(크기·수정 시각)만, 못 읽는 곡(꺼 둔 외장 드라이브 등)은 그 경로의 항목을 그대로 둔다.
    /// - 파일 상태를 읽는 일은 메인 스레드 밖에서 하고, 그동안 새로 저장된 항목은 건드리지 않는다.
    @discardableResult
    func prune(keeping paths: Set<String>) async -> Int {
        guard !paths.isEmpty else { return 0 }
        let stored = Array(values.keys)
        let stale = await Task.detached(priority: .background) { () -> [String] in
            var currentKeys: [String: String?] = [:]
            for path in paths { currentKeys[path] = Self.key(URL(filePath: path)) }
            return stored.filter { key in
                guard let path = Self.path(of: key), let current = currentKeys[path] else { return true }
                guard let current else { return false }
                return current != key
            }
        }.value
        let removable = stale.filter { values[$0] != nil }
        guard !removable.isEmpty else { return 0 }
        removable.forEach { values[$0] = nil }
        // 기다리던 저장이 옛 값을 다시 쓰지 않도록 새 값으로 다시 예약한다
        scheduleSave()
        return removable.count
    }

    /// 키 `경로|크기|수정 시각`의 경로(경로에 `|`가 있어도 뒤 두 칸만 뗀다)
    nonisolated private static func path(of key: String) -> String? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        return parts.dropLast(2).joined(separator: "|")
    }

    private func scheduleSave() {
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
    nonisolated private static func key(_ file: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(file.path)|\(size)|\(Int(modified.timeIntervalSince1970))"
    }
}
