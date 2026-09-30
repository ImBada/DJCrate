import Foundation

/// 스냅샷 작업은 차례로 실행하고, 합쳐서 대기한 호출도 자기 작업이 끝날 때 깨운다.
@MainActor
final class SnapshotRequestQueue {
    private struct Pending {
        var force: Bool
        var quiet: Bool
        let refreshITunes: Bool
        let synchronizingDrafts: Bool
        var operation: @MainActor (Bool, Bool) async -> Task<Void, Never>?
        var waiters: [CheckedContinuation<Task<Void, Never>?, Never>]
    }

    private(set) var isRunning = false
    var waitingCount: Int { pending.reduce(0) { $0 + $1.waiters.count } }
    private var pending: [Pending] = []

    func run(force: Bool, quiet: Bool, operation: @escaping @MainActor (Bool, Bool) async -> Void) async {
        await runWithFollowUp(force: force, quiet: quiet, refreshITunes: false) { force, quiet in
            await operation(force, quiet)
            return nil
        }
    }

    /// DB 작업만 직렬화한다. 후속 Music 작업은 대기열 밖에서 기다리되 병합한 호출도 완료를 기다린다.
    func runWithFollowUp(force: Bool, quiet: Bool, refreshITunes: Bool, synchronizingDrafts: Bool = false,
                         operation: @escaping @MainActor (Bool, Bool) async -> Task<Void, Never>?) async {
        let followUp = await runWork(force: force, quiet: quiet, refreshITunes: refreshITunes, synchronizingDrafts: synchronizingDrafts, operation: operation)
        await followUp?.value
    }

    private func runWork(force: Bool, quiet: Bool, refreshITunes: Bool, synchronizingDrafts: Bool,
                         operation: @escaping @MainActor (Bool, Bool) async -> Task<Void, Never>?) async -> Task<Void, Never>? {
        if isRunning {
            return await withCheckedContinuation { continuation in
                if let last = pending.indices.last, pending[last].refreshITunes == refreshITunes,
                   pending[last].synchronizingDrafts == synchronizingDrafts {
                    var queued = pending[last]
                    queued.force = queued.force || force
                    queued.quiet = queued.quiet && quiet
                    queued.operation = operation
                    queued.waiters.append(continuation)
                    pending[last] = queued
                } else {
                    pending.append(Pending(force: force, quiet: quiet, refreshITunes: refreshITunes, synchronizingDrafts: synchronizingDrafts,
                                           operation: operation, waiters: [continuation]))
                }
            }
        }

        isRunning = true
        let followUp = await operation(force, quiet)
        while !pending.isEmpty {
            let queued = pending.removeFirst()
            let queuedFollowUp = await queued.operation(queued.force, queued.quiet)
            for waiter in queued.waiters { waiter.resume(returning: queuedFollowUp) }
        }
        isRunning = false
        return followUp
    }
}
