import RekordboxKit
import AnicueAnalysis
import AnicueDomain
import AnicueStorage
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
func drawBands(_ context: GraphicsContext, waveform: Waveform, from start: Double, to end: Double,
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

func chip(_ context: GraphicsContext, _ text: String, at point: CGPoint, color: Color, selected: Bool, maxX: CGFloat = .infinity) {
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
struct DrawState {
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
