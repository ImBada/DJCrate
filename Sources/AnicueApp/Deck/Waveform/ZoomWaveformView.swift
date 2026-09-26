import RekordboxKit
import AnicueAnalysis
import AnicueDomain
import AnicueStorage
import AppKit
import SwiftUI

/// 파형 위 스크롤 휠 처리. SwiftUI에는 휠 이벤트가 없어서 로컬 이벤트 모니터로 받는다.
/// 세로 휠: 확대·축소 / 가로 스크롤(트랙패드·Shift+휠): 위치 이동. 파형 영역 밖 스크롤은 건드리지 않는다.
@MainActor
final class WaveformScrollHandler {
    /// 파형 자리의 AppKit 뷰(창 좌표로 마우스가 파형 위인지 본다)
    weak var probe: NSView?
    weak var deck: DeckModel?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let deck = self.deck, let probe = self.probe, event.window === probe.window,
                  probe.bounds.contains(probe.convert(event.locationInWindow, from: nil)) else { return event }
            let precise = event.hasPreciseScrollingDeltas
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            if abs(dy) >= abs(dx) {
                // 손가락을 뗀 뒤의 관성 스크롤로는 확대하지 않는다.
                guard dy != 0, event.momentumPhase.isEmpty else { return nil }
                deck.zoom(by: precise ? exp(-Double(dy) * 0.01) : (dy > 0 ? 0.85 : 1.18))
            } else {
                // 가로 이동은 이벤트마다 오디오를 다시 시작하지 않고 모아서 처리한다.
                let seconds = -Double(dx) / Double(max(probe.bounds.width, 1)) * deck.zoomSeconds * (precise ? 1 : 6)
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
                    PerfProbe.measureDraw { draw(context, size: size, state: state, start: start, window: window, xOf: xOf) }
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
        .background { HitProbe { scroll.probe = $0 } }
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
        if let waveform = state.waveform, !PerfProbe.skipBands {
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

    /// 다음 메모리 큐까지 남은 박(규칙은 `CueCountdown`)
    static func countdown(to cues: [EditableCue], from time: Double, grid: BeatGrid?) -> String? {
        CueCountdown.text(to: cues, from: time, grid: grid)
    }
}

// MARK: - 전체 개요
