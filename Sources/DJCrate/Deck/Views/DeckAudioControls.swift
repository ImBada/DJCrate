import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import SwiftUI

/// 볼륨 · 메트로놈 · 템포(변속) · 키 고정 · 그리드 편집 전환
struct AudioBar: View {
    @Environment(\.textScale) private var textScale
    @Bindable var deck: DeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 12) {
                HStack(spacing: 4) {
                    // 음파 줄 수가 볼륨을 따라 채워진다. 0이면 꺼진 스피커.
                    Group {
                        if deck.volume == 0 {
                            Image(systemName: "speaker.slash")
                        } else {
                            Image(systemName: "speaker.wave.3", variableValue: deck.volume)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    Slider(value: $deck.volume, in: 0...1).frame(width: 90)
                        .accessibilityLabel("재생 볼륨")
                }
                GainControl(deck: deck)
                Group { if PerfProbe.hidden.contains("meter") { EmptyView() } else { LevelMeterView(deck: deck) } }
            }
            FlowLayout(spacing: 12) {
                Toggle(isOn: $deck.metronome) { Label("메트로놈", systemImage: "metronome") }
                    .toggleStyle(.button)
                    .help("그리드의 박마다 클릭 (1박은 높은 음)")
                HStack(spacing: 4) {
                    Text("템포").foregroundStyle(.secondary)
                    Slider(value: $deck.tempoPercent, in: -16...16, step: 0.1).frame(width: 120)
                        .accessibilityLabel("재생 템포")
                    Text(String(format: "%+.1f%%", deck.tempoPercent)).font(.scaled(.caption, textScale).monospacedDigit())
                        .frame(width: TextScale.length(46, scale: textScale), alignment: .trailing)
                    Button("0") { deck.tempoPercent = 0 }.help("원래 속도로")
                }
                Toggle("키 고정", isOn: $deck.keyLock)
                    .toggleStyle(.checkbox)
                    .help("켜면 음정을 유지한 채 속도만 바꿉니다(마스터 템포). 끄면 바이닐처럼 음정도 함께 바뀝니다.")
                Toggle(isOn: $deck.gridEditing) { Label("그리드 편집", systemImage: "grid") }
                    .toggleStyle(.button)
                    .disabled(deck.gridDraft == nil)
                    .help(deck.gridEditBlockedReason ?? "켜면 파형을 끌어 그리드를 옮기고, 아래 막대로 BPM·1박·변속 지점을 고칩니다.")
            }
            // 제안 문구가 길어져도 음량·템포 묶음을 밀어내지 않는다.
            if let suggestion = deck.gainSuggestion {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars").foregroundStyle(UIColors.suggestion.color)
                    Text(String(format: "게인 제안 %+.1f dB (rekordbox %+.1f)", suggestion, deck.rekordboxGainDB ?? 0))
                        .font(.scaled(.caption, textScale)).foregroundStyle(.secondary).lineLimit(1)
                        .help(String(format: "rekordbox 오토게인이 이 파일의 실제 음량과 %.1fdB 다릅니다", abs(deck.gainMismatchDB ?? 0)))
                    Button("제안 받기") { deck.acceptGainSuggestion() }
                        .fixedSize()
                        .help("이 곡은 DJCrate가 잰 음량으로 계산한 게인(−10 LUFS 기준)을 씁니다")
                    Button("무시") { deck.dismissGainSuggestion() }
                        .fixedSize()
                        .help("이 곡에서는 rekordbox 값을 그대로 쓰고 제안을 더 보이지 않습니다")
                }
            } else if deck.hasGainOverride {
                Button("게인 초안 취소") { deck.clearGainDraft() }
                    .font(.scaled(.caption, textScale))
                    .help("이 곡의 게인 초안을 지우고 rekordbox 오토게인으로 돌아갑니다")
            }
            // 그리드 편집에 들어가지 않고 DJCrate 제안을 받거나 무시한다.
            if !deck.gridEditing, !deck.needsGrid, let note = deck.gridSuggestionNote,
               deck.dismissedRevision >= 0, !deck.isGridSuggestionDismissed {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars").foregroundStyle(UIColors.suggestion.color)
                    Text(note).font(.scaled(.caption, textScale)).lineLimit(1).foregroundStyle(.secondary)
                    Button("제안 받기") { deck.applyGridSuggestion() }
                        .fixedSize()
                        .help("DJCrate가 추정한 그리드로 바꿉니다(초안만, 되돌리기 가능)")
                    Button("무시") { deck.dismissGridSuggestion() }
                        .fixedSize()
                        .help("이 곡에서는 제안을 더 보이지 않습니다")
                }
            }
        }
        .controlSize(ControlSize.small.scaled(textScale))
    }
}

/// 게인 버튼: 지금 걸린 게인과 곡 음량을 보여 주고, 누르면 오토게인·트림 설정.
struct GainControl: View {
    @Environment(\.textScale) private var textScale
    @Bindable var deck: DeckModel
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 4) {
                Text(deck.autoGain ? (deck.useRekordboxGain && deck.rekordboxGainDB != nil ? "RB AUTO" : "AUTO") : "GAIN")
                    .font(.scaled(.caption2, textScale).bold())
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(deck.autoGain ? Color.accentColor.opacity(0.35) : UIColors.subtleFill))
                Text(String(format: "%+.1f dB", deck.appliedGain)).font(.scaled(.caption, textScale).monospacedDigit())
                if let loudness = deck.loudness, let lufs = loudness.integrated {
                    // 큰 음량은 색만이 아니라 경고 표식으로도 알린다(초안 주황과 모양으로 구분).
                    HStack(spacing: 2) {
                        if loudness.isHot { Image(systemName: WarningMark.symbol).accessibilityLabel("경고") }
                        Text(String(format: "%.1f LUFS", lufs))
                    }
                    .font(.scaled(.caption, textScale).monospacedDigit())
                    .foregroundStyle(loudness.isHot ? UIColors.warning.color : Color.secondary)
                }
                if deck.isGainSuspicious {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UIColors.warning.color)
                        .help("rekordbox 오토게인이 DJCrate 측정과 1.5dB 넘게 다릅니다")
                }
            }
        }
        .buttonStyle(.borderless)
        .help("게인(볼륨 페이더 앞). 누르면 오토게인·목표 음량·트림을 정합니다. 느낌표가 붙은 LUFS = 매우 큰 마스터(−6 LUFS 초과)이거나 심한 클리핑")
        .popover(isPresented: $shown, arrowEdge: .bottom) { GainSettings(deck: deck).padding(16).frame(width: 340) }
    }
}

struct GainSettings: View {
    @Bindable var deck: DeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("게인").font(.headline)
            Toggle("오토게인", isOn: $deck.autoGain)
                .help("곡마다 목표 음량에 맞춥니다")
            Toggle("rekordbox 값 사용", isOn: $deck.useRekordboxGain)
                .disabled(!deck.autoGain)
                .help("rekordbox 오토게인 값을 씁니다(rekordbox는 약 −10 LUFS에 맞춤)")
            Picker("목표 음량", selection: $deck.gainTarget) {
                ForEach([-14.0, -12, -11, -10, -9, -8], id: \.self) { Text(String(format: "%.0f LUFS", $0)).tag($0) }
            }
            .disabled(!deck.autoGain)
            Toggle("피크 보호", isOn: $deck.peakProtection)
                .disabled(!deck.autoGain)
                .help("0dBFS를 넘지 않을 만큼만 올립니다")
            HStack {
                Text("트림")
                Slider(value: $deck.gainTrim, in: -12...12, step: 0.5)
                Text(String(format: "%+.1f dB", deck.gainTrim)).font(.callout.monospacedDigit()).frame(width: 60, alignment: .trailing)
                Button("0") { deck.gainTrim = 0 }
            }
            Divider()
            if let loudness = deck.loudness {
                VStack(alignment: .leading, spacing: 4) {
                    Text("이 곡").font(.subheadline.bold())
                    Text((loudness.integrated.map { String(format: "음량 %.1f LUFS", $0) } ?? "음량 — (무음)")
                         + String(format: " · 피크 %.1f dBFS", loudness.peak))
                        .help("통합 음량(BS.1770)과 샘플 피크")
                    Text(String(format: "적용 %+.1f dB (오토 %+.1f · 트림 %+.1f)", deck.appliedGain, deck.autoGainDB, deck.gainTrim))
                    if let rekordbox = deck.rekordboxGainDB {
                        Text(String(format: "rekordbox %+.1f dB", rekordbox) + (deck.measuredGainDB.map { String(format: " · DJCrate %+.1f dB", $0) } ?? ""))
                            .help("rekordbox 오토게인 값과 DJCrate가 잰 음량으로 계산한 값")
                        HStack(spacing: 6) {
                            Text("곡 게인")
                            Button("−1") { deck.adjustTrackGain(by: -1) }
                            Button("−0.1") { deck.adjustTrackGain(by: -0.1) }
                            // 초안 값은 초안 색 하나와 연필 표식으로 보인다(목록·시트·인스펙터와 같다).
                            HStack(spacing: 3) {
                                if deck.gainDraft != nil {
                                    Image(systemName: DraftMark.symbol).accessibilityLabel(DraftMark.spoken)
                                }
                                Text(String(format: "%+.1f dB", deck.trackGainDB ?? rekordbox))
                            }
                            .font(.callout.monospacedDigit().bold())
                            .foregroundStyle(deck.gainDraft != nil ? UIColors.draft.color : Color.primary)
                            .frame(width: 84)
                            Button("+0.1") { deck.adjustTrackGain(by: 0.1) }
                            Button("+1") { deck.adjustTrackGain(by: 1) }
                            if deck.gainDraft != nil {
                                Button("되돌리기") { deck.clearGainDraft() }
                            }
                        }
                        .controlSize(.small)
                        .help(deck.gainDraft != nil ? "초안입니다. rekordbox에 반영하면 rekordbox 오토게인이 이 값으로 바뀝니다" : "이 곡의 rekordbox 오토게인을 고칩니다(초안)")
                    } else {
                        Text("rekordbox 값 없음(분석 전)").foregroundStyle(.secondary)
                    }
                    if deck.isGainSuspicious, let mismatch = deck.gainMismatchDB {
                        Label(String(format: "rekordbox 값이 실제 음량과 %.1fdB 다름", abs(mismatch)), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(UIColors.warning.color)
                            .help("파일을 바꿨거나 분석이 오래됐을 수 있습니다. rekordbox에서 다시 분석하거나 DJCrate 값을 쓰세요")
                    }
                    if loudness.isLoud {
                        Label("매우 큼(−6 LUFS 초과)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(UIColors.warning.color)
                            .help("라이브러리 대부분의 곡보다 세게 들립니다")
                    }
                    if loudness.clippedRuns > 0 {
                        Label("클리핑 흔적 \(loudness.clippedRuns)곳\(loudness.isHeavilyClipped ? " · 심함" : "")", systemImage: "waveform.path.badge.minus")
                            .foregroundStyle(loudness.isHeavilyClipped ? UIColors.warning.color : Color.secondary)
                            .help("원본에서 풀스케일에 붙은 구간")
                    }
                }
                .font(.callout)
            } else {
                Text(deck.row == nil ? "곡을 올리면 음량을 잽니다" : "음량을 재는 중이거나 잴 수 없는 파일입니다")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// 레벨 미터(게인 뒤·볼륨 앞, L/R 피크). 초록 ~−12 · 노랑 −12~−3 · 빨강 −3~0dBFS.
/// 오른쪽은 곡을 올린 뒤 최고 피크(0dBFS를 넘은 적이 있으면 빨간 점, 누르면 지움).
struct LevelMeterView: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel
    @State private var ballistics = MeterBallistics()

    var body: some View {
        // 재생 틱이 올리는 meterFrame으로 다시 그린다(따로 타이머를 돌리지 않는다).
        let _ = deck.meterFrame
        Group {
            let reading = deck.meter.read()
            let now = ProcessInfo.processInfo.systemUptime
            let state = ballistics.step(reading, now: now, playing: deck.isPlaying)
            let clipping = now - reading.clipTime < 2 || reading.clipCount > 0
            HStack(spacing: 6) {
                Canvas { context, size in draw(context, size: size, state: state) }
                    .frame(width: 130, height: 13)
                    .background(Palette.well)
                    .environment(\.colorScheme, .dark)
                    .accessibilityElement()
                    .accessibilityLabel("레벨 미터")
                    .modifier(LevelMeterAccessibility(deck: deck))
                // 최고 피크. 0dBFS를 넘은 적이 있으면 빨간 점이 켜진다. 누르면 기록을 지운다.
                Button { deck.meter.resetPeaks() } label: {
                    HStack(spacing: 3) {
                        Circle().fill(UIColors.memory.color).frame(width: 6, height: 6).opacity(clipping ? 1 : 0)
                        Text(reading.maxPeak > 0 ? String(format: "%+.1f", 20 * log10(reading.maxPeak)) : "−∞")
                            .font(.scaled(.caption2, textScale).monospacedDigit())
                            .foregroundStyle(reading.maxPeak >= 1 ? UIColors.memory.color : reading.maxPeak >= 0.708 ? UIColors.warning.color : Color.secondary)
                    }
                    .frame(width: TextScale.length(44, scale: textScale), alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(reading.clipCount > 0
                      ? "최고 피크(dBFS, 게인 뒤). 0dBFS를 \(reading.clipCount)번 넘었습니다 — 게인을 낮추세요. 누르면 기록을 지웁니다"
                      : "곡을 올린 뒤 최고 피크(dBFS, 게인 뒤). 0dBFS를 넘으면 빨간 점이 켜집니다. 누르면 기록을 지웁니다")
                // 최고 피크는 곡마다 가끔만 바뀐다(값이 바뀔 때만 VoiceOver에 알린다).
                .accessibilityLabel("최고 피크")
                .accessibilityValue(reading.maxPeak > 0 ? String(format: "%+.1f dB", 20 * log10(reading.maxPeak)) : "없음")
                .accessibilityHint("누르면 최고 피크와 클리핑 기록을 지웁니다")
            }
        }
    }

    private static let floor: Double = -48
    private static let top: Double = 3

    private func x(_ db: Double, _ width: CGFloat) -> CGFloat {
        CGFloat((min(max(db, Self.floor), Self.top) - Self.floor) / (Self.top - Self.floor)) * width
    }

    private func draw(_ context: GraphicsContext, size: CGSize, state: MeterBallistics.State) {
        let barHeight = (size.height - 1) / 2
        let zones: [(from: Double, to: Double, color: Color)] = [(-48, -12, Palette.meterLow), (-12, -3, Palette.meterMid), (-3, 3, Palette.meterHigh)]
        for (row, channel) in [state.left, state.right].enumerated() {
            let y = CGFloat(row) * (barHeight + 1)
            context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: barHeight)), with: .color(Palette.well))
            let level = x(channel.level, size.width)
            for zone in zones {
                let start = x(zone.from, size.width), end = min(level, x(zone.to, size.width))
                if end > start {
                    context.fill(Path(CGRect(x: start, y: y, width: end - start, height: barHeight)), with: .color(zone.color.opacity(0.9)))
                }
            }
            if channel.hold > Self.floor {
                let hx = x(channel.hold, size.width)
                context.fill(Path(CGRect(x: hx - 1, y: y, width: 2, height: barHeight)),
                             with: .color(channel.hold >= 0 ? Palette.meterHigh : .white.opacity(0.8)))
            }
        }
        // 0dBFS 눈금
        let zero = x(0, size.width)
        context.fill(Path(CGRect(x: zero, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.5)))
    }
}

/// 레벨 미터 VoiceOver 값(지금 피크·클리핑). 미터 그림은 재생 틱(초당 30번)으로 그리지만 값은 `displayTime` 주기(초당 15번)로만 읽는다.
struct LevelMeterAccessibility: ViewModifier {
    let deck: DeckModel

    func body(content: Content) -> some View {
        let _ = deck.displayTime
        content.accessibilityValue(WaveformAccessibility.meterValue(deck.meter.read(), playing: deck.isPlaying,
                                                                    now: ProcessInfo.processInfo.systemUptime))
    }
}

/// 미터 움직임: 오를 땐 바로, 내릴 땐 초당 24dB. 피크 표시는 1.5초 머문 뒤 내려온다.
final class MeterBallistics {
    struct Channel {
        var level: Double = -120
        var hold: Double = -120
        var holdTime: Double = 0
    }

    struct State {
        var left = Channel()
        var right = Channel()
    }

    private var state = State()
    private var last: Double = 0

    func step(_ reading: LevelMeter.Reading, now: Double, playing: Bool) -> State {
        let dt = last == 0 ? 0 : min(max(now - last, 0), 0.5)
        last = now
        // 재생이 멈췄거나 탭이 한동안 오지 않으면 무음으로 본다.
        let fresh = playing && now - reading.time < 0.25
        func db(_ value: Float) -> Double { value > 0 ? 20 * log10(Double(value)) : -120 }
        func update(_ channel: inout Channel, _ peak: Float) {
            let input = fresh ? db(peak) : -120
            channel.level = input >= channel.level ? input : max(input, channel.level - 24 * dt)
            if input >= channel.hold {
                channel.hold = input
                channel.holdTime = now
            } else if now - channel.holdTime > 1.5 {
                channel.hold = max(input, channel.hold - 12 * dt)
            }
        }
        update(&state.left, reading.peak.left)
        update(&state.right, reading.peak.right)
        if !playing { state = State() }
        return state
    }
}
