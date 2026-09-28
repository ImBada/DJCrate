import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import SwiftUI

struct CueListView: View {
    @Environment(\.textScale) private var textScale
    @Bindable var deck: DeckModel
    @AppStorage(SettingKeys.cueListFilter.name) private var storedFilter = SettingKeys.cueListFilter.defaultValue

    private var filter: CueListFilter {
        CueListFilter(rawValue: SettingKeys.cueListFilter.value(from: storedFilter)) ?? .all
    }
    private var visibleCues: [EditableCue] { (deck.draft?.cues ?? []).filter(filter.includes) }

    private var writeHelp: String {
        if deck.isWriteLocked { return String(ui: "쓰기가 끝난 뒤 다시 시도하세요.") }
        guard let row = deck.row else { return String(ui: "덱에 곡을 먼저 불러오세요.") }
        if row.isStaged { return String(ui: "추가한 곡 목록에서 먼저 rekordbox 컬렉션에 넣으세요.") }
        if deck.draft?.hasChanges != true && deck.gridDraft?.hasChanges != true {
            return String(ui: "큐·그리드 초안을 고친 뒤 쓰세요.")
        }
        return String(ui: "이 곡의 큐·그리드 초안을 확인한 뒤 rekordbox에 씁니다.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                let cues = deck.draft?.cues ?? []
                let hot = cues.filter { if case .hot = $0.kind { true } else { false } }.count
                Text(.ui("핫큐 \(hot)")).font(.scaled(.headline, textScale)).foregroundStyle(UIColors.hot.color)
                Text(.ui("메모리 \(cues.count - hot)")).font(.scaled(.headline, textScale)).foregroundStyle(UIColors.memory.color)
                Spacer()
                if let changes = deck.draft?.changes, !changes.isEmpty {
                    Text(.ui("초안 변경 \(changes.count)"))
                        .font(.scaled(.caption, textScale).bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(UIColors.draftFill, in: Capsule())
                        .foregroundStyle(UIColors.draft.color)
                }
            }
            Picker(.ui("큐 목록 보기"), selection: Binding(get: { filter }, set: { storedFilter = $0.rawValue })) {
                ForEach(CueListFilter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(ControlSize.small.scaled(textScale))
            .labelsHidden()
            .accessibilityLabel(.ui("큐 목록 보기"))
            List(selection: $deck.selectedCueID) {
                ForEach(visibleCues) { cue in
                    CueRow(deck: deck, cue: cue)
                        .tag(cue.id)
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()
            .onChange(of: visibleCues.map(\.id), initial: true) { _, ids in
                // 탭이나 큐 종류를 바꿔 숨긴 행을 키보드로 잘못 편집하지 않게 한다.
                if let selected = deck.selectedCueID, !ids.contains(selected) { deck.selectedCueID = nil }
            }

            if let issues = deck.draft?.issues(duration: deck.duration), !issues.isEmpty {
                Label(issues.joined(separator: " · "), systemImage: "exclamationmark.triangle")
                    .font(.scaled(.caption, textScale)).foregroundStyle(UIColors.warning.color)
            }
            HStack {
                Button(.ui("큐 초안 버리기")) { deck.revertDraft() }
                    .disabled(deck.draft?.hasChanges != true)
                    .help(.ui("큐 초안을 버리고 rekordbox에서 불러온 큐로 돌아갑니다."))
                Spacer()
                Button(.ui("rekordbox에 쓰기…")) { if let row = deck.row { deck.onRequestReflection?(row) } }
                    .disabled(deck.isWriteLocked || deck.row?.isStaged != false || (deck.draft?.hasChanges != true && deck.gridDraft?.hasChanges != true))
                    .help(writeHelp)
            }
            .controlSize(ControlSize.small.scaled(textScale))
            if deck.isWriteLocked {
                Text(.ui("rekordbox에 쓰는 중이라 큐 편집을 잠시 막았습니다.")).font(.scaled(.caption2, textScale)).foregroundStyle(.secondary)
            }
        }
    }
}

struct CueRow: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel
    let cue: EditableCue
    @State private var showDetails = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(inlineDetails: true)
            row(inlineDetails: false)
        }
        .controlSize(ControlSize.small.scaled(textScale))
    }

    private func row(inlineDetails: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(UIColors.color(for: cue)).frame(width: 6, height: 6)
                .allowsHitTesting(false)
            Picker(.ui("종류"), selection: Binding(get: { cue.kind }, set: { deck.setKind(cue.id, $0) })) {
                Text(.ui("메모리")).tag(EditableCue.Kind.memory)
                ForEach(0..<8, id: \.self) { slot in
                    Text(.ui("핫큐 \(String(UnicodeScalar(UInt8(65 + slot))))")).tag(EditableCue.Kind.hot(slot))
                }
            }
            .labelsHidden()
            .fixedSize()
            .frame(minWidth: TextScale.length(76, scale: textScale))
            .foregroundStyle(.primary)

            // 자동 큐 표시는 시각 칸 옆에 둔다(좁은 배치에서도 이름을 가리지 않게, #145).
            HStack(spacing: 2) {
                Button { deck.selectCueFromList(cue.id) } label: {
                    Text(cue.time.clockText).font(.scaled(.caption, textScale).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 20, minHeight: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(.ui("이 위치로 이동"))
                autoBadge
            }
            .frame(minWidth: TextScale.length(56, scale: textScale), alignment: .leading)
            .layoutPriority(1)
            if inlineDetails {
                loopControls
                nameField.frame(minWidth: 40).layoutPriority(-1)
                deleteButton
            } else {
                Text(cue.name).font(.scaled(.caption, textScale)).lineLimit(1).layoutPriority(-1)
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
                Button { showDetails.toggle() } label: {
                    Image(systemName: cue.loop == nil ? "ellipsis.circle" : "repeat.circle")
                }
                .buttonStyle(.borderless)
                .help(.ui("큐 이름·루프 편집 및 삭제"))
                .accessibilityLabel(.ui("큐 세부 편집"))
                .popover(isPresented: $showDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(cue.time.clockText).font(.scaled(.caption, textScale).monospacedDigit().bold())
                                .lineLimit(1).fixedSize()
                            Spacer(minLength: 0)
                            loopControls
                            deleteButton
                        }
                        nameField.textFieldStyle(.roundedBorder)
                    }
                    .controlSize(ControlSize.small.scaled(textScale))
                    .padding(10)
                    .frame(width: TextScale.length(200, scale: textScale))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 빈 곳은 이동하되, 위에 놓인 종류·이름·삭제 컨트롤은 자기 동작만 받는다.
        .background {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { deck.selectCueFromList(cue.id) }
        }
    }

    @ViewBuilder private var loopControls: some View {
        let presets: [Double] = [1, 2, 4, 8, 16, 32]
        let current = cue.loop.map { loop in
            loop.beats ?? deck.loopBeats(cue).map(Double.init) ?? (loop.end - cue.time) * (deck.gridBPM ?? 120) / 60
        }
        Menu {
            Picker(.ui("루프 길이"), selection: Binding(get: { current }, set: { beats in
                // 프리셋 밖 현재 값을 다시 골라도 기존 루프 끝은 그대로 둔다.
                guard beats != current else { return }
                deck.setLoop(cue.id, beats: beats.map(Int.init))
            })) {
                Text(.ui("루프 없음")).tag(nil as Double?)
                if let current, !presets.contains(current) {
                    Text(.ui("\(LoopRules.text(current))박 루프")).tag(Optional(current))
                }
                ForEach(presets, id: \.self) { beats in
                    Text(.ui("\(LoopRules.text(beats))박 루프")).tag(Optional(beats))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(cue.loop == nil ? .ui("루프") : .ui("\(cue.loop?.beats.map(LoopRules.text) ?? deck.loopBeats(cue).map(String.init) ?? "?")박"))
                .font(.scaled(.caption, textScale).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(cue.loop == nil ? Color.secondary : UIColors.loop.color)
        .help(.ui("이 큐를 루프로 만들거나 길이를 바꿉니다"))
        if cue.loop != nil {
            Button { deck.toggleActiveLoop(cue.id) } label: {
                Image(systemName: "repeat.circle")
                    .symbolVariant(cue.loop?.active == true ? .fill : .none)
                    .foregroundStyle(cue.loop?.active == true ? UIColors.loop.color : .secondary)
            }
            .buttonStyle(.borderless)
            .help(cue.loop?.active == true ? .ui("활성 루프(곡을 불러오면 자동 반복) — 눌러서 끄기") : .ui("활성 루프로 만들기(곡을 불러오면 이 루프를 자동 반복)"))
            .accessibilityLabel(.ui("활성 루프"))
            .accessibilityValue(cue.loop?.active == true ? .ui("켜짐") : .ui("꺼짐"))
            .accessibilityAddTraits(.isToggle)
        }

    }

    /// rekordbox가 분석 때 넣은 자동 큐(#145). 일반 메모리 큐와 똑같이 고치며, 고치면 이름이 비어 표시가 빠진다.
    @ViewBuilder private var autoBadge: some View {
        if cue.isAutoGenerated {
            Text(.ui("자동"))
                .font(.scaled(.caption2, textScale).bold())
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 3).padding(.vertical, 1)
                .foregroundStyle(.secondary)
                .background(.quaternary, in: Capsule())
                .help(.ui("rekordbox가 분석 때 넣은 메모리 큐입니다. 고치면 일반 큐가 됩니다"))
                .accessibilityLabel(.ui("rekordbox 자동 큐"))
        }
    }

    private var nameField: some View {
        TextField(.ui("이름"), text: Binding(get: { cue.name }, set: { deck.rename(cue.id, $0) }))
            .textFieldStyle(.plain)
            .font(.scaled(.caption, textScale))
    }

    private var deleteButton: some View {
        Button(role: .destructive) { deck.delete(cue.id) } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless).help(.ui("삭제")).accessibilityLabel(.ui("큐 삭제"))
    }
}
