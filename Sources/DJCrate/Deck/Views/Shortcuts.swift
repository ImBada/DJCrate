import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import SwiftUI
import AppKit

/// 도움말 메뉴와 같은 단축키 창을 연다.
struct ShortcutsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HelpLink { openWindow(id: "shortcuts") }
            .help("단축키")
            .accessibilityLabel("단축키 보기")
    }
}

/// 단축키 목록. 설정에서 바꿨으면 바꾼 표를 동작마다 보인다.
struct ShortcutsList: View {
    var shortcuts = DeckShortcuts.standard
    /// 기본 창은 1배 크기로 표시한다.
    var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            Text("단축키").font(.system(size: 20 * scale, weight: .bold))
            Grid(alignment: .leading, horizontalSpacing: 18 * scale, verticalSpacing: 9 * scale) {
                if shortcuts.isStandard { standardRows } else { customRows }
                row(["⌘", "⇧", "E"], "rekordbox에 반영")
                row(["⌘", "I"], "태그 편집")
                row(["⌘", "O"], "곡 추가")
                row(["⌘", "R"], "새 스냅샷")
                row(["⌘", "1", "/", "2"], "목록 · 태그 시트")
                row(["⌘", "?"], "단축키 창")
            }
            Text("덱 단축키는 설정(⌘,) › 단축키에서 바꿀 수 있습니다.")
                .font(.system(size: 12 * scale))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var standardRows: some View {
        row(["Space"], "재생 / 정지")
        row(["C"], "CUE — 재생 중: 큐로 돌아가 정지 · 멈춤: 큐 지점 설정 · 누르고 있기: 미리 듣기")
        row(["1", "~", "8"], "핫큐 A~H (있으면 이동, 없으면 찍기)")
        row(["Shift", "+", "1", "~", "8"], "그 핫큐 지우기")
        row(["`", "·", "M"], "메모리 큐 찍기 (파형 더블클릭도)")
        row(["Shift", "+", "`", "·", "M"], "이 자리 메모리 큐 지우기")
        row(["Q", "/", "E"], "이전 · 다음 큐로")
        row(["←", "→"], "선택한 큐 1박 이동")
        row(["⌫"], "선택한 큐 지우기")
        row(["L"], "루프 걸기 · 나가기 (반복 중 빈 핫큐 = 루프 핫큐로 저장)")
        row(["[", "/", "]"], "루프 길이 ½ · ×2")
        row(["T"], "탭 템포")
        row(["휠", "·", "+", "/", "−"], "파형 확대 · 축소 (가로 스크롤: 이동)")
    }

    /// 바꾼 표: 키가 있는 동작마다 한 줄(키 이름은 구분 기호와 섞이지 않게 키캡으로만 쓴다)
    @ViewBuilder private var customRows: some View {
        ForEach(DeckAction.allCases.filter { !shortcuts.keys(for: $0).isEmpty }, id: \.self) { action in
            GridRow {
                HStack(spacing: 4 * scale) {
                    ForEach(Array(shortcuts.keys(for: action).enumerated()), id: \.offset) { index, key in
                        if index > 0 { separator("·") }
                        keycap(KeyLabel.name(for: key))
                    }
                }
                description(action.title + (action.shiftTitle.map { " (\($0))" } ?? ""))
            }
        }
        row(["휠"], "파형 확대 · 축소 (가로 스크롤: 이동)")
    }

    /// 구분 기호(~ / · +)는 키캡 없이 글자로만 쓴다.
    private static let separators: Set<String> = ["~", "/", "·", "+"]

    private func row(_ keys: [String], _ text: String) -> some View {
        GridRow {
            HStack(spacing: 4 * scale) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    if Self.separators.contains(key) { separator(key) } else { keycap(key) }
                }
            }
            description(text)
        }
    }

    private func separator(_ text: String) -> some View {
        Text(text).font(.system(size: 14 * scale, weight: .medium)).foregroundStyle(.secondary)
    }

    private func keycap(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 14 * scale, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7 * scale).padding(.vertical, 3 * scale)
            .frame(minWidth: 24 * scale)
            .background(RoundedRectangle(cornerRadius: 5 * scale).fill(Color.primary.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 5 * scale).strokeBorder(Color.primary.opacity(0.25)))
    }

    private func description(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15 * scale))
            .frame(maxWidth: 520 * scale, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 단축키 창도 주 창이 될 수 있다. 이 창의 키를 덱 조작으로 보내지 않도록 구분한다.
@MainActor
enum ShortcutsWindow {
    static weak var current: NSWindow?

    struct Tracker: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { TrackingView() }
        func updateNSView(_ nsView: NSView, context: Context) {}

        private final class TrackingView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let window { ShortcutsWindow.current = window }
            }
        }
    }
}

extension DeckShortcuts {
    /// 키를 지웠으면 기본 키 대신 미지정으로 안내한다.
    func keyLabel(for action: DeckAction) -> String {
        let keys = keys(for: action).map(KeyLabel.name(for:))
        return keys.isEmpty ? "미지정" : keys.joined(separator: " · ")
    }
}
