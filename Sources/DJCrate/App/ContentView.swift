import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import SwiftUI

/// A안: 사이드바 | (위) 덱 · (아래) 라이브러리 표
struct ContentView: View {
    @Environment(\.undoManager) private var undoManager
    @Bindable var store: LibraryStore
    @Bindable var deck: DeckModel
    @State private var showTagEditor = false
    @AppStorage(SettingKeys.waveformHeight.name) private var waveformHeight = SettingKeys.waveformHeight.defaultValue
    @AppStorage(SettingKeys.sheetMode.name) private var sheetMode = SettingKeys.sheetMode.defaultValue
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
        .onChange(of: undoManager, initial: true) {
            deck.undoManager = undoManager
            store.undoManager = undoManager
        }
        .task {
            while !Task.isCancelled {
                // 끄는 중인 큐·그리드는 손을 놓아 저장한 뒤에 다시 읽는다.
                if !deck.hasUncommittedCueEdits, deck.cueDragBase == nil, deck.gridDragBase == nil { store.refreshExternalDrafts() }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        // rekordbox에서 곡을 지우거나 고치고 돌아오면 새로 읽는다(옛 목록에 지워진 곡이 남지 않게)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refreshIfRekordboxChanged() }
        }
    }

    @ViewBuilder private var detail: some View {
            switch store.phase {
            case .loaded:
                // VSplitView(NSSplitView)는 자식 최소 크기가 내용에 따라 바뀌면 레이아웃을 끝없이
                // 다시 잡다가 예외로 죽는다. SwiftUI만으로 나누고, 덱 높이는 핸들로 조절한다.
                VStack(spacing: 0) {
                    if let error = store.lastError {
                        Label("스냅샷을 새로 뜨지 못했습니다: \(error)", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(UIColors.warning.color)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let message = store.reflectionMessage {
                        HStack {
                            Label(message, systemImage: message.contains("불일치") ? "exclamationmark.triangle" : "checkmark.seal")
                                .foregroundStyle(message.contains("불일치") ? UIColors.warning.color : Color.secondary)
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
                            .onDisappear { store.canFillDownTags = false }
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
                .help("음원 파일·폴더를 DJCrate에 추가합니다. BPM·그리드를 추정한 뒤 rekordbox XML로 넘길 수 있습니다(창에 끌어다 놓아도 됩니다).")
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
            store.onCueDraftsReloaded = { [weak deck] drafts in
                guard let deck, let uuid = deck.row?.track.uuid else { return }
                deck.reloadExternalCueDraft(drafts[uuid])
            }
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
            #if DEBUG
            DevSelfTests.runIfRequested(store: store, deck: deck)
            #endif
            deck.onDraftChange = { [weak store] uuid, kind, exists in
                store?.draftChanged(trackUUID: uuid, kind: kind, exists: exists)
            }
            if ProcessInfo.processInfo.arguments.contains("--inspector") { showTagEditor = true }
            if ProcessInfo.processInfo.arguments.contains("--sheet") { sheetMode = true }
    }
}

/// 태그 시트 위 안내 줄.
struct SheetHeader: View {
    let store: LibraryStore

    var body: some View {
        HStack(spacing: 14) {
            Text("\(store.sidebarTitle) · \(store.displayRows.count)곡").font(.callout.bold())
            Text("더블클릭·Return·타이핑: 편집  ·  ⌘C/⌘V: 엑셀·시트와 복사·붙여넣기  ·  ⌘D: 아래로 채우기  ·  Delete: 지우기  ·  ⌘Z/⇧⌘Z: 실행 취소·실행 복귀")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text("주황 = 초안(파일·rekordbox 미반영)").font(.caption).foregroundStyle(UIColors.warning.color)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// 덱과 목록 사이 핸들: 끌어서 파형 높이를 조절한다.
struct SplitHandle: View {
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
