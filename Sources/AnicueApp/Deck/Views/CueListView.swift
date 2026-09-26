import RekordboxKit
import AnicueAnalysis
import AnicueDomain
import AnicueStorage
import SwiftUI

struct CueListView: View {
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

struct CueRow: View {
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
                Text(cue.loop == nil ? "루프" : "\(cue.loop?.beats.map(LoopRules.text) ?? deck.loopBeats(cue).map(String.init) ?? "?")박")
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
