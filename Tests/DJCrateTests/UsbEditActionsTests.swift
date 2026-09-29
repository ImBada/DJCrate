@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// 이름 창: 정해 둔 이름을 차례로 돌려준다(비면 취소)
@MainActor
final class ScriptedNamePrompter: UsbNamePrompter {
    var answers: [String?] = []
    private(set) var asked: [(title: String, initial: String)] = []

    func askName(title: String, text: String, initial: String, confirm: String) -> String? {
        asked.append((title, initial))
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

/// USB 편집 시험 자료(곡 제목·ID는 지어낸 값)
enum UsbEditTestData {
    static func localRow(_ id: String, folder: String = "/x") -> TrackRow {
        TrackRow(track: Track(id: id, uuid: "uuid-\(id)", title: "로컬 곡 \(id)", artist: nil, album: nil, albumArtist: nil, genre: nil,
                              composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180,
                              folderPath: "\(folder)/\(id).mp3", comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil,
                              isDeleted: false),
                 cues: [], playCount: 0)
    }

    /// 지어낸 USB DB 지문
    static let base = UsbFingerprint(files: ["PIONEER/rekordbox/exportLibrary.db": .init(size: 10, mtime: Date(timeIntervalSince1970: 0),
                                                                                          sha256: "aa")])

    /// 두 형식의 항목이 다른 목록(4)·폴더(5)·폴더 안 목록(6)을 더한 라이브러리
    static func mixedLibrary() -> UsbLibrary {
        let both = UsbFormat.defaultSet
        return UsbTestData.library(playlists: [
            UsbPlaylist(id: 10, name: "시험 목록", presentIn: both, sortOrder: [.oneLibrary: 0, .deviceLibrary: 0],
                        entries: [.oneLibrary: [2, 1, 2], .deviceLibrary: [2, 1, 2]]),
            UsbPlaylist(id: 4, name: "다름", presentIn: both, sortOrder: [.oneLibrary: 1, .deviceLibrary: 1],
                        entries: [.oneLibrary: [1, 2, 3], .deviceLibrary: [3, 1, 2, 3]]),
            UsbPlaylist(id: 5, name: "폴더", attribute: 1, presentIn: both, sortOrder: [.oneLibrary: 2, .deviceLibrary: 2]),
            UsbPlaylist(id: 6, name: "폴더 안", parentID: 5, presentIn: both, sortOrder: [.oneLibrary: 0, .deviceLibrary: 0],
                        entries: [.oneLibrary: [3], .deviceLibrary: [3]]),
        ])
    }
}

@MainActor
@Suite("USB 편집 동작(UsbEditActions)")
struct UsbEditActionsTests {
    let image = FakeUsbVolume.diskImageFAT32(name: "B13T")
    let service = FakeUsbWriteService()
    let host = FakeUsbWriteHost()
    let prompter = ScriptedPrompter()
    let names = ScriptedNamePrompter()
    let drafts = FileManager.default.temporaryDirectory.appending(path: "djc-usbdrafts-\(UUID().uuidString)")

    var key: String { image.usbKey }

    func setUp(_ library: UsbLibrary = UsbTestData.library(), volumes: [UsbVolumeInfo]? = nil, local: LocalLibraryKeys? = nil,
               lists: UsbPhysicalLists.Loaded = UsbTestData.lists()) async -> (UsbStore, FakeUsbHost, UsbEditActions) {
        let usbHost = FakeUsbHost(volumes ?? [image])
        for volume in volumes ?? [image] { usbHost.serve(volume, library: library) }
        let usb = UsbTestData.store(usbHost, lists: lists, local: local)
        usb.writeService = service
        usb.draftDirectory = drafts
        service.update { $0.base = UsbEditTestData.base }
        await usb.refresh()
        var counter = 0
        let actions = UsbEditActions(usb: usb, host: host, prompter: prompter, namePrompter: names, newKey: {
            counter += 1
            return "k\(counter)"
        })
        return (usb, usbHost, actions)
    }

    func draft() throws -> UsbDraft? { try UsbDraftStore(directory: drafts).load(volumeKey: key) }

    func cleanUp() { try? FileManager.default.removeItem(at: drafts) }

    // MARK: - 초안 쌓기·빼기·버리기

    @Test("편집을 볼륨 초안에 차례로 쌓고(처음 편집 때 USB DB 지문이 base), 하나 빼기·초안 버리기를 한다")
    func draftAppendDiscard() async throws {
        defer { cleanUp() }
        let (usb, _, actions) = await setUp()
        let staged = UsbEditTestData.localRow("djc-1")
        let streaming = UsbEditTestData.localRow("77", folder: "spotify:x")
        await actions.addTracks([UsbEditTestData.localRow("11"), staged, streaming, UsbEditTestData.localRow("12")], to: .collection(volumeKey: key))
        #expect(host.toast?.title == "USB 쓰기 대기에 더했습니다")
        #expect(host.toast?.detail == "B13T · 곡 2개 더하기")
        let usbRows = UsbLibraryRows.collection(library: try #require(usb.libraries[key]), volumeKey: key, mountPoint: image.mountPoint, badges: [:])
        await actions.removeTracks([usbRows[1]], volumeKey: key)
        names.answers = ["새 목록"]
        await actions.createPlaylist(isFolder: false, parent: nil, volumeKey: key)
        #expect(names.asked.first?.title == "B13T에 새 재생 목록")

        let saved = try #require(try draft())
        #expect(saved.edits == [.addTracks(localContentIDs: ["11", "12"], playlist: nil), .removeTracks(usbContentIDs: [2]),
                                .playlist(edit: .create(key: "k1", name: "새 목록", isFolder: false, parent: .root))])
        #expect(saved.base == UsbEditTestData.base)
        // 지문은 처음 편집 때만 뜬다(메인 액터 밖, USB 쓰기 창구)
        #expect(service.current.calls == ["draftBase"])
        #expect(usb.draftCounts[key] == 3)
        #expect(UsbSidebarModel.volumes(usb).first { $0.id == key }?.pendingCount == 3)
        #expect(UsbSidebarModel.volumes(usb).first { $0.id == key }?.pending == .pending(volumeKey: key))

        // 이름 창을 취소하면 더하지 않는다
        names.answers = []
        await actions.createPlaylist(isFolder: true, parent: nil, volumeKey: key)
        #expect(usb.draftCounts[key] == 3)

        // 편집 하나 빼기(편집 번호 1부터)
        await actions.removeEdit(2, volumeKey: key)
        #expect(try draft()?.edits.count == 2)
        #expect(try draft()?.edits.last == .playlist(edit: .create(key: "k1", name: "새 목록", isFolder: false, parent: .root)))
        #expect(usb.draftCounts[key] == 2)

        // 초안 버리기는 확인을 받는다
        prompter.answer = false
        await actions.discardDraft(volumeKey: key)
        #expect(try draft() != nil)
        #expect(prompter.shown.last?.title == "USB 초안 2건을 버릴까요?")
        #expect(prompter.shown.last?.confirm == "버리기")
        #expect(prompter.shown.last?.destructive == true)
        prompter.answer = true
        await actions.discardDraft(volumeKey: key)
        #expect(try draft() == nil)
        #expect((usb.draftCounts[key] ?? 0) == 0)
    }

    // MARK: - 막힘 미리 판정

    @Test("막힐 편집은 메뉴 옆에 이유를 보인다: 실물 USB 곡 더하기, 두 형식 항목이 다른 목록, 폴더, 곡이 다 빠짐")
    func blockedEditHelpText() async throws {
        defer { cleanUp() }
        let physical = FakeUsbVolume.physicalFAT32()
        let library = UsbEditTestData.mixedLibrary()
        func reason(_ edit: UsbLibraryEdit, _ volume: UsbVolumeInfo) -> String? {
            UsbEditActions.blockReason(edit, volume: volume, library: library, info: nil)
        }
        let add = UsbLibraryEdit.addTracks(localContentIDs: ["11"], playlist: nil)
        #expect(reason(add, physical) == "USB 폴더 이름 규칙이 확인되지 않아 실물 USB에는 곡을 더할 수 없습니다")
        #expect(reason(add, image) == nil)
        #expect(reason(.removeTracks(usbContentIDs: [1]), physical) == "확인하지 않은 규칙(USB에서 곡 빼기)이 필요해 이 USB에 쓸 수 없습니다")
        #expect(reason(.removeTracks(usbContentIDs: [1]), image) == nil)
        let differ = "이 재생 목록은 두 형식의 곡 목록이 달라 곡을 고칠 수 없습니다. 이름·위치만 바꿀 수 있습니다"
        #expect(reason(.addTracks(localContentIDs: ["11"], playlist: .id("4")), image) == differ)
        #expect(reason(.playlist(edit: .addTracks(playlist: .id("4"), contentIDs: ["1"])), image) == differ)
        #expect(reason(.playlist(edit: .removeTracks(playlist: .id("4"), entries: [PlaylistEntry(trackNo: 1, contentID: "1")])), image) == differ)
        // 이름·위치는 바꿀 수 있다
        #expect(reason(.playlist(edit: .rename(playlist: .id("4"), name: "새 이름")), image) == nil)
        #expect(reason(.addTracks(localContentIDs: ["11"], playlist: .id("5")), image)
            == "폴더·인텔리전트 재생 목록에는 곡을 넣거나 뺄 수 없습니다. 일반 재생 목록을 고르세요")
        #expect(reason(.removeTracks(usbContentIDs: [1, 2, 3]), image) == "USB에 곡이 하나도 남지 않습니다. 곡을 남기거나 USB를 새로 내보내세요")
        #expect(reason(.playlist(edit: .delete(playlist: .id("99"))), image) == "대상이 USB에서 사라졌습니다. USB를 다시 읽은 뒤 고치세요")
        // 두 형식의 곡 번호가 다른 USB는 모든 편집을 막는다
        var info = UsbInfo(root: image.mountPoint)
        info.consistency = UsbInfo.Consistency(trackIDsMatch: false, editBlocked: true)
        #expect(UsbEditActions.blockReason(add, volume: image, library: library, info: info)
            == "두 형식의 곡 번호가 달라 고칠 수 없습니다. rekordbox에서 다시 내보내세요")

        // 곡 목록 메뉴 'USB에 넣기 ▸': 실물 볼륨의 항목은 이유를 달고 누를 수 없다
        let fixture = try historyFixture()
        let store = LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.usbedit.\(UUID())")!, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
        await store.load(snapshot: fixture.database)
        let (usb, _, _) = await setUp(library, volumes: [image, physical])
        store.usb = usb
        store.selection = ["101"]
        _ = NSApplication.shared
        let coordinator = TrackListCoordinator(store: store)
        let table = NSTableView()
        table.dataSource = coordinator
        table.delegate = coordinator
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        coordinator.table = table
        coordinator.update(rows: store.displayRows, edited: [], selection: store.selection, sortOrder: [], snapshotURL: store.snapshotURL,
                           previewRevision: 0)
        table.selectRowIndexes(IndexSet(integer: try #require(store.displayRows.firstIndex { $0.track.id == "101" })), byExtendingSelection: false)
        let menu = coordinator.makeMenu()
        coordinator.menuNeedsUpdate(menu)
        let usbMenu = try #require(menu.items.first { $0.title == "USB에 넣기" }?.submenu)
        let imageMenu = try #require(usbMenu.items.first { $0.title == "B13T" }?.submenu)
        let physicalMenu = try #require(usbMenu.items.first { $0.title == physical.name }?.submenu)
        let imageCollection = try #require(imageMenu.items.first { $0.title == "컬렉션" })
        #expect(imageCollection.action != nil && imageCollection.toolTip == nil)
        #expect(imageMenu.items.first { $0.title == "다름" }?.toolTip == differ)
        #expect(imageMenu.items.first { $0.title == "다름" }?.action == nil)
        // 폴더는 하위 메뉴로, 그 안의 목록은 누를 수 있다
        #expect(imageMenu.items.first { $0.title == "폴더" }?.submenu?.items.first { $0.title == "폴더 안" }?.action != nil)
        let physicalCollection = try #require(physicalMenu.items.first { $0.title == "컬렉션" })
        #expect(physicalCollection.action == nil)
        #expect(physicalCollection.toolTip == "USB 폴더 이름 규칙이 확인되지 않아 실물 USB에는 곡을 더할 수 없습니다")
        withExtendedLifetime(table) {}

        // 쓰기 금지 목록 볼륨은 초안 메뉴 자체를 보이지 않는다
        let denied = UsbTestData.lists(deny: [image.volumeUUID!.lowercased()])
        let (deniedUsb, _, deniedActions) = await setUp(library, lists: denied)
        #expect(deniedActions.targets.isEmpty)
        #expect(UsbSidebarModel.volumes(deniedUsb).first { $0.id == key }?.pending == nil)
        store.usb = deniedUsb
        let deniedMenu = coordinator.makeMenu()
        coordinator.menuNeedsUpdate(deniedMenu)
        #expect(!deniedMenu.items.contains { $0.title == "USB에 넣기" })
    }

    // MARK: - 볼륨이 빠져도 초안

    @Test("볼륨이 빠져 있어도 초안은 쌓이고 대기 목록이 남는다. 쓰기만 막힌다")
    func volumeAbsentStillDrafts() async throws {
        defer { cleanUp() }
        let (usb, usbHost, actions) = await setUp()
        await actions.addTracks([UsbEditTestData.localRow("11")], to: .playlist(volumeKey: key, id: 10))
        #expect(usb.draftCounts[key] == 1)
        usbHost.mounted = []
        await usb.refresh()
        #expect(usb.volume(key) == nil)
        #expect(usb.contains(.pending(volumeKey: key)))
        #expect(!usb.contains(.collection(volumeKey: key)))
        #expect(usb.title(for: .pending(volumeKey: key)) == "B13T · USB 쓰기 대기")

        // USB를 읽지 않고(지문도 뜨지 않고) 초안에 더한다
        await actions.append(.removeTracks(usbContentIDs: [3]), to: key)
        #expect(try draft()?.edits == [.addTracks(localContentIDs: ["11"], playlist: .id("10")), .removeTracks(usbContentIDs: [3])])
        #expect(service.current.calls == ["draftBase"])
        #expect(usb.draftCounts[key] == 2)
        // 사이드바: 연결 안 됨 + 대기 목록, 편집 대상에도 남는다(연결 안 됨)
        let row = try #require(UsbSidebarModel.volumes(usb).first { $0.id == key })
        #expect(row.status == "연결 안 됨")
        #expect(row.pending == .pending(volumeKey: key) && row.pendingCount == 2)
        #expect(row.collection == nil && !row.canEject)
        #expect(actions.targets.map(\.volumeKey) == [key])
        #expect(actions.targets.first?.isConnected == false)
        #expect(actions.blockReason(.removeTracks(usbContentIDs: [1]), volumeKey: key) == nil)

        // 쓰기만 막힌다: 미리 보기·쓰기를 부르지 않고 연결하라고 알린다
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter, isRekordboxRunning: { false })
        await coordinator.writeDraft(volumeKey: key, database: nil, share: nil)
        #expect(await coordinator.previewDraft(volumeKey: key, database: nil, share: nil) == nil)
        #expect(service.current.calls == ["draftBase"])
        #expect(prompter.shown.last?.text == "USB를 연결한 뒤 쓰세요")
        let model = UsbPendingModel(volumeName: "B13T", isConnected: false, edits: try #require(try draft()).edits,
                                    library: usb.editLibrary(key), summary: nil, busy: false, blockReason: { _ in nil })
        #expect(!model.canWrite)
        #expect(model.writeHelp == "USB를 연결한 뒤 쓰세요")

        // 다시 붙으면 대기 목록이 그 볼륨 아래로 돌아간다
        usbHost.mounted = [image]
        await usb.refresh()
        #expect(usb.volume(key) != nil)
        #expect(UsbSidebarModel.volumes(usb).filter { $0.id == key }.count == 1)
        #expect(UsbSidebarModel.volumes(usb).first { $0.id == key }?.status == nil)
        #expect(usb.draftCounts[key] == 2)
    }

    // MARK: - 끌어다 놓기

    @Test("로컬 곡을 USB 목록에 끌어다 놓으면 그 목록 끝에 넣는 곡 더하기 편집이 된다")
    func dragToUsbPlaylistCreatesAddTracksEdit() async throws {
        defer { cleanUp() }
        let (_, _, actions) = await setUp(UsbEditTestData.mixedLibrary())
        let rows = ["11": UsbEditTestData.localRow("11"), "12": UsbEditTestData.localRow("12"), "djc-9": UsbEditTestData.localRow("djc-9")]
        #expect(actions.acceptsDrop(on: .playlist(volumeKey: key, id: 10)))
        #expect(actions.acceptsDrop(on: .collection(volumeKey: key)))
        // 폴더·대기 목록·없는 목록에는 놓지 않는다
        #expect(!actions.acceptsDrop(on: .playlist(volumeKey: key, id: 5)))
        #expect(!actions.acceptsDrop(on: .pending(volumeKey: key)))
        #expect(!actions.acceptsDrop(on: .playlist(volumeKey: key, id: 99)))

        #expect(await actions.drop(["11", "djc-9", "12", "11", "usb:\(key):1", "없음"], on: .playlist(volumeKey: key, id: 10), rows: rows))
        #expect(try draft()?.edits == [.addTracks(localContentIDs: ["11", "12"], playlist: .id("10"))])
        #expect(host.toast?.detail == "B13T · 곡 2개 더하기 · ‘시험 목록’에 넣기")
        #expect(await actions.drop(["12"], on: .collection(volumeKey: key), rows: rows))
        #expect(try draft()?.edits.last == .addTracks(localContentIDs: ["12"], playlist: nil))
        // 막힐 목록(두 형식의 항목이 다름)이나 넣을 곡이 없으면 초안에 더하지 않는다
        #expect(await actions.drop(["11"], on: .playlist(volumeKey: key, id: 4), rows: rows) == false)
        #expect(host.toast?.kind == .warning)
        #expect(host.toast?.detail == "이 재생 목록은 두 형식의 곡 목록이 달라 곡을 고칠 수 없습니다. 이름·위치만 바꿀 수 있습니다")
        #expect(await actions.drop(["djc-9"], on: .playlist(volumeKey: key, id: 10), rows: rows) == false)
        #expect(try draft()?.edits.count == 2)
    }

    // MARK: - 로컬 변경 반영

    @Test("로컬 변경을 USB에 반영: 로컬이 더 새로운 곡만, 바뀐 부분만 갱신한다")
    func refreshLocalChangesOnlyUpdatable() async throws {
        defer { cleanUp() }
        let tracks = [
            UsbTestData.track(1, info: "3", analysis: "2", cue: "1"),
            UsbTestData.track(2, hasModified: 1),
            UsbTestData.track(3, masterContentId: 999),
            UsbTestData.track(4, info: "5", analysis: "5", cue: "5"),
            UsbTestData.track(5, info: "3", analysis: "2", cue: "1"),
        ]
        let local = LocalLibraryKeys(localDBID: UsbTestData.localDBID, tracks: [
            UsbLocalTrackKey(contentID: "11", masterSongID: "501", fileNameL: "test1.mp3"),
            UsbLocalTrackKey(contentID: "12", masterSongID: "502", fileNameL: "test2.mp3"),
            UsbLocalTrackKey(contentID: "14", masterSongID: "504", fileNameL: "test4.mp3"),
            UsbLocalTrackKey(contentID: "15", masterSongID: "505", fileNameL: "test5.mp3"),
        ], counters: [
            "11": LocalTrackCounters(information: "4", analysis: "2", cue: "1"),
            "12": LocalTrackCounters(information: "3", analysis: "2", cue: "1"),
            "14": LocalTrackCounters(information: "5", analysis: "5", cue: "5"),
            "15": LocalTrackCounters(information: "3", analysis: "3", cue: "2"),
        ])
        let (usb, _, actions) = await setUp(UsbTestData.library(tracks: tracks), local: local)
        #expect(actions.updatableTracks(volumeKey: key) == [1, 5])

        await actions.refreshLocalChanges(volumeKey: key)
        #expect(try draft()?.edits == [.refreshTracks(usbContentIDs: [1, 5], parts: [.info, .artwork, .grid, .cues])])
        #expect(host.toast?.detail == "B13T · 곡 2개 로컬 변경 반영")

        // 고른 곡만: 갱신할 곡이 없으면 더하지 않고 알린다
        let rows = UsbLibraryRows.collection(library: try #require(usb.libraries[key]), volumeKey: key, mountPoint: image.mountPoint,
                                             badges: usb.syncBadges[key] ?? [:])
        await actions.refreshLocalChanges(volumeKey: key, rows: [rows[1], rows[2], rows[3]])
        #expect(try draft()?.edits.count == 1)
        #expect(host.toast?.title == "로컬에서 더 고친 곡이 없습니다")
        await actions.refreshLocalChanges(volumeKey: key, rows: [rows[0], rows[1]])
        #expect(try draft()?.edits.last == .refreshTracks(usbContentIDs: [1], parts: [.info, .artwork]))
    }
}
