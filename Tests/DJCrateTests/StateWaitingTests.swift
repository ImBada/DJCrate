import Foundation
import Synchronization
import Testing

/// 시험이 시간이 아니라 상태로 판정하게 하는 기다리기 도우미(#154).
@MainActor
@Suite("상태 기다리기")
struct StateWaitingTests {
    @Test func 조건이_이미_참이면_바로_참을_돌려준다() async {
        #expect(await waitForState(until: { true }))
    }

    @Test func 조건이_나중에_참이_되면_기다렸다가_참을_돌려준다() async {
        let flag = Mutex(false)
        Task { try? await Task.sleep(for: .milliseconds(50)); flag.withLock { $0 = true } }
        #expect(await waitForState(until: { flag.withLock { $0 } }))
    }

    /// 더 기다려도 참이 될 수 없다고 드러나면 안전망 시간을 다 쓰지 않고 거짓으로 돌아온다.
    @Test func 포기_조건이_참이면_안전망을_기다리지_않고_거짓을_돌려준다() async {
        let clock = ContinuousClock()
        let start = clock.now
        let result = await waitForState(safetyNet: .seconds(60), giveUp: { true }, until: { false })
        #expect(!result)
        #expect(start.duration(to: clock.now) < .seconds(30))
    }

    @Test func 포기_조건이_늦게_참이_되어도_그때_거짓을_돌려준다() async {
        let gaveUp = Mutex(false)
        Task { try? await Task.sleep(for: .milliseconds(50)); gaveUp.withLock { $0 = true } }
        let clock = ContinuousClock()
        let start = clock.now
        #expect(!(await waitForState(safetyNet: .seconds(60), giveUp: { gaveUp.withLock { $0 } }, until: { false })))
        #expect(start.duration(to: clock.now) < .seconds(30))
    }

    /// 판정이 영영 오지 않는 잘못된 구현에서도 시험이 멈춰 있지 않게 안전망 시간이 지나면 거짓을 돌려준다.
    @Test func 안전망_시간이_지나면_거짓을_돌려준다() async {
        #expect(!(await waitForState(safetyNet: .milliseconds(100), until: { false })))
    }
}
