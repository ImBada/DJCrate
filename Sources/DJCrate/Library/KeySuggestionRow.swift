import SwiftUI

/// 태그 인스펙터의 키 제안 줄(#198). 덱의 그리드 제안 줄처럼 "DJCrate 제안: 추정 키 8B [제안 키 적용] [무시]"로 보이고,
/// 무시한 뒤에는 작은 "제안 다시 보기"만 남는다. 좁은 인스펙터(최소 300pt)나 큰 글자 배율에서 문구가 칸을 넘지 않도록
/// 한 줄이 들어가지 않으면 문구는 줄을 바꾸고 버튼은 그 아래로 내려간다(`FlowLayout`은 칩을 줄이지 않아 문구를 넣지 않는다).
struct KeySuggestionRow: View {
    @Environment(\.textScale) private var textScale
    let label: String
    let isDismissed: Bool
    let applyHelp: String
    let apply: () -> Void
    let dismiss: () -> Void
    let restore: () -> Void

    var body: some View {
        Group {
            if isDismissed {
                Button(.ui("제안 다시 보기"), action: restore)
                    .buttonStyle(.link)
                    .help(.ui("무시했던 키 제안을 다시 보이게 합니다"))
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        icon
                        Text(label).lineLimit(1)
                        applyButton
                        dismissButton
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            icon
                            Text(label).fixedSize(horizontal: false, vertical: true)
                        }
                        FlowLayout(spacing: 8) {
                            applyButton
                            dismissButton
                        }
                    }
                }
            }
        }
        .font(.scaled(.caption, textScale))
        .controlSize(ControlSize.small.scaled(textScale))
    }

    private var icon: some View {
        Image(systemName: "wand.and.stars").foregroundStyle(UIColors.suggestion.color)
    }

    private var applyButton: some View {
        Button(.ui("제안 키 적용"), action: apply).help(applyHelp)
    }

    private var dismissButton: some View {
        Button(.ui("무시"), action: dismiss).help(.ui("이 곡에서는 제안을 더 보이지 않습니다"))
    }
}
