import AnicueCore
import SwiftUI

/// A안 위쪽 덱: 커버·정보 | 확대/개요 파형 + 컨트롤 | 큐 목록.
/// 높이는 내용에 맞춰 정해지고(잘리지 않음), 파형 높이만 사용자가 조절한다.
/// 창이 좁으면 커버 열을 작은 헤더로 접고, 컨트롤 줄은 줄바꿈한다.
struct DeckView: View {
    @Bindable var deck: DeckModel
    var waveformHeight: Double
    @FocusState private var focused: Bool
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
                    OverviewWaveformView(deck: deck)
                        .frame(height: 72)
                    TransportBar(deck: deck)
                    AudioBar(deck: deck)
                    if deck.gridEditing { GridEditorBar(deck: deck) }
                    Legend()
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { middleHeight = $0 }
                CueListView(deck: deck)
                    .frame(width: cueListWidth, height: max(middleHeight, 220))
            }
            .padding(14)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onTapGesture { focused = true }
            .onKeyPress(.space) { deck.togglePlay(); return .handled }
            .onKeyPress(.delete) { deleteSelected() }
            .onKeyPress(.deleteForward) { deleteSelected() }
            .onKeyPress(.leftArrow) { nudgeSelected(-1) }
            .onKeyPress(.rightArrow) { nudgeSelected(1) }
            .onKeyPress("m") { deck.addMemoryCue(at: deck.currentTime); return .handled }
            .onKeyPress("t") { deck.tapTempo(); return .handled }
            .onKeyPress("+") { deck.zoom(by: 0.8); return .handled }
            .onKeyPress("=") { deck.zoom(by: 0.8); return .handled }
            .onKeyPress("-") { deck.zoom(by: 1.25); return .handled }
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

    private func deleteSelected() -> KeyPress.Result {
        guard let id = deck.selectedCueID else { return .ignored }
        deck.delete(id)
        return .handled
    }

    private func nudgeSelected(_ beats: Int) -> KeyPress.Result {
        guard let id = deck.selectedCueID else { return .ignored }
        deck.nudge(id, beats: beats)
        return .handled
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
            Text(row.comment.isEmpty ? "(빈 코멘트)" : row.comment)
                .font(.callout.monospaced())
                .foregroundStyle(row.comment.isEmpty ? .tertiary : .primary)
                .lineLimit(2)
                .textSelection(.enabled)
            if let parsed = row.parsed {
                FlowLayout(spacing: 4) {
                    ForEach(Array(chips(parsed).enumerated()), id: \.offset) { _, chip in
                        Text(chip).font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
    }

    private func chips(_ c: ConventionComment) -> [String] {
        var chips = [c.prefix.rawValue]
        if !c.workName.isEmpty { chips.append(c.workName) }
        if let season = c.season { chips.append("\(season)기") }
        chips += c.abbreviations
        chips += c.usages.map { $0.kind.rawValue + ($0.numbers.isEmpty ? "" : " " + $0.numbers.map(String.init).joined(separator: ",")) }
        if c.isCharacterSong { chips.append("CS") }
        if c.isTVSize { chips.append("TVSIZE") }
        return chips
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
                Button {
                    deck.togglePlay()
                } label: {
                    Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .disabled(!deck.canPlay)
                .help("재생/일시정지 (스페이스)")
                PlayheadLabel(deck: deck)
                    .frame(width: 112, alignment: .leading)
            }
            HStack(spacing: 4) {
                ForEach(0..<8, id: \.self) { slot in
                    HotCuePad(deck: deck, slot: slot)
                }
            }
            Button("+ 메모리 큐") { deck.addMemoryCue(at: deck.currentTime) }
                .help("플레이헤드 위치에 메모리 큐 추가 (M)")
            ZoomControl(deck: deck)
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

/// 볼륨 · 메트로놈 · 템포(변속) · 키 고정 · BPM · 그리드 편집 전환
private struct AudioBar: View {
    @Bindable var deck: DeckModel

    var body: some View {
        FlowLayout(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: deck.volume == 0 ? "speaker.slash" : "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: $deck.volume, in: 0...1).frame(width: 90)
                    .accessibilityLabel("재생 볼륨")
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
            if let bpm = deck.gridBPM {
                Text(deck.tempoPercent == 0 ? String(format: "%.2f BPM", bpm)
                     : String(format: "%.2f → %.2f BPM", bpm, bpm * deck.rate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: $deck.gridEditing) { Label("그리드 편집", systemImage: "grid") }
                .toggleStyle(.button)
                .disabled(deck.gridDraft == nil)
                .help(deck.gridEditBlockedReason ?? "켜면 파형을 끌어 그리드를 옮기고, 아래 막대로 BPM·1박·변속 지점을 고칩니다.")
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
                        Button("여기를 1박으로") { deck.setDownbeatAtPlayhead() }
                            .help("플레이헤드에 가장 가까운 박을 마디 첫 박으로")
                        Button("여기서 그리드 시작") { deck.setGridAnchorAtPlayhead() }
                            .help("플레이헤드 위치에 박을 정확히 놓고 1박으로")
                        Button("여기서 BPM 변경") { deck.addTempoChangeAtPlayhead() }
                            .help("변속곡: 가장 가까운 박부터 새 템포 구간을 시작합니다")
                    }
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

/// 매 프레임 바뀌는 시간 표시만 따로 둔다(컨트롤이 많은 줄 전체가 다시 그려지지 않도록).
private struct PlayheadLabel: View {
    let deck: DeckModel

    var body: some View {
        let t = deck.currentTime
        HStack(spacing: 6) {
            Text(t.clockText).font(.callout.monospacedDigit())
            if let grid = deck.grid {
                Text("\(grid.bar(at: t))마디").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

private struct HotCuePad: View {
    let deck: DeckModel
    let slot: Int

    var body: some View {
        let cue = deck.hotCue(slot: slot)
        let letter = String(UnicodeScalar(UInt8(65 + slot)))
        Button {
            deck.pressHotCue(slot: slot)
        } label: {
            Text(letter)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 20)
                .foregroundStyle(cue == nil ? Color.secondary : Color.black)
                .background(cue == nil ? Color.clear : Palette.hot, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(cue == nil ? Color.secondary.opacity(0.5) : Palette.hot))
        }
        .buttonStyle(.plain)
        .help(cue == nil ? "핫큐 \(letter): 플레이헤드에 설정" : "핫큐 \(letter)로 이동 (\(cue!.time.clockText))")
        .accessibilityLabel(cue == nil ? "핫큐 \(letter) 비어 있음, 설정" : "핫큐 \(letter)로 이동")
        .contextMenu {
            if cue != nil {
                Button("플레이헤드로 옮기기") { deck.moveHotCueToPlayhead(slot: slot) }
                Button("삭제", role: .destructive) { if let id = cue?.id { deck.delete(id) } }
            }
        }
    }
}

private struct Legend: View {
    var body: some View {
        FlowLayout(spacing: 12) {
            item(Palette.low, "저음")
            item(Palette.mid, "중음")
            item(Palette.high, "고음")
            item(Palette.section, "섹션")
            item(Palette.hot, "핫큐")
            item(Palette.memory, "메모리 큐")
            item(Palette.suggestion, "제안")
            Text("드래그: 스크럽 · 큐 드래그: 이동 · 더블클릭: 메모리 큐 · 휠: 확대 · ←→: 1박 · ⌫: 삭제 · T: 탭")
                .foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func item(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text)
        }
    }
}

// MARK: - 큐 목록

private struct CueListView: View {
    @Bindable var deck: DeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("큐 \(deck.draft?.cues.count ?? 0)").font(.headline)
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
                Button("rekordbox에 반영…") {}
                    .disabled(true)
                    .help("반영 경로(XML 가져오기) 검증 전까지 잠겨 있습니다. 편집은 anicue 초안에만 저장됩니다.")
            }
            .controlSize(.small)
            Text("편집은 anicue 초안에만 저장됩니다. rekordbox 라이브러리는 바뀌지 않습니다.")
                .font(.caption2).foregroundStyle(.secondary)
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
            .foregroundStyle(cue.kind == .memory ? Palette.memory : Palette.hot)

            Button { deck.nudge(cue.id, beats: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).help("1박 앞으로").accessibilityLabel("1박 앞으로")
            Button { deck.seek(cue.time); deck.selectedCueID = cue.id } label: {
                Text(cue.time.clockText).font(.caption.monospacedDigit())
            }
            .buttonStyle(.plain).help("이 위치로 이동")
            Button { deck.nudge(cue.id, beats: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).help("1박 뒤로").accessibilityLabel("1박 뒤로")

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
