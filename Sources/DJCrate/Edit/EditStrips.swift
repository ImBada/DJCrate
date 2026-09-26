import DJCAnalysis
import DJCDomain
import SwiftUI

/// 편집 창의 구간 색(늘 어두운 파형 위·목록 번호 배지). 이웃한 구간이 잘 갈리게 황금각으로 돌린다.
enum EditColors {
    static func entry(_ index: Int) -> Color {
        Color(hue: (0.55 + Double(index) * 0.618).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.97)
    }

    static let seam = Color.white
}

/// 마디 눈금: 폭에 맞춰 1·4·8·16…마디마다 번호를 적는다.
private func drawBarRuler(_ context: GraphicsContext, layout: BarLayout, bars: ClosedRange<Int>, x: (Double) -> CGFloat,
                          height: CGFloat, width: CGFloat) {
    let pixelsPerBar = max(0.1, Double(x(layout.start(ofBar: 2)) - x(layout.start(ofBar: 1))))
    let step: Int = [1, 2, 4, 8, 16, 32, 64, 128].first(where: { Double($0) * pixelsPerBar >= 28 }) ?? 256
    for bar in bars where bar >= 1 {
        let px = x(layout.start(ofBar: bar))
        let labeled = (bar - 1) % step == 0
        guard labeled || pixelsPerBar >= 4 else { continue }
        var tick = Path()
        tick.move(to: CGPoint(x: px, y: 0))
        tick.addLine(to: CGPoint(x: px, y: labeled ? 7 : 3))
        context.stroke(tick, with: .color(Palette.rulerText.opacity(labeled ? 0.9 : 0.4)), lineWidth: 1)
        if labeled, px < width - 8 {
            context.draw(Text("\(bar)").font(.system(size: 9).monospacedDigit()).foregroundStyle(Palette.rulerText),
                         at: CGPoint(x: px + 2, y: height), anchor: .bottomLeading)
        }
    }
}

// MARK: - 원곡 줄

/// 원곡 전체: 파형·마디 눈금·고른 구간. 누르거나 끌어 "여기서" 위치를 고른다(덱에 같은 곡이 있으면 덱도 옮긴다).
struct EditSourceStrip: View {
    let model: TrackEditModel
    let deck: DeckModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                EditSourceLayer(model: model)
                EditSourcePosition(model: model, deck: deck)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                model.place(at: Double(value.location.x / max(geo.size.width, 1)) * model.duration)
            })
        }
        .background(Palette.well)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement()
        .accessibilityLabel("원곡 전체 파형과 고른 마디 구간")
        .accessibilityHint("눌러서 구간을 더할 위치를 고릅니다")
    }
}

/// 재생 위치를 읽지 않는 층(덱이 재생 중이어도 다시 그리지 않는다).
private struct EditSourceLayer: View {
    let model: TrackEditModel

    var body: some View {
        let entries = model.entries
        let duration = max(model.duration, 1)
        Canvas { context, size in
            let x = { (t: Double) in CGFloat(t / duration) * size.width }
            let ruler: CGFloat = 14
            let wave = CGRect(x: 0, y: ruler, width: size.width, height: size.height - ruler - 18)
            if let waveform = model.waveform {
                drawBands(context, waveform: waveform, from: -model.timelineOffset, to: duration - model.timelineOffset, in: wave)
            }
            guard let layout = model.layout else { return }
            // 고른 구간: 파형 위 반투명 띠 + 아래 번호(같은 자리에서 시작하는 구간은 번호를 옆으로 민다)
            var chipX = -CGFloat.infinity
            for (index, entry) in entries.enumerated() {
                let color = EditColors.entry(index)
                let from = x(layout.start(ofBar: entry.range.first)), to = x(layout.end(ofBar: entry.range.last))
                let band = CGRect(x: from, y: wave.minY, width: max(1, to - from), height: wave.height)
                context.fill(Path(band), with: .color(color.opacity(0.18)))
                context.stroke(Path(band.insetBy(dx: 0.5, dy: 0.5)), with: .color(color.opacity(0.8)), lineWidth: 1)
                chipX = max(from + 8, chipX + 20)
                chip(context, "\(index + 1)", at: CGPoint(x: chipX, y: size.height - 16), color: color, selected: false, maxX: size.width)
            }
            var head = context
            head.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: ruler)))
            drawBarRuler(head, layout: layout, bars: 1...max(1, layout.count), x: x, height: ruler, width: size.width)
        }
    }
}

/// 덱 재생 위치(초당 15번) 또는 창에서 찍은 위치
private struct EditSourcePosition: View {
    let model: TrackEditModel
    let deck: DeckModel

    var body: some View {
        let time = model.isDeckOnTrack ? deck.displayTime : model.cursor
        let duration = max(model.duration, 1)
        Canvas { context, size in
            let px = CGFloat(time / duration) * size.width
            context.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(Palette.cue))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 결과 줄

/// 편집 결과: 조각을 이어 놓은 모양(각 조각은 원곡의 그 부분 파형), 이음새, 옮긴 큐, 미리 듣는 위치.
struct EditOutputStrip: View {
    let model: TrackEditModel

    var body: some View {
        ZStack {
            EditOutputLayer(model: model)
            if model.preview != nil {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    EditOutputPosition(model: model, time: model.previewOutputTime(model.player.currentTime))
                }
            }
        }
        .background(Palette.well)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement()
        .accessibilityLabel(model.edit.map { "편집 결과 파형, \($0.pieces.count)조각, 이음새 \(max(0, $0.pieces.count - 1))곳" } ?? "편집 결과 없음")
    }
}

private struct EditOutputLayer: View {
    let model: TrackEditModel

    var body: some View {
        let edit = model.edit
        let placed = model.carry?.placed ?? []
        // 조각마다 목록 번호 색: 이어진 구간을 합친 조각은 첫 구간 색
        let firstEntry = firstEntryIndices()
        Canvas { context, size in
            guard let edit, edit.duration > 0 else {
                context.draw(Text("구간을 더하면 결과가 여기 이어져 보입니다").font(.callout).foregroundStyle(Palette.rulerText),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let x = { (t: Double) in CGFloat(t / edit.duration) * size.width }
            let ruler: CGFloat = 14
            let wave = CGRect(x: 0, y: ruler, width: size.width, height: size.height - ruler - 6)
            for (index, piece) in edit.pieces.enumerated() {
                let rect = CGRect(x: x(piece.outputStart), y: wave.minY, width: max(1, x(piece.outputEnd) - x(piece.outputStart)), height: wave.height)
                let color = EditColors.entry(firstEntry.indices.contains(index) ? firstEntry[index] : index)
                context.fill(Path(rect), with: .color(color.opacity(0.14)))
                if let waveform = model.waveform {
                    var slice = context
                    slice.clip(to: Path(rect))
                    drawBands(slice, waveform: waveform, from: piece.sourceStart - model.timelineOffset,
                              to: piece.sourceEnd - model.timelineOffset, in: rect)
                }
                context.fill(Path(CGRect(x: rect.minX, y: wave.maxY - 3, width: rect.width, height: 3)), with: .color(color))
                if index > 0 {
                    var seam = Path()
                    seam.move(to: CGPoint(x: rect.minX, y: 0))
                    seam.addLine(to: CGPoint(x: rect.minX, y: size.height))
                    context.stroke(seam, with: .color(EditColors.seam), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            // 옮긴 큐: 위쪽 작은 삼각형(핫큐 초록·메모리 빨강·루프 주황)
            for cue in placed {
                let px = x(cue.time)
                var mark = Path()
                mark.move(to: CGPoint(x: px - 4, y: ruler))
                mark.addLine(to: CGPoint(x: px + 4, y: ruler))
                mark.addLine(to: CGPoint(x: px, y: ruler + 6))
                mark.closeSubpath()
                context.fill(mark, with: .color(Palette.color(for: cue)))
            }
            if let bars = try? BarLayout(grid: [edit.outputGrid], duration: edit.duration) {
                var head = context
                head.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: ruler)))
                drawBarRuler(head, layout: bars, bars: 1...max(1, bars.count), x: x, height: ruler, width: size.width)
            }
        }
    }

    /// 조각(원본에서 이어진 구간을 합친 것)마다 첫 구간의 목록 순서
    private func firstEntryIndices() -> [Int] {
        var result: [Int] = []
        var previous: BarRange?
        for (index, entry) in model.entries.enumerated() {
            if let previous, previous.last + 1 == entry.range.first {} else { result.append(index) }
            previous = entry.range
        }
        return result
    }
}

private struct EditOutputPosition: View {
    let model: TrackEditModel
    let time: Double?

    var body: some View {
        Canvas { context, size in
            guard let time, let duration = model.edit?.duration, duration > 0 else { return }
            let px = CGFloat(time / duration) * size.width
            context.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(Palette.cue))
        }
        .allowsHitTesting(false)
    }
}
