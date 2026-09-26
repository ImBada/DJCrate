import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import SwiftUI

/// rekordbox식 그리드 편집. 모든 변경은 DJCrate 초안에만 저장된다.
struct GridEditorBar: View {
    @Environment(\.textScale) private var textScale
    @Bindable var deck: DeckModel
    @State private var bpm: Double?
    @State private var bpmFieldRevision = 0
    @FocusState private var bpmFocused: Bool

    private var invalidBPM: Bool { bpm.map { !GridDraft.bpmRange.contains($0) } ?? true }
    private var bpmWarning: String { String(ui: "BPM은 20…999 사이로 입력하세요.") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = deck.gridEditBlockedReason {
                Label(reason, systemImage: "lock").font(.scaled(.caption, textScale)).foregroundStyle(UIColors.warning.color)
            } else {
                FlowLayout(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach([-10.0, -1.0, 1.0, 10.0], id: \.self) { milliseconds in
                            GridShiftButton(deck: deck, milliseconds: milliseconds).fixedSize()
                        }
                    }
                    .help(.ui("그리드 전체를 옮깁니다 (1초 동안 누르면 반복 · 파형을 끌어도 됩니다)"))
                    HStack(spacing: 4) {
                        TextField("BPM" as String, value: $bpm, format: .number.precision(.fractionLength(2)))
                            .id(bpmFieldRevision)
                            .focused($bpmFocused)
                            .frame(width: TextScale.length(64, scale: textScale))
                            .onSubmit { bpmFocused = false }
                            .onChange(of: bpmFocused) { _, focused in
                                if !focused { commitBPM() }
                            }
                            .onAppear { bpm = deck.gridBPM }
                            .onChange(of: deck.gridBPM) { bpm = deck.gridBPM }
                            .onChange(of: deck.row?.track.uuid) {
                                bpm = deck.gridBPM
                                bpmFocused = false
                                bpmFieldRevision += 1
                            }
                            .help(invalidBPM ? bpmWarning : String(ui: "현재 템포 구간의 BPM (엔터를 누르거나 칸을 벗어나면 적용)"))
                        if invalidBPM {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(UIColors.warning.color)
                                .accessibilityLabel(bpmWarning)
                                .help(bpmWarning)
                        }
                        Button("×2" as String) { deck.scaleGridBPM(2) }
                        Button("÷2" as String) { deck.scaleGridBPM(0.5) }
                        Button("−0.01" as String) { deck.nudgeGridBPM(-0.01) }
                        Button("+0.01" as String) { deck.nudgeGridBPM(0.01) }
                    }
                    HStack(spacing: 4) {
                        Button(.ui("½박 이동")) { deck.shiftGridHalfBeat() }
                            .help(.ui("그리드를 반 박 옮깁니다(추정이 뒷박을 잡았을 때)"))
                        Button(.ui("여기를 1박으로")) { deck.setDownbeatAtPlayhead() }
                            .help(.ui("플레이헤드에 가장 가까운 박을 마디 첫 박으로"))
                    }
                    HStack(spacing: 4) {
                        Button(.ui("여기서 그리드 시작")) { deck.setGridAnchorAtPlayhead() }
                            .help(.ui("플레이헤드 위치에 박을 정확히 놓고 1박으로"))
                        Button(.ui("여기서 BPM 변경")) { deck.addTempoChangeAtPlayhead() }
                            .help(.ui("변속곡: 가장 가까운 박부터 새 템포 구간을 시작합니다"))
                    }
                    Toggle(.ui("큐도 함께(핫큐·메모리)"), isOn: $deck.carryCues)
                        .toggleStyle(.checkbox)
                        .help(.ui("켜면 그리드를 옮기거나 BPM을 바꿀 때 핫큐·메모리 큐(루프 포함)가 같은 박을 따라 움직입니다"))
                    HStack(spacing: 4) {
                        Button(.ui("탭")) { deck.tapTempo() }
                            .help(.ui("탭 템포 (\(deck.shortcuts.keyLabel(for: .tapTempo)))"))
                        if let tap = deck.tapBPM {
                            Text(.ui("탭 \(tap, specifier: "%.2f")")).font(.scaled(.caption, textScale).monospacedDigit())
                            Button(.ui("적용")) { deck.setGridBPM(tap) }
                        }
                    }
                }
                FlowLayout(spacing: 6) {
                    let segments = deck.gridDraft?.segments ?? []
                    Text(.ui("템포 구간 \(segments.count)")).font(.scaled(.caption, textScale)).foregroundStyle(.secondary)
                    ForEach(Array(segments.prefix(24).enumerated()), id: \.offset) { index, segment in
                        HStack(spacing: 2) {
                            Button(segment.start.clockText + " · " + segment.bpm.formatted(.number.precision(.fractionLength(2)).grouping(.never))) { deck.seek(segment.start) }
                                .buttonStyle(.plain)
                            if index > 0 {
                                Button { deck.removeTempoChange(at: index) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .frame(minWidth: 20, minHeight: 20)
                                        .contentShape(Rectangle())
                                }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .accessibilityLabel(.ui("이 변속 지점 삭제"))
                            }
                        }
                        .font(.scaled(.caption, textScale).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(UIColors.subtleFill, in: Capsule())
                    }
                    if segments.count > 24 { Text(.ui("외 \(segments.count - 24)개")).font(.scaled(.caption, textScale)).foregroundStyle(.secondary) }
                    if deck.gridDraft?.hasChanges == true {
                        Text(.ui("그리드 초안 변경됨")).font(.scaled(.caption, textScale).bold()).foregroundStyle(UIColors.draft.color)
                    }
                    Button(.ui("그리드 되돌리기")) { deck.revertGrid() }
                        .disabled(deck.gridDraft?.hasChanges != true)
                }
            }
        }
        .controlSize(ControlSize.small.scaled(textScale))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UIColors.draftFill, in: RoundedRectangle(cornerRadius: 6))
    }

    private func commitBPM() {
        if let bpm, GridDraft.bpmRange.contains(bpm) { deck.setGridBPM(bpm) }
        bpm = deck.gridBPM
        // 숫자로 해석할 수 없어 바인딩이 바뀌지 않은 입력도 원래 표시로 돌린다.
        bpmFieldRevision += 1
    }
}

/// DJCrate가 추정한 그리드 안내. 그리드가 없는 곡은 편집 모드가 아니어도 보인다.
struct GridSuggestionRow: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel
    /// 파형 위에 띄우는 작은 배지 모양(줄 끝 채우기·긴 버튼 이름 없이)
    var badge = false

    var body: some View {
        HStack(spacing: 8) {
            if deck.needsGrid {
                Image(systemName: "metronome").foregroundStyle(UIColors.suggestion.color)
                if let suggestion = deck.gridSuggestion {
                    Text(.ui("rekordbox 그리드가 없습니다 · 추정 \(suggestion.bpm, specifier: "%.2f") BPM"))
                    confidence(suggestion)
                    Button(.ui("추정 그리드 적용")) { deck.applyGridSuggestion() }
                        .help(.ui("추정한 템포·박 위치를 그리드 초안으로 넣습니다. 적용 뒤 그리드 편집으로 고칠 수 있습니다."))
                } else if deck.analysisError != nil {
                    Text(.ui("rekordbox 그리드가 없고, 분석에 실패해 추정하지 못했습니다.")).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                    Text(.ui("rekordbox 그리드가 없습니다 · BPM·박 위치를 추정하는 중…")).foregroundStyle(.secondary)
                }
            } else if let note = deck.gridSuggestionNote, let suggestion = deck.gridSuggestion {
                Image(systemName: "wand.and.stars").foregroundStyle(UIColors.suggestion.color)
                Text(.ui("DJCrate 제안: \(note)")).lineLimit(1)
                Button(.ui("제안 그리드 적용")) { deck.applyGridSuggestion() }
                    .help(suggestion.isConfident
                          ? .ui("현재 그리드를 추정 그리드로 바꿉니다(초안만, 되돌리기 가능).")
                          : .ui("현재 그리드를 추정 그리드로 바꿉니다(초안만, 되돌리기 가능). 추정 신뢰도가 낮으니 소리로 확인하세요."))
                if deck.dismissedRevision >= 0, deck.isGridSuggestionDismissed {
                    Button(.ui("제안 다시 보기")) { deck.restoreGridSuggestion() }
                        .help(.ui("무시했던 제안을 그리드 편집 밖에서도 다시 보이게 합니다"))
                }
            } else if deck.gridSuggestion != nil {
                Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                Text(.ui("DJCrate 추정과 지금 그리드가 사실상 같습니다")).foregroundStyle(.secondary)
            }
            if !badge { Spacer(minLength: 0) }
            Button { deck.reanalyze() } label: {
                if badge { Image(systemName: "arrow.triangle.2.circlepath") } else { Label(.ui("재분석"), systemImage: "arrow.triangle.2.circlepath") }
            }
            .help(.ui("이 곡의 섹션·그리드 추정·조성 분석 캐시를 지우고 다시 분석합니다(파형·초안은 그대로)"))
            .accessibilityLabel(.ui("재분석"))
        }
        .font(.scaled(.caption, textScale))
        .lineLimit(1)
        .controlSize(ControlSize.small.scaled(textScale))
    }

    /// 추정이 흔들리면 경고 표식(초안 주황과 모양으로 구분)을 붙여 알린다.
    @ViewBuilder private func confidence(_ suggestion: GridEstimator.Estimate) -> some View {
        if !suggestion.isConfident {
            Label(.ui("확인 필요"), systemImage: WarningMark.symbol)
                .font(.scaled(.caption, textScale).bold())
                .foregroundStyle(UIColors.warning.color)
                .help(.ui("박이 흔들리거나 템포가 바뀌는 곡입니다. 적용 뒤 메트로놈으로 확인하고 고쳐 주세요."))
        }
    }
}
