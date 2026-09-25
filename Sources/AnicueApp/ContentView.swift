import AnicueCore
import AppKit
import SwiftUI

/// A안: 사이드바 | (위) 덱 · (아래) 라이브러리 표
struct ContentView: View {
    @Bindable var store: LibraryStore
    @Bindable var deck: DeckModel
    @State private var showTagEditor = false
    @AppStorage("waveformHeight") private var waveformHeight: Double = 150
    @AppStorage("sheetMode") private var sheetMode = false
    @State private var keys = KeyRouter()

    var body: some View {
        NavigationSplitView {
            Sidebar(store: store)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detail
        }
        // rekordbox에 쓰는 동안은 창 전체를 덮어 다른 조작을 막는다.
        .overlay {
            if let stage = store.writeStage {
                WritingOverlay(text: stage).transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                AppToastView(toast: toast,
                             onUndo: toast.undoBackup.map { url in { store.toast = nil; DirectWritePanels.restore(store: store, backupURL: url) } },
                             onClose: { if store.toast?.id == toast.id { store.toast = nil } })
                    .padding(.bottom, 22)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.35), value: store.toast?.id)
        .animation(.easeInOut(duration: 0.15), value: store.writeStage)
        .searchable(text: $store.search, placement: .toolbar, prompt: "제목·아티스트·코멘트")
        .toolbar { toolbarContent }
        .onAppear { setUp() }
    }

    @ViewBuilder private var detail: some View {
            switch store.phase {
            case .loaded:
                // VSplitView(NSSplitView)는 자식 최소 크기가 내용에 따라 바뀌면 레이아웃을 끝없이
                // 다시 잡다가 예외로 죽는다. SwiftUI만으로 나누고, 덱 높이는 핸들로 조절한다.
                VStack(spacing: 0) {
                    if let error = store.lastError {
                        Label("스냅샷을 새로 뜨지 못했습니다: \(error)", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let message = store.reflectionMessage {
                        HStack {
                            Label(message, systemImage: message.contains("불일치") ? "exclamationmark.triangle" : "checkmark.seal")
                                .foregroundStyle(message.contains("불일치") ? .orange : .secondary)
                                .lineLimit(2)
                            Spacer()
                            Button("닫기") { store.reflectionMessage = nil }.controlSize(.small)
                        }
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                    }
                    // 덱 높이는 내용에 맞춘다(잘리지 않게). 핸들은 파형 높이를 조절한다.
                    DeckView(deck: deck, waveformHeight: waveformHeight)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .fixedSize(horizontal: false, vertical: true)
                    SplitHandle(height: $waveformHeight)
                    ListActionBar(store: store)
                    if sheetMode {
                        SheetHeader(store: store)
                        TagSheetView(store: store)
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    } else {
                        TrackTable(store: store)
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                // Finder에서 음원·폴더를 끌어다 놓으면 추가한다.
                .dropDestination(for: URL.self) { urls, _ in
                    Task { await store.addFiles(urls) }
                    return !urls.isEmpty
                }
                .inspector(isPresented: $showTagEditor) {
                    TagInspector(store: store)
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
                }
            case .idle:
                ContentUnavailableView {
                    Label("스냅샷이 없습니다", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("rekordbox를 종료한 뒤 master.db 사본을 떠 주세요. 원본은 읽기만 합니다.")
                } actions: {
                    Button("스냅샷 뜨기") { Task { await store.takeSnapshot() } }
                }
            case let .loading(message):
                ProgressView(message)
            case let .failed(message):
                ContentUnavailableView {
                    Label("불러오지 못했습니다", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("다시 시도") { Task { await store.loadInitial() } }
                    Button("실행 중이어도 읽기용 스냅샷 뜨기") { Task { await store.takeSnapshot(force: true) } }
                }
            }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
            ToolbarItem(placement: .principal) {
                Picker("보기", selection: $sheetMode) {
                    Label("목록", systemImage: "list.bullet").tag(false)
                    Label("태그 시트", systemImage: "tablecells").tag(true)
                }
                .pickerStyle(.segmented)
                .help("태그 시트: 엑셀처럼 셀을 선택·편집·붙여넣기 합니다")
            }
            ToolbarItem {
                Button {
                    StagingPanels.chooseFiles(store: store)
                } label: {
                    Label("곡 추가", systemImage: "plus")
                }
                .disabled(store.rows.isEmpty)
                .help("음원 파일·폴더를 anicue에 추가합니다. BPM·그리드를 추정한 뒤 rekordbox XML로 넘길 수 있습니다(창에 끌어다 놓아도 됩니다).")
            }
            ToolbarItem {
                Button {
                    showTagEditor.toggle()
                } label: {
                    Label("태그 편집", systemImage: "tag")
                }
                .keyboardShortcut("i", modifiers: .command)
                .help("선택한 곡의 태그를 편집합니다 (⌘I). 여러 곡을 한꺼번에 편집할 수 있습니다.")
            }
            ToolbarItem {
                Button {
                    // rekordbox가 켜져 있어도 읽기용 사본을 뜬다(최근 변경이 담긴 WAL까지 사본 안에서 합친다).
                    Task { await store.takeSnapshot(force: LibrarySnapshot.isRekordboxRunning()) }
                } label: {
                    Label("새 스냅샷", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)
                .help("rekordbox master.db 사본을 새로 떠서 다시 읽습니다(원본은 읽기만). rekordbox에서 반영 XML을 가져온 뒤 누르면 자동으로 검증합니다.")
            }
    }

    private func setUp() {
            // 선택 변경은 스토어가 150ms 뒤에 알려 준다(루트 뷰가 선택마다 다시 그려지지 않도록).
            store.onPrimaryRowChange = { [weak deck] row in deck?.load(row) }
            store.onGridDraftSaved = { [weak deck] uuid in deck?.gridDraftSavedExternally(uuid) }
            deck.onStagedGridChange = { [weak store] uuid, bpm in store?.stagedGridChanged(uuid: uuid, bpm: bpm) }
            deck.onCueDraftChange = { [weak store] draft in store?.cueDraftChanged(draft) }
            deck.onRequestReflection = { [weak store] row in
                guard let store else { return }
                DirectWritePanels.write(store: store, rows: [row])
            }
            store.onWriteLock = { [weak deck] locked in deck?.isWriteLocked = locked }
            store.onRekordboxWritten = { [weak deck, weak store] uuids in
                // 처음부터 다시 불러오지 않고 초안·그리드·게인만 새 rekordbox 값으로 맞춘다(소리·파형은 그대로).
                guard let deck, let uuid = deck.row?.track.uuid, uuids.contains(uuid) else { return }
                deck.refreshAfterWrite(store?.rowsByUUID[uuid])
            }
            keys.install(deck: deck)
            DevSelfTests.runIfRequested(store: store, deck: deck)
            deck.onDraftChange = { [weak store] uuid, kind, exists in
                store?.draftChanged(trackUUID: uuid, kind: kind, exists: exists)
            }
            if ProcessInfo.processInfo.arguments.contains("--inspector") { showTagEditor = true }
            if ProcessInfo.processInfo.arguments.contains("--sheet") { sheetMode = true }
    }
}

/// 태그 시트 위 안내 줄.
private struct SheetHeader: View {
    let store: LibraryStore

    var body: some View {
        HStack(spacing: 14) {
            Text("\(store.sidebarTitle) · \(store.displayRows.count)곡").font(.callout.bold())
            Text("더블클릭·Return·타이핑: 편집  ·  ⌘C/⌘V: 엑셀·시트와 복사·붙여넣기  ·  ⌘D: 아래로 채우기  ·  Delete: 지우기  ·  ⌘Z: 되돌리기")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button { store.undoTags() } label: { Label("되돌리기", systemImage: "arrow.uturn.backward") }
                .disabled(!store.canUndoTags)
            Button { store.redoTags() } label: { Label("다시 실행", systemImage: "arrow.uturn.forward") }
                .disabled(!store.canRedoTags)
            Text("주황 = 초안(파일·rekordbox 미반영)").font(.caption).foregroundStyle(.orange)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// 덱과 목록 사이 핸들: 끌어서 파형 높이를 조절한다.
private struct SplitHandle: View {
    @Binding var height: Double
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if start == nil { start = height }
                    height = min(max((start ?? height) + value.translation.height, 80), 480)
                }
                .onEnded { _ in start = nil })
            .accessibilityLabel("파형 높이 조절")
    }
}

struct Sidebar: View {
    @Bindable var store: LibraryStore
    @AppStorage("sidebar.playlistsExpanded") private var playlistsExpanded = true
    @AppStorage("sidebar.summaryExpanded") private var summaryExpanded = true

    var body: some View {
        List(selection: $store.sidebar) {
            Section("라이브러리") {
                ForEach(LibraryFilter.allCases) { filter in
                    Label(filter.rawValue, systemImage: filter.systemImage)
                        .badge(store.count(filter))
                        .tag(SidebarItem.filter(filter))
                }
            }
            Section("anicue") {
                Label("추가한 곡", systemImage: "tray.and.arrow.down")
                    .badge(store.staged.count)
                    .tag(SidebarItem.staged)
                Label("rekordbox 반영 대기", systemImage: "square.and.arrow.up.on.square")
                    .badge(store.pendingLibraryCount)
                    .tag(SidebarItem.pending)
                    .help("큐·그리드 초안이 있어 rekordbox에 반영할 곡")
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
            if let report = store.report {
                Section("현황", isExpanded: $summaryExpanded) {
                    LabeledContent("실제 컬렉션", value: "\(report.liveTracks)")
                    LabeledContent("삭제 행(제외)", value: "\(report.deletedRows)")
                    LabeledContent("규칙 코멘트", value: "\(report.commentClasses[.convention, default: 0])")
                    LabeledContent("수동 큐 곡", value: "\(report.tracksWithManualCues)")
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
        // 일괄 반영은 사이드바 맨 아래에 둔다(툴바의 공유 모양 아이콘과 헷갈리지 않게).
        .safeAreaInset(edge: .bottom, spacing: 0) { ReflectFooter(store: store) }
    }
}

/// 사이드바 아래 고정: 반영 대기 곡 수와 rekordbox 일괄 반영 버튼(⌘⇧E).
private struct ReflectFooter: View {
    let store: LibraryStore

    var body: some View {
        let targets = store.reflectionTargets
        let selectedOnly = targets.contains { store.selection.contains($0.id) }
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Button {
                DirectWritePanels.write(store: store, rows: targets)
            } label: {
                Label(store.isWritingRekordbox ? "rekordbox에 쓰는 중…"
                      : selectedOnly ? "선택한 \(targets.count)곡 rekordbox에 반영" : "rekordbox에 반영 (\(store.pendingLibraryCount)곡)",
                      systemImage: "square.and.arrow.up.on.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(store.pendingLibraryCount == 0 || store.isWritingRekordbox)
            .help("선택한 곡에 초안이 있으면 그 곡들만, 없으면 반영 대기 곡 전체의 큐를 rekordbox 라이브러리에 바로 씁니다. 미리 보기로 확인한 뒤, rekordbox가 꺼져 있을 때만 씁니다 (⌘⇧E).")
            // 마지막 반영 되돌리기(토스트가 사라진 뒤에도)
            if store.lastWriteBackup != nil {
                Button { DirectWritePanels.restoreLatest(store: store) } label: {
                    Label("마지막 반영 되돌리기…", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(store.isWritingRekordbox)
                .help("anicue가 마지막으로 rekordbox에 쓰기 직전 백업으로 되돌립니다(rekordbox가 꺼져 있어야 합니다)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .background(.bar)
    }
}

/// 목록 위 작업 줄: 추가한 곡(추가·빼기·XML 내보내기), BPM 없는 곡(일괄 추정).
private struct ListActionBar: View {
    let store: LibraryStore

    var body: some View {
        switch store.sidebar {
        case .staged:
            bar {
                Button { StagingPanels.chooseFiles(store: store) } label: { Label("곡 추가…", systemImage: "plus") }
                Button { store.removeStaged(store.selection) } label: { Label("선택 빼기", systemImage: "minus") }
                    .disabled(!store.selection.contains { $0.hasPrefix("anicue-") })
                    .help("추가 목록에서만 뺍니다. 파일은 지우지 않습니다.")
                Button { StagingPanels.exportXML(store: store) } label: { Label("rekordbox XML로 내보내기…", systemImage: "square.and.arrow.up") }
                    .disabled(store.staged.isEmpty)
                    .help("rekordbox › 환경설정 › 고급 › rekordbox xml에서 이 파일을 지정한 뒤, 트리의 rekordbox xml에서 곡을 선택하고 Import To Collection 하세요. 가져온 뒤 새 스냅샷을 뜨면 anicue가 그리드가 그대로 들어갔는지 확인합니다.")
                if store.staged.contains(where: { $0.importCheck != nil && $0.importCheck?.result != .pending }) {
                    Button { store.removeImportedStaged() } label: { Label("가져온 곡 정리", systemImage: "checkmark.circle") }
                        .help("rekordbox에 들어간 것이 확인된 곡을 추가 목록에서 뺍니다(파일·초안은 그대로).")
                }
                message
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
                .help("anicue가 마지막으로 rekordbox에 쓰기 직전 백업으로 되돌립니다.")
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
                message
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var message: some View {
        if let text = store.stagingMessage {
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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

/// 파일 선택·저장 창.
@MainActor
enum StagingPanels {
    static func chooseFiles(store: LibraryStore) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.prompt = "추가"
        panel.message = "anicue에 추가할 음원 파일이나 폴더를 고르세요. 이미 rekordbox에 있는 파일은 건너뜁니다."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await store.addFiles(urls) }
    }

    static func exportXML(store: LibraryStore) {
        let selected = store.selection.filter { $0.hasPrefix("anicue-") }
        do {
            let url = try RekordboxLink.prepare()
            let result = try store.exportStaged(to: url, only: selected.isEmpty ? nil : selected)
            var text = "\(result.count)곡을 연동 XML에 썼습니다 · rekordbox: rekordbox xml 새로고침 › \"anicue 추가\" › Import To Collection"
            if result.withoutGrid > 0 { text += " · \(result.withoutGrid)곡은 그리드 없이(rekordbox가 분석)" }
            store.stagingMessage = text
            RekordboxLink.showSetupIfNeeded()
        } catch {
            store.stagingMessage = "내보내지 못했습니다: \(error.localizedDescription)"
        }
    }
}

/// anicue ↔ rekordbox 연동 XML. 저장 창 없이 늘 같은 파일에 쓴다.
/// rekordbox 환경설정 › 고급 › 데이터베이스 › rekordbox xml에 이 파일을 한 번만 지정하면,
/// 이후에는 rekordbox에서 트리 새로고침 → 재생 목록 → Import To Collection만 하면 된다.
@MainActor
enum RekordboxLink {
    static var url: URL {
        URL.documentsDirectory.appending(path: "anicue/anicue-rekordbox.xml")
    }

    static func prepare() throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    /// 처음 한 번만 rekordbox 설정 방법을 알려 주고 경로를 클립보드에 복사한다.
    static func showSetupIfNeeded() {
        let key = "rekordboxLinkSetupShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        let alert = NSAlert()
        alert.messageText = "rekordbox에 연동 파일을 한 번만 지정해 주세요"
        alert.informativeText = """
        anicue는 반영할 내용을 늘 이 파일에 씁니다(경로를 클립보드에 복사했습니다):
        \(url.path)

        1. rekordbox › 환경설정 › 고급 › 데이터베이스 › rekordbox xml › "가져온 라이브러리"에 이 파일을 지정합니다(처음 한 번만).
        2. 트리에 "rekordbox xml"이 보이게 합니다(환경설정 › 보기 › 레이아웃에서 켤 수 있습니다).

        이후 반영할 때마다 rekordbox에서:
        • "rekordbox xml" 옆 새로고침 → 재생 목록 "anicue 반영"(새 곡은 "anicue 추가") → 곡 모두 선택 → 오른쪽 클릭 › Import To Collection
        • anicue에서 새 스냅샷(⟳)을 누르면 곡마다 제대로 들어갔는지 자동으로 확인합니다.

        처음 반영하기 전에 rekordbox › 파일 › 라이브러리 › 라이브러리 백업을 한 번 해 두세요.
        """
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "Finder에서 보기")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        UserDefaults.standard.set(true, forKey: key)
    }
}

/// rekordbox에 바로 쓰기(기본 경로). rekordbox가 켜져 있으면 절대 쓰지 않는다.
@MainActor
enum DirectWritePanels {
    static func write(store: LibraryStore, rows: [TrackRow]) {
        guard !store.isWritingRekordbox else { return }
        guard !LibrarySnapshot.isRekordboxRunning() else {
            alert("rekordbox가 켜져 있어 쓰지 않았습니다",
                  "rekordbox를 완전히 종료한 뒤 다시 누르세요. anicue는 rekordbox가 켜져 있는 동안에는 rekordbox 라이브러리에 절대 쓰지 않습니다.")
            return
        }
        let targets = store.writeTargets(rows)
        guard !targets.isEmpty else {
            alert("반영할 초안이 없습니다", "고른 곡에 rekordbox와 다른 큐·그리드 초안이 없습니다.")
            return
        }
        lock(store, true)
        Task {
            defer { lock(store, false) }
            do {
                store.writeStage = "바꿀 내용을 확인하는 중…"
                let preview = try await store.previewWrite(rows: targets)
                store.writeStage = nil
                let writable = preview.report.written, blocked = preview.report.blocked
                let gridWritable = preview.report.gridWritten, gridBlocked = preview.report.gridBlocked
                let gainWritable = preview.report.gainWritten, gainBlocked = preview.report.gainBlocked
                guard !writable.isEmpty || !gridWritable.isEmpty || !gainWritable.isEmpty else {
                    let reasons = (blocked + gridBlocked + gainBlocked).prefix(8).map { "• \($0.title): \($0.reason ?? "")" }
                    alert("rekordbox에 쓸 수 있는 초안이 없습니다", reasons.joined(separator: "\n"))
                    return
                }
                let alert = NSAlert()
                var title: [String] = []
                if !writable.isEmpty { title.append("큐 \(writable.count)곡") }
                if !gridWritable.isEmpty { title.append("그리드 \(gridWritable.count)곡") }
                if !gainWritable.isEmpty { title.append("게인 \(gainWritable.count)곡") }
                alert.messageText = "rekordbox에 " + title.joined(separator: " · ") + "을 씁니다"
                let gridBlockedByUUID = Dictionary(gridBlocked.map { ($0.trackUUID, $0) }, uniquingKeysWith: { a, _ in a })
                var body = writable.prefix(12).map { outcome -> String in
                    var line = "• \(outcome.title) — 큐 추가 \(outcome.added) · 삭제 \(outcome.removed)"
                    if gridWritable.contains(where: { $0.trackUUID == outcome.trackUUID }) { line += " · 그리드" }
                    if gridBlockedByUUID[outcome.trackUUID] != nil { line += " · ⚠︎ 그리드는 안 들어감" }
                    return line
                }
                for grid in gridWritable where !writable.contains(where: { $0.trackUUID == grid.trackUUID }) {
                    body.append("• \(grid.title) — 그리드(박 \(grid.added)개)")
                }
                for gain in gainWritable {
                    body.append(String(format: "• %@ — 오토게인 %+.1f dB", gain.title, Double(gain.added) / 100))
                }
                if writable.count > 12 { body.append("… 외 \(writable.count - 12)곡") }
                let notWritten = blocked + gridBlocked + gainBlocked
                if !notWritten.isEmpty {
                    body += ["", "쓰지 않는 것 \(notWritten.count):"] + notWritten.prefix(8).map { "• \($0.title): \($0.reason ?? "")" }
                }
                body += ["", "쓰기 전에 rekordbox 라이브러리(master.db)와 바꿀 분석 파일을 백업하고, 쓴 뒤 다시 읽어 확인합니다. 끝날 때까지 rekordbox를 켜지 마세요."]
                alert.informativeText = body.joined(separator: "\n")
                alert.addButton(withTitle: "rekordbox에 쓰기")
                alert.addButton(withTitle: "취소")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let uuids = Set(writable.map(\.trackUUID)), gridUUIDs = Set(gridWritable.map(\.trackUUID))
                let gainUUIDs = Set(gainWritable.map(\.trackUUID))
                _ = try await store.writeToRekordbox(preview.drafts.filter { uuids.contains($0.trackUUID) },
                                                     grids: preview.grids.filter { gridUUIDs.contains($0.trackUUID) },
                                                     gains: preview.gains.filter { gainUUIDs.contains($0.key) })
            } catch {
                store.writeStage = nil
                store.toast = AppToast(kind: .failure, title: "rekordbox에 쓰지 않았습니다", detail: String(describing: error))
            }
        }
    }

    static func restoreLatest(store: LibraryStore) {
        guard let backup = RekordboxWriter.backups().first(where: \.isWrite) else {
            alert("되돌릴 쓰기 기록이 없습니다", "anicue가 rekordbox에 쓴 적이 없거나 백업이 정리됐습니다.")
            return
        }
        restore(store: store, backup: backup)
    }

    static func restore(store: LibraryStore, backupURL: URL) {
        guard let backup = RekordboxWriter.backups().first(where: { $0.url.path == backupURL.path }) else {
            alert("백업을 찾지 못했습니다", backupURL.path)
            return
        }
        restore(store: store, backup: backup)
    }

    static func restore(store: LibraryStore, backup: RekordboxWriter.Backup) {
        guard !store.isWritingRekordbox else { return }
        guard !LibrarySnapshot.isRekordboxRunning() else {
            alert("rekordbox가 켜져 있어 되돌리지 않았습니다", "rekordbox를 완전히 종료한 뒤 다시 누르세요.")
            return
        }
        lock(store, true)
        Task {
            defer { lock(store, false) }
            store.writeStage = "백업 뒤 바뀐 것을 확인하는 중…"
            let changed = await store.libraryChangedSince(backup)
            store.writeStage = nil
            let alert = NSAlert()
            alert.messageText = "rekordbox를 \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)) 쓰기 전으로 되돌릴까요?"
            var lines: [String] = []
            if !backup.titles.isEmpty {
                lines.append("그때 쓴 곡: " + backup.titles.prefix(8).joined(separator: ", ") + (backup.titles.count > 8 ? " 외 \(backup.titles.count - 8)곡" : ""))
            }
            lines.append("rekordbox 라이브러리 파일 전체를 그때 백업으로 바꿉니다. 그때 쓴 큐 초안은 anicue에 다시 살아납니다. 지금 상태도 따로 백업해 둡니다.")
            switch changed {
            case true?:
                alert.alertStyle = .critical
                lines.append("⚠︎ 이 백업 뒤에 rekordbox에서도 라이브러리가 바뀌었습니다(큐·재생 목록·곡 추가 등). 되돌리면 그 변경도 함께 사라집니다.")
            case nil:
                lines.append("백업 뒤 rekordbox에서 바뀐 것이 있는지 확인하지 못했습니다. 그 뒤 rekordbox에서 한 변경은 함께 사라집니다.")
            case false?:
                break
            }
            alert.informativeText = lines.joined(separator: "\n\n")
            alert.addButton(withTitle: "되돌리기")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try await store.restoreRekordbox(backup)
            } catch {
                store.toast = AppToast(kind: .failure, title: "되돌리지 못했습니다", detail: String(describing: error))
            }
        }
    }

    private static func lock(_ store: LibraryStore, _ locked: Bool) {
        store.isWritingRekordbox = locked
        store.onWriteLock?(locked)
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

/// 반영 XML 만들기(연동 파일에 바로 쓴다).
@MainActor
enum ReflectionPanels {
    static func export(store: LibraryStore, rows: [TrackRow]) {
        let plans = store.reflectionPlans(for: rows)
        let eligible = plans.filter(\.isEligible), blocked = plans.filter { !$0.blockers.isEmpty }
        guard !eligible.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "반영할 수 있는 곡이 없습니다"
            alert.informativeText = blocked.isEmpty
                ? "고른 곡에 rekordbox와 다른 큐·그리드 초안이 없습니다."
                : blocked.prefix(5).map { "• \($0.title): \($0.blockers.joined(separator: " / "))" }.joined(separator: "\n")
            alert.runModal()
            return
        }
        do {
            let url = try RekordboxLink.prepare()
            _ = try store.exportReflection(rows: rows, to: url)
        } catch {
            store.reflectionMessage = "반영 XML을 쓰지 못했습니다: \(error.localizedDescription)"
            return
        }
        var text = "\(eligible.count)곡을 연동 XML에 썼습니다 · rekordbox: rekordbox xml 새로고침 › \"anicue 반영\" › 곡 모두 선택 › Import To Collection → anicue 새 스냅샷(⟳)"
        if !blocked.isEmpty {
            text += " · 막혀서 뺀 곡 \(blocked.count): " + blocked.prefix(2).map { "\($0.title)(\($0.blockers.first ?? ""))" }.joined(separator: ", ")
        }
        store.reflectionMessage = text
        RekordboxLink.showSetupIfNeeded()
    }
}
