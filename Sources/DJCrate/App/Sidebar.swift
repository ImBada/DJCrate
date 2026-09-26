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
    @State private var historiesExpanded = true

    var body: some View {
        List(selection: $store.sidebar) {
            Section("라이브러리") {
                ForEach(LibraryFilter.allCases) { filter in
                    Label(filter.rawValue, systemImage: filter.systemImage)
                        .badge(store.count(filter))
                        .tag(SidebarItem.filter(filter))
                }
            }
            Section("DJCrate") {
                Label("추가한 곡", systemImage: "tray.and.arrow.down")
                    .badge(store.staged.count)
                    .tag(SidebarItem.staged)
                Label("rekordbox 반영 대기", systemImage: "square.and.arrow.up.on.square")
                    .badge(store.pendingLibraryCount)
                    .tag(SidebarItem.pending)
                    .help("큐·그리드 초안이 있어 rekordbox에 반영할 곡")
                Button { store.showingWriteResult = true } label: {
                    Label("마지막 쓰기 결과…", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.plain)
                .disabled(store.isWritingRekordbox)
                if let job = store.gridJob {
                    HStack(spacing: 6) {
                        ProgressView(value: Double(job.done), total: Double(max(job.total, 1))).controlSize(.small)
                        Text("그리드 추정 \(job.done)/\(job.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if !store.playlistTree.isEmpty {
                Section("rekordbox 플레이리스트 (\(store.playlistCount))", isExpanded: $playlistsExpanded) {
                    OutlineGroup(store.playlistTree, children: \.children) { node in
                        Label(node.name.isEmpty ? "(이름 없음)" : node.name,
                              systemImage: node.isFolder ? "folder" : "music.note.list")
                            .badge(store.count(playlist: node))
                            .lineLimit(1)
                            .tag(SidebarItem.playlist(node.id))
                    }
                }
            }
            Section("재생 기록", isExpanded: $historiesExpanded) {
                if store.histories.isEmpty {
                    Text("재생 기록이 없습니다").foregroundStyle(.secondary)
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
                Section("현황", isExpanded: $summaryExpanded) {
                    LabeledContent("실제 컬렉션", value: report.liveTracks.formatted())
                    LabeledContent("삭제 행(제외)", value: report.deletedRows.formatted())
                    LabeledContent("규칙 코멘트", value: report.commentClasses[.convention, default: 0].formatted())
                    LabeledContent("수동 큐 곡", value: report.tracksWithManualCues.formatted())
                }
                .font(.callout)
            }
            if let url = store.snapshotURL {
                Section("스냅샷") {
                    Text(url.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
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
                    Label(store.isWritingRekordbox ? "rekordbox에 쓰는 중…" : "rekordbox에 바로 넣기 (\(addTargets.count)곡)…",
                          systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(addTargets.isEmpty || store.isWritingRekordbox)
                .help("선택한 곡(없으면 추가 목록 전체)을 rekordbox 컬렉션에 바로 넣습니다. 추정 그리드·파형·오토게인까지 만들어 넣고, 미리 보기로 확인한 뒤 rekordbox가 꺼져 있을 때만 씁니다. 되돌리기로 무를 수 있습니다.")
                Button { StagingPanels.chooseFiles(store: store) } label: { Label("곡 추가…", systemImage: "plus") }
                Button { store.removeStaged(store.selection) } label: { Label("선택 빼기", systemImage: "minus") }
                    .disabled(!store.selection.contains { $0.hasPrefix("djc-") })
                    .help("추가 목록에서만 뺍니다. 파일은 지우지 않습니다.")
                Button { StagingPanels.exportXML(store: store) } label: { Label("XML로…", systemImage: "doc.text") }
                    .disabled(store.staged.isEmpty)
                    .help("rekordbox › 환경설정 › 고급 › rekordbox xml에서 이 파일을 지정한 뒤, 트리의 rekordbox xml에서 곡을 선택하고 Import To Collection 하세요. 가져온 뒤 새 스냅샷을 뜨면 DJCrate가 그리드가 그대로 들어갔는지 확인합니다.")
                if store.staged.contains(where: { $0.importCheck != nil && $0.importCheck?.result != .pending }) {
                    Button { store.removeImportedStaged() } label: { Label("가져온 곡 정리", systemImage: "checkmark.circle") }
                        .help("rekordbox에 들어간 것이 확인된 곡을 추가 목록에서 뺍니다(파일·초안은 그대로).")
                }
            }
        case .pending:
            bar {
                let targets = store.selection.isEmpty ? store.displayRows : store.selectedRows
                Button { DirectWritePanels.write(store: store, rows: targets) } label: {
                    Label("rekordbox에 쓰기 (\(targets.count)곡)…", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(targets.isEmpty || store.isWritingRekordbox)
                .help("선택한 곡(없으면 목록 전체)의 큐 초안을 rekordbox 라이브러리에 바로 씁니다. 미리 보기로 확인한 뒤 씁니다. rekordbox가 꺼져 있어야 합니다.")
                Button { ReflectionPanels.export(store: store, rows: targets) } label: {
                    Label("XML로…", systemImage: "doc.text")
                }
                .disabled(targets.isEmpty)
                .help("직접 쓰지 않고 rekordbox XML로 만듭니다(그리드 초안은 아직 이 경로로만 반영됩니다).")
                Button { DirectWritePanels.restoreLatest(store: store) } label: {
                    Label("되돌리기…", systemImage: "arrow.uturn.backward")
                }
                .disabled(store.isWritingRekordbox)
                .help("DJCrate가 마지막으로 rekordbox에 쓰기 직전 백업으로 되돌립니다.")
                if store.isWritingRekordbox {
                    ProgressView().controlSize(.small)
                    Text("rekordbox 라이브러리 확인·쓰는 중…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("rekordbox가 꺼져 있을 때만 씁니다 · 쓰기 전에 전체 백업").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .filter(.noBPM):
            bar {
                Button { store.estimateGridsForDisplayedRows() } label: {
                    Label("이 목록 그리드 추정 (\(store.displayRows.count)곡)", systemImage: "metronome")
                }
                .disabled(store.displayRows.isEmpty || store.gridJob != nil)
                .help("rekordbox가 분석하지 않은 곡의 BPM·박 위치를 추정해 그리드 초안으로 저장합니다(rekordbox는 바뀌지 않습니다).")
                Text("초안만 만듭니다 · 덱에서 확인·수정").font(.caption).foregroundStyle(.secondary)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
