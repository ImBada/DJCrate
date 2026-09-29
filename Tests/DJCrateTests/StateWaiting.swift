import Foundation

/// 시험이 걸린 시간이 아니라 상태로 판정하게 하는 기다리기(#153·#154).
/// `condition`이 참이 되면 true를 돌려준다. 참이 될 수 없다고 이미 드러난 상태(`giveUp`, 예: 작업이 조건 없이 끝남)가 되면 기다리지 않고 false로 돌아온다.
/// `safetyNet`은 판정이 영영 오지 않는 잘못된 구현에서 시험이 멈춰 있지 않게 하는 안전망일 뿐이다. 통과하는 경로에서 만료되지 않게
/// (다른 `@MainActor` 시험이 메인 액터를 나눠 써서 시험 하나가 80~190초 밀린 부하 실험보다 길게) 넉넉히 잡는다.
@MainActor
func waitForState(safetyNet: Duration = .seconds(300), giveUp: () -> Bool = { false },
                  until condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + safetyNet
    while !condition() {
        if giveUp() || ContinuousClock.now >= deadline { return condition() }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
