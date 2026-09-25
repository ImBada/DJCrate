import AnicueCore
import SwiftUI

/// A안 위쪽 덱: 커버·정보 | 확대/개요 파형 + 컨트롤 | 큐 목록.
/// 높이는 내용에 맞춰 정해지고(잘리지 않음), 파형 높이만 사용자가 조절한다.
/// 창이 좁으면 커버 열을 작은 헤더로 접고, 컨트롤 줄은 줄바꿈한다.
struct DeckView: View {
    @Bindable var deck: DeckModel
    var waveformHeight: Double
    @State private var width: CGFloat = 1400
    @State private var middleHeight: CGFloat = 320

    private var compact: Bool { width < 1150 }
    private var cueListWidth: CGFloat { width < 1400 ? 250 : 290 }

    var body: some View {
        if let row = deck.row {
            HStack(alignment: .top, spacing: 16) {
                if !compact {
                    DeckInfoColumn(deck: deck, row: row)
                        .frame(width: 210)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if compact { CompactInfo(deck: deck, row: row) }
                    ZoomWaveformView(deck: deck)
                        .frame(height: waveformHeight)
                        .overlay(alignment: .center) { loadingOverlay }
                        .overlay(alignment: .top) {
                            if let toast = deck.toast {
                                Label(toast, systemImage: "exclamationmark.circle.fill")
                                    .font(.callout.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(.regularMaterial, in: Capsule())
                                    .padding(.top, 22)
                                    .transition(.opacity)
                                    .allowsHitTesting(false)
                            }
                        }
                        .animation(.easeOut(duration: 0.15), value: deck.toast)
                    OverviewWaveformView(deck: deck)
                        .frame(height: 86)
                    TransportBar(deck: deck)
                    AudioBar(deck: deck)
                    if deck.gridEditing || deck.needsGrid { GridSuggestionRow(deck: deck) }
                    if deck.gridEditing { GridEditorBar(deck: deck) }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { middleHeight = $0 }
                CueListView(deck: deck)
                    .frame(width: cueListWidth, height: max(middleHeight, 220))
            }
            .padding(14)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // 단축키는 창 전체에서 KeyRouter가 받는다(포커스 위치와 무관).
        } else {
            ContentUnavailableView("곡을 선택하세요", systemImage: "music.note",
                                   description: Text("아래 목록에서 곡을 고르면 파형과 큐가 여기 뜹니다."))
                .frame(height: 220)
        }
    }

    @ViewBuilder private var loadingOverlay: some View {
        if deck.row?.track.isStreaming == true {
            Text("스트리밍 곡은 파형·재생·분석을 할 수 없습니다").font(.callout).foregroundStyle(.secondary)
        } else if let error = deck.waveformError {
            Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
        } else if deck.waveform == nil {
            ProgressView().controlSize(.small)
        }
    }

}

/// 좁은 창: 커버 열 대신 한 줄 헤더.
private struct CompactInfo: View {
    let deck: DeckModel
    let row: TrackRow

    var body: some View {
        HStack(spacing: 10) {
            CoverView(image: deck.artwork, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.headline).lineLimit(1)
                Text([row.artist, row.genre].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(row.comment.isEmpty ? "(빈 코멘트)" : row.comment)
                .font(.caption.monospaced()).lineLimit(1)
                .foregroundStyle(row.comment.isEmpty ? .tertiary : .secondary)
        }
    }
}

// MARK: - 커버·정보

private struct DeckInfoColumn: View {
    let deck: DeckModel
    let row: TrackRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverView(image: deck.artwork, size: 150)
            Text(row.title).font(.headline).lineLimit(2).textSelection(.enabled)
            Text(row.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if let genre = row.track.genre, !genre.trimmingCharacters(in: .whitespaces).isEmpty {
                Label(genre, systemImage: "guitars").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) {
                if let bpm = row.track.bpm { Text(String(format: "%.1f BPM", bpm)) }
                if let key = row.track.key { Text(key) }
                Text(Double(row.track.lengthSeconds).clockText.dropLast(3))
                if row.playCount > 0 { Text("재생 \(row.playCount)") }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if let path = row.track.analysisDataPath, !path.isEmpty, !row.track.isStreaming,
               !RekordboxShare.hasWaveformAnalysis(path) {
                Label("rekordbox 분석 전 · 파형 없음", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help("rekordbox가 이 곡을 아직 분석하지 않았습니다(파형 파일 없음). rekordbox에서 트랙 분석을 먼저 해야 그리드를 쓸 수 있습니다")
            }
            // 코멘트는 적힌 그대로(태그로 나누지 않는다)
            Text(row.comment.isEmpty ? "(빈 코멘트)" : row.comment)
                .font(.callout)
                .foregroundStyle(row.comment.isEmpty ? .tertiary : .primary)
                .lineLimit(3)
                .textSelection(.enabled)
                .help(row.comment)
        }
        // 글자 길이와 상관없이 늘 왼쪽 위에 붙인다.
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct CoverView: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note").font(.system(size: size * 0.28)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 8 : 3))
        .accessibilityLabel("앨범 커버")
    }
}

// MARK: - 트랜스포트

private struct TransportBar: View {
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
                PlayheadLabel(deck: deck)
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
private struct ZoomControl: View {
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

/// 볼륨 · 메트로놈 · 템포(변속) · 키 고정 · 그리드 편집 전환
private struct AudioBar: View {
    @Bindable var deck: DeckModel

    var body: some View {
        FlowLayout(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: deck.volume == 0 ? "speaker.slash" : "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: $deck.volume, in: 0...1).frame(width: 90)
                    .accessibilityLabel("재생 볼륨")
            }
            HStack(spacing: 6) {
                GainControl(deck: deck)
                LevelMeterView(deck: deck)
                // rekordbox 오토게인이 이상하면 그리드 제안처럼 옆에 띄운다.
                if let suggestion = deck.gainSuggestion {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars").foregroundStyle(Palette.suggestion)
                        Text(String(format: "게인 제안 %+.1f dB (rekordbox %+.1f)", suggestion, deck.rekordboxGainDB ?? 0))
                            .font(.caption).foregroundStyle(.secondary)
                        Button("제안 받기") { deck.acceptGainSuggestion() }
                            .help("이 곡은 anicue가 잰 음량으로 계산한 게인(−10 LUFS 기준)을 씁니다")
                        Button("무시") { deck.dismissGainSuggestion() }
                            .help("이 곡에서는 rekordbox 값을 그대로 쓰고 제안을 더 보이지 않습니다")
                    }
                    .help(String(format: "rekordbox 오토게인이 이 파일의 실제 음량과 %.1fdB 다릅니다", abs(deck.gainMismatchDB ?? 0)))
                } else if deck.hasGainOverride {
                    Button("게인 초안 취소") { deck.clearGainDraft() }
                        .font(.caption)
                        .help("이 곡의 게인 초안을 지우고 rekordbox 오토게인으로 돌아갑니다")
                }
            }
            Toggle(isOn: $deck.metronome) { Label("메트로놈", systemImage: "metronome") }
                .toggleStyle(.button)
                .help("그리드의 박마다 클릭 (1박은 높은 음)")
            HStack(spacing: 4) {
                Text("템포").foregroundStyle(.secondary)
                Slider(value: $deck.tempoPercent, in: -16...16, step: 0.1).frame(width: 120)
                    .accessibilityLabel("재생 템포")
                Text(String(format: "%+.1f%%", deck.tempoPercent)).font(.caption.monospacedDigit()).frame(width: 46, alignment: .trailing)
                Button("0") { deck.tempoPercent = 0 }.help("원래 속도로")
            }
            Toggle("키 고정", isOn: $deck.keyLock)
                .toggleStyle(.checkbox)
                .help("켜면 음정을 유지한 채 속도만 바꿉니다(마스터 템포). 끄면 바이닐처럼 음정도 함께 바뀝니다.")
            Toggle(isOn: $deck.gridEditing) { Label("그리드 편집", systemImage: "grid") }
                .toggleStyle(.button)
                .disabled(deck.gridDraft == nil)
                .help(deck.gridEditBlockedReason ?? "켜면 파형을 끌어 그리드를 옮기고, 아래 막대로 BPM·1박·변속 지점을 고칩니다.")
            // 그리드 편집에 들어가지 않고 anicue 제안을 받거나 무시한다.
            if !deck.gridEditing, !deck.needsGrid, let note = deck.gridSuggestionNote,
               deck.dismissedRevision >= 0, !deck.isGridSuggestionDismissed {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars").foregroundStyle(Palette.suggestion)
                    Text(note).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    Button("제안 받기") { deck.applyGridSuggestion() }
                        .help("anicue가 추정한 그리드로 바꿉니다(초안만, 되돌리기 가능)")
                    Button("무시") { deck.dismissGridSuggestion() }
                        .help("이 곡에서는 제안을 더 보이지 않습니다")
                }
            }
        }
        .controlSize(.small)
    }
}

/// rekordbox식 그리드 편집. 모든 변경은 anicue 초안에만 저장된다.
private struct GridEditorBar: View {
    @Bindable var deck: DeckModel
    @State private var bpmText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = deck.gridEditBlockedReason {
                Label(reason, systemImage: "lock").font(.caption).foregroundStyle(.orange)
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
                    Toggle("핫큐도 함께", isOn: $deck.carryHotCues)
                        .toggleStyle(.checkbox)
                        .help("켜면 그리드를 옮기거나 BPM을 바꿀 때 핫큐(루프 포함)도 같은 박을 따라 움직입니다. 메모리 큐는 그대로입니다")
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
                        .background(.quaternary, in: Capsule())
                    }
                    if segments.count > 24 { Text("외 \(segments.count - 24)개").font(.caption).foregroundStyle(.secondary) }
                    if deck.gridDraft?.hasChanges == true {
                        Text("그리드 초안 변경됨").font(.caption.bold()).foregroundStyle(Palette.mid)
                    }
                    Button("그리드 되돌리기") { deck.revertGrid() }
                        .disabled(deck.gridDraft?.hasChanges != true)
                }
            }
        }
        .controlSize(.small)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.mid.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// anicue가 추정한 그리드 안내. 그리드가 없는 곡은 편집 모드가 아니어도 보인다.
private struct GridSuggestionRow: View {
    let deck: DeckModel

    var body: some View {
        HStack(spacing: 8) {
            if deck.needsGrid {
                Image(systemName: "metronome").foregroundStyle(Palette.suggestion)
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
                Image(systemName: "wand.and.stars").foregroundStyle(Palette.suggestion)
                Text("anicue 제안: \(note)").lineLimit(1)
                Button("제안 그리드 적용") { deck.applyGridSuggestion() }
                    .help("현재 그리드를 추정 그리드로 바꿉니다(초안만, 되돌리기 가능). \(suggestion.isConfident ? "" : "추정 신뢰도가 낮으니 소리로 확인하세요.")")
                if deck.dismissedRevision >= 0, deck.isGridSuggestionDismissed {
                    Button("제안 다시 보기") { deck.restoreGridSuggestion() }
                        .help("무시했던 제안을 그리드 편집 밖에서도 다시 보이게 합니다")
                }
            } else if deck.gridSuggestion != nil {
                Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                Text("anicue 추정과 지금 그리드가 사실상 같습니다").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { deck.reanalyze() } label: { Label("재분석", systemImage: "arrow.triangle.2.circlepath") }
                .help("이 곡의 섹션·그리드 추정·조성 분석 캐시를 지우고 다시 분석합니다(파형·초안은 그대로)")
        }
        .font(.caption)
        .controlSize(.small)
    }

    private func confidence(_ suggestion: GridEstimator.Estimate) -> some View {
        Text(suggestion.isConfident ? "" : "확인 필요")
            .font(.caption.bold())
            .foregroundStyle(.orange)
            .help(suggestion.isConfident
                  ? "박이 고르게 잡혔습니다. 1박(마디 첫 박)과 반 박 어긋남은 소리로 한 번 확인하세요."
                  : "박이 흔들리거나 템포가 바뀌는 곡입니다. 적용 뒤 메트로놈으로 확인하고 고쳐 주세요.")
    }
}

/// 매 프레임 바뀌는 시간 표시만 따로 둔다(컨트롤이 많은 줄 전체가 다시 그려지지 않도록).
private struct PlayheadLabel: View {
    let deck: DeckModel

    var body: some View {
        let t = deck.currentTime
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

/// 게인 버튼: 지금 걸린 게인과 곡 음량을 보여 주고, 누르면 오토게인·트림 설정.
private struct GainControl: View {
    @Bindable var deck: DeckModel
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 4) {
                Text(deck.autoGain ? (deck.useRekordboxGain && deck.rekordboxGainDB != nil ? "RB AUTO" : "AUTO") : "GAIN")
                    .font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(deck.autoGain ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.2)))
                Text(String(format: "%+.1f dB", deck.appliedGain)).font(.caption.monospacedDigit())
                if let loudness = deck.loudness, let lufs = loudness.integrated {
                    Text(String(format: "%.1f LUFS", lufs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(loudness.isHot ? Color.orange : Color.secondary)
                }
                if deck.isGainSuspicious {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help("rekordbox 오토게인이 anicue 측정과 1.5dB 넘게 다릅니다")
                }
            }
        }
        .buttonStyle(.borderless)
        .help("게인(볼륨 페이더 앞). 누르면 오토게인·목표 음량·트림을 정합니다. 주황 LUFS = 매우 큰 마스터(−6 LUFS 초과)이거나 심한 클리핑")
        .popover(isPresented: $shown, arrowEdge: .bottom) { GainSettings(deck: deck).padding(16).frame(width: 340) }
    }
}

private struct GainSettings: View {
    @Bindable var deck: DeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("게인").font(.headline)
            Toggle("오토게인 — 곡마다 목표 음량에 맞춤", isOn: $deck.autoGain)
            Toggle("rekordbox 오토게인 값 쓰기(rekordbox는 약 −10 LUFS에 맞춤)", isOn: $deck.useRekordboxGain)
                .disabled(!deck.autoGain)
            Picker("목표 음량", selection: $deck.gainTarget) {
                ForEach([-14.0, -12, -11, -10, -9, -8], id: \.self) { Text(String(format: "%.0f LUFS", $0)).tag($0) }
            }
            .disabled(!deck.autoGain)
            Toggle("피크 보호 — 0dBFS를 넘지 않을 만큼만 올림", isOn: $deck.peakProtection)
                .disabled(!deck.autoGain)
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
                    Text(loudness.integrated.map { String(format: "통합 음량 %.1f LUFS", $0) } ?? "통합 음량 — (무음)")
                    Text(String(format: "샘플 피크 %.1f dBFS", loudness.peak))
                    Text(String(format: "적용 게인 %+.1f dB (오토 %+.1f · 트림 %+.1f)", deck.appliedGain, deck.autoGainDB, deck.gainTrim))
                    if let rekordbox = deck.rekordboxGainDB {
                        Text(String(format: "rekordbox 오토게인 %+.1f dB", rekordbox) + (deck.measuredGainDB.map { String(format: " · anicue 계산 %+.1f dB", $0) } ?? ""))
                        HStack(spacing: 6) {
                            Text("이 곡 오토게인")
                            Button("−1") { deck.adjustTrackGain(by: -1) }
                            Button("−0.1") { deck.adjustTrackGain(by: -0.1) }
                            Text(String(format: "%+.1f dB", deck.trackGainDB ?? rekordbox))
                                .font(.callout.monospacedDigit().bold())
                                .foregroundStyle(deck.gainDraft != nil ? Color.accentColor : Color.primary)
                                .frame(width: 64)
                            Button("+0.1") { deck.adjustTrackGain(by: 0.1) }
                            Button("+1") { deck.adjustTrackGain(by: 1) }
                            if deck.gainDraft != nil {
                                Button("되돌리기") { deck.clearGainDraft() }
                            }
                        }
                        .controlSize(.small)
                        if deck.gainDraft != nil {
                            Text("초안입니다. rekordbox에 반영하면 rekordbox 오토게인이 이 값으로 바뀝니다.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("rekordbox 오토게인 값 없음(rekordbox에서 분석하지 않은 곡)").foregroundStyle(.secondary)
                    }
                    if deck.isGainSuspicious, let mismatch = deck.gainMismatchDB {
                        Label(String(format: "rekordbox 값이 이 파일 음량과 %.1fdB 다릅니다. 파일을 바꿨거나 분석이 오래됐을 수 있습니다 — rekordbox에서 다시 분석하거나 anicue 계산값을 쓰세요.", abs(mismatch)),
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if loudness.isLoud {
                        Label("마스터가 매우 큽니다(−6 LUFS 초과). 라이브러리 대부분의 곡보다 세게 들립니다.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if loudness.clippedRuns > 0 {
                        Label("원본에 클리핑 흔적 \(loudness.clippedRuns)곳(풀스케일에 붙은 구간)\(loudness.isHeavilyClipped ? " — 심함" : "")",
                              systemImage: "waveform.path.badge.minus")
                            .foregroundStyle(loudness.isHeavilyClipped ? .orange : .secondary)
                    }
                }
                .font(.callout)
            } else {
                Text(deck.row == nil ? "곡을 올리면 음량을 잽니다." : "곡 음량을 재는 중이거나 잴 수 없는 파일입니다(20분 넘는 파일·스트리밍).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("미터는 게인 뒤·볼륨 앞 레벨입니다. 0dBFS를 넘으면 CLIP이 켜지고, 누르면 기록을 지웁니다.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 레벨 미터(게인 뒤·볼륨 앞, L/R 피크). 초록 ~−12 · 노랑 −12~−3 · 빨강 −3~0dBFS.
/// 오른쪽은 곡을 올린 뒤 최고 피크와 CLIP 표시(0dBFS 이상, 누르면 지움).
private struct LevelMeterView: View {
    let deck: DeckModel
    @State private var ballistics = MeterBallistics()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !deck.isPlaying)) { _ in
            let reading = deck.meter.read()
            let now = ProcessInfo.processInfo.systemUptime
            let state = ballistics.step(reading, now: now, playing: deck.isPlaying)
            let clipping = now - reading.clipTime < 2 || reading.clipCount > 0
            HStack(spacing: 6) {
                Canvas { context, size in draw(context, size: size, state: state) }
                    .frame(width: 130, height: 13)
                // 최고 피크. 0dBFS를 넘은 적이 있으면 빨간 점이 켜진다. 누르면 기록을 지운다.
                Button { deck.meter.resetPeaks() } label: {
                    HStack(spacing: 3) {
                        Circle().fill(Color.red).frame(width: 6, height: 6).opacity(clipping ? 1 : 0)
                        Text(reading.maxPeak > 0 ? String(format: "%+.1f", 20 * log10(reading.maxPeak)) : "−∞")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(reading.maxPeak >= 1 ? Color.red : reading.maxPeak >= 0.708 ? Color.orange : Color.secondary)
                    }
                    .frame(width: 44, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(reading.clipCount > 0
                      ? "최고 피크(dBFS, 게인 뒤). 0dBFS를 \(reading.clipCount)번 넘었습니다 — 게인을 낮추세요. 누르면 기록을 지웁니다"
                      : "곡을 올린 뒤 최고 피크(dBFS, 게인 뒤). 0dBFS를 넘으면 빨간 점이 켜집니다. 누르면 기록을 지웁니다")
            }
        }
        .accessibilityLabel("레벨 미터")
    }

    private static let floor: Double = -48
    private static let top: Double = 3

    private func x(_ db: Double, _ width: CGFloat) -> CGFloat {
        CGFloat((min(max(db, Self.floor), Self.top) - Self.floor) / (Self.top - Self.floor)) * width
    }

    private func draw(_ context: GraphicsContext, size: CGSize, state: MeterBallistics.State) {
        let barHeight = (size.height - 1) / 2
        let zones: [(from: Double, to: Double, color: Color)] = [(-48, -12, .green), (-12, -3, .yellow), (-3, 3, .red)]
        for (row, channel) in [state.left, state.right].enumerated() {
            let y = CGFloat(row) * (barHeight + 1)
            context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: barHeight)), with: .color(.black.opacity(0.35)))
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
                             with: .color(channel.hold >= 0 ? .red : .white.opacity(0.8)))
            }
        }
        // 0dBFS 눈금
        let zero = x(0, size.width)
        context.fill(Path(CGRect(x: zero, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.5)))
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

/// CDJ의 CUE 버튼. 누르는 순간과 떼는 순간을 모두 받아야 해서(미리 듣기) Button 대신 제스처를 쓴다.
private struct CueButton: View {
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

private struct HotCuePad: View {
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
private struct LoopControl: View {
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

/// 단축키 안내(? 버튼을 누를 때만 보인다).
private struct ShortcutsButton: View {
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "questionmark.circle") }
            .buttonStyle(.borderless)
            .help("단축키")
            .accessibilityLabel("단축키 보기")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                ShortcutsList(scale: 1.1).padding(18)
            }
    }
}

/// 단축키 목록(? 버튼 팝오버). 키는 키캡 모양으로 크게 쓴다.
struct ShortcutsList: View {
    /// 1 = 팝오버, ⌘ 안내는 더 크게
    var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            Text("단축키").font(.system(size: 20 * scale, weight: .bold))
            Grid(alignment: .leading, horizontalSpacing: 18 * scale, verticalSpacing: 9 * scale) {
                row(["Space"], "재생 / 정지")
                row(["C"], "CUE — 재생 중: 큐로 돌아가 정지 · 멈춤: 큐 지점 설정 · 누르고 있기: 미리 듣기")
                row(["1", "~", "8"], "핫큐 A~H (있으면 이동, 없으면 찍기)")
                row(["Shift", "+", "1", "~", "8"], "그 핫큐 지우기")
                row(["`", "·", "M"], "메모리 큐 찍기 (파형 더블클릭도)")
                row(["Shift", "+", "`", "·", "M"], "이 자리 메모리 큐 지우기")
                row(["Q", "/", "E"], "이전 · 다음 큐로")
                row(["←", "→"], "선택한 큐 1박 이동")
                row(["⌫"], "선택한 큐 지우기")
                row(["L"], "루프 걸기 · 나가기 (반복 중 빈 핫큐 = 루프 핫큐로 저장)")
                row(["[", "/", "]"], "루프 길이 ½ · ×2")
                row(["T"], "탭 템포")
                row(["휠", "·", "+", "/", "−"], "파형 확대 · 축소 (가로 스크롤: 이동)")
                row(["⌘", "⇧", "E"], "rekordbox에 반영")
                row(["⌘", "I"], "태그 편집")
            }
        }
    }

    /// 구분 기호(~ / · +)는 키캡 없이 글자로만 쓴다.
    private static let separators: Set<String> = ["~", "/", "·", "+"]

    private func row(_ keys: [String], _ text: String) -> some View {
        GridRow {
            HStack(spacing: 4 * scale) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    if Self.separators.contains(key) {
                        Text(key).font(.system(size: 14 * scale, weight: .medium)).foregroundStyle(.secondary)
                    } else {
                        Text(key)
                            .font(.system(size: 14 * scale, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 7 * scale).padding(.vertical, 3 * scale)
                            .frame(minWidth: 24 * scale)
                            .background(RoundedRectangle(cornerRadius: 5 * scale).fill(Color.primary.opacity(0.10)))
                            .overlay(RoundedRectangle(cornerRadius: 5 * scale).strokeBorder(Color.primary.opacity(0.25)))
                    }
                }
            }
            Text(text)
                .font(.system(size: 15 * scale))
                .frame(maxWidth: 520 * scale, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 큐 목록

private struct CueListView: View {
    @Bindable var deck: DeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                let cues = deck.draft?.cues ?? []
                let hot = cues.filter { if case .hot = $0.kind { true } else { false } }.count
                Text("핫큐 \(hot)").font(.headline).foregroundStyle(Palette.hot)
                Text("메모리 \(cues.count - hot)").font(.headline).foregroundStyle(Palette.memory)
                Spacer()
                if let changes = deck.draft?.changes, !changes.isEmpty {
                    Text("초안 변경 \(changes.count)")
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.mid.opacity(0.2), in: Capsule())
                        .foregroundStyle(Palette.mid)
                }
            }
            List(selection: $deck.selectedCueID) {
                ForEach(deck.draft?.cues ?? []) { cue in
                    CueRow(deck: deck, cue: cue)
                        .tag(cue.id)
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()

            if let issues = deck.draft?.issues(duration: deck.duration), !issues.isEmpty {
                Label(issues.joined(separator: " · "), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("되돌리기") { deck.revertDraft() }
                    .disabled(deck.draft?.hasChanges != true)
                    .help("rekordbox에서 불러온 상태로 되돌립니다")
                Spacer()
                Button("rekordbox에 반영…") { if let row = deck.row { deck.onRequestReflection?(row) } }
                    .disabled(deck.isWriteLocked || deck.row?.isStaged != false || (deck.draft?.hasChanges != true && deck.gridDraft?.hasChanges != true))
                    .help("이 곡의 큐 초안을 rekordbox 라이브러리에 바로 씁니다(미리 보기로 확인한 뒤, rekordbox가 꺼져 있을 때만). 그리드 초안은 아직 XML로만 반영됩니다.")
            }
            .controlSize(.small)
            if deck.isWriteLocked {
                Text("rekordbox에 쓰는 중이라 큐 편집을 잠시 막았습니다.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CueRow: View {
    let deck: DeckModel
    let cue: EditableCue

    var body: some View {
        HStack(spacing: 6) {
            Picker("종류", selection: Binding(get: { cue.kind }, set: { deck.setKind(cue.id, $0) })) {
                Text("메모리").tag(EditableCue.Kind.memory)
                ForEach(0..<8, id: \.self) { slot in
                    Text("핫큐 \(String(UnicodeScalar(UInt8(65 + slot))))").tag(EditableCue.Kind.hot(slot))
                }
            }
            .labelsHidden()
            .frame(width: 76)
            .foregroundStyle(Palette.color(for: cue))

            Button { deck.nudge(cue.id, beats: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).help("1박 앞으로").accessibilityLabel("1박 앞으로")
            Button { deck.seek(cue.time); deck.selectedCueID = cue.id } label: {
                Text(cue.time.clockText).font(.caption.monospacedDigit())
            }
            .buttonStyle(.plain).help("이 위치로 이동")
            Button { deck.nudge(cue.id, beats: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).help("1박 뒤로").accessibilityLabel("1박 뒤로")

            // 루프: 박 수 메뉴, 활성 루프 켜기·끄기
            Menu {
                Button("루프 없음") { deck.setLoop(cue.id, beats: nil) }
                Divider()
                ForEach([1, 2, 4, 8, 16, 32], id: \.self) { beats in
                    Button("\(beats)박 루프") { deck.setLoop(cue.id, beats: beats) }
                }
            } label: {
                Text(cue.loop == nil ? "루프" : "\(cue.loop?.beats.map(DeckModel.beatsText) ?? deck.loopBeats(cue).map(String.init) ?? "?")박")
                    .font(.caption.monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(cue.loop == nil ? Color.secondary : Palette.loop)
            .help("이 큐를 루프로 만들거나 길이를 바꿉니다")
            if cue.loop != nil {
                Button { deck.toggleActiveLoop(cue.id) } label: {
                    Image(systemName: "repeat.circle\(cue.loop?.active == true ? ".fill" : "")")
                        .foregroundStyle(cue.loop?.active == true ? Palette.loop : .secondary)
                }
                .buttonStyle(.borderless)
                .help(cue.loop?.active == true ? "활성 루프(곡을 불러오면 자동 반복) — 눌러서 끄기" : "활성 루프로 만들기(곡을 불러오면 이 루프를 자동 반복)")
            }

            TextField("이름", text: Binding(get: { cue.name }, set: { deck.rename(cue.id, $0) }))
                .textFieldStyle(.plain)
                .font(.caption)

            Button(role: .destructive) { deck.delete(cue.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("삭제").accessibilityLabel("큐 삭제")
        }
        .controlSize(.small)
    }
}

/// 칩을 줄바꿈하며 배치한다.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
