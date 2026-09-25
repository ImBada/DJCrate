import AnicueCore
import AppKit
import SwiftUI

enum Palette {
    static let low = Color(red: 0.23, green: 0.44, blue: 0.96)
    static let mid = Color(red: 0.94, green: 0.64, blue: 0.24)
    static let high = Color(red: 0.95, green: 0.94, blue: 0.91)
    static let hot = Color(red: 1.0, green: 0.35, blue: 0.55)
    static let memory = Color(red: 0.94, green: 0.28, blue: 0.28)
    static let suggestion = Color(red: 0.21, green: 0.82, blue: 0.69)
    static let section = Color(red: 0.56, green: 0.53, blue: 1.0)
    static let well = Color(red: 0.043, green: 0.047, blue: 0.055)
}

/// 3밴드 파형을 가운데 기준 대칭으로 그린다.
/// 픽셀 열의 샘플 구간을 곡의 절대 시간(빈 = span/열 수)에 고정한다. 창이 움직여도 빈 경계가
/// 바뀌지 않아 스크롤 중 반짝임(에일리어싱)이 생기지 않는다.
private func drawBands(_ context: GraphicsContext, waveform: Waveform, from start: Double, to end: Double,
                       in rect: CGRect, scales: (Double, Double, Double) = (1, 0.78, 0.5)) {
    let columns = max(1, Int(rect.width))
    let span = end - start
    guard span > 0, waveform.count > 0 else { return }
    let binDuration = span / Double(columns)
    let firstBin = Int((start / binDuration).rounded(.down))
    let cy = rect.midY, half = rect.height / 2
    // 가장자리 빈이 창 밖으로 반 칸 나가므로 가로만 잘라낸다.
    var context = context
    context.clip(to: Path(rect.insetBy(dx: 0, dy: -rect.height)))
    for (band, scale, color) in [(waveform.low, scales.0, Palette.low), (waveform.mid, scales.1, Palette.mid),
                                 (waveform.high, scales.2, Palette.high)] {
        var top: [CGPoint] = [], bottom: [CGPoint] = []
        top.reserveCapacity(columns + 2); bottom.reserveCapacity(columns + 2)
        for k in 0...(columns + 1) {
            let t0 = Double(firstBin + k) * binDuration
            let a = Int((t0 * waveform.rate).rounded(.down))
            let b = max(a + 1, Int(((t0 + binDuration) * waveform.rate).rounded(.down)))
            var peak: UInt8 = 0
            if a < band.count, b > 0 {
                for i in max(0, a)..<min(band.count, b) where band[i] > peak { peak = band[i] }
            }
            let amplitude = Double(peak) / 255 * half * scale
            let x = rect.minX + CGFloat((t0 - start) / span) * rect.width
            top.append(CGPoint(x: x, y: cy - amplitude))
            bottom.append(CGPoint(x: x, y: cy + amplitude))
        }
        var path = Path()
        path.addLines(top + bottom.reversed())
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }
}

private func chip(_ context: GraphicsContext, _ text: String, at point: CGPoint, color: Color, selected: Bool, maxX: CGFloat = .infinity) {
    let label = context.resolve(Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.black))
    let size = label.measure(in: CGSize(width: 200, height: 20))
    let half = size.width / 2 + 4
    let cx = min(max(point.x, half + 1), maxX - half - 1)
    let rect = CGRect(x: cx - half, y: point.y, width: size.width + 8, height: 14)
    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
    if selected { context.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4), with: .color(.white), lineWidth: 1.5) }
    context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY))
}

// MARK: - 확대 파형

/// Canvas 렌더러 안에서 읽은 값은 관찰 추적이 되지 않으므로, 본문에서 읽어 넘긴다.
private struct DrawState {
    var grid: BeatGrid?
    var waveform: Waveform?
    var sections: [PartAnalysis.Span]
    var energies: [PartLabeler.SectionEnergy]
    var suggestions: [Double]
    var cues: [EditableCue]
    var selected: EditableCue.ID?
    var playhead: Double
    var zoomSeconds: Double
    var segments: [GridSegment]
    var gridEditing: Bool

    @MainActor init(_ deck: DeckModel) {
        grid = deck.grid
        waveform = deck.waveform
        sections = deck.analysis?.sections ?? []
        energies = deck.sectionEnergies
        suggestions = deck.suggestions
        cues = deck.draft?.cues ?? []
        selected = deck.selectedCueID
        playhead = deck.currentTime
        zoomSeconds = deck.zoomSeconds
        segments = deck.gridDraft?.segments ?? []
        gridEditing = deck.gridEditing && deck.canEditGrid
    }
}

/// 파형 위 스크롤 휠 처리. SwiftUI에는 휠 이벤트가 없어서 로컬 이벤트 모니터로 받는다.
/// 세로 휠: 확대·축소 / 가로 스크롤(트랙패드·Shift+휠): 위치 이동. 파형 영역 밖 스크롤은 건드리지 않는다.
@MainActor
final class WaveformScrollHandler {
    var frame: CGRect = .zero
    weak var deck: DeckModel?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let deck = self.deck, let content = event.window?.contentView else { return event }
            let location = event.locationInWindow
            let point = CGPoint(x: location.x, y: content.bounds.height - location.y)
            guard self.frame.contains(point) else { return event }
            let precise = event.hasPreciseScrollingDeltas
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            if abs(dy) >= abs(dx) {
                // 손가락을 뗀 뒤의 관성 스크롤로는 확대하지 않는다.
                guard dy != 0, event.momentumPhase.isEmpty else { return nil }
                deck.zoom(by: precise ? exp(-Double(dy) * 0.01) : (dy > 0 ? 0.85 : 1.18))
            } else {
                // 가로 이동은 이벤트마다 오디오를 다시 시작하지 않고 모아서 처리한다.
                let seconds = -Double(dx) / Double(max(self.frame.width, 1)) * deck.zoomSeconds * (precise ? 1 : 6)
                deck.scrubCoalesced(to: deck.currentTime + seconds)
            }
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct ZoomWaveformView: View {
    @Bindable var deck: DeckModel
    @State private var drag: DragMode?
    @State private var scroll = WaveformScrollHandler()
    @State private var pinchBase: Double?

    private enum DragMode {
        /// 큐를 잡았다. 3px 넘게 끌기 전에는 움직이지 않는다(클릭만으로 큐가 바뀌지 않도록).
        case cue(EditableCue.ID, originalTime: Double)
        case scrub(from: Double)
        case grid
    }

    var body: some View {
        GeometryReader { geo in
                let center = deck.currentTime
                let window = deck.zoomSeconds
                let start = center - window / 2
                let time = { (x: CGFloat) in start + Double(x / max(geo.size.width, 1)) * window }
                let xOf = { (t: Double) in CGFloat((t - start) / window) * geo.size.width }

                let state = DrawState(deck)
                Canvas { context, size in
                    draw(context, size: size, state: state, start: start, window: window, xOf: xOf)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if drag == nil {
                                if deck.gridEditing, deck.canEditGrid {
                                    deck.beginGridDrag()
                                    drag = .grid
                                } else if let hit = hitCue(atX: value.startLocation.x, xOf: xOf) {
                                    deck.selectedCueID = hit
                                    drag = .cue(hit, originalTime: deck.cue(hit)?.time ?? center)
                                } else {
                                    deck.beginScrub()
                                    drag = .scrub(from: center)
                                }
                            }
                            let secondsPerPoint = window / Double(max(geo.size.width, 1))
                            switch drag {
                            case let .cue(id, originalTime):
                                guard abs(value.translation.width) > 3 else { break }
                                deck.move(id, to: originalTime + Double(value.translation.width) * secondsPerPoint, save: false)
                            case let .scrub(from):
                                deck.scrub(to: from - Double(value.translation.width) * secondsPerPoint)
                            case .grid:
                                deck.dragGrid(by: Double(value.translation.width) * secondsPerPoint)
                            case nil:
                                break
                            }
                        }
                        .onEnded { value in
                            switch drag {
                            case .cue:
                                if abs(value.translation.width) > 3 { deck.commitDraft() }
                            case .grid:
                                deck.endGridDrag()
                            case .scrub:
                                // 제안 마커를 짧게 클릭하면 메모리 큐로 받아들인다.
                                if abs(value.translation.width) < 2,
                                   let s = deck.suggestions.first(where: { abs(xOf($0) - value.location.x) < 7 }) {
                                    deck.acceptSuggestion(s)
                                }
                                deck.endScrub()
                            case nil:
                                break
                            }
                            drag = nil
                        }
                )
                .simultaneousGesture(
                    SpatialTapGesture(count: 2).onEnded { value in
                        if !deck.gridEditing, hitCue(atX: value.location.x, xOf: xOf) == nil {
                            deck.addMemoryCue(at: time(value.location.x))
                        }
                    }
                )
        }
        .background(Palette.well)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    if pinchBase == nil { pinchBase = deck.zoomSeconds }
                    deck.setZoom((pinchBase ?? deck.zoomSeconds) / max(value.magnification, 0.05))
                }
                .onEnded { _ in pinchBase = nil }
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { scroll.frame = $0 }
        .onAppear { scroll.deck = deck; scroll.install() }
        .onDisappear { scroll.remove() }
        .accessibilityLabel("확대 3밴드 파형. 드래그로 스크럽, 큐를 끌어 이동, 더블클릭으로 메모리 큐 추가, 휠로 확대·축소")
    }

    private func hitCue(atX x: CGFloat, xOf: (Double) -> CGFloat) -> EditableCue.ID? {
        deck.draft?.cues
            .map { ($0.id, abs(xOf($0.time) - x)) }
            .filter { $0.1 < 7 }
            .min { $0.1 < $1.1 }?.0
    }

    private func draw(_ context: GraphicsContext, size: CGSize, state: DrawState, start: Double, window: Double, xOf: (Double) -> CGFloat) {
        let end = start + window
        // 비트 그리드 (rekordbox PQTZ): 창 안의 박만 이진 탐색으로 찾아 돈다.
        if let grid = state.grid {
            var i = grid.firstIndex(atOrAfter: start)
            while i < grid.beats.count, grid.beats[i].time <= end {
                let beat = grid.beats[i]
                i += 1
                let x = xOf(beat.time)
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                let strong = state.gridEditing ? (beat.isDownbeat ? 0.55 : 0.22) : (beat.isDownbeat ? 0.22 : 0.07)
                context.stroke(line, with: .color((state.gridEditing ? Palette.mid : .white).opacity(strong)),
                               lineWidth: beat.isDownbeat && state.gridEditing ? 1.5 : 1)
                if state.gridEditing {
                    context.draw(Text("\(beat.number)").font(.system(size: 9, weight: beat.isDownbeat ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(beat.isDownbeat ? Palette.mid : Color.gray), at: CGPoint(x: x + 2, y: size.height - 26), anchor: .leading)
                }
                if beat.isDownbeat {
                    let bar = grid.bar(at: beat.time)
                    if bar % 4 == 1, x < size.width - 18 {
                        context.draw(Text("\(bar)").font(.system(size: 10).monospacedDigit()).foregroundStyle(Color.gray),
                                     at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                    }
                }
            }
        }
        if let waveform = state.waveform {
            drawBands(context, waveform: waveform, from: start, to: end,
                      in: CGRect(x: 0, y: 16, width: size.width, height: size.height - 34))
        }
        // 변속 지점(템포 구간 경계)
        for segment in state.segments.dropFirst() where segment.start > start && segment.start < end {
            let x = xOf(segment.start)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.yellow), lineWidth: 2)
            let nearRight = x > size.width - 80
            context.draw(Text(String(format: "%.2f BPM", segment.bpm)).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.yellow),
                         at: CGPoint(x: nearRight ? x - 4 : x + 4, y: 20), anchor: nearRight ? .trailing : .leading)
        }
        // MU 섹션 경계
        for section in state.sections where section.start > start && section.start < end {
            var line = Path()
            line.move(to: CGPoint(x: xOf(section.start), y: 16)); line.addLine(to: CGPoint(x: xOf(section.start), y: size.height))
            context.stroke(line, with: .color(Palette.section), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        }
        for s in state.suggestions where s > start && s < end {
            var line = Path()
            line.move(to: CGPoint(x: xOf(s), y: 16)); line.addLine(to: CGPoint(x: xOf(s), y: size.height - 16))
            context.stroke(line, with: .color(Palette.suggestion), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            context.draw(Text("+").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.suggestion),
                         at: CGPoint(x: xOf(s), y: size.height - 8))
        }
        // 큐 (초안)
        for cue in state.cues where cue.time >= start - 1 && cue.time <= end + 1 {
            let x = xOf(cue.time)
            let selected = cue.id == state.selected
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
            switch cue.kind {
            case .memory:
                context.stroke(line, with: .color(Palette.memory), lineWidth: selected ? 2.5 : 1.2)
                var tri = Path()
                tri.addLines([CGPoint(x: x - 6, y: 16), CGPoint(x: x + 6, y: 16), CGPoint(x: x, y: 26)])
                tri.closeSubpath()
                context.fill(tri, with: .color(Palette.memory))
                if selected { context.stroke(tri, with: .color(.white), lineWidth: 1.2) }
            case .hot:
                context.stroke(line, with: .color(Palette.hot), lineWidth: selected ? 2.5 : 1.8)
                chip(context, cue.kind.slotLetter ?? "", at: CGPoint(x: x, y: size.height - 16), color: Palette.hot, selected: selected, maxX: size.width)
            }
            if !cue.name.isEmpty {
                let nearRight = x > size.width - 90
                context.draw(Text(cue.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white),
                             at: CGPoint(x: nearRight ? x - 5 : x + 5, y: 34), anchor: nearRight ? .trailing : .leading)
            }
        }
        // 플레이헤드
        let px = xOf(state.playhead)
        var head = Path()
        head.move(to: CGPoint(x: px, y: 0)); head.addLine(to: CGPoint(x: px, y: size.height))
        context.stroke(head, with: .color(.white), lineWidth: 2)
    }
}

// MARK: - 전체 개요

struct OverviewWaveformView: View {
    @Bindable var deck: DeckModel
    @State private var scrubbing = false

    var body: some View {
        GeometryReader { geo in
            let duration = max(deck.duration, 1)
            ZStack {
                OverviewStaticLayer(deck: deck, duration: duration)
                OverviewPlayheadLayer(deck: deck, duration: duration)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !scrubbing { scrubbing = true; deck.beginScrub() }
                    deck.scrub(to: Double(value.location.x / max(geo.size.width, 1)) * duration)
                }
                .onEnded { _ in
                    scrubbing = false
                    deck.endScrub()
                })
        }
        .background(Palette.well)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("전체 곡 3밴드 파형. 클릭해서 위치 이동")
    }
}

/// 파형·섹션 띠·큐·제안. 재생 위치를 읽지 않으므로 재생 중에는 다시 그려지지 않는다.
private struct OverviewStaticLayer: View {
    let deck: DeckModel
    let duration: Double

    var body: some View {
        let waveform = deck.waveform
        let energies = deck.sectionEnergies
        let suggestions = deck.suggestions
        let cues = deck.draft?.cues ?? []
        let selected = deck.selectedCueID
        Canvas { context, size in
            let xOf = { (t: Double) in CGFloat(t / duration) * size.width }
            let waveHeight = size.height - 20
            if let waveform {
                drawBands(context, waveform: waveform, from: 0, to: duration,
                          in: CGRect(x: 0, y: 2, width: size.width, height: waveHeight - 2))
            }
            let scores = energies.map(\.score).filter(\.isFinite)
            let lo = scores.min() ?? 0, hi = scores.max() ?? 1
            for e in energies {
                let norm = e.score.isFinite && hi > lo ? (e.score - lo) / (hi - lo) : 0
                let rect = CGRect(x: xOf(e.span.start), y: waveHeight + 3,
                                  width: max(1, xOf(e.span.end) - xOf(e.span.start) - 1), height: 14)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Palette.section.opacity(0.1 + 0.62 * norm * norm)))
            }
            for s in suggestions {
                var line = Path()
                line.move(to: CGPoint(x: xOf(s), y: 0)); line.addLine(to: CGPoint(x: xOf(s), y: waveHeight))
                context.stroke(line, with: .color(Palette.suggestion), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            for cue in cues {
                var line = Path()
                line.move(to: CGPoint(x: xOf(cue.time), y: 0)); line.addLine(to: CGPoint(x: xOf(cue.time), y: waveHeight))
                let color = cue.kind == .memory ? Palette.memory : Palette.hot
                context.stroke(line, with: .color(color), lineWidth: cue.id == selected ? 2.5 : 1.2)
            }
        }
    }
}

/// 재생선과 확대 창 범위만 그린다(매 프레임).
private struct OverviewPlayheadLayer: View {
    let deck: DeckModel
    let duration: Double

    var body: some View {
        let t = deck.currentTime
        let zoom = deck.zoomSeconds
        Canvas { context, size in
            let xOf = { (time: Double) in CGFloat(time / duration) * size.width }
            let waveHeight = size.height - 20
            let window = CGRect(x: xOf(t - zoom / 2), y: 0, width: xOf(zoom), height: waveHeight)
            context.fill(Path(window), with: .color(.white.opacity(0.08)))
            context.stroke(Path(window), with: .color(.white.opacity(0.3)), lineWidth: 1)
            var head = Path()
            head.move(to: CGPoint(x: xOf(t), y: 0)); head.addLine(to: CGPoint(x: xOf(t), y: size.height))
            context.stroke(head, with: .color(.white), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

