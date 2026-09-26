import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import SwiftUI

/// rekordbox식 그리드 편집. 모든 변경은 DJCrate 초안에만 저장된다.
struct GridEditorBar: View {
    @Bindable var deck: DeckModel
    @State private var bpmText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = deck.gridEditBlockedReason {
                Label(reason, systemImage: "lock").font(.caption).foregroundStyle(UIColors.warning.color)
            } else {
                FlowLayout(spacing: 8) {
                    HStack(spacing: 4) {
                        Button("◀ 10ms") { deck.shiftGrid(ms: -10) }
                        Button("◀ 1ms") { deck.shiftGrid(ms: -1) }
                        Button("1ms ▶") { deck.shiftGrid(ms: 1) }
                        Button("10ms ▶") { deck.shiftGrid(ms: 10) }
                    }
                    .help("그리드 전체를 옮깁니다 (파형을 끌어도 됩니다)")
                    HStack(spacing: 4) {
                        TextField("BPM", text: $bpmText)
                            .frame(width: 64)
                            .onSubmit { if let v = Double(bpmText) { deck.setGridBPM(v) } }
                            .onAppear { bpmText = deck.gridBPM.map { String(format: "%.2f", $0) } ?? "" }
                            .onChange(of: deck.gridBPM) { bpmText = deck.gridBPM.map { String(format: "%.2f", $0) } ?? "" }
                            .help("현재 템포 구간의 BPM (엔터로 적용)")
                        Button("×2") { deck.scaleGridBPM(2) }
                        Button("÷2") { deck.scaleGridBPM(0.5) }
                        Button("−0.01") { deck.nudgeGridBPM(-0.01) }
                        Button("+0.01") { deck.nudgeGridBPM(0.01) }
                    }
                    HStack(spacing: 4) {
                        Button("½박 이동") { deck.shiftGridHalfBeat() }
                            .help("그리드를 반 박 옮깁니다(추정이 뒷박을 잡았을 때)")
                        Button("여기를 1박으로") { deck.setDownbeatAtPlayhead() }
                            .help("플레이헤드에 가장 가까운 박을 마디 첫 박으로")
                        Button("여기서 그리드 시작") { deck.setGridAnchorAtPlayhead() }
                            .help("플레이헤드 위치에 박을 정확히 놓고 1박으로")
                        Button("여기서 BPM 변경") { deck.addTempoChangeAtPlayhead() }
                            .help("변속곡: 가장 가까운 박부터 새 템포 구간을 시작합니다")
                    }
                    Toggle("큐도 함께(핫큐·메모리)", isOn: $deck.carryCues)
                        .toggleStyle(.checkbox)
                        .help("켜면 그리드를 옮기거나 BPM을 바꿀 때 핫큐·메모리 큐(루프 포함)가 같은 박을 따라 움직입니다")
                    HStack(spacing: 4) {
                        Button("탭 (T)") { deck.tapTempo() }
                        if let tap = deck.tapBPM {
                            Text(String(format: "탭 %.2f", tap)).font(.caption.monospacedDigit())
                            Button("적용") { deck.setGridBPM(tap) }
                        }
                    }
                }
                FlowLayout(spacing: 6) {
                    let segments = deck.gridDraft?.segments ?? []
                    Text("템포 구간 \(segments.count)").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(segments.prefix(24).enumerated()), id: \.offset) { index, segment in
                        HStack(spacing: 2) {
                            Button(String(format: "%@ · %.2f", segment.start.clockText, segment.bpm)) { deck.seek(segment.start) }
                                .buttonStyle(.plain)
                            if index > 0 {
                                Button { deck.removeTempoChange(at: index) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .accessibilityLabel("이 변속 지점 삭제")
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(UIColors.subtleFill, in: Capsule())
                    }
                    if segments.count > 24 { Text("외 \(segments.count - 24)개").font(.caption).foregroundStyle(.secondary) }
                    if deck.gridDraft?.hasChanges == true {
                        Text("그리드 초안 변경됨").font(.caption.bold()).foregroundStyle(UIColors.draft.color)
                    }
                    Button("그리드 되돌리기") { deck.revertGrid() }
                        .disabled(deck.gridDraft?.hasChanges != true)
                }
            }
        }
        .controlSize(.small)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UIColors.draftFill, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// DJCrate가 추정한 그리드 안내. 그리드가 없는 곡은 편집 모드가 아니어도 보인다.
struct GridSuggestionRow: View {
    let deck: DeckModel
    /// 파형 위에 띄우는 작은 배지 모양(줄 끝 채우기·긴 버튼 이름 없이)
    var badge = false

    var body: some View {
        HStack(spacing: 8) {
            if deck.needsGrid {
                Image(systemName: "metronome").foregroundStyle(UIColors.suggestion.color)
                if let suggestion = deck.gridSuggestion {
                    Text(String(format: "rekordbox 그리드가 없습니다 · 추정 %.2f BPM", suggestion.bpm))
                    confidence(suggestion)
                    Button("추정 그리드 적용") { deck.applyGridSuggestion() }
                        .help("추정한 템포·박 위치를 그리드 초안으로 넣습니다. 적용 뒤 그리드 편집으로 고칠 수 있습니다.")
                } else if deck.analysisError != nil {
                    Text("rekordbox 그리드가 없고, 분석에 실패해 추정하지 못했습니다.").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                    Text("rekordbox 그리드가 없습니다 · BPM·박 위치를 추정하는 중…").foregroundStyle(.secondary)
                }
            } else if let note = deck.gridSuggestionNote, let suggestion = deck.gridSuggestion {
                Image(systemName: "wand.and.stars").foregroundStyle(UIColors.suggestion.color)
                Text("DJCrate 제안: \(note)").lineLimit(1)
                Button("제안 그리드 적용") { deck.applyGridSuggestion() }
                    .help("현재 그리드를 추정 그리드로 바꿉니다(초안만, 되돌리기 가능). \(suggestion.isConfident ? "" : "추정 신뢰도가 낮으니 소리로 확인하세요.")")
                if deck.dismissedRevision >= 0, deck.isGridSuggestionDismissed {
                    Button("제안 다시 보기") { deck.restoreGridSuggestion() }
                        .help("무시했던 제안을 그리드 편집 밖에서도 다시 보이게 합니다")
                }
            } else if deck.gridSuggestion != nil {
                Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                Text("DJCrate 추정과 지금 그리드가 사실상 같습니다").foregroundStyle(.secondary)
            }
            if !badge { Spacer(minLength: 0) }
            Button { deck.reanalyze() } label: {
                if badge { Image(systemName: "arrow.triangle.2.circlepath") } else { Label("재분석", systemImage: "arrow.triangle.2.circlepath") }
            }
            .help("이 곡의 섹션·그리드 추정·조성 분석 캐시를 지우고 다시 분석합니다(파형·초안은 그대로)")
        }
        .font(.caption)
        .lineLimit(1)
        .controlSize(.small)
    }

    private func confidence(_ suggestion: GridEstimator.Estimate) -> some View {
        Text(suggestion.isConfident ? "" : "확인 필요")
            .font(.caption.bold())
            .foregroundStyle(UIColors.warning.color)
            .help(suggestion.isConfident
                  ? "박이 고르게 잡혔습니다. 1박(마디 첫 박)과 반 박 어긋남은 소리로 한 번 확인하세요."
                  : "박이 흔들리거나 템포가 바뀌는 곡입니다. 적용 뒤 메트로놈으로 확인하고 고쳐 주세요.")
    }
}
