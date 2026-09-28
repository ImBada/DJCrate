import AppKit
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
    /// 편집 창 좌표 이름(원곡 줄에서 결과 줄로 끌어 넣을 때 두 줄 자리를 맞춘다)
    static let space = "trackEdit"
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

// MARK: - 누르기·끌기

/// 두 줄의 누르기·끌기를 편집 동작으로 바꾼다. 뷰의 DragGesture는 좌표를 시각으로 바꿔 넘기기만 한다.
/// 위 눈금은 재생선만(끄는 동안 소리를 멈췄다가 손을 떼면 잇는다), 원곡 파형은 누르기 = 재생선·옆으로 끌기 = 마디 구간 고르기,
/// 고른 구간 안을 아래로 끌기 = 결과의 원하는 자리에 넣기. 결과는 클립 누르기 = 고르기·재생선, 클립 끌기 = 순서 바꾸기,
/// 클립 가장자리 끌기 = 마디 줄에 붙여 다듬기(손을 뗄 때 한 번에 바꿔 실행 취소 하나).
struct EditPointer {
    enum Mode: Equatable {
        case scrub
        /// 누른 클립(결과 줄, 없으면 nil)
        case press(clip: Int?)
        case select
        case move(TrackEditModel.Entry.ID)
        case trim(TrackEditModel.Entry.ID, EditEdge)
        /// 원곡에서 고른 구간을 결과로 끌어 넣는 중
        case carry
    }

    /// 다듬는 클립과 새 구간(끄는 동안 결과 줄에 그린다)
    struct Trim: Equatable {
        var id: TrackEditModel.Entry.ID
        var clip: Int
        var edge: EditEdge
        var range: BarRange
    }

    /// 이만큼(포인트) 움직이면 누르기가 아니라 끌기다.
    static let slop: CGFloat = 4
    /// 클립 가장자리를 잡는 폭(포인트, 가장자리 양쪽)
    static let edgeReach: CGFloat = 5

    private(set) var mode: Mode?
    /// 끄는 클립을 놓을 자리(옮기기 전 기준 앞 클립 수)
    private(set) var dropOffset: Int?
    private(set) var trimming: Trim?
    /// 누른 클립 가장자리(끌면 다듬기)
    private var pressedEdge: EditEdgeHit?

    var dragging: TrackEditModel.Entry.ID? {
        if case .move(let id) = mode { id } else { nil }
    }

    /// 원곡 줄. `moved`·`rise`는 누른 자리에서 가로·세로로 움직인 거리, `output`은 포인터가 결과 줄 위에 있으면 그 결과 시각.
    @MainActor
    mutating func source(_ model: TrackEditModel, from start: Double, to time: Double, inRuler: Bool, moved: CGFloat,
                         rise: CGFloat = 0, output: Double? = nil) {
        if mode == nil { mode = inRuler ? .scrub : .press(clip: nil) }
        if mode == .press(clip: nil) {
            // 고른 구간을 아래(결과 쪽)로 끌면 넣기, 옆으로 끌면 예전처럼 새로 고르기
            if rise > Self.slop, rise > moved, model.selectionContains(start) {
                mode = .carry
            } else if moved > Self.slop {
                mode = .select
            }
        }
        switch mode {
        case .scrub: model.scrub(.source, to: time)
        case .select: model.select(from: start, to: time)
        case .carry: model.insertPreview = output.flatMap { model.insertion(atOutput: $0) }
        default: model.focus = .source
        }
    }

    @MainActor
    mutating func endSource(_ model: TrackEditModel, at time: Double) {
        switch mode {
        case .scrub: model.endScrub()
        case .select: model.finishSelection()
        case .carry:
            if let insertion = model.insertPreview { model.insert(insertion) }
            model.insertPreview = nil
        default: model.seek(.source, to: time)
        }
        mode = nil
    }

    /// 결과 줄. `secondsPerPoint`는 지금 확대에서 한 포인트의 길이(초, 가장자리를 잡는 폭을 시각으로 바꾼다).
    @MainActor
    mutating func output(_ model: TrackEditModel, from start: Double, to time: Double, inRuler: Bool, moved: CGFloat,
                         secondsPerPoint: Double = 0) {
        if mode == nil {
            mode = inRuler ? .scrub : .press(clip: model.clipLayout.clipIndex(atOutput: start))
            pressedEdge = inRuler ? nil : model.clipLayout.edge(atOutput: start, tolerance: Self.edgeReach * secondsPerPoint)
        }
        switch mode {
        case .scrub:
            model.scrub(.output, to: time)
        case .press where moved > Self.slop && pressedEdge.map { model.entries.indices.contains($0.clip) } == true:
            let hit = pressedEdge!
            mode = .trim(model.entries[hit.clip].id, hit.edge)
            trim(model, from: start, to: time)
        case .press(let index?) where moved > Self.slop && model.entries.indices.contains(index):
            mode = .move(model.entries[index].id)
            dropOffset = model.clipLayout.dropOffset(atOutput: time)
        case .move:
            dropOffset = model.clipLayout.dropOffset(atOutput: time)
        case .trim:
            trim(model, from: start, to: time)
        default:
            model.focus = .output
        }
    }

    @MainActor
    private mutating func trim(_ model: TrackEditModel, from start: Double, to time: Double) {
        guard case let .trim(id, edge) = mode, let clip = model.entries.firstIndex(where: { $0.id == id }),
              let range = model.trimmed(id, edge: edge, by: time - start) else { return }
        trimming = Trim(id: id, clip: clip, edge: edge, range: range)
    }

    @MainActor
    mutating func endOutput(_ model: TrackEditModel, at time: Double) {
        switch mode {
        case .scrub:
            model.endScrub()
        case .move(let id):
            if let dropOffset { model.moveClip(id, toOffset: dropOffset) }
        case .trim(let id, _):
            if let trimming { model.trim(id, to: trimming.range) }
        case .press(let index):
            model.selectedClip = index.flatMap { model.entries.indices.contains($0) ? model.entries[$0].id : nil }
            if model.edit != nil { model.seek(.output, to: time) }
        case .select, .carry, nil:
            break
        }
        mode = nil
        dropOffset = nil
        trimming = nil
        pressedEdge = nil
    }
}

// MARK: - 보기(확대·가로 스크롤)

/// 줄의 시각 ↔ 가로 위치(지금 보이는 자리 기준, #134)
struct EditLaneScale {
    let view: EditViewport
    let length: Double
    let width: CGFloat

    @MainActor
    init(_ model: TrackEditModel, _ lane: TrackEditModel.Lane, width: CGFloat) {
        view = model.viewport(lane)
        length = model.extent(lane)
        self.width = width
    }

    var visible: ClosedRange<Double> { view.visible(length: length) }
    func x(_ time: Double) -> CGFloat { CGFloat(view.x(of: time, width: Double(width), length: length)) }
    func time(_ x: CGFloat) -> Double { view.time(atX: Double(x), width: Double(width), length: length) }
    /// 한 포인트의 길이(초)
    var secondsPerPoint: Double { (visible.upperBound - visible.lowerBound) / Double(max(width, 1)) }
}

/// 줄 위 스크롤 휠·트랙패드. SwiftUI에는 휠 이벤트가 없어 로컬 이벤트 모니터로 받는다(덱 확대 파형과 같다).
/// 세로: 포인터 자리를 두고 확대·축소, 가로(트랙패드·Shift+휠): 보이는 자리 옮기기. 무엇을 받을지는 `WaveformScrollPolicy`가 정한다.
@MainActor
final class EditScrollHandler {
    weak var probe: NSView?
    weak var model: TrackEditModel?
    var lane: TrackEditModel.Lane = .source
    private var monitor: Any?
    private var policy = WaveformScrollPolicy()

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let model = self.model, let probe = self.probe, event.window === probe.window else { return event }
            let point = probe.convert(event.locationInWindow, from: nil)
            let scale = EditLaneScale(model, self.lane, width: probe.bounds.width)
            guard scale.length > 0 else { return event }
            let span = scale.visible.upperBound - scale.visible.lowerBound
            switch self.policy.handle(.init(event, over: probe.bounds.contains(point)), zoomSeconds: span, width: Double(probe.bounds.width)) {
            case .pass:
                return event
            case .swallow:
                return nil
            case let .zoom(factor):
                // 덱과 같은 방향: factor는 보이는 길이에 곱한다.
                model.zoom(self.lane, by: 1 / factor, around: scale.time(point.x))
                return nil
            case let .scrub(seconds):
                model.scroll(self.lane, by: seconds)
                return nil
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// 줄마다 휠·핀치 확대(포인터 자리 기준)
private struct LaneZoomGestures: ViewModifier {
    let model: TrackEditModel
    let lane: TrackEditModel.Lane
    @State private var scroll = EditScrollHandler()
    @State private var pinch: CGFloat?
    @State private var width: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let last = pinch ?? 1
                        pinch = value.magnification
                        let scale = EditLaneScale(model, lane, width: width)
                        guard last > 0, scale.length > 0 else { return }
                        model.zoom(lane, by: value.magnification / last, around: scale.time(value.startLocation.x))
                    }
                    .onEnded { _ in pinch = nil }
            )
            .background { HitProbe { scroll.probe = $0 } }
            .onAppear {
                scroll.model = model
                scroll.lane = lane
                scroll.install()
            }
            .onDisappear { scroll.remove() }
    }
}

extension View {
    /// VoiceOver 확대·축소 동작(줄 접근성 요소에 붙인다)
    func laneZoomAction(_ model: TrackEditModel, _ lane: TrackEditModel.Lane) -> some View {
        accessibilityZoomAction { action in
            model.zoom(lane, by: action.direction == .zoomIn ? 2 : 0.5)
        }
    }
}

/// 줄 아래: 보이는 자리 막대(끌어 옮기기)와 확대·축소·전체 단추. 줄 전체를 보는 동안에는 확대하는 법을 적는다.
struct EditZoomBar: View {
    let model: TrackEditModel
    let lane: TrackEditModel.Lane

    var body: some View {
        let length = model.extent(lane)
        let view = model.viewport(lane)
        let visible = view.visible(length: length)
        let zoomed = view.isZoomed(length: length)
        let closest = visible.upperBound - visible.lowerBound <= model.minimumSpan + 1e-6
        let name = lane == .source ? String(ui: "원곡") : String(ui: "결과")
        HStack(spacing: 6) {
            if zoomed {
                EditScroller(model: model, lane: lane)
                    .frame(height: 8)
                    .accessibilityElement()
                    .accessibilityLabel(.ui("\(name) 보이는 자리"))
                    .accessibilityValue(Text(verbatim: "\(visible.lowerBound.clockText)–\(visible.upperBound.clockText)"))
                    .accessibilityAdjustableAction { direction in
                        let span = visible.upperBound - visible.lowerBound
                        model.scroll(lane, by: direction == .increment ? span / 2 : -span / 2)
                    }
                Text(verbatim: String(format: "×%.1f", view.scale(length: length)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(.ui("세로 휠·핀치·= 키로 확대합니다"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .opacity(length > 0 ? 1 : 0)
                Spacer(minLength: 0)
            }
            HStack(spacing: 2) {
                Button { model.zoom(lane, by: 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(!zoomed)
                    .help(.ui("축소합니다(− 키)"))
                    .accessibilityLabel(.ui("\(name) 축소"))
                Button { model.zoom(lane, by: 2) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(length <= 0 || closest)
                    .help(.ui("재생선을 두고 확대합니다(= 키). 세로 휠·핀치는 포인터 자리를 둡니다"))
                    .accessibilityLabel(.ui("\(name) 확대"))
                Button { model.fit(lane) } label: { Image(systemName: "arrow.left.and.right.square") }
                    .disabled(!zoomed)
                    .help(.ui("줄 전체를 봅니다(0 키)"))
                    .accessibilityLabel(.ui("\(name) 전체 보기"))
            }
            .buttonStyle(.borderless)
        }
        .controlSize(.mini)
        .frame(height: 16)
    }
}

/// 보이는 자리 막대: 손잡이를 끌거나, 빈 곳을 누르면 그 자리를 가운데로 옮겨 이어 끈다.
private struct EditScroller: View {
    let model: TrackEditModel
    let lane: TrackEditModel.Lane
    /// 누른 자리와 손잡이 왼쪽 끝의 거리(초)
    @State private var grab: Double?

    var body: some View {
        GeometryReader { geo in
            let length = model.extent(lane), visible = model.viewport(lane).visible(length: length)
            let width = geo.size.width, span = visible.upperBound - visible.lowerBound
            let x = { (t: Double) in CGFloat(t / max(length, 0.001)) * width }
            ZStack(alignment: .leading) {
                Capsule().fill(UIColors.subtleFill)
                Capsule().fill(Color.secondary.opacity(0.55))
                    .frame(width: max(12, x(visible.upperBound) - x(visible.lowerBound)))
                    .offset(x: x(visible.lowerBound))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let time = Double(value.location.x / max(width, 1)) * length
                if grab == nil {
                    let start = Double(value.startLocation.x / max(width, 1)) * length
                    grab = visible.contains(start) ? start - visible.lowerBound : span / 2
                }
                model.scroll(lane, to: time - (grab ?? 0))
            }.onEnded { _ in grab = nil })
        }
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
        let view = model.viewport(lane), length = model.extent(lane)
        return Canvas { context, size in
            guard length > 0 else { return }
            let px = CGFloat(view.x(of: time, width: Double(size.width), length: length))
            guard px >= -6, px <= size.width + 6 else { return }
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

/// 원곡: 눈금·파형·결과에 쓴 구간·끌어 고른 구간·재생선. 확대하면 보이는 자리만 그린다.
/// 위 눈금을 누르거나 끌면 재생선, 파형을 누르면 재생선, 옆으로 끌면 마디 구간 고르기, 고른 구간을 아래로 끌면 결과에 넣기.
struct EditSourceStrip: View {
    let model: TrackEditModel
    /// 결과 줄 자리(이 줄 좌표). 고른 구간을 끌어 놓을 자리를 찾는다.
    let outputFrame: CGRect
    @State private var pointer: EditPointer

    /// - Parameter pointer: 처음 누르기·끌기 상태(끄는 중 모습을 캡처할 때)
    init(model: TrackEditModel, outputFrame: CGRect = .zero, pointer: EditPointer = EditPointer()) {
        self.model = model
        self.outputFrame = outputFrame
        _pointer = State(initialValue: pointer)
    }

    var body: some View {
        GeometryReader { geo in
            let scale = EditLaneScale(model, .source, width: geo.size.width)
            let output = { (point: CGPoint) -> Double? in
                guard outputFrame.width > 0, outputFrame.contains(point) else { return nil }
                return EditLaneScale(model, .output, width: outputFrame.width).time(point.x - outputFrame.minX)
            }
            ZStack {
                EditSourceLayer(model: model, scale: scale)
                EditSelectionLayer(model: model, scale: scale, carrying: pointer.mode == .carry)
                EditPlayhead(model: model, lane: .source)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                pointer.source(model, from: scale.time(value.startLocation.x), to: scale.time(value.location.x),
                               inRuler: value.startLocation.y < EditMetrics.ruler, moved: abs(value.translation.width),
                               rise: abs(value.translation.height), output: output(value.location))
            }.onEnded { value in
                pointer.endSource(model, at: scale.time(value.location.x))
            })
        }
        .modifier(LaneZoomGestures(model: model, lane: .source))
        .modifier(LaneFrame(focused: model.focus == .source))
        .selfTestFrame("editSource")
        .accessibilityElement()
        .accessibilityLabel(.ui("원곡 파형"))
        .accessibilityValue(model.selection.map { String(ui: "고른 구간 마디 \($0.description)") } ?? String(ui: "고른 구간 없음"))
        .accessibilityHint(.ui("끌어서 마디 구간을 고르고, 눌러서 재생선을 옮깁니다. 고른 구간을 아래로 끌면 결과에 넣습니다"))
        .laneZoomAction(model, .source)
    }
}

/// 파형·눈금·결과에 쓴 구간(재생 위치·고르기를 읽지 않아 끄는 동안 다시 그리지 않는다)
private struct EditSourceLayer: View {
    let model: TrackEditModel
    let scale: EditLaneScale

    var body: some View {
        let entries = model.entries
        let scale = scale
        Canvas { context, size in
            let x = { (t: Double) in scale.x(t) }
            let visible = scale.visible
            let ruler = EditMetrics.ruler
            let wave = CGRect(x: 0, y: ruler, width: size.width, height: size.height - ruler - 14)
            if let waveform = model.waveform, visible.upperBound > visible.lowerBound {
                drawBands(context, waveform: waveform, from: visible.lowerBound - model.timelineOffset,
                          to: visible.upperBound - model.timelineOffset, in: wave)
            }
            guard let layout = model.layout else { return }
            // 결과에 쓴 구간: 아래 가는 띠 + 번호(같은 자리에서 시작하는 구간은 번호를 옆으로 민다)
            var chipX = -CGFloat.infinity
            for (index, entry) in entries.enumerated() {
                let color = EditColors.entry(index)
                let from = x(layout.start(ofBar: entry.range.first)), to = x(layout.end(ofBar: entry.range.last))
                guard to >= 0, from <= size.width else { continue }
                context.fill(Path(CGRect(x: from, y: size.height - 13, width: max(1, to - from), height: 3)), with: .color(color))
                chipX = max(max(from, 0) + 1, chipX + 16)
                if chipX < size.width - 10 {
                    context.draw(Text(verbatim: "\(index + 1)").font(.system(size: 8, weight: .bold).monospacedDigit()).foregroundStyle(color),
                                 at: CGPoint(x: chipX, y: size.height - 1), anchor: .bottomLeading)
                }
            }
            drawBarRuler(context, layout: layout, bars: visibleBars(layout, visible), x: x, height: ruler, width: size.width)
        }
    }
}

/// 보이는 자리의 마디(눈금은 이것만 그린다)
private func visibleBars(_ layout: BarLayout, _ visible: ClosedRange<Double>) -> ClosedRange<Int> {
    let first = max(1, layout.bar(at: visible.lowerBound))
    return first...max(first, min(max(1, layout.count), layout.bar(at: visible.upperBound) + 1))
}

/// 끌어 고른 구간(고르는 동안 이 층만 다시 그린다). 결과로 끄는 동안은 점선으로 그린다.
private struct EditSelectionLayer: View {
    let model: TrackEditModel
    let scale: EditLaneScale
    let carrying: Bool

    var body: some View {
        let selection = model.selection
        let scale = scale, carrying = carrying
        Canvas { context, size in
            guard let selection, let layout = model.layout else { return }
            let from = scale.x(layout.start(ofBar: selection.first)), to = scale.x(layout.end(ofBar: selection.last))
            let band = CGRect(x: from, y: EditMetrics.ruler, width: max(2, to - from), height: size.height - EditMetrics.ruler)
            context.fill(Path(band), with: .color(EditColors.selection.opacity(carrying ? 0.35 : 0.22)))
            context.stroke(Path(band.insetBy(dx: 0.75, dy: 0.75)), with: .color(EditColors.selection),
                           style: StrokeStyle(lineWidth: 1.5, dash: carrying ? [5, 3] : []))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 결과 타임라인

/// 편집 결과: 클립(목록 구간)을 이어 놓은 타임라인. 클립을 누르면 고르고 재생선을 옮기며, 끌면 순서를 바꾸고,
/// 가장자리를 끌면 마디 줄에 붙여 다듬는다. 위 눈금을 누르거나 끌면 재생선만 옮긴다. 아래 줄의 가위 단추로 이음새 앞뒤를 들어 본다.
struct EditOutputStrip: View {
    let model: TrackEditModel
    /// 클립 줄 자리를 알린다(편집 창 좌표). 원곡에서 고른 구간을 끌어 놓을 자리를 찾는다.
    let onLaneFrame: (CGRect) -> Void
    @State private var pointer: EditPointer

    /// - Parameter pointer: 처음 누르기·끌기 상태(끄는 중 모습을 캡처할 때)
    init(model: TrackEditModel, pointer: EditPointer = EditPointer(), onLaneFrame: @escaping (CGRect) -> Void = { _ in }) {
        self.model = model
        self.onLaneFrame = onLaneFrame
        _pointer = State(initialValue: pointer)
    }
    /// 포인터가 클립 가장자리 위인지(다듬기 커서)
    @State private var overEdge = false

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let scale = EditLaneScale(model, .output, width: geo.size.width)
                ZStack {
                    EditOutputLayer(model: model, scale: scale, dragging: pointer.dragging)
                    if let offset = pointer.dropOffset {
                        EditDropMarker(model: model, scale: scale, offset: offset, label: nil)
                    }
                    if let trim = pointer.trimming {
                        EditTrimMarker(model: model, scale: scale, trim: trim)
                    }
                    EditInsertMarker(model: model, scale: scale)
                    EditPlayhead(model: model, lane: .output)
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    var edge = false
                    if case let .active(point) = phase, point.y >= EditMetrics.ruler {
                        edge = model.clipLayout.edge(atOutput: scale.time(point.x),
                                                     tolerance: EditPointer.edgeReach * scale.secondsPerPoint) != nil
                    }
                    if overEdge != edge { overEdge = edge }
                }
                .pointerStyle(overEdge || pointer.trimming != nil ? .columnResize : nil)
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    pointer.output(model, from: scale.time(value.startLocation.x), to: scale.time(value.location.x),
                                   inRuler: value.startLocation.y < EditMetrics.ruler, moved: abs(value.translation.width),
                                   secondsPerPoint: scale.secondsPerPoint)
                }.onEnded { value in
                    pointer.endOutput(model, at: scale.time(value.location.x))
                })
            }
            .modifier(LaneZoomGestures(model: model, lane: .output))
            .modifier(LaneFrame(focused: model.focus == .output))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(EditMetrics.space)) } action: { onLaneFrame($0) }
            .selfTestFrame("editOutput")
            .accessibilityElement(children: .contain)
            .accessibilityLabel(.ui("편집 결과 타임라인"))
            .laneZoomAction(model, .output)
            .accessibilityChildren {
                // VoiceOver로 클립을 고른다(끌어 옮기기는 아래 앞으로·뒤로 단추, 다듬기는 마디 칸).
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

/// 클립·이음새·옮긴 큐·눈금(재생 위치를 읽지 않는다). 확대하면 보이는 자리만 그린다.
private struct EditOutputLayer: View {
    let model: TrackEditModel
    let scale: EditLaneScale
    let dragging: TrackEditModel.Entry.ID?

    var body: some View {
        let clips = model.clipLayout
        let entries = model.entries
        let selected = model.selectedClip
        let seams = model.edit.map { $0.pieces.dropFirst().map(\.outputStart) } ?? []
        let placed = model.carry?.placed ?? []
        let bars = model.outputLayout
        let scale = scale
        Canvas { context, size in
            guard let length = clips.last?.outputEnd, length > 0, clips.count == entries.count else {
                context.draw(Text(.ui("원곡 파형을 끌어 구간을 고른 뒤 ‘결과에 넣기’를 누르거나 여기로 끌어 오면 이어집니다"))
                    .font(.callout).foregroundStyle(Palette.rulerText),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let x = { (t: Double) in scale.x(t) }
            let ruler = EditMetrics.ruler
            let lane = CGRect(x: 0, y: ruler + 2, width: size.width, height: size.height - ruler - 4)
            for (index, clip) in clips.enumerated() {
                let color = EditColors.entry(index)
                let rect = CGRect(x: x(clip.outputStart), y: lane.minY, width: max(2, x(clip.outputEnd) - x(clip.outputStart)), height: lane.height)
                let body = rect.insetBy(dx: 0.5, dy: 0)
                guard body.maxX >= 0, body.minX <= size.width else { continue }
                // 보이는 부분만 그린다(확대하면 클립이 창보다 몇십 배 넓다).
                let shown = body.intersection(CGRect(x: -2, y: body.minY, width: size.width + 4, height: body.height))
                var slice = context
                slice.clip(to: Path(roundedRect: body, cornerRadius: 3))
                slice.opacity = entries[index].id == dragging ? 0.35 : 1
                slice.fill(Path(shown), with: .color(color.opacity(0.16)))
                if let waveform = model.waveform, shown.width > 0 {
                    let from = clip.sourceStart + scale.time(shown.minX) - clip.outputStart
                    let to = clip.sourceStart + scale.time(shown.maxX) - clip.outputStart
                    let wave = CGRect(x: shown.minX, y: body.minY + 16, width: shown.width, height: body.height - 16)
                    drawBands(slice, waveform: waveform, from: from - model.timelineOffset, to: to - model.timelineOffset, in: wave)
                }
                // 머리 띠: 번호와 원곡 마디(확대해 클립 머리가 왼쪽 밖이면 보이는 왼쪽 끝에 붙인다)
                slice.fill(Path(CGRect(x: shown.minX, y: body.minY, width: shown.width, height: 14)), with: .color(color.opacity(0.85)))
                if shown.width > 18 {
                    let label = shown.width > 70 ? "\(index + 1) · \(clip.bars.description)" : "\(index + 1)"
                    slice.draw(Text(verbatim: label).font(.system(size: 9, weight: .semibold).monospacedDigit()).foregroundStyle(.black),
                               at: CGPoint(x: max(body.minX, 0) + 4, y: body.minY + 7), anchor: .leading)
                }
                let isSelected = entries[index].id == selected
                context.stroke(Path(roundedRect: body.insetBy(dx: isSelected ? 1 : 0.5, dy: isSelected ? 1 : 0.5), cornerRadius: 3),
                               with: .color(isSelected ? .white : color.opacity(0.9)), lineWidth: isSelected ? 2 : 1)
            }
            // 이음새(원곡에서 이어지지 않는 경계): 흰 점선
            for seam in seams {
                let px = x(seam)
                guard px >= -2, px <= size.width + 2 else { continue }
                var line = Path()
                line.move(to: CGPoint(x: px, y: ruler))
                line.addLine(to: CGPoint(x: px, y: size.height))
                context.stroke(line, with: .color(EditColors.seam), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            // 옮긴 큐: 머리 띠 아래 작은 삼각형(핫큐 초록·메모리 빨강·루프 주황)
            for cue in placed {
                let px = x(cue.time), top = lane.minY + 14
                guard px >= -5, px <= size.width + 5 else { continue }
                var mark = Path()
                mark.move(to: CGPoint(x: px - 4, y: top))
                mark.addLine(to: CGPoint(x: px + 4, y: top))
                mark.addLine(to: CGPoint(x: px, y: top + 6))
                mark.closeSubpath()
                context.fill(mark, with: .color(Palette.color(for: cue)))
            }
            if let bars {
                drawBarRuler(context, layout: bars, bars: visibleBars(bars, scale.visible), x: x, height: ruler, width: size.width)
            }
        }
    }
}

/// 끌어 온 클립·구간을 놓을 자리(클립 사이 세로 막대, 넣을 구간이면 그 마디를 적는다)
private struct EditDropMarker: View {
    let model: TrackEditModel
    let scale: EditLaneScale
    let offset: Int
    let label: String?

    var body: some View {
        let clips = model.clipLayout
        let scale = scale, label = label
        Canvas { context, size in
            let time = offset < clips.count ? clips[offset].outputStart : clips.last?.outputEnd ?? 0
            let px = min(max(scale.x(time), 1.5), size.width - 1.5)
            context.fill(Path(CGRect(x: px - 1.5, y: EditMetrics.ruler, width: 3, height: size.height - EditMetrics.ruler)),
                         with: .color(.accentColor))
            if let label {
                let text = context.resolve(Text(verbatim: label).font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white))
                let textSize = text.measure(in: size)
                let chip = CGRect(x: min(px + 4, size.width - textSize.width - 10), y: EditMetrics.ruler + 18,
                                  width: textSize.width + 8, height: textSize.height + 4)
                context.fill(Path(roundedRect: chip, cornerRadius: 4), with: .color(.accentColor))
                context.draw(text, at: CGPoint(x: chip.midX, y: chip.midY))
            }
        }
        .allowsHitTesting(false)
    }
}

/// 원곡에서 고른 구간을 끌어 오는 동안 놓을 자리(끌기는 원곡 줄이 받는다)
private struct EditInsertMarker: View {
    let model: TrackEditModel
    let scale: EditLaneScale

    var body: some View {
        if let insertion = model.insertPreview {
            EditDropMarker(model: model, scale: scale, offset: insertion.offset, label: "+ \(insertion.range.description)")
        }
    }
}

/// 가장자리를 끄는 동안: 새 가장자리(마디 줄에 붙은 자리)와 새 구간. 줄어드는 쪽은 어둡게, 늘어나는 쪽은 강조색으로.
private struct EditTrimMarker: View {
    let model: TrackEditModel
    let scale: EditLaneScale
    let trim: EditPointer.Trim

    var body: some View {
        let clips = model.clipLayout
        let scale = scale, trim = trim
        Canvas { context, size in
            guard let layout = model.layout, clips.indices.contains(trim.clip) else { return }
            let clip = clips[trim.clip]
            let old = trim.edge == .end ? clip.outputEnd : clip.outputStart
            let new = trim.edge == .end ? clip.outputEnd + layout.end(ofBar: trim.range.last) - clip.sourceEnd
                : clip.outputStart + layout.start(ofBar: trim.range.first) - clip.sourceStart
            let top = EditMetrics.ruler + 2, height = size.height - top - 2
            let a = scale.x(min(old, new)), b = scale.x(max(old, new))
            let shrinking = trim.edge == .end ? new < old : new > old
            if b - a > 0.5 {
                context.fill(Path(CGRect(x: a, y: top, width: b - a, height: height)),
                             with: .color(shrinking ? .black.opacity(0.55) : Color.accentColor.opacity(0.3)))
            }
            let px = scale.x(new)
            context.fill(Path(CGRect(x: px - 1, y: top, width: 2, height: height)), with: .color(.accentColor))
            let text = context.resolve(Text(verbatim: trim.range.description).font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white))
            let textSize = text.measure(in: size)
            let x = trim.edge == .end ? px - textSize.width - 12 : px + 4
            let chip = CGRect(x: min(max(x, 2), size.width - textSize.width - 10), y: top + 16,
                              width: textSize.width + 8, height: textSize.height + 4)
            context.fill(Path(roundedRect: chip, cornerRadius: 4), with: .color(.accentColor))
            context.draw(text, at: CGPoint(x: chip.midX, y: chip.midY))
        }
        .allowsHitTesting(false)
    }
}

/// 이음새마다 들어 보기 단추(타임라인 아래, 이음새 자리). 확대하면 보이는 이음새만.
private struct EditSeamBar: View {
    let model: TrackEditModel

    var body: some View {
        GeometryReader { geo in
            if let edit = model.edit, edit.duration > 0 {
                let scale = EditLaneScale(model, .output, width: geo.size.width)
                ForEach(Array(edit.pieces.enumerated().dropFirst()).filter { scale.visible.contains($0.element.outputStart) },
                        id: \.offset) { piece, item in
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
                    .position(x: min(max(scale.x(item.outputStart), 20), geo.size.width - 20), y: geo.size.height / 2)
                }
            }
        }
    }
}
