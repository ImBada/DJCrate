import AppKit
import SwiftUI

/// 이 자리의 AppKit 뷰를 알려 준다(떼어 둔 화면 안에서도 창 좌표로 마우스 위치를 확인하려고).
struct HitProbe: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        onView(view)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
