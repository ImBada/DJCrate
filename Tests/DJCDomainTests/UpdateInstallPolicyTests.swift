import DJCDomain
import Testing

/// 앱 업데이트(#59): rekordbox·USB에 쓰는 동안에는 설치·다시 켜기를 미룬다.
@Suite("업데이트 설치 판정")
struct UpdateInstallPolicyTests {
    @Test func 아무것도_쓰지_않으면_바로_설치한다() {
        #expect(UpdateInstallPolicy.decision(for: .idle) == .proceed)
        #expect(UpdateInstallPolicy.decision(for: .idle).waitMessage == nil)
    }

    @Test func rekordbox에_쓰는_중이면_미룬다() {
        let decision = UpdateInstallPolicy.decision(for: AppWriteActivity(writingRekordbox: true, writingUsb: false))
        #expect(decision == .waitForRekordbox)
        #expect(decision.waitMessage != nil)
    }

    @Test func USB에_쓰는_중이면_미룬다() {
        let decision = UpdateInstallPolicy.decision(for: AppWriteActivity(writingRekordbox: false, writingUsb: true))
        #expect(decision == .waitForUsb)
        #expect(decision.waitMessage != nil)
    }

    @Test func 둘_다_쓰는_중이면_rekordbox_쓰기를_먼저_알린다() {
        #expect(UpdateInstallPolicy.decision(for: AppWriteActivity(writingRekordbox: true, writingUsb: true)) == .waitForRekordbox)
    }
}
