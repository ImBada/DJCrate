import Foundation

/// 스냅샷 작업은 차례로 실행하고, 합쳐서 대기한 호출도 자기 작업이 끝날 때 깨운다.
@MainActor
final class SnapshotRequestQueue {
    private struct Pending {
        var force: Bool
        var quiet: Bool
        var operation: @MainActor (Bool, Bool) async -> Void
        var waiters: [CheckedContinuation<Void, Never>]
    }

    private(set) var isRunning = false
    var waitingCount: Int { pending?.waiters.count ?? 0 }
    private var pending: Pending?

    func run(force: Bool, quiet: Bool, operation: @escaping @MainActor (Bool, Bool) async -> Void) async {
        if isRunning {
            await withCheckedContinuation { continuation in
                if var queued = pending {
                    queued.force = queued.force || force
                    queued.quiet = queued.quiet && quiet
                    queued.operation = operation
                    queued.waiters.append(continuation)
                    pending = queued
                } else {
                    pending = Pending(force: force, quiet: quiet, operation: operation, waiters: [continuation])
                }
            }
            return
        }

        isRunning = true
        await operation(force, quiet)
        while let queued = pending {
            pending = nil
            await queued.operation(queued.force, queued.quiet)
            for waiter in queued.waiters { waiter.resume() }
        }
        isRunning = false
    }
}
