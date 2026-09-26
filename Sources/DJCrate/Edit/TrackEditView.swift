import DJCDomain
import SwiftUI

/// 곡 편집 창: 원곡 줄에서 위치 고르기 → "여기서 N마디" → 구간 목록(순서·마디 고치기) → 결과 줄·미리 듣기 → 렌더.
struct TrackEditView: View {
    @Bindable var model: TrackEditModel
    let deck: DeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditHeader(model: model)
            if let reason = model.blockedReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(UIColors.warning.color)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(UIColors.subtleFill, in: RoundedRectangle(cornerRadius: 8))
                Spacer(minLength: 0)
            } else {
                EditSourceStrip(model: model, deck: deck)
                    .frame(height: 96)
                EditAddBar(model: model, deck: deck)
                Divider()
                EditEntryList(model: model)
                    .frame(minHeight: 150, maxHeight: .infinity)
                Divider()
                EditOutputStrip(model: model)
                    .frame(height: 78)
                EditFooter(model: model)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        // 덱을 다시 재생하면 미리 듣기는 멈춘다(두 소리가 겹치지 않게).
        .onChange(of: deck.isPlaying) { _, playing in if playing { model.stopPreview() } }
    }
}

// MARK: - 머리

private struct EditHeader: View {
    let model: TrackEditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.row.title).font(.title3.bold()).lineLimit(1)
                Text(model.row.artist).foregroundStyle(.secondary).lineLimit(1)
            }
            if let layout = model.layout {
                let notes = [
                    String(format: "%.2f BPM", layout.segment.bpm),
                    "마디 \(layout.count)개",
                    String(format: "1마디 %.3f초", layout.barLength),
                    layout.hasLeadIn ? "첫 다운비트 앞 곡 머리(0마디) \(layout.firstDownbeat.clockText)" : nil,
                    layout.lastBarIsPartial ? "마지막 마디는 곡 끝에서 잘림" : nil,
                ].compactMap { $0 }
                Text(notes.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.blockedReason == nil, !model.isDeckOnTrack {
                Label("덱에 다른 곡이 올라가 있습니다. 원곡 줄을 눌러 더할 위치를 고르세요", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(UIColors.info.color)
            }
        }
    }
}

// MARK: - 더하기

private struct EditAddBar: View {
    @Bindable var model: TrackEditModel
    let deck: DeckModel

    var body: some View {
        HStack(spacing: 10) {
            HerePosition(model: model, deck: deck)
                .frame(minWidth: 170, alignment: .leading)
            Stepper(value: $model.barsToAdd, in: 1...256) {
                HStack(spacing: 4) {
                    TextField("마디 수", value: $model.barsToAdd, format: .number)
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("더할 마디 수")
                    Text("마디")
                }
            }
            .fixedSize()
            Menu {
                ForEach([4, 8, 16, 32, 64], id: \.self) { bars in
                    Button("\(bars)마디") { model.barsToAdd = bars }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("자주 쓰는 마디 수")
            Button {
                model.addHere()
            } label: {
                Label("여기서 \(model.barsToAdd)마디 더하기", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .help("재생 위치가 든 마디 처음부터 \(model.barsToAdd)마디를 목록 끝에 더합니다. 목록이 비었고 첫 다운비트 앞이면 곡 머리까지 넣습니다")
            Spacer(minLength: 0)
            if let message = model.message {
                Label(message.text, systemImage: message.kind.icon)
                    .font(.caption)
                    .foregroundStyle(message.kind.tint)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .controlSize(.small)
    }
}

/// 초당 15번 바뀌는 위치 글자만 따로 둔다(창 전체가 다시 그려지지 않게).
private struct HerePosition: View {
    let model: TrackEditModel
    let deck: DeckModel

    var body: some View {
        let time = model.isDeckOnTrack ? deck.displayTime : model.cursor
        let bar = model.layout?.bar(at: time) ?? 0
        HStack(spacing: 6) {
            Text(model.isDeckOnTrack ? "덱 위치" : "고른 위치").foregroundStyle(.secondary)
            Text(time.clockText).monospacedDigit()
            Text(bar == 0 ? "곡 머리(0마디)" : "\(bar)마디").monospacedDigit().bold()
        }
        .font(.callout)
    }
}

// MARK: - 구간 목록

private struct EditEntryList: View {
    let model: TrackEditModel

    var body: some View {
        if model.entries.isEmpty {
            ContentUnavailableView {
                Label("고른 구간이 없습니다", systemImage: "scissors")
            } description: {
                Text("덱에서 곡을 들으며(또는 위 원곡 줄을 눌러) 위치를 고른 뒤 ‘여기서 N마디 더하기’를 누르세요. 같은 구간을 두 번 넣으면 늘어나고, 빼면 줄어듭니다.")
            }
        } else {
            List {
                ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                    VStack(alignment: .leading, spacing: 4) {
                        if let seam = model.seams.first(where: { $0.index == index }) {
                            SeamRow(model: model, seam: seam)
                        }
                        EntryRow(model: model, index: index, entry: entry)
                    }
                }
                .onMove { model.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
        }
    }
}

private struct SeamRow: View {
    let model: TrackEditModel
    let seam: EditSeam

    var body: some View {
        let playing = model.preview == .seam(seam.index)
        HStack(spacing: 8) {
            Image(systemName: "scissors").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("이음새 · 마디 \(seam.preview.map(\.description).joined(separator: " → "))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                model.togglePreview(.seam(seam.index))
            } label: {
                if playing && model.isPreparingPreview {
                    ProgressView().controlSize(.mini)
                } else {
                    Label(playing ? "멈추기" : "이음새 듣기", systemImage: playing ? "stop.fill" : "play.fill")
                }
            }
            .controlSize(.mini)
            .help("이음새 앞 2마디부터 뒤 2마디까지 렌더해 들어 봅니다(섞는 소리까지 결과와 같습니다)")
        }
        .padding(.leading, 30)
    }
}

private struct EntryRow: View {
    let model: TrackEditModel
    let index: Int
    let entry: TrackEditModel.Entry

    var body: some View {
        let layout = model.layout
        let minFirst = layout?.hasLeadIn == true ? 0 : 1
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.black)
                .frame(width: 22, height: 18)
                .background(EditColors.entry(index), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("구간 \(index + 1)")
            Text("마디").foregroundStyle(.secondary)
            BarField(label: "시작 마디", value: entry.range.first, range: minFirst...max(minFirst, entry.range.last)) {
                model.setFirst(entry.id, $0)
            }
            Text("–")
            BarField(label: "끝 마디", value: entry.range.last, range: max(1, entry.range.first)...max(1, layout?.count ?? 1)) {
                model.setLast(entry.id, $0)
            }
            if let layout {
                let bars = entry.range.last - max(entry.range.first, 1) + 1
                Text("\(bars)마디\(entry.range.first == 0 ? " + 곡 머리" : "") · 원곡 \(layout.start(ofBar: entry.range.first).clockText)–\(layout.end(ofBar: entry.range.last).clockText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                Button { model.move(entry.id, by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0)
                    .help("앞으로")
                    .accessibilityLabel("구간 \(index + 1) 앞으로")
                Button { model.move(entry.id, by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == model.entries.count - 1)
                    .help("뒤로")
                    .accessibilityLabel("구간 \(index + 1) 뒤로")
                Button { model.duplicate(entry.id) } label: { Image(systemName: "plus.square.on.square") }
                    .help("바로 뒤에 같은 구간을 하나 더(늘이기)")
                    .accessibilityLabel("구간 \(index + 1) 복제")
                Button { model.remove(entry.id) } label: { Image(systemName: "trash") }
                    .help("목록에서 빼기")
                    .accessibilityLabel("구간 \(index + 1) 빼기")
            }
            .buttonStyle(.borderless)
        }
        .controlSize(.small)
    }
}

/// 마디 번호 칸(숫자 입력 + 위아래)
private struct BarField: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    let set: (Int) -> Void

    var body: some View {
        let binding = Binding(get: { value }, set: { set($0) })
        HStack(spacing: 2) {
            TextField(label, value: binding, format: .number)
                .frame(width: 40)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
            Stepper(label, value: binding, in: range).labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

// MARK: - 결과·렌더

private struct EditFooter: View {
    @Bindable var model: TrackEditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.planError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(UIColors.warning.color)
                    .textSelection(.enabled)
            } else if let edit = model.edit {
                Text(summary(edit))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                let playing = model.preview == .all
                Button {
                    model.togglePreview(.all)
                } label: {
                    if playing && model.isPreparingPreview {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("준비 중…") }
                    } else {
                        Label(playing ? "멈추기" : "전체 듣기", systemImage: playing ? "stop.fill" : "play.fill")
                    }
                }
                .disabled(model.edit == nil || model.renderProgress != nil)
                .help("편집 결과 전체를 렌더해 처음부터 들어 봅니다")
                Spacer(minLength: 8)
                Text("제목").foregroundStyle(.secondary)
                TextField("새 곡 제목", text: $model.title)
                    .frame(minWidth: 180, maxWidth: 280)
                    .disabled(model.renderProgress != nil)
                if let progress = model.renderProgress {
                    ProgressView(value: progress)
                        .frame(width: 120)
                        .accessibilityLabel("렌더 진행")
                    Button("취소") { model.cancelRender() }
                } else {
                    Button {
                        model.render()
                    } label: {
                        Label("렌더해서 추가한 곡에 넣기", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRender)
                    .help("WAV로 렌더해 ‘추가한 곡’에 넣습니다(그리드는 편집으로 옮긴 값, 큐는 옮긴 위치, 곡 정보는 원곡). 원곡과 rekordbox는 그대로이고, rekordbox로는 추가한 곡에서 넘깁니다")
                }
            }
            .controlSize(.regular)
        }
    }

    private func summary(_ edit: TrackEdit) -> String {
        var parts = ["결과 \(edit.barCount)마디", edit.duration.clockText, "이음새 \(max(0, edit.pieces.count - 1))곳"]
        if let carry = model.carry {
            parts.append("큐 \(carry.placed.count)개 옮김")
            if !carry.dropped.isEmpty {
                let reasons = Dictionary(grouping: carry.dropped, by: \.reason.label).map { "\($0.key) \($0.value.count)" }.sorted()
                parts.append("\(carry.dropped.count)개 빠짐(\(reasons.joined(separator: ", ")))")
            }
        }
        return parts.joined(separator: " · ")
    }
}
