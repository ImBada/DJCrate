import AppKit

/// 같은 글자·글꼴의 높이는 창 폭이 바뀌어도 다시 재지 않는다.
@MainActor
struct TrackTextHeight {
    private var text: String?
    private var font: NSFont?
    private var height: CGFloat?

    mutating func value(text: String, font: NSFont?, measure: () -> CGFloat) -> CGFloat {
        if self.text == text, self.font == font, let height { return height }
        let height = measure()
        self.text = text
        self.font = font
        self.height = height
        return height
    }

    mutating func invalidate() { height = nil }
}
