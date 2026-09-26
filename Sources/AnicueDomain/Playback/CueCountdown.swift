import Foundation

/// 재생 위치에서 다음 메모리 큐까지 남은 박(파형 위 "−16 Beats").
public enum CueCountdown {
    /// 64박 넘으면 마디.박, 그리드가 없으면 초. 다음 메모리 큐가 없으면 nil.
    public static func text(to cues: [EditableCue], from time: Double, grid: BeatGrid?) -> String? {
        guard let next = cues.filter({ $0.kind == .memory && $0.time > time + 0.005 }).min(by: { $0.time < $1.time }) else { return nil }
        guard let grid, !grid.beats.isEmpty else { return String(format: "−%.1fs", next.time - time) }
        // 지금 박 = 플레이헤드 이하 마지막 박, 큐 박 = 큐 지점 이상 첫 박(±5ms)
        let current = grid.firstIndex(atOrAfter: time + 0.001) - 1
        let target = grid.firstIndex(atOrAfter: next.time - 0.005)
        let beats = max(target - current, 0)
        guard beats > 0 else { return nil }
        return beats <= 64 ? "−\(beats) Beats" : "−\(beats / 4).\(beats % 4) Bars"
    }
}
