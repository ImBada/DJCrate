@testable import DJCrate
import Testing

@Suite("USB 동기화 창 닫기")
@MainActor
struct UsbSyncCloseTests {
    /// 닫기는 확인 창·쓰기를 기다리는 동안 다시 불릴 수 있다. 첫 닫기가 끝나기 전 두 번째 닫기는 아무것도 하지 않는다.
    @Test func 닫는_중에_다시_닫으면_들어가지_않는다() {
        let model = UsbSyncModel(volumeKey: "synthetic")
        #expect(model.beginClosing())
        #expect(!model.beginClosing())
        model.endClosing()
        #expect(model.beginClosing())
    }
}
