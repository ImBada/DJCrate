import AppKit
import DJCDomain

/// 큐 이름·ID는 그림에 필요 없다. 위치만 비교해 이름 편집 때 파형을 다시 만들지 않는다.
struct PreviewCueMark: Hashable, Sendable {
    let time: Double
    let end: Double?
    let hot: Bool

    init(_ cue: EditableCue) {
        time = cue.time; end = cue.loop?.end
        if case .hot = cue.kind { hot = true } else { hot = false }
    }

    static func current(saved: [Cue], draft: [Self]?) -> [Self] {
        // rekordbox 자동 큐도 메모리 큐로 보인다(#145, 덱 목록과 같다).
        draft ?? saved.compactMap(EditableCue.init).map(Self.init)
    }

    struct Shape {
        let rect: CGRect
        let color: UIColors
    }

    /// 눈금 크기(pt). 칸 크기대로 그리되 기본 칸(파형 자리 154×20pt)에서도 알아볼 수 있게 최소 크기를 둔다(#121).
    static let tickWidth = 2.0
    static let loopThickness = 2.0
    static func tickHeight(for height: Double) -> Double { min(12, max(6, (height * 0.4).rounded())) }

    /// 칸의 파형 자리(pt) 기준. 핫큐는 위쪽, 메모리 큐는 아래쪽 눈금이고 루프는 눈금 안쪽 끝에서 오른쪽으로 짧은 막대다.
    static func shapes(_ marks: [Self], duration: Double, width: Double, height: Double) -> [Shape] {
        guard duration.isFinite, duration > 0, width >= tickWidth * 2, height >= 10 else { return [] }
        let tick = tickHeight(for: height)
        var shapes: [Shape] = []
        for mark in marks where mark.time.isFinite && mark.time >= 0 && mark.time <= duration {
            let x = min(width - tickWidth, floor(mark.time / duration * width))
            let y = mark.hot ? 1 : height - 1 - tick
            shapes.append(Shape(rect: CGRect(x: x, y: y, width: tickWidth, height: tick), color: mark.hot ? .hot : .memory))
            if let end = mark.end, end.isFinite, end > mark.time {
                // 긴 루프가 파형을 덮지 않도록 짧은 막대로만 표시한다.
                let length = min(width - x, min(24, max(3, (min(end, duration) - mark.time) / duration * width)))
                shapes.append(Shape(rect: CGRect(x: x, y: mark.hot ? y + tick + 1 : y - 1 - loopThickness, width: length, height: loopThickness),
                                    color: .loop))
            }
        }
        return shapes
    }
}
