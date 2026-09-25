import SwiftUI

/// 창 아래에 잠깐 뜨는 알림. rekordbox 반영이 끝났을 때 결과와 되돌리기를 보여 준다.
struct AppToast: Identifiable, Equatable {
    enum Kind { case success, warning, failure }

    let id = UUID()
    var kind: Kind = .success
    var title: String
    var detail: String?
    /// 되돌리기 버튼(이번 쓰기 직전 백업)
    var undoBackup: URL?

    /// 떠 있는 시간(실패·경고는 더 오래)
    var duration: Double {
        switch kind {
        case .success: undoBackup == nil ? 3.5 : 7
        case .warning: 10
        case .failure: 14
        }
    }
}

/// 토스트 모양: 둥근 카드, 아이콘 + 제목 + 설명 + (되돌리기) + 닫기. 마우스를 올려 두면 사라지지 않는다.
struct AppToastView: View {
    let toast: AppToast
    var onUndo: (() -> Void)?
    var onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: toast.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.system(size: 13, weight: .semibold))
                if let detail = toast.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            if let onUndo, toast.undoBackup != nil {
                Button("되돌리기", action: onUndo)
                    .controlSize(.small)
                    .help("rekordbox 라이브러리를 이번 쓰기 직전 백업으로 되돌립니다(rekordbox가 꺼져 있어야 합니다)")
            }
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("알림 닫기")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.35)))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .onHover { hovering = $0 }
        .task(id: toast.id) {
            // 올려 둔 동안은 기다린다.
            var remaining = toast.duration
            while remaining > 0 {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                if !hovering { remaining -= 0.25 }
            }
            onClose()
        }
    }

    private var icon: String {
        switch toast.kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch toast.kind {
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}

/// rekordbox에 쓰는 동안 창 전체를 덮어 다른 조작을 막는다.
struct WritingOverlay: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
            VStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text(text).font(.system(size: 13, weight: .semibold))
                Text("끝날 때까지 rekordbox를 켜지 마세요").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        }
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .combine)
    }
}
