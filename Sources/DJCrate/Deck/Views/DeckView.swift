import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import SwiftUI

/// A안 위쪽 덱: 커버·정보 | 확대/개요 파형 + 컨트롤 | 큐 목록.
/// 높이는 내용에 맞춰 정해지고(잘리지 않음), 파형 높이만 사용자가 조절한다.
/// 창이 좁으면 커버 열을 작은 헤더로 접고, 컨트롤 줄은 줄바꿈한다.
struct DeckView: View {
    @Bindable var deck: DeckModel
    var waveformHeight: Double
    @State private var width: CGFloat = 1400
    @State private var middleHeight: CGFloat = 320

    private var compact: Bool { width < 1150 }
    private var cueListWidth: CGFloat { width < 1400 ? 250 : 290 }

    var body: some View {
        if let row = deck.row {
            HStack(alignment: .top, spacing: 16) {
                if !compact {
                    DeckInfoColumn(deck: deck, row: row)
                        .frame(width: 210)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if compact { CompactInfo(deck: deck, row: row) }
                    Group { if PerfProbe.hidden.contains("zoom") { EmptyView() } else { ZoomWaveformView(deck: deck) } }
                        .frame(height: waveformHeight)
                        .overlay(alignment: .center) { loadingOverlay }
                        .overlay(alignment: .top) {
                            if let toast = deck.toast {
                                Label(toast, systemImage: "exclamationmark.circle.fill")
                                    .font(.callout.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(.regularMaterial, in: Capsule())
                                    .padding(.top, 22)
                                    .transition(.opacity)
                                    .allowsHitTesting(false)
                            }
                        }
                        .animation(.easeOut(duration: 0.15), value: deck.toast)
                        // 그리드 없는 곡 안내는 파형 위에 띄운다(줄로 끼워 넣으면 덱 높이가 바뀌어 아래 목록이 밀렸다)
                        .overlay(alignment: .bottomLeading) {
                            if deck.needsGrid && !deck.gridEditing {
                                GridSuggestionRow(deck: deck, badge: true)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(.regularMaterial, in: Capsule())
                                    .padding(8)
                                    .transition(.opacity)
                            }
                        }
                        .animation(.easeOut(duration: 0.15), value: deck.needsGrid)
                        .environment(\.colorScheme, .dark)
                    Group { if PerfProbe.hidden.contains("overview") { EmptyView() } else { OverviewWaveformView(deck: deck) } }
                        .frame(height: 86)
                    TransportBar(deck: deck)
                    AudioBar(deck: deck)
                    if deck.gridEditing { GridSuggestionRow(deck: deck) }
                    if deck.gridEditing { GridEditorBar(deck: deck) }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { middleHeight = $0 }
                CueListView(deck: deck)
                    .frame(width: cueListWidth, height: max(middleHeight, 220))
            }
            .padding(14)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // 단축키는 창 전체에서 KeyRouter가 받는다(포커스 위치와 무관).
        } else {
            ContentUnavailableView("곡을 선택하세요", systemImage: "music.note",
                                   description: Text("아래 목록에서 곡을 고르면 파형과 큐가 여기 뜹니다."))
                .frame(height: 220)
        }
    }

    @ViewBuilder private var loadingOverlay: some View {
        if deck.row?.track.isStreaming == true {
            Text("스트리밍 곡은 파형·재생·분석을 할 수 없습니다").font(.callout).foregroundStyle(.secondary)
        } else if let error = deck.waveformError {
            Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(UIColors.warning.color)
        } else if deck.waveform == nil {
            ProgressView().controlSize(.small)
        }
    }

}

/// 좁은 창: 커버 열 대신 한 줄 헤더.
struct CompactInfo: View {
    let deck: DeckModel
    let row: TrackRow

    var body: some View {
        HStack(spacing: 10) {
            CoverView(image: deck.artwork, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.headline).lineLimit(1)
                Text([row.artist, row.genre].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(row.comment.isEmpty ? "(빈 코멘트)" : row.comment)
                .font(.caption.monospaced()).lineLimit(1)
                .foregroundStyle(row.comment.isEmpty ? .tertiary : .secondary)
        }
    }
}

// MARK: - 커버·정보

struct DeckInfoColumn: View {
    let deck: DeckModel
    let row: TrackRow

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            CoverView(image: deck.artwork, size: 150)
            Text(row.title).font(.headline).lineLimit(2).textSelection(.enabled)
            Text(row.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if let genre = row.track.genre, !genre.trimmingCharacters(in: .whitespaces).isEmpty {
                Label(genre, systemImage: "guitars").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) {
                if let bpm = row.track.bpm { Text(String(format: "%.1f BPM", bpm)) }
                if let key = row.track.key { Text(key) }
                Text(Double(row.track.lengthSeconds).clockText.dropLast(3))
                if row.playCount > 0 { Text("재생 \(row.playCount)") }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if let path = row.track.analysisDataPath, !path.isEmpty, !row.track.isStreaming,
               !RekordboxShare.hasWaveformAnalysis(path) {
                Label("rekordbox 분석 전 · 파형 없음", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(UIColors.warning.color)
                    .help("rekordbox가 이 곡을 아직 분석하지 않았습니다(파형 파일 없음). rekordbox에서 트랙 분석을 먼저 해야 그리드를 쓸 수 있습니다")
            }
            // 코멘트는 적힌 그대로(태그로 나누지 않는다)
            Text(row.comment.isEmpty ? "(빈 코멘트)" : row.comment)
                .font(.callout)
                .foregroundStyle(row.comment.isEmpty ? .tertiary : .primary)
                .lineLimit(3)
                .textSelection(.enabled)
                .help(row.comment)
        }
        // 글자 길이와 상관없이 칸 가운데 세로축에 맞춘다.
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

struct CoverView: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(UIColors.subtleFill)
                    Image(systemName: "music.note").font(.system(size: size * 0.28)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 8 : 3))
        .accessibilityLabel("앨범 커버")
    }
}

// MARK: - 트랜스포트
