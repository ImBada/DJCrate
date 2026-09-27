import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import SwiftUI

struct Sidebar: View {
    @Bindable var store: LibraryStore
    @AppStorage(SettingKeys.sidebarPlaylistsExpanded.name) private var playlistsExpanded = SettingKeys.sidebarPlaylistsExpanded.defaultValue
    @AppStorage(SettingKeys.sidebarSummaryExpanded.name) private var summaryExpanded = SettingKeys.sidebarSummaryExpanded.defaultValue
    @AppStorage(SettingKeys.sidebarHistoriesExpanded.name) private var historiesExpanded = SettingKeys.sidebarHistoriesExpanded.defaultValue

    var body: some View {
        List(selection: $store.sidebar) {
            Section(.ui("라이브러리")) {
                ForEach(LibraryFilter.visible(commentPreset: store.commentPreset)) { filter in
                    Label(filter.title, systemImage: filter.systemImage)
                        .badge(store.count(filter))
                        .tag(SidebarItem.filter(filter))
                }
                Label(.ui("중복 후보"), systemImage: "square.on.square")
                    .badge(store.duplicateGroups.count)
                    .tag(SidebarItem.duplicates)
                    .help(.ui("제목·아티스트가 같고 길이 차이가 2초 이내인 후보 묶음"))
            }
            Section("DJCrate" as String) {
                Label(.ui("추가한 곡"), systemImage: "tray.and.arrow.down")
                    .badge(store.staged.count)
                    .tag(SidebarItem.staged)
                Label(.ui("rekordbox 쓰기 대기"), systemImage: "square.and.arrow.up.on.square")
                    .badge(store.pendingLibraryCount)
                    .tag(SidebarItem.pending)
                    .help(.ui("rekordbox에 쓸 곡 초안을 모아 봅니다. 재생 목록 초안도 함께 쓸 수 있습니다."))
                Button { store.showingWriteResult = true } label: {
                    Label(.ui("마지막 쓰기 결과…"), systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.plain)
                .disabled(store.isWritingRekordbox)
                if let job = store.gridJob {
                    HStack(spacing: 6) {
                        ProgressView(value: Double(job.done), total: Double(max(job.total, 1))).controlSize(.small)
                        Text(.ui("그리드 추정 \(job.done)/\(job.total)")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if case .loaded = store.phase {
                PlaylistSection(store: store, isExpanded: $playlistsExpanded)
                ITunesPlaylistSection(store: store)
            }
            Section(.ui("재생 기록"), isExpanded: $historiesExpanded) {
                if store.histories.isEmpty {
                    Text(.ui("재생 기록이 없습니다")).foregroundStyle(.secondary)
                }
                ForEach(store.histories) { history in
                    Label(store.historyTitle(history), systemImage: "clock")
                        .badge(store.count(history: history))
                        .lineLimit(1)
                        .help(store.historyTitle(history))
                        .tag(SidebarItem.history(history.id))
                }
            }
            if let report = store.report {
                Section(.ui("현황"), isExpanded: $summaryExpanded) {
                    LabeledContent(.ui("실제 컬렉션"), value: report.liveTracks.formatted())
                    LabeledContent(.ui("삭제 행(제외)"), value: report.deletedRows.formatted())
                    if store.commentRuleEnabled {
                        LabeledContent(.ui("규칙 코멘트"), value: report.matchingComments.formatted())
                    }
                    LabeledContent(.ui("수동 큐 곡"), value: report.tracksWithManualCues.formatted())
                }
                .font(.callout)
            }
            if let url = store.snapshotURL {
                Section(.ui("스냅샷")) {
                    Text(url.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .modifier(PlaylistSidebarMenu(store: store))
    }
}

/// 목록 위 작업 줄: 추가한 곡(추가·빼기·XML 내보내기), BPM 없는 곡(일괄 추정).
struct ListActionBar: View {
    let store: LibraryStore

    var body: some View {
        switch store.sidebar {
        case .staged:
            bar {
                let selectedStaged = store.selectedRows.filter(\.isStaged)
                let addTargets = selectedStaged.isEmpty ? store.stagedRows : selectedStaged
                Button { DirectWritePanels.addTracks(store: store, rows: addTargets) } label: {
                    Label(store.isWritingRekordbox ? LocalizedStringResource.ui("rekordbox에 쓰는 중…") : .ui("rekordbox에 바로 넣기 (\(addTargets.count)곡)…"),
                          systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(addTargets.isEmpty || store.isWritingRekordbox)
                .help(.ui("고른 곡(없으면 추가 목록 전체)을 확인한 뒤 rekordbox 컬렉션에 넣습니다."))
                Button { StagingPanels.chooseFiles(store: store) } label: { Label(.ui("곡 추가…"), systemImage: "plus") }
                Button { store.removeStaged(store.selection) } label: { Label(.ui("추가 목록에서 제거"), systemImage: "minus") }
                    .disabled(!store.selection.contains { $0.hasPrefix("djc-") })
                    .help(.ui("추가 목록에서만 뺍니다. 파일은 지우지 않습니다."))
                Button { StagingPanels.exportXML(store: store) } label: { Label(.ui("XML 만들기"), systemImage: "doc.text") }
                    .disabled(store.staged.isEmpty)
                    .help(.ui("추가한 곡을 rekordbox에서 가져올 XML로 만듭니다."))
                if store.staged.contains(where: { $0.importCheck != nil && $0.importCheck?.result != .pending }) {
                    Button { store.removeImportedStaged() } label: { Label(.ui("가져온 곡 정리"), systemImage: "checkmark.circle") }
                        .help(.ui("rekordbox에 들어간 것이 확인된 곡을 추가 목록에서 뺍니다(파일·초안은 그대로)."))
                }
            }
        case .pending:
            bar {
                let targets = store.selection.isEmpty ? store.displayRows : store.selectedRows
                let playlistEdits = store.playlistDraft.steps.count
                Button { DirectWritePanels.write(store: store, rows: targets) } label: {
                    Label(playlistEdits > 0 ? LocalizedStringResource.ui("rekordbox에 쓰기 (\(targets.count)곡 · 재생 목록 \(playlistEdits)건)…")
                            : .ui("rekordbox에 쓰기 (\(targets.count)곡)…"),
                          systemImage: "square.and.arrow.up.on.square")
                }
                .disabled((targets.isEmpty && playlistEdits == 0) || store.isWritingRekordbox)
                .help(.ui("고른 곡(없으면 목록 전체)과 재생 목록 초안을 확인한 뒤 rekordbox에 씁니다."))
                if playlistEdits > 0 {
                    Button { PlaylistPanels.discardAll(store: store) } label: {
                        Label(.ui("재생 목록 초안 버리기…"), systemImage: "trash")
                    }
                    .disabled(store.isWritingRekordbox)
                    .help(.ui("rekordbox에 아직 쓰지 않은 재생 목록 편집을 모두 버립니다."))
                }
                Button { ReflectionPanels.export(store: store, rows: targets) } label: {
                    Label(.ui("XML 만들기"), systemImage: "doc.text")
                }
                .disabled(targets.isEmpty)
                .help(.ui("큐·그리드 초안을 rekordbox에서 가져올 XML로 만듭니다."))
                Button { DirectWritePanels.restoreLatest(store: store) } label: {
                    Label(.ui("쓰기 전으로 복원…"), systemImage: "arrow.uturn.backward")
                }
                .disabled(store.isWritingRekordbox || !store.hasWriteBackup)
                .help(store.hasWriteBackup
                      ? String(ui: "라이브러리 전체를 마지막 쓰기 전 백업으로 복원합니다.")
                      : String(ui: "복원할 백업이 없습니다. rekordbox에 쓰면 쓰기 전 백업이 생깁니다."))
                if store.isWritingRekordbox {
                    ProgressView().controlSize(.small)
                    Text(.ui("rekordbox 라이브러리 확인·쓰는 중…")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(.ui("rekordbox가 꺼져 있을 때만 씁니다 · 쓰기 전에 전체 백업")).font(.caption).foregroundStyle(.secondary)
                }
            }
        case let .itunesPlaylist(id):
            bar {
                Label(.ui("목록 구성과 순서는 Music에서 바꿉니다 · 큐·태그는 여기서 편집할 수 있습니다"), systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                if let node = store.iTunesLibrary.index[id], node.unavailableTrackCount > 0 {
                    Text(.ui("연결하지 못한 \(node.unavailableTrackCount)곡은 rekordbox 컬렉션 등록과 파일 위치를 확인하세요"))
                        .font(.caption).foregroundStyle(UIColors.warning.color)
                }
            }
        case let .playlist(id):
            if let node = store.playlistIndex[id], node.isDraft || node.blockedReason != nil {
                bar {
                    if let reason = node.blockedReason {
                        Label(.ui("이 목록의 초안 일부를 쓸 수 없습니다: \(reason)"), systemImage: WarningMark.symbol)
                            .foregroundStyle(UIColors.warning.color)
                            .lineLimit(2)
                    } else {
                        Label(.ui("아직 쓰지 않은 목록 초안입니다 · rekordbox에 쓰기(⇧⌘E)로 저장합니다"), systemImage: DraftMark.symbol)
                            .foregroundStyle(UIColors.draft.color)
                    }
                    Button(.ui("이 목록의 초안 버리기")) { store.discardPlaylistDraft(id) }
                        .disabled(store.isWritingRekordbox)
                }
            } else {
                EmptyView()
            }
        case .filter(.noBPM):
            bar {
                Button { store.estimateGridsForDisplayedRows() } label: {
                    Label(.ui("이 목록 그리드 추정 (\(store.displayRows.count)곡)"), systemImage: "metronome")
                }
                .disabled(store.displayRows.isEmpty || store.gridJob != nil)
                .help(.ui("rekordbox가 분석하지 않은 곡의 BPM·박 위치를 추정해 그리드 초안으로 저장합니다(rekordbox는 바뀌지 않습니다)."))
                Text(.ui("초안만 만듭니다 · 덱에서 확인·수정")).font(.caption).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.edge)
        .padding(.vertical, 6)
    }
}
