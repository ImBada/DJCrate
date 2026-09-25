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

    var body: some View {
        NavigationSplitView {
            Sidebar(store: store)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
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
                    // 덱 높이는 내용에 맞춘다(잘리지 않게). 핸들은 파형 높이를 조절한다.
                    DeckView(deck: deck, waveformHeight: waveformHeight)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .fixedSize(horizontal: false, vertical: true)
                    SplitHandle(height: $waveformHeight)
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
        .searchable(text: $store.search, placement: .toolbar, prompt: "제목·아티스트·코멘트")
        .toolbar {
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
                    showTagEditor.toggle()
                } label: {
                    Label("태그 편집", systemImage: "tag")
                }
                .keyboardShortcut("i", modifiers: .command)
                .help("선택한 곡의 태그를 편집합니다 (⌘I). 여러 곡을 한꺼번에 편집할 수 있습니다.")
            }
            ToolbarItem {
                Button {
                    Task { await store.takeSnapshot() }
                } label: {
                    Label("새 스냅샷", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)
                .help("rekordbox master.db 사본을 새로 떠서 다시 읽습니다")
            }
        }
        .onAppear {
            // 선택 변경은 스토어가 150ms 뒤에 알려 준다(루트 뷰가 선택마다 다시 그려지지 않도록).
            store.onPrimaryRowChange = { [weak deck] row in deck?.load(row) }
            deck.onDraftChange = { [weak store] uuid, kind, exists in
                store?.draftChanged(trackUUID: uuid, kind: kind, exists: exists)
            }
            if ProcessInfo.processInfo.arguments.contains("--inspector") { showTagEditor = true }
            if ProcessInfo.processInfo.arguments.contains("--sheet") { sheetMode = true }
        }
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

    var body: some View {
        List(selection: $store.sidebar) {
            Section("라이브러리") {
                ForEach(LibraryFilter.allCases) { filter in
                    Label(filter.rawValue, systemImage: filter.systemImage)
                        .badge(store.count(filter))
                        .tag(SidebarItem.filter(filter))
                }
            }
            if !store.playlistTree.isEmpty {
                Section("rekordbox 플레이리스트") {
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
                Section("현황") {
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
    }
}
