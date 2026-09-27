@testable import DJCrate
import Testing

private actor SnapshotPauseGate {
    private var paused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        for waiter in pauseWaiters { waiter.resume() }
        pauseWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@MainActor
@Suite("스냅샷 갱신 대기")
struct SnapshotRequestQueueTests {
    @Test func 겹친_두번째_호출도_자신의_읽기가_끝나야_반환한다() async {
        let queue = SnapshotRequestQueue()
        let gate = SnapshotPauseGate()
        var completed: [String] = []
        let first = Task {
            await queue.run(force: false, quiet: true) { _, _ in
                await gate.pause()
                completed.append("첫 읽기")
            }
        }
        await gate.waitUntilPaused()

        let second = Task {
            await queue.run(force: true, quiet: false) { force, quiet in
                #expect(force && !quiet)
                completed.append("두번째 읽기")
            }
            completed.append("두번째 호출 반환")
        }
        for _ in 0..<100 where queue.waitingCount == 0 { await Task.yield() }
        #expect(queue.waitingCount == 1)
        #expect(completed.isEmpty)
        await gate.release()
        await first.value
        await second.value
        #expect(completed == ["첫 읽기", "두번째 읽기", "두번째 호출 반환"])
    }
}
