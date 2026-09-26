import RekordboxKit
import AnicueAnalysis
import AnicueDomain
import AnicueStorage
import SwiftUI

/// 단축키 안내(? 버튼을 누를 때만 보인다).
struct ShortcutsButton: View {
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "questionmark.circle") }
            .buttonStyle(.borderless)
            .help("단축키")
            .accessibilityLabel("단축키 보기")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                ShortcutsList(scale: 1.1).padding(18)
            }
    }
}

/// 단축키 목록(? 버튼 팝오버). 키는 키캡 모양으로 크게 쓴다.
struct ShortcutsList: View {
    /// 1 = 팝오버, ⌘ 안내는 더 크게
    var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            Text("단축키").font(.system(size: 20 * scale, weight: .bold))
            Grid(alignment: .leading, horizontalSpacing: 18 * scale, verticalSpacing: 9 * scale) {
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
                row(["⌘", "⇧", "E"], "rekordbox에 반영")
                row(["⌘", "I"], "태그 편집")
            }
        }
    }

    /// 구분 기호(~ / · +)는 키캡 없이 글자로만 쓴다.
    private static let separators: Set<String> = ["~", "/", "·", "+"]

    private func row(_ keys: [String], _ text: String) -> some View {
        GridRow {
            HStack(spacing: 4 * scale) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    if Self.separators.contains(key) {
                        Text(key).font(.system(size: 14 * scale, weight: .medium)).foregroundStyle(.secondary)
                    } else {
                        Text(key)
                            .font(.system(size: 14 * scale, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 7 * scale).padding(.vertical, 3 * scale)
                            .frame(minWidth: 24 * scale)
                            .background(RoundedRectangle(cornerRadius: 5 * scale).fill(Color.primary.opacity(0.10)))
                            .overlay(RoundedRectangle(cornerRadius: 5 * scale).strokeBorder(Color.primary.opacity(0.25)))
                    }
                }
            }
            Text(text)
                .font(.system(size: 15 * scale))
                .frame(maxWidth: 520 * scale, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 큐 목록
