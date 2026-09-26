import RekordboxKit
import AnicueAnalysis
import AnicueDomain
import AnicueStorage
import SwiftUI

struct TransportBar: View {
    @Bindable var deck: DeckModel

    var body: some View {
        FlowLayout(spacing: 10) {
            HStack(spacing: 8) {
                CueButton(deck: deck)
                Button {
                    deck.togglePlay()
                } label: {
                    Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .disabled(!deck.canPlay)
                .help("재생/일시정지 (스페이스)")
                Group { if PerfProbe.hidden.contains("label") { EmptyView() } else { PlayheadLabel(deck: deck) } }
                    .frame(width: 190, alignment: .leading)
            }
            HStack(spacing: 4) {
                ForEach(0..<8, id: \.self) { slot in
                    HotCuePad(deck: deck, slot: slot)
                }
            }
            LoopControl(deck: deck)
            HStack(spacing: 2) {
                Button { deck.jumpToCue(forward: false) } label: { Image(systemName: "backward.end.fill") }
                    .help("이전 큐로 (Q)").accessibilityLabel("이전 큐로")
                Button { deck.jumpToCue(forward: true) } label: { Image(systemName: "forward.end.fill") }
                    .help("다음 큐로 (E)").accessibilityLabel("다음 큐로")
            }
            .disabled(!deck.canPlay)
            Button("+ 메모리 큐") {
                // Shift+클릭 = 이 자리 메모리 큐 지우기
                if NSEvent.modifierFlags.contains(.shift) { deck.deleteMemoryCue(at: deck.currentTime) } else { deck.addMemoryCueAtPlayhead() }
            }
            .help("플레이헤드 위치에 메모리 큐 추가 (` 또는 M). Shift를 누르고 누르면 이 자리 메모리 큐를 지웁니다")
            ZoomControl(deck: deck)
            ShortcutsButton()
            HStack(spacing: 8) {
                Toggle("퀀타이즈", isOn: $deck.quantize)
                    .toggleStyle(.checkbox)
                    .help("rekordbox 비트 그리드의 박에 맞춤")
                Toggle("제안", isOn: $deck.showSuggestions)
                    .toggleStyle(.checkbox)
                    .help("섹션 경계 기반 메모리 큐 제안 표시. 초록 + 를 클릭하면 추가")
            }
        }
        .controlSize(.small)
    }
}

/// 확대 배율: − / + 버튼, 현재 값(누르면 프리셋). 파형 위 휠·핀치로도 조절된다.
struct ZoomControl: View {
    let deck: DeckModel

    var body: some View {
        HStack(spacing: 2) {
            Button { deck.zoom(by: 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("축소 (−)").accessibilityLabel("파형 축소")
            Menu {
                ForEach([4.0, 8, 16, 32, 64], id: \.self) { seconds in
                    Button("\(Int(seconds))초") { deck.setZoom(seconds) }
                }
            } label: {
                Text(String(format: "%.1f초", deck.zoomSeconds)).font(.caption.monospacedDigit()).frame(width: 46)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("확대 창 폭. 파형 위에서 휠(세로)로 확대·축소, 가로 스크롤로 이동, 핀치로 확대")
            Button { deck.zoom(by: 0.8) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("확대 (+)").accessibilityLabel("파형 확대")
        }
    }
}

/// 매 프레임 바뀌는 시간 표시만 따로 둔다(컨트롤이 많은 줄 전체가 다시 그려지지 않도록).
struct PlayheadLabel: View {
    let deck: DeckModel

    var body: some View {
        // 글자는 초당 15번이면 읽기에 충분하다(매 프레임 창 전체를 다시 그리지 않게).
        let t = deck.displayTime
        HStack(spacing: 6) {
            Text(t.clockText).font(.callout.monospacedDigit())
            if let position = deck.grid?.positionText(at: t) {
                Text(position).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("마디.박(박은 0부터)")
            }
            if let key = deck.key(at: t) {
                Text(key).font(.caption.monospacedDigit().bold())
                    .foregroundStyle(Palette.keyColor(key))
                    .help(deck.keySegments.count > 1 ? "지금 조성(Camelot, 추정). 이 곡은 조성이 바뀝니다" : "지금 조성(Camelot)")
            }
            // 지금 BPM(그리드의 이 구간 BPM × 템포). 템포를 바꾸면 주황색.
            if let bpm = deck.gridBPM {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.2f", bpm * deck.rate)).font(.callout.monospacedDigit().bold())
                    Text("BPM").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                }
                .foregroundStyle(deck.tempoPercent == 0 ? Color.primary : Palette.cue)
                .help(deck.tempoPercent == 0 ? "지금 BPM(그리드 기준, 변속 곡은 구간마다 바뀝니다)"
                      : String(format: "지금 BPM · 원래 %.2f BPM, 템포 %+.1f%%", bpm, deck.tempoPercent))
            }
        }
    }
}

/// CDJ의 CUE 버튼. 누르는 순간과 떼는 순간을 모두 받아야 해서(미리 듣기) Button 대신 제스처를 쓴다.
struct CueButton: View {
    let deck: DeckModel
    @State private var pressed = false

    var body: some View {
        // 재생 중에는 위치를 읽지 않는다(매 프레임 다시 그리지 않게).
        let lit = deck.isCuePreviewing || deck.isAtCue
        Text("CUE")
            .font(.system(size: 10, weight: .heavy))
            .frame(width: 36, height: 20)
            .foregroundStyle(lit ? Color.black : Palette.cue)
            .background(lit ? Palette.cue : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.cue))
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
            .help("CUE (C) — 재생 중: 큐 지점으로 돌아가 정지 · 멈춘 곳: 새 큐 지점 · 큐 지점에서 누르고 있기: 미리 듣기 · 누른 채 재생: 계속 재생\n큐 지점 \(deck.cuePoint.clockText)")
            .accessibilityElement()
            .accessibilityLabel("CUE")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { deck.cueDown(); deck.cueUp() }
    }
}

struct HotCuePad: View {
    let deck: DeckModel
    let slot: Int

    var body: some View {
        let cue = deck.hotCue(slot: slot)
        let letter = String(UnicodeScalar(UInt8(65 + slot)))
        let color = cue.map(Palette.color(for:)) ?? .secondary
        let engaged = cue != nil && cue?.id == deck.engagedLoopID
        Button {
            // Shift+클릭 = 지우기
            if NSEvent.modifierFlags.contains(.shift) { deck.deleteHotCue(slot: slot) } else { deck.pressHotCue(slot: slot) }
        } label: {
            Text(cue?.loop == nil ? letter : letter + "↻")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 20)
                .foregroundStyle(cue == nil ? Color.secondary : Color.black)
                .background(cue == nil ? Color.clear : color, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(engaged ? Color.white : cue == nil ? Color.secondary.opacity(0.5) : color,
                                                                  lineWidth: engaged ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(cue == nil ? (deck.instantLoop != nil ? "핫큐 \(letter) (\(slot + 1)): 지금 루프를 루프 핫큐로 저장" : "핫큐 \(letter) (\(slot + 1)): 플레이헤드에 설정")
              : cue?.loop != nil ? "루프 핫큐 \(letter) (\(slot + 1)): 누르면 루프 반복, 반복 중에 다시 누르면 나가기 · Shift+클릭: 지우기"
              : "핫큐 \(letter) (\(slot + 1))로 이동 (\(cue!.time.clockText)) · Shift+클릭 또는 Shift+\(slot + 1): 지우기")
        .accessibilityLabel(cue == nil ? "핫큐 \(letter) 비어 있음, 설정" : "핫큐 \(letter)로 이동")
        .contextMenu {
            if cue != nil {
                Button("플레이헤드로 옮기기") { deck.moveHotCueToPlayhead(slot: slot) }
                Button("삭제", role: .destructive) { if let id = cue?.id { deck.delete(id) } }
            }
        }
    }
}

/// 오토 비트 루프: ½ · LOOP n박 · ×2. 반복 중에 빈 핫큐 칸이나 + 메모리 큐를 누르면 그 루프가 저장된다.
struct LoopControl: View {
    let deck: DeckModel

    var body: some View {
        let looping = deck.isLooping
        HStack(spacing: 2) {
            Button { deck.resizeLoop(-1) } label: { Text("½").frame(width: 14) }
                .help("루프 길이 반으로 ([)").accessibilityLabel("루프 길이 반으로")
            Button { deck.toggleLoop() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "repeat").font(.system(size: 9, weight: .bold))
                    Text(deck.loopSizeText).font(.system(size: 11, weight: .heavy).monospacedDigit())
                }
                .frame(width: 44, height: 20)
                .foregroundStyle(looping ? Color.black : Palette.loop)
                .background(looping ? Palette.loop : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.loop))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(deck.canPlay ? 1 : 0.4)
            .help(looping ? "루프에서 나가기 (L)"
                  : "플레이헤드에서 \(deck.loopSizeText)박 루프 (L). 반복 중에 빈 핫큐 칸을 누르면 루프 핫큐, + 메모리 큐를 누르면 메모리 루프로 저장")
            .accessibilityLabel(looping ? "루프 나가기" : "\(deck.loopSizeText)박 루프")
            Button { deck.resizeLoop(1) } label: { Text("×2").frame(width: 18) }
                .help("루프 길이 두 배로 (])").accessibilityLabel("루프 길이 두 배로")
        }
        .disabled(!deck.canPlay)
    }
}
