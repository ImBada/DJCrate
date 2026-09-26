import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import SwiftUI

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
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("전체 곡 \(deck.waveformColorMode.title) 파형. 클릭해서 위치 이동")
    }
}

/// 파형·섹션 띠·큐·제안. 재생 위치를 읽지 않으므로 재생 중에는 다시 그려지지 않는다.
struct OverviewStaticLayer: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let deck: DeckModel
    let duration: Double

    var body: some View {
        let waveform = deck.waveform
        let colorWaveform = deck.colorWaveform
        let mode = deck.waveformColorMode
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
            if mode == .threeBand, let waveform {
                drawBands(context, waveform: waveform, from: -audioOffset, to: duration - audioOffset,
                          in: CGRect(x: 0, y: 2, width: size.width, height: waveHeight - 2))
            } else {
                colorWaveform?.draw(context, from: 0, to: duration,
                                    in: CGRect(x: 0, y: 2, width: size.width, height: waveHeight - 2), full: true)
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
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(Palette.keyBandOpacity(changes: keyChanges))))
                if rect.width > 24 {
                    context.draw(Text(key.name).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white),
                                 at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading)
                }
            }
            for s in suggestions {
                var line = Path()
                line.move(to: CGPoint(x: xOf(s), y: 0)); line.addLine(to: CGPoint(x: xOf(s), y: waveHeight))
                context.stroke(line, with: .color(.black.opacity(0.5)), lineWidth: 3)
                context.stroke(line, with: .color(contrast == .increased ? Color.white : Palette.suggestion), style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
            }
            if let loop = instantLoop {
                let band = CGRect(x: xOf(loop.start), y: 0, width: max(2, xOf(loop.end) - xOf(loop.start)), height: waveHeight)
                context.fill(Path(band), with: .color(Palette.loop.opacity(contrast == .increased ? 0.65 : 0.45)))
            }
            for cue in cues {
                if let loop = cue.loop {
                    let band = CGRect(x: xOf(cue.time), y: 0, width: max(1.5, xOf(loop.end) - xOf(cue.time)), height: waveHeight)
                    context.fill(Path(band), with: .color(Palette.loop.opacity(contrast == .increased ? (loop.active ? 0.55 : 0.4) : (loop.active ? 0.35 : 0.2))))
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
struct OverviewPlayheadLayer: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let deck: DeckModel
    let duration: Double

    var body: some View {
        // 전체 파형은 넓어서 초당 15번이면 충분하다(창 전체 갱신을 매 프레임 일으키지 않게).
        let t = deck.displayTime
        let zoom = deck.zoomSeconds
        Canvas { context, size in
            let xOf = { (time: Double) in CGFloat(time / duration) * size.width }
            let waveHeight = size.height - 34
            let window = CGRect(x: xOf(t - zoom / 2), y: 0, width: xOf(zoom), height: waveHeight)
            context.fill(Path(window), with: .color(.white.opacity(0.08)))
            context.stroke(Path(window), with: .color(.white.opacity(contrast == .increased ? 0.7 : 0.3)), lineWidth: 1)
            var head = Path()
            head.move(to: CGPoint(x: xOf(t), y: 0)); head.addLine(to: CGPoint(x: xOf(t), y: size.height))
            context.stroke(head, with: .color(.white), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}
