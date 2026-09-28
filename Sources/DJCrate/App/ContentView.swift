import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A안: 사이드바 | (위) 덱 · (아래) 라이브러리 표
struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    @Bindable var store: LibraryStore
    @Bindable var deck: DeckModel
    /// 저장된 창 프레임을 적용했는지. 그 전의 기본 크기 폭으로는 사이드바를 접지 않는다(#119).
    var windowFrameRestored = true
    @AppStorage(SettingKeys.showTagEditor.name) private var showTagEditor = SettingKeys.showTagEditor.defaultValue
    @AppStorage(SettingKeys.waveformHeight.name) private var waveformHeight = SettingKeys.waveformHeight.defaultValue
    @AppStorage(SettingKeys.sheetMode.name) private var sheetMode = SettingKeys.sheetMode.defaultValue
    @AppStorage(SettingKeys.sidebarVisible.name) private var sidebarVisible = SettingKeys.sidebarVisible.defaultValue
    @State private var keys = KeyRouter()
    @State private var sidebarAutoCollapse = SidebarVisibility()
    @State private var detailHeight = 650.0
    @State private var deckChromeHeight = 240.0
    @State private var noticeHeight = 0.0
    @State private var listHeaderHeight = 40.0
    @State private var isFileDropTargeted = false

    private var otherHeight: Double { noticeHeight + listHeaderHeight + DeckLayout.splitHandleHeight }
    private var displayedWaveformHeight: Double {
        DeckLayout.waveformHeight(requested: waveformHeight, detailHeight: detailHeight,
                                  deckChromeHeight: deckChromeHeight, otherHeight: otherHeight)
    }
    private var maximumWaveformHeight: Double {
        DeckLayout.waveformHeight(requested: DeckLayout.maximumWaveformHeight, detailHeight: detailHeight,
                                  deckChromeHeight: deckChromeHeight, otherHeight: otherHeight)
    }
    /// 메뉴 '파형 크게·작게'(덱이 보일 때만)
    private var waveformHeightControl: WaveformHeightControl? {
        guard case .loaded = store.phase else { return nil }
        return WaveformHeightControl(displayed: displayedWaveformHeight, maximum: maximumWaveformHeight) { waveformHeight = $0 }
    }

    /// 사이드바 표시 상태는 저장해 두고 다음 실행을 같은 모양으로 시작한다(#119).
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding { SidebarVisibility.columns(visible: sidebarVisible) } set: { sidebarVisible = SidebarVisibility.isVisible($0) }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            Sidebar(store: store)
                .disabled(!store.writeLockPolicy.allowsLibraryInteraction)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detail
                .navigationTitle(store.sidebarTitle)
                .navigationSubtitle(store.sidebar == .duplicates
                    ? String(ui: "\(store.displayDuplicateGroups.count)묶음 · \(store.displayRows.count)곡")
                    : store.selection.count > 1
                    ? String(ui: "\(store.displayRows.count)곡 · \(store.selection.count)곡 선택")
                    : String(ui: "\(store.displayRows.count)곡"))
                .disabled(!store.writeLockPolicy.allowsLibraryInteraction)
                // 위쪽 알림 줄(스냅샷 오류·반영·곡 추가)과 겹치지 않게 아래에 띄운다(#122).
                .overlay(alignment: .bottom) {
                    if let toast = store.toast {
                        AppToastView(toast: toast,
                                     onUndo: toast.undoBackup.map { url in { store.toast = nil; DirectWritePanels.restore(store: store, backupURL: url) } },
                                     onDetails: { store.showingWriteResult = true },
                                     onClose: { if store.toast?.id == toast.id { store.toast = nil } })
                            .padding(.bottom, 16)
                            .padding(.horizontal, 16)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                            .id(toast.id)
                    }
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35), value: store.toast?.id)
        }
        // rekordbox에 쓰는 동안은 창 전체를 덮어 다른 조작을 막는다.
        .overlay {
            if let stage = store.writeStage {
                WritingOverlay(stage: stage, onCancel: { store.cancelWritePreparation() }).transition(.opacity)
            }
        }
        .sheet(isPresented: $store.showingWriteResult) { WriteResultView(history: store.resultHistory) }
        .sheet(isPresented: $store.showingPlaylistPicker) { PlaylistPickerView(store: store) }
        .animation(.easeInOut(duration: 0.15), value: store.writeStage)
        .searchable(text: $store.search, placement: .toolbar, prompt: Text(.ui("제목·아티스트·코멘트")))
        .toolbar(id: "main") { toolbarContent }
        .focusedSceneValue(\.appCommands, AppCommandContext(store: store, deck: deck, showTagEditor: $showTagEditor,
                                                             waveformHeight: waveformHeightControl))
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
                let displayedHeight = displayedWaveformHeight
                let maximumHeight = maximumWaveformHeight
                // VSplitView(NSSplitView)는 자식 최소 크기가 내용에 따라 바뀌면 레이아웃을 끝없이
                // 다시 잡다가 예외로 죽는다. SwiftUI만으로 나누고, 덱 높이는 핸들로 조절한다.
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if let error = store.lastError {
                            Label(.ui("스냅샷을 새로 뜨지 못했습니다: \(error)"), systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(UIColors.warning.color)
                                .padding(.horizontal, Spacing.edge).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let message = store.reflectionMessage {
                            AppMessageView(message: message, onClose: { store.reflectionMessage = nil })
                        }
                        if let message = store.stagingMessage {
                            AppMessageView(message: message, onClose: { store.stagingMessage = nil })
                        }
                        if let message = store.playlistMessage {
                            AppMessageView(message: message, onClose: { store.playlistMessage = nil })
                        }
                    }
                    .onGeometryChange(for: Double.self) { $0.size.height } action: { noticeHeight = $0 }
                    // 먼저 파형을 줄이고, 그리드 편집 등으로도 모자라면 덱만 스크롤한다.
                    ScrollView(.vertical) {
                        DeckView(deck: deck, waveformHeight: displayedHeight)
                            .frame(maxWidth: .infinity, alignment: .top)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: Double.self) {
                                max(0, $0.size.height - displayedHeight)
                            } action: { deckChromeHeight = $0 }
                    }
                    // 들어맞을 때는 튕기지 않게 해 스크럽 뒤 불필요한 감속을 막는다(#92).
                    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                    .frame(height: DeckLayout.deckViewportHeight(contentHeight: deckChromeHeight + displayedHeight,
                                                                 detailHeight: detailHeight, otherHeight: otherHeight))
                    // 곡 목록에서 끌어다 놓으면 덱에 올린다(#93)
                    .modifier(DeckDropTarget(store: store))
                    SplitHandle(height: $waveformHeight, displayedHeight: displayedHeight, maximumHeight: maximumHeight)
                    VStack(spacing: 0) {
                        ListActionBar(store: store)
                        if sheetMode && store.sidebar != .duplicates { SheetHeader() }
                    }
                    .onGeometryChange(for: Double.self) { $0.size.height } action: { listHeaderHeight = $0 }
                    Group {
                        if store.sidebar == .duplicates {
                            DuplicateTracksView(store: store)
                                .frame(minWidth: 0, maxWidth: .infinity, minHeight: DeckLayout.minimumLibraryHeight, maxHeight: .infinity)
                        } else if sheetMode {
                            TagSheetView(store: store)
                                .onDisappear { store.canFillDownTags = false }
                                .frame(minWidth: 0, maxWidth: .infinity, minHeight: DeckLayout.minimumLibraryHeight, maxHeight: .infinity)
                                .overlay { if store.displayRows.isEmpty { emptyLibrary } }
                        } else {
                            TrackTable(store: store, deck: deck)
                                .frame(minWidth: 0, maxWidth: .infinity, minHeight: DeckLayout.minimumLibraryHeight, maxHeight: .infinity)
                                .overlay { if store.displayRows.isEmpty { emptyLibrary } }
                        }
                    }
                    // 내부 곡 끌기는 재생 목록·덱이 맡으므로 파일 추가가 가로채지 않는다.
                    .onDrop(of: [.fileURL], delegate: LibraryFileDropDelegate(store: store, isTargeted: $isFileDropTargeted))
                    .overlay {
                        if isFileDropTargeted {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                                .padding(4)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    detailHeight = size.height
                    // 인스펙터를 열어 덱 폭이 모자라면 탐색 열을 접어 컨트롤 자리를 남긴다.
                    if sidebarAutoCollapse.shouldCollapse(detailWidth: size.width, windowFrameRestored: windowFrameRestored) {
                        sidebarVisible = false
                    }
                }
                // 새 스냅샷을 읽고 다시 그릴 때도 첫 측정은 임시 폭이다.
                .onDisappear { sidebarAutoCollapse.reset() }
                .inspector(isPresented: $showTagEditor) {
                    TagInspector(store: store)
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
                }
            case .idle:
                ContentUnavailableView {
                    Label(.ui("스냅샷이 없습니다"), systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text(.ui("rekordbox를 종료한 뒤 master.db 사본을 떠 주세요. 원본은 읽기만 합니다."))
                } actions: {
                    Button(.ui("스냅샷 뜨기")) { Task { await store.takeSnapshot() } }
                }
            case let .loading(message):
                ProgressView(message)
            case let .failed(message):
                ContentUnavailableView {
                    Label(.ui("불러오지 못했습니다"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button(.ui("다시 시도")) { Task { await store.loadInitial() } }
                    Button(.ui("실행 중이어도 읽기용 스냅샷 뜨기")) { Task { await store.takeSnapshot(force: true) } }
                }
            }
    }

    @ViewBuilder private var emptyLibrary: some View {
        if !store.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: store.search)
        } else if store.sidebar == .pending {
            ContentUnavailableView {
                Label(.ui("쓸 초안이 없습니다"), systemImage: "checkmark.circle")
            } description: {
                Text(.ui("곡의 큐·그리드·게인을 고치면 여기에 모입니다."))
            }
        } else if store.sidebar == .staged {
            ContentUnavailableView {
                Label(.ui("추가한 곡이 없습니다"), systemImage: "music.note")
            } description: {
                Text(.ui("음원 파일을 끌어다 놓거나 ‘곡 추가’를 눌러 시작하세요."))
            } actions: {
                Button(.ui("곡 추가…")) { StagingPanels.chooseFiles(store: store) }
            }
        } else {
            ContentUnavailableView {
                Label(.ui("표시할 곡이 없습니다"), systemImage: "music.note.list")
            } description: {
                Text(.ui("다른 목록을 선택하거나 새 스냅샷으로 라이브러리를 다시 읽어 보세요."))
            }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some CustomizableToolbarContent {
            ToolbarItem(id: "relatedTracks") {
                RelatedTracksButton(store: store, deck: deck)
            }
            ToolbarItem(id: "viewMode", placement: .principal) {
                Picker(.ui("보기"), selection: $sheetMode) {
                    Label(.ui("목록"), systemImage: "list.bullet").tag(false)
                        .help(.ui("곡 목록을 봅니다(⌘1)."))
                    Label(.ui("태그 시트"), systemImage: "tablecells").tag(true)
                        .help(.ui("태그를 표에서 편집합니다(⌘2)."))
                }
                .pickerStyle(.segmented)
                .disabled(!store.writeLockPolicy.allowsLibraryInteraction || store.sidebar == .duplicates)
            }
            ToolbarItem(id: "addFiles") {
                Button {
                    StagingPanels.chooseFiles(store: store)
                } label: {
                    Label(.ui("곡 추가"), systemImage: "plus")
                }
                .disabled(!LibraryMenuAction.addFiles.isEnabled(in: store))
                .help(.ui("음원 파일·폴더를 추가합니다. 창에 끌어다 놓아도 됩니다."))
            }
            ToolbarItem(id: "tagEditor") {
                Button {
                    showTagEditor.toggle()
                } label: {
                    Label(.ui("태그 편집"), systemImage: "tag")
                }
                .help(.ui("선택한 곡의 태그를 편집합니다 (⌘I). 여러 곡을 한꺼번에 편집할 수 있습니다."))
                .disabled(!store.writeLockPolicy.allowsLibraryInteraction)
            }
            ToolbarItem(id: "snapshot") {
                Button {
                    // rekordbox가 켜져 있어도 읽기용 사본을 뜬다(최근 변경이 담긴 WAL까지 사본 안에서 합친다).
                    Task { await store.takeSnapshot(force: LibrarySnapshot.isRekordboxRunning()) }
                } label: {
                    Label(.ui("새 스냅샷"), systemImage: "arrow.clockwise")
                }
                .disabled(!LibraryMenuAction.snapshot.isEnabled(in: store))
                .help(.ui("라이브러리 사본을 새로 읽고 XML 가져오기 결과를 확인합니다(⌘R)."))
            }
            ToolbarItem(id: "reflection", placement: .primaryAction) {
                ReflectionMenu(store: store)
            }
    }

    private func setUp() {
            deck.feedback = store.feedback
            // 목록 선택은 덱을 바꾸지 않는다. 더블클릭·⌘→·오른쪽 클릭·끌어다 놓기로만 덱에 올린다(#93).
            store.onLoadToDeck = { [weak deck] row in deck?.load(row) }
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
            keys.install(deck: deck, store: store)
            TrackEditWindow.shared.attach(deck: deck, store: store)
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
    @Environment(\.textScale) private var textScale

    var body: some View {
        HStack(spacing: 14) {
            Text(.ui("더블클릭·Return·타이핑: 편집  ·  ⌘→: 덱에 불러오기  ·  ⌃Tab: 표 밖으로  ·  ⌘C/⌘V: 엑셀·시트와 복사·붙여넣기  ·  ⌘D: 아래로 채우기  ·  Delete: 지우기  ·  ⌘Z/⇧⌘Z: 실행 취소·실행 복귀"))
                .font(.scaled(.caption, textScale)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            // 색이 아니라 칸의 모양(왼쪽 위 모서리 삼각형)으로 알린다.
            Label { Text(.ui("= 초안(파일·rekordbox에 쓰기 전)")) } icon: { DraftCornerSwatch() }
                .font(.scaled(.caption, textScale)).foregroundStyle(.secondary)
                .help(.ui("왼쪽 위 삼각형은 초안입니다. 아직 음원 파일과 rekordbox에 쓰지 않았습니다."))
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(.ui("왼쪽 위 모서리 삼각형이 붙은 칸은 초안(파일·rekordbox에 쓰기 전)"))
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.edge)
        .padding(.vertical, 6)
    }
}

/// 덱과 목록 사이 핸들: 끌어서 파형 높이를 조절한다.
struct SplitHandle: View {
    @Binding var height: Double
    var displayedHeight: Double
    var maximumHeight: Double
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
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if start == nil { start = displayedHeight }
                    height = clamped((start ?? displayedHeight) + value.translation.height)
                }
                .onEnded { _ in start = nil })
            .onTapGesture(count: 2) { height = DeckLayout.defaultWaveformHeight }
            .accessibilityLabel(.ui("파형 높이 조절"))
            .accessibilityValue(.ui("\(Int(displayedHeight))포인트"))
            .accessibilityHint(.ui("위아래로 조절하거나 두 번 클릭하면 기본 높이로 돌아갑니다"))
            .accessibilityAdjustableAction { direction in
                // 메뉴 '파형 크게·작게'와 같은 한 칸
                switch direction {
                case .increment: height = DeckLayout.steppedWaveformHeight(displayed: displayedHeight, direction: 1, maximum: maximumHeight)
                case .decrement: height = DeckLayout.steppedWaveformHeight(displayed: displayedHeight, direction: -1, maximum: maximumHeight)
                @unknown default: break
                }
            }
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, DeckLayout.minimumWaveformHeight), maximumHeight)
    }
}

/// 파일 URL과 내부 곡 ID를 함께 싣는 드래그를 구별해야 하므로 형식을 검사할 수 있는 delegate를 쓴다.
struct LibraryFileDropDelegate: DropDelegate {
    let store: LibraryStore
    @Binding var isTargeted: Bool

    static func accepts(_ providers: [NSItemProvider]) -> Bool {
        !providers.isEmpty
            && providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            && !providers.contains { $0.hasItemConformingToTypeIdentifier(DeckDragType.track.identifier)
                || $0.hasItemConformingToTypeIdentifier(PlaylistDragType.tracks.identifier) }
    }

    func validateDrop(info: DropInfo) -> Bool {
        store.writeLockPolicy.allowsLibraryInteraction
            && !store.isITunesSelection
            && Self.accepts(info.itemProviders(for: [.fileURL, DeckDragType.track, PlaylistDragType.tracks]))
    }

    func dropEntered(info: DropInfo) { isTargeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { isTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let accepted = validateDrop(info: info)
        isTargeted = accepted
        return DropProposal(operation: accepted ? .copy : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            guard !urls.isEmpty, store.writeLockPolicy.allowsLibraryInteraction else { return }
            await store.addFiles(urls)
        }
        return true
    }
}
