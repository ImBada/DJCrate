@testable import DJCrate
import DJCDomain
import DJCStorage
import RekordboxKit
import Testing

@Suite("USB 재생 목록 동기화 계획")
struct UsbSyncPlanTests {
    private func item(_ id: String, _ name: String, parent: String = PlaylistLayout.root,
                      folder: Bool = false, smart: Bool = false, tracks: [String] = []) -> PlaylistLayout.Item {
        PlaylistLayout.Item(id: id, name: name, parentID: parent, isFolder: folder, isSmart: smart,
                            entries: tracks.enumerated().map { PlaylistEntry(trackNo: $0.offset + 1, contentID: $0.element) })
    }

    private func layout(_ items: [PlaylistLayout.Item]) -> PlaylistLayout {
        PlaylistLayout(items.enumerated().map { (item: $0.element, seq: $0.offset) })
    }

    private func playlist(_ id: Int, _ name: String, parent: Int = 0, folder: Bool = false,
                          order: Int = 0, tracks: [Int] = []) -> UsbPlaylist {
        UsbPlaylist(id: id, name: name, parentID: parent, attribute: folder ? 1 : 0,
                    presentIn: UsbFormat.defaultSet,
                    sortOrder: [.oneLibrary: order, .deviceLibrary: order],
                    entries: [.oneLibrary: tracks, .deviceLibrary: tracks])
    }

    private func library(_ playlists: [UsbPlaylist], tracks: [Int] = [], history: [Int] = []) -> UsbLibrary {
        var library = UsbLibrary(formats: UsbFormat.defaultSet, property: UsbProperty(dbVersion: "1000"))
        library.playlists = playlists
        library.tracks = tracks.map { UsbTrack(id: $0) }
        if !history.isEmpty { library.histories = [UsbHistory(format: .oneLibrary, id: 1, name: "합성 기록", entries: history)] }
        return library
    }

    @Test("미반영 목록·인텔리전트 목록을 빼고 기존 트리와 곡 순서를 유지한다")
    func sourceExcludesUnsupportedPlaylists() {
        let raw = layout([item("folder", "폴더", folder: true),
                          item("one", "일반 목록", parent: "folder", tracks: ["local-two", "local-one"]),
                          item("smart", "인텔리전트 목록", parent: "folder", smart: true),
                          item("new:draft", "미반영 목록", parent: "folder"),
                          item("new:folder", "미반영 폴더", folder: true),
                          item("new:child", "미반영 하위 목록", parent: "new:folder"),
                          item("two", "다른 일반 목록")])
        let source = UsbSyncPlan.source(raw)
        #expect(source.outline.map(\.id) == ["folder", "one", "two"])
        #expect(source.item("one")?.trackIDs == ["local-two", "local-one"])
        #expect(source.item("folder")?.isFolder == true)
    }

    @Test("폴더 선택은 하위를 포함하고 하위 하나를 끄면 형제와 조상 폴더를 보존한다")
    func folderSelectionAndPartialSelection() {
        let source = layout([item("folder", "폴더", folder: true),
                             item("one", "목록 하나", parent: "folder"),
                             item("nested", "하위 폴더", parent: "folder", folder: true),
                             item("two", "목록 둘", parent: "nested"),
                             item("outside", "다른 목록")])
        let nodes = UsbSyncPlan.nodes(source)
        var selection = ITunesSyncSelection(selectedIDs: ["folder"])
        #expect(UsbSyncPlan.selectedLayout(source, selection: selection).outline.map(\.id) == ["folder", "one", "nested", "two"])
        selection.setSelected(false, id: "one", in: nodes)
        #expect(selection.state(of: "folder", in: nodes) == .mixed)
        #expect(UsbSyncPlan.selectedLayout(source, selection: selection).outline.map(\.id) == ["folder", "nested", "two"])
        #expect(nodes.first { $0.id == "folder" }?.parentID == UsbSyncSource.rekordboxSelectionID)
    }

    @Test("처음 여는 선택은 전체 경로가 같은 일반 목록만 연결하고 NFC를 맞춘다")
    func initialSelectionMatchesWholeNormalizedPath() {
        let source = layout([item("folder", "가", folder: true),
                             item("one", "같은 이름", parent: "folder"),
                             item("other-folder", "다른 폴더", folder: true),
                             item("two", "같은 이름", parent: "other-folder"),
                             // "root"는 PlaylistLayout.root 표지와 겹쳐 자기 자신의 자식이 되므로 쓰지 않는다.
                             item("top-list", "같은 이름")])
        let usb = library([playlist(10, "\u{1100}\u{1161}", folder: true),
                           playlist(11, "같은 이름", parent: 10)])
        let selection = UsbSyncPlan.initialSelection(source: source, library: usb)
        #expect(selection.selectedIDs == ["one"])
        #expect(UsbSyncPlan.selectedLayout(source, selection: selection).outline.map(\.id) == ["folder", "one"])
    }

    @Test("이름·부모가 바뀐 원본은 rekordbox처럼 새 USB 목록을 만들고 옛 목록은 옮기거나 지우지 않는다")
    func renamedSourceCreatesNewPlaylistAndKeepsOld() throws {
        let source = layout([item("new-parent", "남길 폴더", folder: true),
                             item("local-list", "바꾼 목록 이름", parent: "new-parent")])
        let usb = library([playlist(10, "옛 폴더", folder: true),
                           playlist(11, "예전 목록 이름", parent: 10),
                           playlist(20, "남길 폴더", folder: true, order: 1)])
        let bindings = ["local-list": UsbSyncPlaylistBinding(usbID: 11, path: ["옛 폴더", "예전 목록 이름"], isFolder: false)]
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["local-list"]),
                                        library: usb, matches: [:], badges: [:], bindings: bindings, newKey: { "renamed" })
        #expect(plan.edits == [.playlist(edit: .create(key: "renamed", name: "바꾼 목록 이름", isFolder: false, parent: .id("20")))])
        #expect(plan.playlistRefs == ["new-parent": .id("20"), "local-list": .new("renamed")])
        #expect(plan.unlinkedPlaylistCount == 2)
    }

    @Test("이름과 위치가 그대로면 저장한 연결의 USB 목록을 쓴다")
    func unchangedPathKeepsLinkedPlaylist() throws {
        let source = layout([item("local-list", "현재 목록")])
        let usb = library([playlist(11, "현재 목록")])
        let bindings = ["local-list": UsbSyncPlaylistBinding(usbID: 11, path: ["예전 목록"], isFolder: false)]
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["local-list"]),
                                        library: usb, matches: [:], badges: [:], bindings: bindings)
        #expect(plan.edits.isEmpty)
        #expect(plan.playlistRefs == ["local-list": .id("11")])
    }

    @Test("다른 원본에 이어진 USB 목록은 이름이 같아도 잇지 않는다")
    func playlistLinkedToAnotherSourceIsNotReused() throws {
        let source = layout([item("renamed", "같은 이름"), item("other", "다른 원본")])
        let usb = library([playlist(10, "같은 이름")])
        let bindings = ["other": UsbSyncPlaylistBinding(usbID: 10, path: ["같은 이름"], isFolder: false)]
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["renamed"]),
                                        library: usb, matches: [:], badges: [:], bindings: bindings, newKey: { "fresh" })
        #expect(plan.playlistRefs == ["renamed": .new("fresh")])
        #expect(plan.edits == [.playlist(edit: .create(key: "fresh", name: "같은 이름", isFolder: false, parent: .root))])
    }

    @Test("옛 부모에 이어진 목록을 새 폴더로 옮기지 않고 어느 목록에도 없는 곡만 뺄 곡으로 알린다")
    func movedSourceKeepsOldTreeAndReportsOrphans() throws {
        let source = layout([item("new-parent", "새 폴더", folder: true),
                             item("local-list", "남길 목록", parent: "new-parent", tracks: ["local-one"])])
        let usb = library([playlist(10, "옛 폴더", folder: true),
                           playlist(11, "남길 목록", parent: 10, tracks: [1]),
                           playlist(12, "선택하지 않은 목록", parent: 10, order: 1, tracks: [2])],
                          tracks: [1, 2, 3, 4], history: [4])
        let bindings = ["local-list": UsbSyncPlaylistBinding(usbID: 11, path: ["옛 폴더", "남길 목록"], isFolder: false)]
        var keys = ["folder-key", "list-key"].makeIterator()
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["local-list"]),
                                        library: usb, matches: [1: "local-one"], badges: [:], bindings: bindings,
                                        newKey: { keys.next()! })
        #expect(plan.edits == [.playlist(edit: .create(key: "folder-key", name: "새 폴더", isFolder: true, parent: .root)),
                               .playlist(edit: .create(key: "list-key", name: "남길 목록", isFolder: false, parent: .new("folder-key"))),
                               .syncPlaylist(playlist: .new("list-key"), localContentIDs: ["local-one"])])
        #expect(plan.unlinkedPlaylistCount == 3)
        #expect(plan.trackIDs == ["local-one"])
        // 3은 어느 목록에도 없다. 4는 재생 기록에 있어 곡 빼기가 막으므로 넣지 않는다. 곡 빼기는 확인 뒤 모델이 더한다.
        #expect(plan.orphanTrackIDs == [3])
        #expect(!plan.edits.contains { if case .removeTracks = $0 { true } else { false } })
    }

    @Test("전체 해제는 USB 목록을 지우지 않고 연결만 끊는다")
    func clearingSelectionKeepsUsbPlaylists() throws {
        let usb = library([playlist(10, "폴더", folder: true),
                           playlist(11, "하위 목록", parent: 10, tracks: [1]),
                           playlist(20, "다른 목록", order: 1, tracks: [2])], tracks: [1, 2])
        let plan = try UsbSyncPlan.build(source: PlaylistLayout(), selection: ITunesSyncSelection(),
                                        library: usb, matches: [:], badges: [:], bindings: [:])
        #expect(plan.edits.isEmpty)
        #expect(plan.unlinkedPlaylistCount == 3)
        #expect(plan.trackIDs.isEmpty && plan.orphanTrackIDs.isEmpty)
    }

    @Test("이은 목록끼리만 원본 순서로 맞추고 남은 목록은 그 자리에 둔다")
    func reorderKeepsUnlinkedSlots() throws {
        let source = layout([item("b", "B"), item("a", "A")])
        let usb = library([playlist(10, "A"), playlist(11, "남은 목록", order: 1), playlist(12, "B", order: 2)])
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["0"]),
                                        library: usb, matches: [:], badges: [:], bindings: [:])
        #expect(plan.edits == [.playlist(edit: .reorder(playlist: .id("12"), index: 0)),
                               .playlist(edit: .reorder(playlist: .id("11"), index: 1))])
    }

    @Test("USB의 맨 끝 생성 규칙을 반영해 필요한 재정렬만 계획한다")
    func newPlaylistsUseUsbAppendOrder() throws {
        let source = layout([item("before", "앞 목록"), item("kept", "기존 목록"), item("after", "뒤 목록")])
        let usb = library([playlist(10, "기존 목록")])
        var keys = ["before-key", "after-key"].makeIterator()
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["0"]),
                                        library: usb, matches: [:], badges: [:], bindings: [:],
                                        newKey: { keys.next()! })
        #expect(plan.edits == [.playlist(edit: .create(key: "before-key", name: "앞 목록", isFolder: false, parent: .root)),
                               .playlist(edit: .create(key: "after-key", name: "뒤 목록", isFolder: false, parent: .root)),
                               .playlist(edit: .reorder(playlist: .new("before-key"), index: 0))])
    }

    @Test("선택한 로컬 목록의 같은 경로가 중복이면 전체 계획을 거부한다")
    func duplicateLocalPathsAreRejected() {
        let source = layout([item("one", "중복 이름"), item("two", "중복 이름")])
        #expect(throws: PlaylistLayout.Blocked.self) {
            try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["0"]),
                                  library: library([]), matches: [:], badges: [:], bindings: [:])
        }
    }

    @Test("이름으로 이어야 하는데 USB에 같은 경로가 여럿이면 전체 계획을 거부한다")
    func duplicateUsbPathsAreRejectedWithoutBinding() {
        let source = layout([item("local-list", "중복 이름")])
        let usb = library([playlist(10, "중복 이름"), playlist(11, "중복 이름", order: 1)])
        #expect(throws: PlaylistLayout.Blocked.self) {
            try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["local-list"]),
                                  library: usb, matches: [:], badges: [:], bindings: [:])
        }
    }

    @Test("이어진 목록이 있으면 USB의 같은 이름 목록이 남아 있어도 그 목록을 쓴다")
    func linkedPlaylistWinsOverDuplicateNames() throws {
        let source = layout([item("local-list", "중복 이름")])
        let usb = library([playlist(10, "중복 이름"), playlist(11, "중복 이름", order: 1)])
        let bindings = ["local-list": UsbSyncPlaylistBinding(usbID: 11, path: ["중복 이름"], isFolder: false)]
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["local-list"]),
                                        library: usb, matches: [:], badges: [:], bindings: bindings)
        #expect(plan.playlistRefs == ["local-list": .id("11")])
        #expect(plan.edits.isEmpty)
    }

    @Test("선택하지 않은 USB 목록의 이름이 겹쳐도 남겨 두고 막지 않는다")
    func duplicateUnselectedUsbPathsAreKept() throws {
        let source = layout([item("kept", "남길 목록")])
        let usb = library([playlist(10, "남길 목록"), playlist(20, "중복 이름", order: 1), playlist(21, "중복 이름", order: 2)])
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["kept"]),
                                         library: usb, matches: [:], badges: [:], bindings: [:])
        #expect(plan.edits.isEmpty)
        #expect(plan.unlinkedPlaylistCount == 2)
    }

    @Test("같은 경로의 폴더와 일반 목록은 자동으로 바꾸지 않는다")
    func mismatchedPlaylistTypesAreRejected() {
        let source = layout([item("folder", "같은 이름", folder: true)])
        #expect(throws: PlaylistLayout.Blocked.self) {
            try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["folder"]),
                                  library: library([playlist(10, "같은 이름")]), matches: [:], badges: [:], bindings: [:])
        }
    }

    @Test("두 로컬 목록이 하나의 USB ID에 이어져 있어도 한 USB 목록은 한 원본에만 잇는다")
    func duplicateStoredPlaylistPairLinksOnce() throws {
        let source = layout([item("one", "USB 목록"), item("two", "목록 둘")])
        let bindings = ["one": UsbSyncPlaylistBinding(usbID: 10, path: ["USB 목록"], isFolder: false),
                        "two": UsbSyncPlaylistBinding(usbID: 10, path: ["USB 목록"], isFolder: false)]
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["0"]),
                                        library: library([playlist(10, "USB 목록")]), matches: [:], badges: [:], bindings: bindings,
                                        newKey: { "two-key" })
        #expect(plan.playlistRefs == ["one": .id("10"), "two": .new("two-key")])
    }

    @Test("선택한 로컬 곡의 USB 짝이 여럿이면 전체 계획을 거부한다")
    func ambiguousTrackPairIsRejected() {
        let source = layout([item("one", "목록", tracks: ["local-one"])])
        let usb = library([playlist(10, "목록", tracks: [1])])
        #expect(throws: PlaylistLayout.Blocked.self) {
            try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["one"]),
                                  library: usb, matches: [1: "local-one", 2: "local-one"], badges: [:], bindings: [:])
        }
    }

    @Test("로컬에서 바뀐 필드만 갱신하고 같은 목록 내용을 다시 쓰지 않는다", arguments: [
        (Set<UsbSyncStatus.Field>([.information]), Set<UsbRefreshPart>([.info, .artwork])),
        (Set<UsbSyncStatus.Field>([.analysis]), Set<UsbRefreshPart>([.grid])),
        (Set<UsbSyncStatus.Field>([.cue]), Set<UsbRefreshPart>([.cues])),
        (Set<UsbSyncStatus.Field>([.analysis, .cue]), Set<UsbRefreshPart>([.grid, .cues])),
    ])
    func localNewerTracksAreRefreshed(fields: Set<UsbSyncStatus.Field>, parts: Set<UsbRefreshPart>) throws {
        let source = layout([item("one", "목록", tracks: ["local-one", "local-two"])])
        let usb = library([playlist(10, "목록", tracks: [1, 2])])
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["one"]),
                                        library: usb, matches: [1: "local-one", 2: "local-two"],
                                        badges: [1: .localNewer(fields), 2: .deviceModified], bindings: [:])
        #expect(plan.edits == [.refreshTracks(usbContentIDs: [1], parts: parts)])
    }

    @Test("같은 변경 필드의 곡을 묶고 서로 다른 변경 부분은 섞지 않는다")
    func refreshGroupsKeepChangedPartsSeparate() throws {
        let source = layout([item("one", "목록", tracks: ["local-one", "local-two", "local-three"])])
        let usb = library([playlist(10, "목록", tracks: [1, 2, 3])])
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["one"]),
                                        library: usb, matches: [1: "local-one", 2: "local-two", 3: "local-three"],
                                        badges: [1: .localNewer([.cue]), 2: .localNewer([.cue]), 3: .localNewer([.analysis])],
                                        bindings: [:])
        #expect(plan.edits.count == 2)
        #expect(Set(plan.edits) == [.refreshTracks(usbContentIDs: [1, 2], parts: [.cues]),
                                  .refreshTracks(usbContentIDs: [3], parts: [.grid])])
    }

    @Test("트리·목록 내용·갱신 상태가 같으면 편집을 만들지 않는다")
    func identicalLibraryNeedsNoEdits() throws {
        let source = layout([item("folder", "폴더", folder: true),
                             item("one", "목록 하나", parent: "folder", tracks: ["local-one", "local-two"]),
                             item("two", "목록 둘", parent: "folder")])
        let usb = library([playlist(10, "폴더", folder: true),
                           playlist(11, "목록 하나", parent: 10, tracks: [1, 2]),
                           playlist(12, "목록 둘", parent: 10, order: 1)])
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["0"]),
                                        library: usb, matches: [1: "local-one", 2: "local-two"],
                                        badges: [1: .upToDate, 2: .upToDate], bindings: [:])
        #expect(plan.edits.isEmpty)
        #expect(plan.unlinkedPlaylistCount == 0)
        #expect(plan.trackIDs == ["local-one", "local-two"])
    }
}
