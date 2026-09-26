import DJCDomain
import SwiftUI

struct RelatedTracksButton: View {
    let store: LibraryStore
    let deck: DeckModel
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label("관련 곡", systemImage: "music.note.list")
        }
        .disabled(deck.row == nil || store.isWritingRekordbox)
        .help("덱에 올린 곡과 BPM·키·장르·코멘트의 #태그가 어울리는 곡을 찾습니다")
        .popover(isPresented: $isPresented) {
            RelatedTracksView(source: deck.row, rows: store.rows) { id in
                // 기존 목록 선택 경로로 덱을 올려 로드·단축키 동작을 유지한다.
                store.selection = [id]
                isPresented = false
            }
            .disabled(store.isWritingRekordbox)
        }
    }
}

private struct RelatedTracksView: View {
    let source: TrackRow?
    let rows: [TrackRow]
    let onSelect: (String) -> Void
    @State private var model = RelatedTracksModel()
    @State private var libraryRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("관련 곡").font(.headline)
            if let source {
                Text("기준: \(source.title)").font(.callout).lineLimit(1)
            }
            Text("BPM ±6% · 반·두 배 포함 · 키 이웃 · 장르 · #태그\n점수순 상위 100곡 · 곡을 누르면 덱에 올립니다")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if model.isLoading {
                ProgressView("관련 곡을 찾는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if source == nil {
                ContentUnavailableView("기준곡이 없습니다", systemImage: "music.note",
                                       description: Text("목록에서 곡을 골라 덱에 올리세요"))
            } else if model.matches.isEmpty {
                ContentUnavailableView("관련 곡이 없습니다", systemImage: "music.note.list",
                                       description: Text("다른 기준곡을 고르거나 BPM·키·장르·#태그를 확인하세요"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.matches) { match in
                            Button { onSelect(match.id) } label: {
                                candidate(match)
                                    .padding(.vertical, 9)
                                    .padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("\(match.row.title)을 덱에 올리기")
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 440, height: 460)
        .task(id: Request(source: source?.track, libraryRevision: libraryRevision)) {
            await model.load(source: source?.track, rows: rows)
        }
        .onChange(of: rows) { libraryRevision += 1 }
    }

    private struct Request: Equatable {
        let source: Track?
        let libraryRevision: Int
    }

    private func candidate(_ match: RelatedTrackRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(match.row.title).font(.body).lineLimit(1)
                HStack(spacing: 8) {
                    if !match.row.artist.isEmpty { Text(match.row.artist).lineLimit(1) }
                    if let bpm = match.row.track.bpm, bpm.isFinite, bpm > 0 {
                        Text("\(bpm, specifier: "%.1f") BPM").fixedSize()
                    }
                    if let key = match.row.track.key { Text(key).fixedSize() }
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(reasons(match.score)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(match.score.total, specifier: "%.0f")점")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func reasons(_ score: RelatedTracks.Score) -> String {
        var reasons: [String] = []
        if score.bpm > 0 {
            reasons.append(score.tempoMultiplier == 2 ? "BPM 두 배로 비교" : score.tempoMultiplier == 0.5 ? "BPM 절반으로 비교" : "가까운 BPM")
        }
        if score.key > 0 { reasons.append(score.key == 30 ? "같은 키" : "호환 키") }
        if score.genre > 0 { reasons.append("같은 장르") }
        if score.tags > 0 { reasons.append("#태그 겹침") }
        return reasons.joined(separator: " · ")
    }
}
