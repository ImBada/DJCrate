import AnicueCore
import AppKit
import SwiftUI

enum Palette {
    /// Camelot 번호마다 색(휠 순서로 색상이 돈다). A/B는 밝기만 다르다.
    static func keyColor(_ camelot: String) -> Color {
        let text = camelot.uppercased()
        guard let number = Int(text.dropLast()), (1...12).contains(number) else { return .secondary }
        return Color(hue: Double(number - 1) / 12, saturation: 0.62, brightness: text.hasSuffix("A") ? 0.78 : 0.95)
    }

    /// 루프 구간·루프 큐(rekordbox처럼 주황)
    static let loop = Color(red: 1.0, green: 0.55, blue: 0.0)

    static let low = Color(red: 0.23, green: 0.44, blue: 0.96)
    static let mid = Color(red: 0.94, green: 0.64, blue: 0.24)
    static let high = Color(red: 0.95, green: 0.94, blue: 0.91)
    /// 핫큐: rekordbox 기본 핫큐 색(초록). 메모리 큐(빨강)와 한눈에 구분되게.
    static let hot = Color(red: 0.16, green: 0.86, blue: 0.24)
    static let memory = Color(red: 0.94, green: 0.25, blue: 0.25)
    static let cue = Color(red: 1.0, green: 0.56, blue: 0.08)
    /// 제안(메모리 큐 후보·추정 그리드): 핫큐 초록과 겹치지 않는 하늘색
    static let suggestion = Color(red: 0.35, green: 0.80, blue: 1.0)
    static let section = Color(red: 0.56, green: 0.53, blue: 1.0)
    static let well = Color(red: 0.043, green: 0.047, blue: 0.055)

    /// 큐 표시 색: 루프 = 주황, 핫큐 = 초록, 메모리 큐 = 빨강
    static func color(for cue: EditableCue) -> Color {
        cue.loop != nil ? loop : cue.kind == .memory ? memory : hot
    }
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
    var cuePoint: Double
    var previewGrid: BeatGrid?
    /// 파형은 음원 시간축이다. rekordbox 시간축 창을 이만큼 당겨서 읽는다.
    var audioOffset: Double
    var zoomSeconds: Double
    var segments: [GridSegment]
    var gridEditing: Bool
    var engagedLoop: EditableCue.ID?
    var instantLoop: DeckModel.InstantLoop?
    var loopSizeText: String

    @MainActor init(_ deck: DeckModel) {
        grid = deck.grid
        waveform = deck.waveform
        sections = deck.analysis?.sections ?? []
        energies = deck.sectionEnergies
        suggestions = deck.suggestions
        cues = deck.draft?.cues ?? []
        selected = deck.selectedCueID
        playhead = deck.currentTime
        cuePoint = deck.cuePoint
        previewGrid = deck.grid == nil ? deck.suggestedGrid : nil
        audioOffset = deck.timelineOffset
        zoomSeconds = deck.zoomSeconds
        segments = deck.gridDraft?.segments ?? []
        engagedLoop = deck.engagedLoopID
        instantLoop = deck.instantLoop
        loopSizeText = deck.loopSizeText
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
                                   let s = deck.suggestions.first(where: { abs(xOf($0) - value.location.x) < 11 }) {
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
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: Self.rulerHeight)), with: .color(.black.opacity(0.35)))
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
                // 상단 위치 표시(마디.박, 박은 0부터: 14.0 → 14.1 → 14.2 → 14.3).
                // 자리가 있으면 모든 박에 전체를, 좁으면 마디 첫 박만 전체로 쓰고 나머지는 `.1 .2 .3`으로 줄인다.
                let beatWidth = size.width / window * 60 / max(beat.bpm, 1)
                let bar = grid.bar(at: beat.time)
                let index = max(beat.number - 1, 0)
                let full = "\(bar).\(index)"
                let fullWidth = CGFloat(full.count) * 6 + 5
                let label: String? = if beat.isDownbeat {
                    beatWidth * 4 >= fullWidth || bar % 4 == 1 ? full : nil
                } else if beatWidth >= fullWidth {
                    full
                } else if beatWidth >= 15 {
                    ".\(index)"
                } else {
                    nil
                }
                if let label, x < size.width - CGFloat(label.count) * 6 - 4 {
                    context.draw(Text(label)
                        .font(.system(size: beat.isDownbeat ? 10 : 9, weight: beat.isDownbeat ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(Color.gray.opacity(beat.isDownbeat ? 1 : 0.7)),
                                 at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                }
            }
        }
        // 그리드가 없는 곡: 적용 전 추정 박을 점선으로 미리 보여 준다.
        if let preview = state.previewGrid {
            var i = preview.firstIndex(atOrAfter: start)
            while i < preview.beats.count, preview.beats[i].time <= end {
                let beat = preview.beats[i]
                i += 1
                var line = Path()
                line.move(to: CGPoint(x: xOf(beat.time), y: 0)); line.addLine(to: CGPoint(x: xOf(beat.time), y: size.height))
                context.stroke(line, with: .color(Palette.suggestion.opacity(beat.isDownbeat ? 0.6 : 0.25)),
                               style: StrokeStyle(lineWidth: beat.isDownbeat ? 1.5 : 1, dash: [3, 4]))
            }
        }
        if let waveform = state.waveform {
            drawBands(context, waveform: waveform, from: start - state.audioOffset, to: end - state.audioOffset,
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
        // 메모리 큐 제안: 밝은 파형 위에서도 보이게 어두운 테두리 위에 굵은 점선, 아래에 "+" 배지(누르면 메모리 큐)
        for s in state.suggestions where s > start && s < end {
            let x = xOf(s)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height - 22))
            context.stroke(line, with: .color(.black.opacity(0.55)), lineWidth: 4)
            context.stroke(line, with: .color(Palette.suggestion), style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
            let badge = CGRect(x: x - 9, y: size.height - 21, width: 18, height: 18)
            context.fill(Path(ellipseIn: badge.insetBy(dx: -1.5, dy: -1.5)), with: .color(.black.opacity(0.6)))
            context.fill(Path(ellipseIn: badge), with: .color(Palette.suggestion))
            context.draw(Text("+").font(.system(size: 15, weight: .heavy)).foregroundStyle(Color.black),
                         at: CGPoint(x: badge.midX, y: badge.midY - 0.5))
        }
        // 루프 구간(큐 선보다 먼저 칠한다). 활성 루프는 진하게 + ↻
        for cue in state.cues {
            guard let loop = cue.loop, loop.end >= start, cue.time <= end else { continue }
            let x0 = xOf(cue.time), x1 = xOf(loop.end)
            let band = CGRect(x: x0, y: Self.rulerHeight, width: max(1, x1 - x0), height: size.height - Self.rulerHeight)
            let engaged = state.engagedLoop == cue.id
            context.fill(Path(band), with: .color(Palette.loop.opacity(engaged ? 0.35 : loop.active ? 0.22 : 0.12)))
            let top = CGRect(x: x0, y: Self.rulerHeight, width: max(1, x1 - x0), height: 4)
            context.fill(Path(top), with: .color(Palette.loop.opacity(loop.active ? 0.95 : 0.6)))
            var endLine = Path()
            endLine.move(to: CGPoint(x: x1, y: Self.rulerHeight)); endLine.addLine(to: CGPoint(x: x1, y: size.height))
            context.stroke(endLine, with: .color(Palette.loop.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if loop.active, x1 - x0 > 16 {
                context.draw(Text("↻").font(.system(size: 12, weight: .heavy)).foregroundStyle(Palette.loop),
                             at: CGPoint(x: x0 + 8, y: Self.rulerHeight + 14))
            }
        }
        // 즉석 루프(아직 큐가 아님): 진한 주황 + 양끝 실선 + 박 수
        if let loop = state.instantLoop, loop.end >= start, loop.start <= end {
            let x0 = xOf(loop.start), x1 = xOf(loop.end)
            let band = CGRect(x: x0, y: Self.rulerHeight, width: max(1, x1 - x0), height: size.height - Self.rulerHeight)
            context.fill(Path(band), with: .color(Palette.loop.opacity(0.3)))
            context.fill(Path(CGRect(x: x0, y: Self.rulerHeight, width: max(1, x1 - x0), height: 4)), with: .color(Palette.loop))
            for x in [x0, x1] {
                var edge = Path()
                edge.move(to: CGPoint(x: x, y: Self.rulerHeight)); edge.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(edge, with: .color(Palette.loop), lineWidth: 1.5)
            }
            if x1 - x0 > 30 {
                context.draw(Text("↻ \(state.loopSizeText)").font(.system(size: 11, weight: .heavy)).foregroundStyle(Palette.loop),
                             at: CGPoint(x: x0 + 5, y: Self.rulerHeight + 14), anchor: .leading)
            }
        }
        // 큐 (초안)
        for cue in state.cues where cue.time >= start - 1 && cue.time <= end + 1 {
            let x = xOf(cue.time)
            let selected = cue.id == state.selected
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
            switch cue.kind {
            case .memory:
                context.stroke(line, with: .color(Palette.color(for: cue)), lineWidth: selected ? 2.5 : 1.2)
                var tri = Path()
                tri.addLines([CGPoint(x: x - 6, y: 16), CGPoint(x: x + 6, y: 16), CGPoint(x: x, y: 26)])
                tri.closeSubpath()
                context.fill(tri, with: .color(Palette.color(for: cue)))
                if selected { context.stroke(tri, with: .color(.white), lineWidth: 1.2) }
            case .hot:
                context.stroke(line, with: .color(Palette.color(for: cue)), lineWidth: selected ? 2.5 : 1.8)
                chip(context, cue.kind.slotLetter ?? "", at: CGPoint(x: x, y: size.height - 16), color: Palette.color(for: cue), selected: selected, maxX: size.width)
            }
            if !cue.name.isEmpty {
                let nearRight = x > size.width - 90
                context.draw(Text(cue.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white),
                             at: CGPoint(x: nearRight ? x - 5 : x + 5, y: 34), anchor: nearRight ? .trailing : .leading)
            }
        }
        // CUE 지점: 위쪽 주황 삼각형(메모리 큐 삼각형보다 위)
        if state.cuePoint >= start, state.cuePoint <= end {
            let x = xOf(state.cuePoint)
            var tri = Path()
            tri.addLines([CGPoint(x: x - 6, y: 0), CGPoint(x: x + 6, y: 0), CGPoint(x: x, y: 10)])
            tri.closeSubpath()
            context.fill(tri, with: .color(Palette.cue))
            var line = Path()
            line.move(to: CGPoint(x: x, y: 10)); line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(Palette.cue.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
        // 플레이헤드: 위 눈금 줄(마디.박 표시) 아래부터 긋고, 눈금 줄에는 작은 삼각형만 둔다(숫자를 가리지 않게).
        let px = xOf(state.playhead)
        var head = Path()
        head.move(to: CGPoint(x: px, y: Self.rulerHeight)); head.addLine(to: CGPoint(x: px, y: size.height))
        context.stroke(head, with: .color(.white), lineWidth: 2)
        var marker = Path()
        marker.addLines([CGPoint(x: px - 4, y: Self.rulerHeight - 5), CGPoint(x: px + 4, y: Self.rulerHeight - 5), CGPoint(x: px, y: Self.rulerHeight)])
        marker.closeSubpath()
        context.fill(marker, with: .color(.white))
        // 다음 메모리 큐까지: 재생선 바로 왼쪽 위 알약(파형 높이에 맞춰 글자 크기를 줄인다)
        if let text = Self.countdown(to: state.cues, from: state.playhead, grid: state.grid) {
            let fontSize = min(13, max(10, size.height / 9))
            let label = context.resolve(Text(text).font(.system(size: fontSize, weight: .heavy).monospacedDigit()).foregroundStyle(Palette.memory))
            let textSize = label.measure(in: CGSize(width: 200, height: 40))
            let width = textSize.width + 12
            let pill = CGRect(x: max(2, px - width - 3), y: Self.rulerHeight + 4, width: width, height: textSize.height + 4)
            context.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(.black.opacity(0.65)))
            context.draw(label, at: CGPoint(x: pill.midX, y: pill.midY))
        }
    }

    /// 위 눈금 줄(마디.박 숫자) 높이
    static let rulerHeight: CGFloat = 16

    /// 다음 메모리 큐까지 남은 박(64박 넘으면 마디.박, 그리드가 없으면 초).
    static func countdown(to cues: [EditableCue], from time: Double, grid: BeatGrid?) -> String? {
        guard let next = cues.filter({ $0.kind == .memory && $0.time > time + 0.005 }).min(by: { $0.time < $1.time }) else { return nil }
        guard let grid, !grid.beats.isEmpty else { return String(format: "−%.1fs", next.time - time) }
        // 지금 박 = 플레이헤드 이하 마지막 박, 큐 박 = 큐 지점 이상 첫 박(±5ms)
        let current = grid.firstIndex(atOrAfter: time + 0.001) - 1
        let target = grid.firstIndex(atOrAfter: next.time - 0.005)
        let beats = max(target - current, 0)
        guard beats > 0 else { return nil }
        return beats <= 64 ? "−\(beats) Beats" : "−\(beats / 4).\(beats % 4) Bars"
    }
}

// MARK: - 전체 개요

struct OverviewWaveformView: View {
    @Bindable var deck: DeckModel
    @State private var scrubbing = false

    var body: some View {
        GeometryReader { geo in
            let duration = max(deck.duration, 1)
            ZStack(alignment: .bottom) {
                OverviewStaticLayer(deck: deck, duration: duration)
                if deck.isAnalyzingSections {
                    // 섹션 칸(아래 띠) 자리에 분석 진행 표시
                    HStack(spacing: 6) {
                        ProgressView().progressViewStyle(.linear).tint(Palette.section)
                        Text("섹션 분석 중").font(.system(size: 9)).foregroundStyle(Palette.section)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .padding(.bottom, 15)
                    .allowsHitTesting(false)
                    .accessibilityLabel("섹션 분석 중")
                }
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
        let instantLoop = deck.instantLoop
        let selected = deck.selectedCueID
        let cuePoint = deck.cuePoint
        let audioOffset = deck.timelineOffset
        let keys = deck.keySegments.map { (segment: $0, name: deck.keyName(for: $0)) }
        let keyChanges = deck.keySegments.count > 1
        Canvas { context, size in
            let xOf = { (t: Double) in CGFloat(t / duration) * size.width }
            let waveHeight = size.height - 34
            if let waveform {
                drawBands(context, waveform: waveform, from: -audioOffset, to: duration - audioOffset,
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
            // 조성 띠(섹션 띠 아래). 바뀌는 곳이 있으면 진하게.
            for key in keys {
                let rect = CGRect(x: xOf(key.segment.start), y: waveHeight + 19,
                                  width: max(1, xOf(key.segment.end) - xOf(key.segment.start) - 1), height: 12)
                let color = Palette.keyColor(key.name)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(keyChanges ? 0.55 : 0.3)))
                if rect.width > 24 {
                    context.draw(Text(key.name).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white),
                                 at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading)
                }
            }
            for s in suggestions {
                var line = Path()
                line.move(to: CGPoint(x: xOf(s), y: 0)); line.addLine(to: CGPoint(x: xOf(s), y: waveHeight))
                context.stroke(line, with: .color(.black.opacity(0.5)), lineWidth: 3)
                context.stroke(line, with: .color(Palette.suggestion), style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
            }
            if let loop = instantLoop {
                let band = CGRect(x: xOf(loop.start), y: 0, width: max(2, xOf(loop.end) - xOf(loop.start)), height: waveHeight)
                context.fill(Path(band), with: .color(Palette.loop.opacity(0.45)))
            }
            for cue in cues {
                if let loop = cue.loop {
                    let band = CGRect(x: xOf(cue.time), y: 0, width: max(1.5, xOf(loop.end) - xOf(cue.time)), height: waveHeight)
                    context.fill(Path(band), with: .color(Palette.loop.opacity(loop.active ? 0.35 : 0.2)))
                }
                var line = Path()
                line.move(to: CGPoint(x: xOf(cue.time), y: 0)); line.addLine(to: CGPoint(x: xOf(cue.time), y: waveHeight))
                context.stroke(line, with: .color(Palette.color(for: cue)), lineWidth: cue.id == selected ? 2.5 : 1.2)
            }
            var tri = Path()
            let cx = xOf(cuePoint)
            tri.addLines([CGPoint(x: cx - 5, y: 0), CGPoint(x: cx + 5, y: 0), CGPoint(x: cx, y: 8)])
            tri.closeSubpath()
            context.fill(tri, with: .color(Palette.cue))
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
            let waveHeight = size.height - 34
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

