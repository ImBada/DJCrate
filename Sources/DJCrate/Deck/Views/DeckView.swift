import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation
import SwiftUI

/// 위쪽 덱: 커버·정보 헤더 / 확대·개요 파형과 컨트롤 | 큐 목록.
/// 높이는 내용에 맞춰 정해지고(잘리지 않음), 파형 높이만 사용자가 조절한다.
/// 커버는 창 폭과 관계없이 위쪽에 두고, 컨트롤 줄은 필요하면 줄바꿈한다.
struct DeckView: View {
    @Environment(\.textScale) private var textScale
    let store: LibraryStore
    @Bindable var deck: DeckModel
    var waveformHeight: Double
    @State private var width: CGFloat = 1400
    @State private var middleHeight: CGFloat = 320

    private var waveGroupHeight: Double {
        max(TextScale.length(190, scale: textScale),
            waveformHeight + 8 + WaveformMetrics(scale: textScale).overviewHeight
                + TextScale.length(28, scale: textScale))
    }
    /// 글자 배율의 절반만큼 넓힌다(큐 이름이 보이게 하되 파형 자리를 너무 빼앗지 않게).
    private var cueListWidth: CGFloat { TextScale.length(width < 1400 ? 250 : 290, scale: 1 + (textScale - 1) / 2) }
    private var leftRailWidth: CGFloat { TextScale.length(66, scale: textScale) }
    private var rightRailWidth: CGFloat { TextScale.length(58, scale: textScale) }

    var body: some View {
        if let row = deck.row {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    DeckInfoHeader(deck: deck, row: row, coverSize: TextScale.length(66, scale: textScale))
                    HStack(alignment: .top, spacing: 8) {
                        DeckSideControls(store: store, deck: deck, availableHeight: waveGroupHeight)
                            .frame(width: leftRailWidth, height: waveGroupHeight)
                        VStack(alignment: .leading, spacing: 8) {
                            Group {
                                if PerfProbe.hidden.contains("zoom") {
                                    EmptyView()
                                } else {
                                    ZoomWaveformView(deck: deck)
                                        .overlay(alignment: .leading) {
                                            ZoomControl(deck: deck, availableHeight: waveformHeight).padding(.leading, 8)
                                        }
                                        .overlay(alignment: .trailing) {
                                            TrackEditButton(deck: deck).padding(.trailing, 8)
                                        }
                                }
                            }
                            .frame(height: waveformHeight)
                            .overlay(alignment: .center) { loadingOverlay }
                            .overlay(alignment: .top) {
                                if let toast = deck.toast {
                                    HStack {
                                        Label(toast.text, systemImage: toast.kind.icon)
                                            .foregroundStyle(toast.kind.tint)
                                            .textSelection(.enabled)
                                        Button { deck.toastTask?.cancel(); deck.toast = nil } label: {
                                            Image(systemName: "xmark")
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(.ui("덱 알림 닫기"))
                                    }
                                    .font(.scaled(.callout, textScale).weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(.regularMaterial, in: Capsule())
                                    .padding(.top, 22)
                                    .transition(.opacity)
                                }
                            }
                            .animation(.easeOut(duration: 0.15), value: deck.toast)
                            .environment(\.colorScheme, .dark)
                            VStack(spacing: 0) {
                                Group { if PerfProbe.hidden.contains("overview") { EmptyView() } else { OverviewWaveformView(deck: deck) } }
                                    .frame(height: WaveformMetrics(scale: textScale).overviewHeight)
                                GridTempoSegments(deck: deck)
                            }
                            .background(Palette.well)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        if !PerfProbe.hidden.contains("meter") {
                            let gainHeight = TextScale.length(44, scale: textScale)
                            let meterHeight = min(TextScale.length(170, scale: textScale),
                                                  max(TextScale.length(100, scale: textScale), waveGroupHeight - TextScale.length(75, scale: textScale)))
                            VStack(spacing: 6) {
                                LevelMeterView(deck: deck, meterHeight: meterHeight)
                                GainControl(deck: deck)
                                    .frame(height: gainHeight)
                            }
                            .frame(width: rightRailWidth, height: waveGroupHeight)
                            .background(Palette.controlRail, in: RoundedRectangle(cornerRadius: 6))
                            .environment(\.colorScheme, .dark)
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        TransportBar(deck: deck)
                        AudioBar(deck: deck)
                    }
                    .padding(.leading, leftRailWidth + 8)
                    .padding(.trailing, PerfProbe.hidden.contains("meter") ? 0 : rightRailWidth + 8)
                    GridEditorBar(deck: deck)
                        .padding(.leading, leftRailWidth + 8)
                        .padding(.trailing, PerfProbe.hidden.contains("meter") ? 0 : rightRailWidth + 8)
                    GridSuggestionRow(deck: deck)
                        .frame(height: TextScale.length(28, scale: textScale))
                        .padding(.leading, leftRailWidth + 8)
                        .padding(.trailing, PerfProbe.hidden.contains("meter") ? 0 : rightRailWidth + 8)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { middleHeight = $0 }
                CueListView(deck: deck)
                    .frame(width: cueListWidth, height: max(middleHeight, 220))
            }
            .padding(Spacing.edge)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // 단축키는 창 전체에서 KeyRouter가 받는다(포커스 위치와 무관).
        } else {
            ContentUnavailableView(.ui("덱에 곡을 불러오세요"), systemImage: "music.note",
                                   description: Text(.ui("아래 목록에서 곡을 더블클릭하거나 여기로 끌어다 놓으면(⌘→도 됩니다) 파형과 큐가 여기 뜹니다.")))
                .frame(height: 220)
        }
    }

    @ViewBuilder private var loadingOverlay: some View {
        if deck.row?.track.isStreaming == true {
            Text(.ui("스트리밍 곡은 파형·재생·분석을 할 수 없습니다")).font(.scaled(.callout, textScale)).foregroundStyle(.secondary)
        } else if let error = deck.waveformError {
            Label(error, systemImage: "exclamationmark.triangle").font(.scaled(.callout, textScale)).foregroundStyle(UIColors.warning.color)
        } else if deck.waveform == nil {
            ProgressView().controlSize(.small)
                .accessibilityLabel(.ui("파형 불러오는 중"))
        }
    }

}

/// 현재 목록의 곡과 재생 위치를 큰 파형 왼쪽에서 조작한다.
private struct DeckSideControls: View {
    @Environment(\.textScale) private var textScale
    let store: LibraryStore
    let deck: DeckModel
    let availableHeight: Double
    @State private var beatStep = 4

    private var playableRows: [TrackRow] { store.displayRows.filter { !$0.track.isStreaming } }

    private func adjacentRow(forward: Bool) -> TrackRow? {
        let rows = playableRows
        guard !rows.isEmpty else { return nil }
        guard let uuid = deck.row?.track.uuid,
              let index = rows.firstIndex(where: { $0.track.uuid == uuid }) else {
            return forward ? rows.first : rows.last
        }
        let next = index + (forward ? 1 : -1)
        return rows.indices.contains(next) ? rows[next] : nil
    }

    private func load(_ row: TrackRow?) {
        guard let row else { return }
        store.selection = [row.id]
        store.loadToDeck(row)
    }

    var body: some View {
        let previous = adjacentRow(forward: false)
        let next = adjacentRow(forward: true)
        let compact = availableHeight < TextScale.length(225, scale: textScale)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { load(previous) } label: {
                    Image(systemName: "backward.end.fill")
                        .frame(width: TextScale.length(24, scale: textScale), height: TextScale.length(24, scale: textScale))
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                    .disabled(previous == nil || !store.writeLockPolicy.allowsLibraryInteraction)
                    .help(.ui("이전 곡"))
                    .accessibilityLabel(.ui("이전 곡"))
                Button { load(next) } label: {
                    Image(systemName: "forward.end.fill")
                        .frame(width: TextScale.length(24, scale: textScale), height: TextScale.length(24, scale: textScale))
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                    .disabled(next == nil || !store.writeLockPolicy.allowsLibraryInteraction)
                    .help(.ui("다음 곡"))
                    .accessibilityLabel(.ui("다음 곡"))
            }
            .padding(.bottom, TextScale.length(compact ? 10 : 20, scale: textScale))
            HStack(spacing: 4) {
                Button { deck.beatJump(beats: -beatStep) } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: TextScale.length(24, scale: textScale), height: TextScale.length(24, scale: textScale))
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                    .help(.ui("\(beatStep)박 뒤로 이동"))
                    .accessibilityLabel(.ui("\(beatStep)박 뒤로 이동"))
                Button { deck.beatJump(beats: beatStep) } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: TextScale.length(24, scale: textScale), height: TextScale.length(24, scale: textScale))
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                    .help(.ui("\(beatStep)박 앞으로 이동"))
                    .accessibilityLabel(.ui("\(beatStep)박 앞으로 이동"))
            }
            .disabled(!deck.canPlay || deck.isWriteLocked)
            .padding(.bottom, 4)
            Menu {
                ForEach([1, 2, 4, 8, 16, 32], id: \.self) { beats in
                    Button(.ui("\(beats)박")) { beatStep = beats }
                }
            } label: {
                VStack(spacing: 0) {
                    Text(.ui("\(beatStep)박"))
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .frame(width: TextScale.length(54, scale: textScale), height: TextScale.length(26, scale: textScale))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: TextScale.length(54, scale: textScale), height: TextScale.length(26, scale: textScale))
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .help(.ui("한 번 누를 때 이동할 박 수를 고릅니다"))
            .accessibilityLabel(.ui("박 이동량"))
            .padding(.bottom, TextScale.length(compact ? 10 : 48, scale: textScale))
            CueButton(deck: deck)
                .padding(.bottom, TextScale.length(compact ? 6 : 12, scale: textScale))
            DeckPlayButton(deck: deck)
        }
        .font(.scaled(.caption, textScale))
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .controlSize(ControlSize.small.scaled(textScale))
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Palette.controlRail, in: RoundedRectangle(cornerRadius: 6))
        .environment(\.colorScheme, .dark)
    }
}

/// 창 폭과 관계없이 쓰는 한 줄 곡 정보 헤더.
struct DeckInfoHeader: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel
    let row: TrackRow
    let coverSize: CGFloat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                cover
                details.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                if !PerfProbe.hidden.contains("label") {
                    DeckHeaderTime(deck: deck)
                    DeckHeaderMetrics(deck: deck)
                }
            }
            HStack(spacing: 10) {
                cover
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title).font(.scaled(.headline, textScale)).lineLimit(1)
                    if !PerfProbe.hidden.contains("label") {
                        HStack(spacing: 8) {
                            DeckHeaderTime(deck: deck)
                            Spacer(minLength: 0)
                            DeckHeaderMetrics(deck: deck)
                        }
                    }
                }
            }
        }
        .frame(height: coverSize)
    }

    private var cover: some View {
        CoverView(image: deck.artwork, size: coverSize * 0.8)
            .frame(width: coverSize, height: coverSize, alignment: .center)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title).font(.scaled(.headline, textScale)).lineLimit(1)
            Text([row.artist, row.genre].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.scaled(.caption, textScale)).foregroundStyle(.secondary).lineLimit(1)
            if !row.comment.isEmpty {
                Text(row.comment).font(.scaled(.caption2, textScale)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

/// 재생 틱보다 느린 표시 시각으로 남은 시간·현재 시각만 갱신한다.
private struct DeckHeaderTime: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel

    var body: some View {
        let elapsed = max(deck.displayTime, 0)
        let remaining = max(deck.duration - elapsed, 0)
        HStack(spacing: 4) {
            Text(verbatim: "-" + clock(remaining))
                .foregroundStyle(.primary)
                .frame(width: TextScale.length(76, scale: textScale), alignment: .trailing)
                .help(.ui("남은 시간"))
            Text(verbatim: clock(elapsed))
                .foregroundStyle(.secondary)
                .frame(width: TextScale.length(68, scale: textScale), alignment: .trailing)
                .help(.ui("재생 위치"))
        }
        .font(.scaled(.callout, textScale).monospacedDigit())
    }

    private func clock(_ seconds: Double) -> String {
        let hundredths = Int((seconds * 100).rounded())
        return String(format: "%02d:%02d.%02d", hundredths / 6000, (hundredths / 100) % 60, hundredths % 100)
    }
}

/// 현재 조성·실제 재생 BPM과 네 박 진행을 헤더 오른쪽에 고정한다.
private struct DeckHeaderMetrics: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel

    var body: some View {
        let t = deck.displayTime
        let beat = deck.grid?.position(at: t)?.beat ?? 0
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 8) {
                if let key = deck.key(at: t) {
                    HStack(spacing: 3) {
                        Circle().fill(UIColors.keyDot(key)).frame(width: 6, height: 6)
                        Text(key).font(.scaled(.caption, textScale).monospacedDigit())
                    }
                    .help(deck.keySegments.count > 1 ? String(ui: "지금 조성(Camelot, 추정). 이 곡은 조성이 바뀝니다") : String(ui: "지금 조성(Camelot)"))
                }
                if let bpm = deck.gridBPM {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(verbatim: (bpm * deck.rate).formatted(.number.precision(.fractionLength(2)).grouping(.never)))
                            .font(.scaled(.callout, textScale).monospacedDigit().bold())
                        Text(verbatim: "BPM").font(.scaled(.caption2, textScale)).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(deck.tempoPercent == 0 ? Color.primary : UIColors.cue.color)
                    .help(deck.tempoPercent == 0 ? String(ui: "지금 BPM(그리드 기준, 변속 곡은 구간마다 바뀝니다)")
                          : String(ui: "지금 BPM · 원래 \(bpm, specifier: "%.2f") BPM, 템포 \(deck.tempoPercent, specifier: "%+.1f")%"))
                }
            }
            HStack(spacing: 3) {
                ForEach(1...4, id: \.self) { number in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(number == beat ? UIColors.tempo.color
                              : number < beat ? UIColors.tempo.color.opacity(0.45) : Color.secondary.opacity(0.22))
                        .frame(width: TextScale.length(7, scale: textScale), height: TextScale.length(7, scale: textScale))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(.ui("마디.박"))
            .accessibilityValue(deck.grid?.positionText(at: t) ?? "—")
            .help(.ui("마디.박"))
        }
        .frame(width: TextScale.length(112, scale: textScale), alignment: .trailing)
    }
}

// MARK: - 커버·정보

struct DeckInfoColumn: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel
    let row: TrackRow

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            CoverView(image: deck.artwork, size: 150)
            Text(row.title).font(.scaled(.headline, textScale)).lineLimit(2).textSelection(.enabled)
            Text(row.artist).font(.scaled(.subheadline, textScale)).foregroundStyle(.secondary).lineLimit(1)
            if let genre = row.track.genre, !genre.trimmingCharacters(in: .whitespaces).isEmpty {
                Label(genre, systemImage: "guitars").font(.scaled(.caption, textScale)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) {
                if let bpm = row.track.bpm { Text(verbatim: bpm.formatted(.number.precision(.fractionLength(1)).grouping(.never)) + " BPM") }
                if let key = row.track.key { Text(key) }
                Text(Double(row.track.lengthSeconds).clockText.dropLast(3))
                if row.playCount > 0 { Text(.ui("재생 \(row.playCount)")) }
            }
            .font(.scaled(.caption, textScale).monospacedDigit())
            .foregroundStyle(.secondary)
            if !row.track.isStreaming, !row.isStaged, let note = analysisNote(row.track.analysisDataPath) {
                Label(note.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.scaled(.caption, textScale)).foregroundStyle(UIColors.warning.color)
                    .help(note.help)
            }
            // 코멘트는 적힌 그대로(태그로 나누지 않는다)
            Text(row.comment.isEmpty ? String(ui: "(빈 코멘트)") : row.comment)
                .font(.scaled(.callout, textScale))
                .foregroundStyle(row.comment.isEmpty ? .tertiary : .primary)
                .lineLimit(3)
                .textSelection(.enabled)
                .help(row.comment)
        }
        // 글자 길이와 상관없이 칸 가운데 세로축에 맞춘다.
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// rekordbox 분석 전 곡 표시. 분석 파일이 없는 곡은 반영 때 DJCrate가 붙일 수 있고(열려 있으면),
    /// `.DAT`만 있고 파형(.EXT)이 없는 곡은 rekordbox 분석이 끝나지 않은 곡이라 rekordbox에서 다시 분석해야 한다.
    func analysisNote(_ analysisDataPath: String?) -> (title: String, help: String)? {
        if RekordboxWriter.needsAnalysis(analysisDataPath) {
            return (String(ui: "rekordbox 분석 전"), RekordboxWriter.attachesAnalysis
                ? String(ui: "그리드 초안을 쓰면 이 미분석 곡에 파형·그리드·오토게인 분석 파일을 붙입니다.")
                : String(ui: "rekordbox가 이 곡을 아직 분석하지 않았습니다. rekordbox에서 트랙 분석을 먼저 해야 그리드를 쓸 수 있습니다"))
        }
        guard !RekordboxShare.hasWaveformAnalysis(analysisDataPath) else { return nil }
        return (String(ui: "rekordbox 분석 전 · 파형 없음"),
                String(ui: "rekordbox 분석이 끝나지 않은 곡입니다(파형 파일 없음). rekordbox에서 트랙 분석을 다시 해야 그리드를 쓸 수 있습니다"))
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
        .accessibilityLabel(.ui("앨범 커버"))
    }
}

// MARK: - 트랜스포트
