import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import SwiftUI

struct TransportBar: View {
    @Environment(\.textScale) private var textScale
    @Bindable var deck: DeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 10) {
                HStack(spacing: 8) {
                    CueButton(deck: deck)
                    Button {
                        deck.togglePlay()
                    } label: {
                        Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                    }
                    .disabled(!deck.canPlay)
                    .help(.ui("재생/일시정지 (\(deck.shortcuts.keyLabel(for: .playPause)))"))
                    PlayQuantizeToggle(deck: deck)
                    Group { if PerfProbe.hidden.contains("label") { EmptyView() } else { PlayheadLabel(deck: deck) } }
                        .frame(width: TextScale.length(200, scale: textScale), alignment: .leading)
                }
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        Button { deck.jumpToCue(forward: false) } label: { Image(systemName: "backward.end.fill") }
                            .help(.ui("이전 큐로 (\(deck.shortcuts.keyLabel(for: .previousCue)))")).accessibilityLabel(.ui("이전 큐로"))
                        Button { deck.jumpToCue(forward: true) } label: { Image(systemName: "forward.end.fill") }
                            .help(.ui("다음 큐로 (\(deck.shortcuts.keyLabel(for: .nextCue)))")).accessibilityLabel(.ui("다음 큐로"))
                    }
                    .disabled(!deck.canPlay)
                    Button(.ui("+ 메모리 큐")) {
                        // Shift+클릭 = 이 자리 메모리 큐 지우기
                        if NSEvent.modifierFlags.contains(.shift) { deck.deleteMemoryCue(at: deck.currentTime) } else { deck.addMemoryCue() }
                    }
                    .help(.ui("CUE 위치에 메모리 큐 추가 (\(deck.shortcuts.keyLabel(for: .memoryCue))). Shift를 누르고 누르면 현재 재생 위치의 메모리 큐를 지웁니다"))
                }
                HStack(spacing: 4) {
                    ForEach(0..<8, id: \.self) { slot in
                        HotCuePad(deck: deck, slot: slot)
                    }
                }
                LoopControl(deck: deck)
            }
            // 재생·큐 묶음 다음 줄에 확대·보기 묶음을 둔다.
            FlowLayout(spacing: 10) {
                ZoomControl(deck: deck)
                ShortcutsButton()
                TrackEditButton(deck: deck)
                HStack(spacing: 8) {
                    Toggle(.ui("퀀타이즈"), isOn: $deck.quantize)
                        .toggleStyle(.checkbox)
                        .help(.ui("rekordbox 비트 그리드의 박에 맞춤"))
                    Toggle(.ui("제안"), isOn: $deck.showSuggestions)
                        .toggleStyle(.checkbox)
                        .help(.ui("섹션 경계 기반 메모리 큐 제안 표시. 초록 + 를 클릭하면 추가"))
                }
            }
        }
        .controlSize(ControlSize.small.scaled(textScale))
    }
}

/// 재생 퀀타이즈(Q): 켜면 재생 중 핫큐가 다음 박 조각 경계에서 박자를 이어 넘어간다. 단위는 설정 › 덱.
/// 큐를 찍을 때 박에 맞추는 '퀀타이즈' 체크와는 따로다.
struct PlayQuantizeToggle: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel

    var body: some View {
        let unit = PlayQuantize.unitText(deck.playQuantizeBeats)
        let on = deck.playQuantize
        // CUE·루프 버튼처럼 켜지면 색이 찬다(핫큐·메모리·루프 색과 겹치지 않는 파랑).
        Button { deck.playQuantize.toggle() } label: {
            Text(verbatim: "Q")
                .font(.scaled(size: 11, weight: .heavy, textScale))
                .frame(width: TextScale.length(22, scale: textScale), height: TextScale.length(20, scale: textScale))
                .foregroundStyle(on ? UIColors.onFill : UIColors.info.color)
                .background(on ? UIColors.info.color : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(UIColors.info.color))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .help(.ui("재생 퀀타이즈: 켜면 재생 중 핫큐를 누른 뒤 다음 \(unit) 경계에서 박자를 이어 넘어갑니다. 단위는 설정 › 덱에서 바꿉니다"))
        .accessibilityLabel(.ui("재생 퀀타이즈"))
        .accessibilityValue(on ? String(ui: "켜짐, \(unit)") : String(ui: "꺼짐"))
    }
}

extension PlayQuantize {
    /// 설정·도움말에 보이는 단위 이름
    static func unitText(_ beats: Double) -> String {
        switch beats {
        case 0.25: String(ui: "1/4박")
        case 0.5: String(ui: "1/2박")
        default: String(ui: "1박")
        }
    }
}

/// 확대 배율: − / + 버튼, 현재 값(누르면 프리셋). 파형 위 휠·핀치로도 조절된다.
struct ZoomControl: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel

    var body: some View {
        HStack(spacing: 2) {
            Button { deck.zoom(by: 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help(.ui("축소 (\(deck.shortcuts.keyLabel(for: .zoomOut)))")).accessibilityLabel(.ui("파형 축소"))
            Menu {
                ForEach([4.0, 8, 16, 32, 64], id: \.self) { seconds in
                    Button(.ui("\(Int(seconds))초")) { deck.setZoom(seconds) }
                }
            } label: {
                Text(.ui("\(deck.zoomSeconds, specifier: "%.1f")초")).font(.scaled(.caption, textScale).monospacedDigit())
                    .frame(width: TextScale.length(46, scale: textScale))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(.ui("확대 창 폭. 파형 위에서 휠(세로)로 확대·축소, 가로 스크롤로 이동, 핀치로 확대"))
            Button { deck.zoom(by: 0.8) } label: { Image(systemName: "plus.magnifyingglass") }
                .help(.ui("확대 (\(deck.shortcuts.keyLabel(for: .zoomIn)))")).accessibilityLabel(.ui("파형 확대"))
        }
    }
}

/// 매 프레임 바뀌는 시간 표시만 따로 둔다(컨트롤이 많은 줄 전체가 다시 그려지지 않도록).
/// 글자 단계: 주 수치(시각·BPM)는 callout 굵게, 보조 수치(마디.박·조성)는 caption, 단위는 caption2.
struct PlayheadLabel: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel

    var body: some View {
        // 글자는 초당 15번이면 읽기에 충분하다(매 프레임 창 전체를 다시 그리지 않게).
        let t = deck.displayTime
        HStack(spacing: 6) {
            Text(t.clockText).font(.scaled(.callout, textScale).monospacedDigit().bold())
            if let position = deck.grid?.positionText(at: t) {
                Text(position).font(.scaled(.caption, textScale).monospacedDigit()).foregroundStyle(.secondary)
                    .help(.ui("마디.박(박은 0부터)"))
            }
            if let key = deck.key(at: t) {
                HStack(spacing: 3) {
                    Circle().fill(UIColors.keyDot(key)).frame(width: 6, height: 6)
                    Text(key).font(.scaled(.caption, textScale).monospacedDigit()).foregroundStyle(.primary)
                }
                .help(deck.keySegments.count > 1 ? String(ui: "지금 조성(Camelot, 추정). 이 곡은 조성이 바뀝니다") : String(ui: "지금 조성(Camelot)"))
            }
            // 지금 BPM(그리드의 이 구간 BPM × 템포). 템포를 바꾸면 주황색.
            if let bpm = deck.gridBPM {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(verbatim: (bpm * deck.rate).formatted(.number.precision(.fractionLength(2)).grouping(.never))).font(.scaled(.callout, textScale).monospacedDigit().bold())
                    Text(verbatim: "BPM").font(.scaled(.caption2, textScale)).foregroundStyle(.secondary)
                }
                .foregroundStyle(deck.tempoPercent == 0 ? Color.primary : UIColors.cue.color)
                .help(deck.tempoPercent == 0 ? String(ui: "지금 BPM(그리드 기준, 변속 곡은 구간마다 바뀝니다)")
                      : String(ui: "지금 BPM · 원래 \(bpm, specifier: "%.2f") BPM, 템포 \(deck.tempoPercent, specifier: "%+.1f")%"))
            }
        }
    }
}

/// CDJ의 CUE 버튼. 누르는 순간과 떼는 순간을 모두 받아야 해서(미리 듣기) Button 대신 제스처를 쓴다.
struct CueButton: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel
    @State private var pressed = false

    var body: some View {
        // 재생 중에는 위치를 읽지 않는다(매 프레임 다시 그리지 않게).
        let lit = deck.isCuePreviewing || deck.isAtCue
        Text(verbatim: "CUE")
            .font(.scaled(size: 10, weight: .heavy, textScale))
            .frame(width: TextScale.length(36, scale: textScale), height: TextScale.length(20, scale: textScale))
            .foregroundStyle(lit ? UIColors.onFill : UIColors.cue.color)
            .background(lit ? UIColors.cue.color : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(UIColors.cue.color))
            .opacity(deck.canPlay ? 1 : 0.4)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    deck.cueDown()
                }
                .onEnded { _ in
                    pressed = false
                    deck.cueUp()
                })
            .help(.ui("CUE (\(deck.shortcuts.keyLabel(for: .cue))) — 재생 중: 큐 지점으로 돌아가 정지 · 멈춘 곳: 새 큐 지점 · 큐 지점에서 누르고 있기: 미리 듣기 · 누른 채 재생: 계속 재생\n큐 지점 \(deck.cuePoint.clockText)"))
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: "CUE"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { deck.cueDown(); deck.cueUp() }
    }
}

struct HotCuePad: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel
    let slot: Int

    var body: some View {
        let cue = deck.hotCue(slot: slot)
        let letter = String(UnicodeScalar(UInt8(65 + slot)))
        let keys = DeckAction.allCases.first { $0.hotCueSlot == slot }.map { deck.shortcuts.keyLabel(for: $0) } ?? String(ui: "미지정")
        let color = cue.map(UIColors.color(for:)) ?? .secondary
        let engaged = cue != nil && cue?.id == deck.engagedLoopID
        let accessibility = deck.hotCueAccessibility(slot: slot)
        Button {
            // Shift+클릭 = 지우기
            if NSEvent.modifierFlags.contains(.shift) { deck.deleteHotCue(slot: slot) } else { deck.pressHotCue(slot: slot) }
        } label: {
            // 루프 핫큐는 글자 옆에 반복 심볼을 같은 글꼴로 붙인다(파형 칩과 같은 표기).
            // 글자는 번역하지 않아 지역화 문자열 보간 대신 나란히 둔다.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: letter)
                if cue?.loop != nil { Image(systemName: "repeat") }
            }
                .font(.scaled(size: 11, weight: .bold, textScale))
                .imageScale(.small)
                .frame(width: TextScale.length(24, scale: textScale), height: TextScale.length(20, scale: textScale))
                .foregroundStyle(cue == nil ? Color.secondary : UIColors.onFill)
                .background(cue == nil ? Color.clear : color, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(engaged ? Color.primary : cue == nil ? Color.secondary.opacity(0.5) : color,
                                                                  lineWidth: engaged ? 2 : 1))
        }
        .buttonStyle(.plain)
        .selfTestFrame("hotCue.\(slot)")
        .help(cue == nil ? (deck.instantLoop != nil ? String(ui: "핫큐 \(letter) (\(keys)): 지금 루프를 루프 핫큐로 저장") : String(ui: "핫큐 \(letter) (\(keys)): 플레이헤드에 설정"))
              : cue?.loop != nil ? String(ui: "루프 핫큐 \(letter) (\(keys)): 누르면 루프 반복, 반복 중에 다시 누르면 나가기 · Shift+클릭: 지우기")
              : String(ui: "핫큐 \(letter) (\(keys))로 이동 (\(cue!.time.clockText)) · Shift+클릭 또는 Shift와 단축키: 지우기"))
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value)
        .contextMenu {
            if cue != nil {
                Button(.ui("플레이헤드로 옮기기")) { deck.moveHotCueToPlayhead(slot: slot) }
                Button(.ui("삭제"), role: .destructive) { if let id = cue?.id { deck.delete(id) } }
            }
        }
    }
}

/// 오토 비트 루프: ½ · LOOP n박 · ×2. 반복 중에 빈 핫큐 칸이나 + 메모리 큐를 누르면 그 루프가 저장된다.
struct LoopControl: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel

    var body: some View {
        let looping = deck.isLooping
        HStack(spacing: 2) {
            Button { deck.resizeLoop(-1) } label: { Text(verbatim: "½").frame(width: TextScale.length(14, scale: textScale)) }
                .help(.ui("루프 길이 반으로 (\(deck.shortcuts.keyLabel(for: .loopHalve)))")).accessibilityLabel(.ui("루프 길이 반으로"))
            Button { deck.toggleLoop() } label: {
                // 심볼과 글자에 같은 글꼴을 한 번만 주고, 심볼은 작은 크기로 글자 높이에 맞춘다.
                HStack(spacing: 3) {
                    Image(systemName: "repeat").imageScale(.small)
                    Text(deck.loopSizeText).monospacedDigit()
                }
                .font(.scaled(size: 11, weight: .heavy, textScale))
                .frame(width: TextScale.length(44, scale: textScale), height: TextScale.length(20, scale: textScale))
                .foregroundStyle(looping ? UIColors.onFill : UIColors.loop.color)
                .background(looping ? UIColors.loop.color : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(UIColors.loop.color))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(deck.canPlay ? 1 : 0.4)
            .help(looping ? String(ui: "루프에서 나가기 (\(deck.shortcuts.keyLabel(for: .loop)))")
                  : String(ui: "플레이헤드에서 \(deck.loopSizeText)박 루프 (\(deck.shortcuts.keyLabel(for: .loop))). 반복 중에 빈 핫큐 칸을 누르면 루프 핫큐, + 메모리 큐를 누르면 메모리 루프로 저장"))
            .accessibilityLabel(looping ? String(ui: "루프 나가기") : String(ui: "\(deck.loopSizeText)박 루프"))
            Button { deck.resizeLoop(1) } label: { Text(verbatim: "×2").frame(width: TextScale.length(18, scale: textScale)) }
                .help(.ui("루프 길이 두 배로 (\(deck.shortcuts.keyLabel(for: .loopDouble)))")).accessibilityLabel(.ui("루프 길이 두 배로"))
        }
        .disabled(!deck.canPlay)
    }
}
