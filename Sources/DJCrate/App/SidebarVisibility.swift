import SwiftUI

/// 주 창 사이드바를 보일지 정한다(#119). 표시 상태는 저장해 다음 실행을 같은 모양으로 시작하고,
/// 넉넉하던 본문이 모자라게 줄어들 때만(인스펙터를 열거나 창·열을 좁힐 때) 저절로 접는다.
struct SidebarVisibility {
    /// 자동 접기의 기준이 되는 마지막 본문 폭. 본문을 새로 그린 뒤 아직 재지 않았으면 없다.
    private(set) var baselineWidth: Double?

    static func columns(visible: Bool) -> NavigationSplitViewVisibility { visible ? .all : .detailOnly }

    /// 탐색 열만 숨긴 `.detailOnly`가 닫힌 상태다.
    static func isVisible(_ columns: NavigationSplitViewVisibility) -> Bool { columns != .detailOnly }

    /// 본문 폭을 새로 쟀을 때 사이드바를 접어야 하는지.
    /// 본문을 처음 그릴 때는 100pt 같은 임시 폭이 한 번 오므로 첫 측정은 기준으로만 쓰고,
    /// 창 프레임을 복원하기 전의 기본 크기 폭은 기준으로도 쓰지 않는다.
    mutating func shouldCollapse(detailWidth: Double, windowFrameRestored: Bool) -> Bool {
        guard windowFrameRestored, detailWidth > 0 else { return false }
        defer { baselineWidth = detailWidth }
        guard let baselineWidth else { return false }
        return baselineWidth >= DeckLayout.minimumDetailWidth && detailWidth < DeckLayout.minimumDetailWidth
    }

    /// 본문(덱·목록)이 사라질 때(새 스냅샷을 읽는 동안 등). 다시 그리면 첫 측정부터 기준을 새로 잡는다.
    mutating func reset() { baselineWidth = nil }
}
