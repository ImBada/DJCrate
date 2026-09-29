@testable import DJCrate
import AppKit
import DJCTestSupport
import SwiftUI
import Testing

/// 재생 중 덱 머리 글자(남은 시간·재생 위치)는 초당 15번 바뀐다. 글자가 바뀔 때마다 덱 전체의 크기를
/// 다시 재면(`ScrollView` 재측정) 메인 스레드가 그만큼 일한다(#139). 글자 자리는 크기가 정해져 있어야 한다.
@MainActor
struct DeckHeaderLayoutTests {
    /// 자식 크기를 물어 오는 횟수를 센다(바깥 레이아웃이 자식 때문에 다시 계산됐는지 보는 표지).
    struct CountingLayout: Layout {
        final class Counter { var sizeCalls = 0 }
        let counter: Counter
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            counter.sizeCalls += 1
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }

    /// 창에 올린 호스팅 뷰. 바깥 레이아웃(`CountingLayout`)의 크기 요청 횟수를 센다.
    private func host<Content: View>(_ content: Content, counter: CountingLayout.Counter) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: CountingLayout(counter: counter) { content }.padding(20))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        return (window, view)
    }

    private func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(30))
        view.layoutSubtreeIfNeeded()
    }

    /// 재생 위치가 바뀔 때마다 바깥 크기 요청이 몇 번 더 왔는지(`step`번 바꾼다)
    private func extraSizeCalls<Content: View>(_ content: (DeckModel) -> Content, steps: Int = 20) async throws -> (baseline: Int, extra: Int) {
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()))
        deck.duration = 200
        let counter = CountingLayout.Counter()
        let (window, view) = host(content(deck), counter: counter)
        defer { window.close() }
        try await settle(view)
        // 처음 한 번 바뀔 때는 SwiftUI가 뷰 그래프를 마저 만드느라 한 번 더 잰다.
        deck.displayTime = 0.5
        try await settle(view)
        let baseline = counter.sizeCalls
        for step in 1...steps {
            deck.displayTime = 1 + Double(step) * 0.37
            try await settle(view)
        }
        return (baseline, counter.sizeCalls - baseline)
    }

    @Test func 글자_길이가_바뀌면_바깥_크기를_다시_잰다_기준_시험() async throws {
        // 이 시험 도구가 바깥 레이아웃의 재계산을 실제로 잡는지 확인한다(길이가 바뀌는 글자는 바깥 크기가 바뀐다).
        struct Growing: View {
            let deck: DeckModel
            var body: some View { Text(verbatim: String(repeating: "0", count: max(1, Int(deck.displayTime)))) }
        }
        let result = try await extraSizeCalls({ Growing(deck: $0) }, steps: 5)
        #expect(result.extra > 0)
    }

    @Test func 재생_위치_글자가_바뀌어도_바깥_크기를_다시_재지_않는다() async throws {
        let result = try await extraSizeCalls { DeckHeaderTime(deck: $0) }
        #expect(result.baseline > 0)
        #expect(result.extra == 0)
    }
}
