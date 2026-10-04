@testable import DJCrate
import AppKit
import DJCDomain
import SwiftUI
import Testing

/// 키 제안 줄(#198): 넓으면 그리드 제안처럼 한 줄, 좁은 인스펙터(최소 300pt)나 큰 글자 배율에서는 문구가 줄을 바꾸고 버튼이 내려가며 칸 밖으로 넘치지 않는다.
@MainActor
@Suite("키 제안 줄 배치")
struct KeySuggestionRowTests {
    /// 인스펙터 최소 폭 300pt에서 폼 가장자리를 뺀 안쪽 폭
    static let narrow = 240.0

    private struct Host: View {
        var label = "DJCrate 제안: 음원 태그 키 12B"
        var dismissed = false
        var scale = 1.0
        var body: some View {
            KeySuggestionRow(label: label, isDismissed: dismissed, applyHelp: "", apply: {}, dismiss: {}, restore: {})
                .environment(\.textScale, scale)
        }
    }

    private func size(_ host: Host, width: Double) -> CGSize {
        NSHostingController(rootView: host).sizeThatFits(in: CGSize(width: width, height: 1000))
    }

    @Test func 넓으면_한_줄이다() {
        let single = size(Host(), width: 800)
        #expect(single.height < 30, "한 줄 높이: \(single.height)")
        #expect(single.width <= 800)
    }

    @Test(arguments: TextScale.steps)
    func 좁은_폭과_큰_글자_배율에서도_칸_밖으로_넘치지_않는다(scale: Double) {
        let fitted = size(Host(scale: scale), width: Self.narrow)
        #expect(fitted.width <= Self.narrow + 0.5, "배율 \(scale): 폭 \(fitted.width)")
    }

    @Test(arguments: [
        "DJCrate 제안: 음원 태그 키 12B", "DJCrate suggests: audio tag key 12B", "DJCrate suggests: estimated key 12B",
        "DJCrateの候補：音源タグのキー 12B", "DJCrateの候補：推定キー 12B",
    ])
    func 세_언어의_실제_문구가_가장_큰_배율의_최소_폭_인스펙터에서도_넘치지_않는다(label: String) {
        let fitted = size(Host(label: label, scale: 1.5), width: Self.narrow)
        #expect(fitted.width <= Self.narrow + 0.5, "\(label): 폭 \(fitted.width)")
    }

    @Test func 긴_영어_문구도_줄을_바꿔_칸_안에_둔다() {
        let longLabel = "DJCrate suggests: audio tag key 12B, which differs from the estimated key shown in the deck"
        let fitted = size(Host(label: longLabel, scale: 1.5), width: Self.narrow)
        #expect(fitted.width <= Self.narrow + 0.5, "폭 \(fitted.width)")
        #expect(fitted.height > size(Host(), width: 800).height * 2, "문구가 여러 줄로 나뉘고 버튼은 그 아래로 내려간다")
    }

    @Test func 좁으면_버튼이_문구_아래로_내려가_높이가_늘어난다() {
        let wide = size(Host(scale: 1.5), width: 800)
        let narrow = size(Host(scale: 1.5), width: Self.narrow)
        #expect(narrow.height > wide.height)
    }

    @Test func 무시한_뒤에는_다시_보기_단추_하나만_보인다() {
        let dismissed = size(Host(dismissed: true), width: Self.narrow)
        #expect(dismissed.height < size(Host(), width: Self.narrow).height)
        #expect(dismissed.width <= Self.narrow + 0.5)
    }
}
