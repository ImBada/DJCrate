import DJCDomain
import SwiftUI

/// 주 창 본문: (위) 덱 · (아래) 라이브러리 표.
/// 덱과 목록이 잰 크기(`detailHeight`·`deckChromeHeight` …)는 창 크기·사이드바·인스펙터가 움직이는 동안 줄바꿈 따위로
/// 프레임마다 바뀐다. 그 값을 주 창(`ContentView`)이 들면 바뀔 때마다 툴바·사이드바·메뉴까지 본문을 다시 계산하므로
/// 이 뷰가 든다(#138).
struct LibraryDetail: View {
    @Bindable var store: LibraryStore
    @Bindable var deck: DeckModel
    /// 저장된 창 프레임을 적용했는지. 그 전의 기본 크기 폭으로는 사이드바를 접지 않는다(#119).
    var windowFrameRestored: Bool
    /// 폭이 모자라면 탐색 열을 접는다. 값은 읽지 않고 쓰기만 한다(읽으면 이 뷰가 사이드바를 여닫을 때마다 다시 계산된다).
    let sidebarVisible: ObservedSetting<Bool>
    @AppStorage(SettingKeys.waveformHeight.name) private var waveformHeight = SettingKeys.waveformHeight.defaultValue
    @AppStorage(SettingKeys.sheetMode.name) private var sheetMode = SettingKeys.sheetMode.defaultValue
    @State private var sidebarAutoCollapse = SidebarVisibility()
    @State private var widthClass = DeckWidthClass(width: 1400)
    @State private var detailHeight = 650.0
    @State private var deckChromeHeight = 240.0
    /// 곡 로드 중 내용 높이 재측정은 파형 높이에 반영하지 않는다(PR #151).
    @State private var fittedChromeHeight = 240.0
    @State private var noticeHeight = 0.0
    @State private var listHeaderHeight = 40.0
    @State private var fileDropHighlight = DropHighlight()

    private var otherHeight: Double { noticeHeight + listHeaderHeight + DeckLayout.splitHandleHeight }
    private var displayedWaveformHeight: Double {
        DeckLayout.waveformHeight(requested: waveformHeight, detailHeight: detailHeight,
                                  deckChromeHeight: fittedChromeHeight, otherHeight: otherHeight)
    }
    private var maximumWaveformHeight: Double {
        DeckLayout.waveformHeight(requested: DeckLayout.maximumWaveformHeight, detailHeight: detailHeight,
                                  deckChromeHeight: fittedChromeHeight, otherHeight: otherHeight)
    }
    /// 메뉴 '파형 크게·작게'
    private var waveformHeightControl: WaveformHeightControl {
        WaveformHeightControl(displayed: displayedWaveformHeight, maximum: maximumWaveformHeight) { waveformHeight = $0 }
    }

    var body: some View {
        let _ = PerfProbe.body(Self.self)
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
            // 파형은 본문 높이가 바뀔 때만 맞추고, 덱 내용이 늘면 덱만 스크롤한다(PR #151).
            ScrollView(.vertical) {
                DeckView(store: store, deck: deck, waveformHeight: displayedHeight, widthClass: widthClass)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                    // 높이는 아래 본문 크기와 같은 배치에서 함께 잰다(인스펙터가 만든 본문 사본의 덱 높이를 걸러 내려고).
                    .anchorPreference(key: DeckBoundsKey.self, value: .bounds) { $0 }
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
                        .overlay { EmptyLibraryOverlay(store: store) }
                } else {
                    TrackTable(store: store, deck: deck)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: DeckLayout.minimumLibraryHeight, maxHeight: .infinity)
                        .overlay { EmptyLibraryOverlay(store: store) }
                }
            }
            // 내부 곡 끌기는 재생 목록·덱이 맡으므로 파일 추가가 가로채지 않는다.
            .onDrop(of: [.fileURL], delegate: LibraryFileDropDelegate(store: store, highlight: $fileDropHighlight))
            .overlay {
                if fileDropHighlight.isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                        .padding(4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        // 인스펙터가 본문을 임시 높이로 한 번 더 배치해, 그 크기·덱 높이가 진짜 값과 번갈아 와서 창 크기를 바꿀 때마다
        // 본문을 두 번씩 다시 계산했다(#138). 본문 크기와 덱 높이를 한 번에 재고 본문이 아닌 측정은 통째로 버린다.
        .backgroundPreferenceValue(DeckBoundsKey.self) { deckBounds in
            Color.clear.onGeometryChange(for: DetailGeometry.self) { proxy in
                DetailGeometry(size: proxy.size, deckHeight: deckBounds.map { proxy[$0].height } ?? 0)
            } action: { geometry in
                guard DeckLayout.isDetailMeasurement(height: geometry.size.height) else { return }
                // 폭은 창 크기·사이드바·인스펙터가 움직이는 동안 프레임마다 바뀐다. 바뀐 상태만 써서
                // 이 본문과 덱을 프레임마다 다시 계산하지 않는다(#138).
                if deck.row != nil, abs(detailHeight - geometry.size.height) > 1 {
                    fittedChromeHeight = deckChromeHeight
                }
                if detailHeight != geometry.size.height { detailHeight = geometry.size.height }
                let width = DeckWidthClass(width: geometry.size.width)
                if widthClass != width { widthClass = width }
                let chrome = max(0, geometry.deckHeight - displayedHeight)
                if deckChromeHeight != chrome { deckChromeHeight = chrome }
                // 인스펙터를 열어 덱 폭이 모자라면 탐색 열을 접어 컨트롤 자리를 남긴다.
                var autoCollapse = sidebarAutoCollapse
                let collapse = autoCollapse.shouldCollapse(detailWidth: geometry.size.width, windowFrameRestored: windowFrameRestored)
                if autoCollapse != sidebarAutoCollapse { sidebarAutoCollapse = autoCollapse }
                if collapse { sidebarVisible.value = false }
            }
        }
        // 새 스냅샷을 읽고 다시 그릴 때도 첫 측정은 임시 폭이다.
        .onDisappear { sidebarAutoCollapse.reset() }
        .focusedSceneValue(\.waveformHeight, waveformHeightControl)
    }
}

/// 덱 전체(스크롤 안 내용)의 위치·크기
private struct DeckBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// 한 배치에서 함께 잰 본문 크기와 덱 높이
private struct DetailGeometry: Equatable {
    var size: CGSize
    var deckHeight: Double
}
