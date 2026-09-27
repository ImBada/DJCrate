import DJCAnalysis
import DJCDomain
import SwiftUI

/// 편집 창의 구간 색(늘 어두운 파형 위·클립 번호 배지). 이웃한 구간이 잘 갈리게 황금각으로 돌린다.
enum EditColors {
    static func entry(_ index: Int) -> Color {
        Color(hue: (0.55 + Double(index) * 0.618).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.97)
    }

    static let seam = Color.white
    /// 원곡에서 끌어 고른 구간(늘 어두운 파형 위)
    static let selection = Color(red: 0.35, green: 0.80, blue: 1.0)
}

/// 두 줄이 함께 쓰는 치수
enum EditMetrics {
    /// 위 눈금 띠. 누르거나 끌면 재생선만 옮긴다(아래 파형은 고르기·클립 조작).
    static let ruler: CGFloat = 16
}

/// 마디 눈금: 폭에 맞춰 1·4·8·16…마디마다 번호를 적는다.
private func drawBarRuler(_ context: GraphicsContext, layout: BarLayout, bars: ClosedRange<Int>, x: (Double) -> CGFloat,
                          height: CGFloat, width: CGFloat) {
    let pixelsPerBar = max(0.1, Double(x(layout.start(ofBar: 2)) - x(layout.start(ofBar: 1))))
    let step: Int = [1, 2, 4, 8, 16, 32, 64, 128].first(where: { Double($0) * pixelsPerBar >= 28 }) ?? 256
    context.fill(Path(CGRect(x: 0, y: 0, width: width, height: height)), with: .color(.white.opacity(0.05)))
    for bar in bars where bar >= 1 {
        let px = x(layout.start(ofBar: bar))
        let labeled = (bar - 1) % step == 0
        guard labeled || pixelsPerBar >= 4 else { continue }
        var tick = Path()
        tick.move(to: CGPoint(x: px, y: 0))
        tick.addLine(to: CGPoint(x: px, y: labeled ? 7 : 3))
        context.stroke(tick, with: .color(Palette.rulerText.opacity(labeled ? 0.9 : 0.4)), lineWidth: 1)
        if labeled, px < width - 8 {
            context.draw(Text(verbatim: "\(bar)").font(.system(size: 9).monospacedDigit()).foregroundStyle(Palette.rulerText),
                         at: CGPoint(x: px + 2, y: height), anchor: .bottomLeading)
        }
    }
}

/// 줄 테두리: 스페이스바·←→가 움직이는 줄은 강조색으로 두른다.
private struct LaneFrame: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .background(Palette.well)
            .environment(\.colorScheme, .dark)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 2))
    }
}

// MARK: - 재생선

/// 재생선(재생 중에만 초당 30번 다시 그린다). 누르지 않는다.
struct EditPlayhead: View {
    let model: TrackEditModel
    let lane: TrackEditModel.Lane

    var body: some View {
        if model.playing == lane {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in line(model.position(lane)) }
        } else {
            line(model.position(lane))
        }
    }

    private func line(_ time: Double) -> some View {
        let length = lane == .source ? model.duration : model.length(.output)
        return Canvas { context, size in
            guard length > 0 else { return }
            let px = CGFloat(time / length) * size.width
            context.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(Palette.cue))
            var head = Path()
            head.move(to: CGPoint(x: px - 5, y: 0))
            head.addLine(to: CGPoint(x: px + 5, y: 0))
            head.addLine(to: CGPoint(x: px, y: 7))
            head.closeSubpath()
            context.fill(head, with: .color(Palette.cue))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 원곡 줄

/// 원곡 전체: 눈금·파형·결과에 쓴 구간·끌어 고른 구간·재생선.
/// 위 눈금을 누르거나 끌면 재생선, 파형을 누르면 재생선, 파형을 끌면 마디 구간 고르기.
struct EditSourceStrip: View {
    let model: TrackEditModel
    @State private var gesture: Gesture?

    private enum Gesture { case scrub, press, select }

    var body: some View {
        GeometryReader { geo in
            let time = { (x: CGFloat) in Double(x / max(geo.size.width, 1)) * model.duration }
            ZStack {
                EditSourceLayer(model: model)
                EditSelectionLayer(model: model)
                EditPlayhead(model: model, lane: .source)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if gesture == nil { gesture = value.startLocation.y < EditMetrics.ruler ? .scrub : .press }
                if gesture == .press, abs(value.translation.width) > 3 { gesture = .select }
                switch gesture {
                case .scrub: model.scrub(.source, to: time(value.location.x))
                case .select: model.select(from: time(value.startLocation.x), to: time(value.location.x))
                default: model.focus = .source
                }
            }.onEnded { value in
                switch gesture {
                case .scrub: model.endScrub()
                case .select: model.finishSelection()
                default: model.seek(.source, to: time(value.location.x))
                }
                gesture = nil
            })
        }
        .modifier(LaneFrame(focused: model.focus == .source))
        .accessibilityElement()
        .accessibilityLabel(.ui("원곡 파형"))
        .accessibilityValue(model.selection.map { String(ui: "고른 구간 마디 \($0.description)") } ?? String(ui: "고른 구간 없음"))
        .accessibilityHint(.ui("끌어서 마디 구간을 고르고, 눌러서 재생선을 옮깁니다"))
    }
}

/// 파형·눈금·결과에 쓴 구간(재생 위치·고르기를 읽지 않아 끄는 동안 다시 그리지 않는다)
private struct EditSourceLayer: View {
    let model: TrackEditModel

    var body: some View {
        let entries = model.entries
        let duration = max(model.duration, 1)
        Canvas { context, size in
            let x = { (t: Double) in CGFloat(t / duration) * size.width }
            let ruler = EditMetrics.ruler
            let wave = CGRect(x: 0, y: ruler, width: size.width, height: size.height - ruler - 14)
            if let waveform = model.waveform {
                drawBands(context, waveform: waveform, from: -model.timelineOffset, to: duration - model.timelineOffset, in: wave)
            }
            guard let layout = model.layout else { return }
            // 결과에 쓴 구간: 아래 가는 띠 + 번호(같은 자리에서 시작하는 구간은 번호를 옆으로 민다)
            var chipX = -CGFloat.infinity
            for (index, entry) in entries.enumerated() {
                let color = EditColors.entry(index)
                let from = x(layout.start(ofBar: entry.range.first)), to = x(layout.end(ofBar: entry.range.last))
                context.fill(Path(CGRect(x: from, y: size.height - 13, width: max(1, to - from), height: 3)), with: .color(color))
                chipX = max(from + 1, chipX + 16)
                if chipX < size.width - 10 {
                    context.draw(Text(verbatim: "\(index + 1)").font(.system(size: 8, weight: .bold).monospacedDigit()).foregroundStyle(color),
                                 at: CGPoint(x: chipX, y: size.height - 1), anchor: .bottomLeading)
                }
            }
            drawBarRuler(context, layout: layout, bars: 1...max(1, layout.count), x: x, height: ruler, width: size.width)
        }
    }
}

/// 끌어 고른 구간(고르는 동안 이 층만 다시 그린다)
private struct EditSelectionLayer: View {
    let model: TrackEditModel

    var body: some View {
        let selection = model.selection
        let duration = max(model.duration, 1)
        Canvas { context, size in
            guard let selection, let layout = model.layout else { return }
            let from = CGFloat(layout.start(ofBar: selection.first) / duration) * size.width
            let to = CGFloat(layout.end(ofBar: selection.last) / duration) * size.width
            let band = CGRect(x: from, y: EditMetrics.ruler, width: max(2, to - from), height: size.height - EditMetrics.ruler)
            context.fill(Path(band), with: .color(EditColors.selection.opacity(0.22)))
            context.stroke(Path(band.insetBy(dx: 0.75, dy: 0.75)), with: .color(EditColors.selection), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 결과 타임라인

/// 편집 결과: 클립(목록 구간)을 이어 놓은 타임라인. 클립을 누르면 고르고 재생선을 옮기며, 끌면 순서를 바꾼다.
/// 위 눈금을 누르거나 끌면 재생선만 옮긴다. 아래 줄의 가위 단추로 이음새 앞뒤를 들어 본다.
struct EditOutputStrip: View {
    let model: TrackEditModel
    @State private var gesture: Gesture?
    /// 끄는 클립과 지금 놓을 자리(옮기기 전 기준 앞 클립 수)
    @State private var drag: (id: TrackEditModel.Entry.ID, offset: Int)?

    private enum Gesture { case scrub, press(Int?), move }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let length = max(model.clipLayout.last?.outputEnd ?? 0, 0.001)
                let time = { (x: CGFloat) in Double(x / max(geo.size.width, 1)) * length }
                ZStack {
                    EditOutputLayer(model: model, dragging: drag?.id)
                    if let drag {
                        EditDropMarker(model: model, offset: drag.offset)
                    }
                    EditPlayhead(model: model, lane: .output)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    if gesture == nil {
                        gesture = value.startLocation.y < EditMetrics.ruler
                            ? .scrub : .press(model.clipLayout.clipIndex(atOutput: time(value.startLocation.x)))
                    }
                    switch gesture {
                    case .scrub:
                        model.scrub(.output, to: time(value.location.x))
                    case .press(let index?) where abs(value.translation.width) > 4 && model.entries.indices.contains(index):
                        gesture = .move
                        drag = (model.entries[index].id, model.clipLayout.dropOffset(atOutput: time(value.location.x)))
                    case .move:
                        if let id = drag?.id { drag = (id, model.clipLayout.dropOffset(atOutput: time(value.location.x))) }
                    default:
                        model.focus = .output
                    }
                }.onEnded { value in
                    switch gesture {
                    case .scrub:
                        model.endScrub()
                    case .move:
                        if let drag { model.moveClip(drag.id, toOffset: drag.offset) }
                    case .press(let index):
                        model.selectedClip = index.flatMap { model.entries.indices.contains($0) ? model.entries[$0].id : nil }
                        if model.edit != nil { model.seek(.output, to: time(value.location.x)) }
                    case nil:
                        break
                    }
                    gesture = nil
                    drag = nil
                })
            }
            .modifier(LaneFrame(focused: model.focus == .output))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(.ui("편집 결과 타임라인"))
            .accessibilityChildren {
                // VoiceOver로 클립을 고른다(끌어 옮기기는 아래 앞으로·뒤로 단추).
                HStack(spacing: 0) {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                        Rectangle()
                            .accessibilityLabel(.ui("클립 \(index + 1), 마디 \(entry.range.description)"))
                            .accessibilityAddTraits(model.selectedClip == entry.id ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { model.selectedClip = entry.id }
                    }
                }
            }
            EditSeamBar(model: model)
                .frame(height: 20)
        }
    }
}

/// 클립·이음새·옮긴 큐·눈금(재생 위치를 읽지 않는다)
private struct EditOutputLayer: View {
    let model: TrackEditModel
    let dragging: TrackEditModel.Entry.ID?

    var body: some View {
        let clips = model.clipLayout
        let entries = model.entries
        let selected = model.selectedClip
        let seams = model.edit.map { $0.pieces.dropFirst().map(\.outputStart) } ?? []
        let placed = model.carry?.placed ?? []
        let bars = model.outputLayout
        Canvas { context, size in
            guard let length = clips.last?.outputEnd, length > 0, clips.count == entries.count else {
                context.draw(Text(.ui("원곡 파형을 끌어 구간을 고른 뒤 ‘결과에 넣기’를 누르면 여기 이어집니다"))
                    .font(.callout).foregroundStyle(Palette.rulerText),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let x = { (t: Double) in CGFloat(t / length) * size.width }
            let ruler = EditMetrics.ruler
            let lane = CGRect(x: 0, y: ruler + 2, width: size.width, height: size.height - ruler - 4)
            for (index, clip) in clips.enumerated() {
                let color = EditColors.entry(index)
                let rect = CGRect(x: x(clip.outputStart), y: lane.minY, width: max(2, x(clip.outputEnd) - x(clip.outputStart)), height: lane.height)
                let body = rect.insetBy(dx: 0.5, dy: 0)
                var slice = context
                slice.clip(to: Path(roundedRect: body, cornerRadius: 3))
                slice.opacity = entries[index].id == dragging ? 0.35 : 1
                slice.fill(Path(body), with: .color(color.opacity(0.16)))
                if let waveform = model.waveform {
                    let wave = CGRect(x: body.minX, y: body.minY + 16, width: body.width, height: body.height - 16)
                    drawBands(slice, waveform: waveform, from: clip.sourceStart - model.timelineOffset,
                              to: clip.sourceEnd - model.timelineOffset, in: wave)
                }
                // 머리 띠: 번호와 원곡 마디
                slice.fill(Path(CGRect(x: body.minX, y: body.minY, width: body.width, height: 14)), with: .color(color.opacity(0.85)))
                if body.width > 18 {
                    let label = body.width > 70 ? "\(index + 1) · \(clip.bars.description)" : "\(index + 1)"
                    slice.draw(Text(verbatim: label).font(.system(size: 9, weight: .semibold).monospacedDigit()).foregroundStyle(.black),
                               at: CGPoint(x: body.minX + 4, y: body.minY + 7), anchor: .leading)
                }
                let isSelected = entries[index].id == selected
                context.stroke(Path(roundedRect: body.insetBy(dx: isSelected ? 1 : 0.5, dy: isSelected ? 1 : 0.5), cornerRadius: 3),
                               with: .color(isSelected ? .white : color.opacity(0.9)), lineWidth: isSelected ? 2 : 1)
            }
            // 이음새(원곡에서 이어지지 않는 경계): 흰 점선
            for seam in seams {
                var line = Path()
                line.move(to: CGPoint(x: x(seam), y: ruler))
                line.addLine(to: CGPoint(x: x(seam), y: size.height))
                context.stroke(line, with: .color(EditColors.seam), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            // 옮긴 큐: 머리 띠 아래 작은 삼각형(핫큐 초록·메모리 빨강·루프 주황)
            for cue in placed {
                let px = x(cue.time), top = lane.minY + 14
                var mark = Path()
                mark.move(to: CGPoint(x: px - 4, y: top))
                mark.addLine(to: CGPoint(x: px + 4, y: top))
                mark.addLine(to: CGPoint(x: px, y: top + 6))
                mark.closeSubpath()
                context.fill(mark, with: .color(Palette.color(for: cue)))
            }
            if let bars {
                drawBarRuler(context, layout: bars, bars: 1...max(1, bars.count), x: x, height: ruler, width: size.width)
            }
        }
    }
}

/// 끌어 온 클립을 놓을 자리
private struct EditDropMarker: View {
    let model: TrackEditModel
    let offset: Int

    var body: some View {
        let clips = model.clipLayout
        Canvas { context, size in
            guard let length = clips.last?.outputEnd, length > 0 else { return }
            let time = offset < clips.count ? clips[offset].outputStart : length
            let px = min(max(CGFloat(time / length) * size.width, 1.5), size.width - 1.5)
            context.fill(Path(CGRect(x: px - 1.5, y: EditMetrics.ruler, width: 3, height: size.height - EditMetrics.ruler)),
                         with: .color(.accentColor))
        }
        .allowsHitTesting(false)
    }
}

/// 이음새마다 들어 보기 단추(타임라인 아래, 이음새 자리)
private struct EditSeamBar: View {
    let model: TrackEditModel

    var body: some View {
        GeometryReader { geo in
            if let edit = model.edit, edit.duration > 0 {
                ForEach(Array(edit.pieces.enumerated().dropFirst()), id: \.offset) { piece, item in
                    let playing = model.playing == .output && model.auditioning == piece
                    Button {
                        if playing { model.pause() } else { model.auditionSeam(piece) }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "scissors")
                            Image(systemName: playing ? "stop.fill" : "play.fill")
                        }
                        .font(.system(size: 9))
                        .frame(width: 30, height: 14)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!model.canPlay(.output))
                    .help(.ui("이음새 앞 2마디부터 뒤 2마디까지 들어 봅니다(섞는 소리까지 결과와 같습니다)"))
                    .accessibilityLabel(playing ? String(ui: "멈추기") : String(ui: "이음새 \(piece) 듣기"))
                    .position(x: min(max(CGFloat(item.outputStart / edit.duration) * geo.size.width, 20), geo.size.width - 20),
                              y: geo.size.height / 2)
                }
            }
        }
    }
}
