@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Darwin
import Foundation
@testable import RekordboxKit
import Testing

/// 시험용 USB 호스트: 볼륨·읽기 결과는 지어낸 값만 돌려주고, 부른 횟수를 센다(실제 볼륨·지원 폴더를 읽지 않는다)
@MainActor
final class FakeUsbHost: UsbHost {
    var mounted: [UsbVolumeInfo]
    /// 볼륨키 → 읽기 결과(없으면 읽기 실패)
    var infos: [String: UsbInfo] = [:]
    var libraryResults: [String: UsbLibrary] = [:]
    var ejectError: (any Error)?
    private(set) var infoCalls: [String] = []
    private(set) var libraryCalls: [String] = []
    private(set) var ejectCalls: [String] = []
    let volumeEvents: AsyncStream<[UsbVolumeInfo]>
    let continuation: AsyncStream<[UsbVolumeInfo]>.Continuation

    init(_ mounted: [UsbVolumeInfo]) {
        self.mounted = mounted
        (volumeEvents, continuation) = AsyncStream.makeStream(of: [UsbVolumeInfo].self)
    }

    func volumes() -> [UsbVolumeInfo] { mounted }

    func info(for volume: UsbVolumeInfo) async throws -> UsbInfo {
        infoCalls.append(volume.usbKey)
        guard let info = infos[volume.usbKey] else { throw UsbError.readFailed(detail: "fake") }
        return info
    }

    func library(for volume: UsbVolumeInfo) async throws -> UsbLibrary {
        libraryCalls.append(volume.usbKey)
        guard let library = libraryResults[volume.usbKey] else { throw UsbError.readFailed(detail: "fake") }
        return library
    }

    func eject(_ volume: UsbVolumeInfo) async throws {
        ejectCalls.append(volume.usbKey)
        if let ejectError { throw ejectError }
        mounted.removeAll { $0.usbKey == volume.usbKey }
    }

    /// rekordbox USB 하나를 읽을 수 있게 둔다
    func serve(_ volume: UsbVolumeInfo, library: UsbLibrary) {
        infos[volume.usbKey] = UsbInfo(root: volume.mountPoint, formats: UsbFormat.allCases.filter(library.formats.contains).map(\.rawValue))
        libraryResults[volume.usbKey] = library
    }

    /// 빈 FAT32(라이브러리 없음)
    func serveEmpty(_ volume: UsbVolumeInfo) {
        infos[volume.usbKey] = UsbInfo(root: volume.mountPoint)
    }
}

/// 합성 USB 자료(곡 제목·경로·ID·DB ID는 모두 지어낸 값)
enum UsbTestData {
    static let otherUUID = "00000000-0000-0000-0000-00000000BEEF"
    static let localDBID: Int64 = 424_242

    static func lists(_ fixed: UsbDenyListStatus.State = .ok, entries: Int = 1, userData: UsbDenyListStatus.State = .missing,
                      deny: Set<String> = [otherUUID]) -> UsbPhysicalLists.Loaded {
        UsbPhysicalLists.Loaded(allow: [], deny: deny,
                                denyStatus: UsbDenyListStatus(fixedLocation: fixed, fixedEntryCount: entries, userData: userData),
                                allowState: .missing)
    }

    static func track(_ id: Int, formats: Set<UsbFormat> = UsbFormat.defaultSet, info: String = "3", analysis: String = "2",
                      cue: String = "1", hasModified: Int = 0, masterContentId: Int64? = nil) -> UsbTrack {
        UsbTrack(id: id, presentIn: formats, title: "시험 곡 \(id)", bpmx100: 12_800, lengthSeconds: 200, artistID: 1, keyID: 1,
                 path: "/Contents/시험 아티스트/test\(id).mp3", fileName: "test\(id).mp3",
                 masterDbId: localDBID, masterContentId: masterContentId ?? Int64(500 + id), hasModified: hasModified,
                 cueUpdateCount: cue, analysisDataUpdateCount: analysis, informationUpdateCount: info)
    }

    static func library(formats: Set<UsbFormat> = UsbFormat.defaultSet, tracks: [UsbTrack]? = nil,
                        playlists: [UsbPlaylist]? = nil) -> UsbLibrary {
        var library = UsbLibrary(formats: formats, property: UsbProperty(dbVersion: "1000"))
        library.tracks = tracks ?? [1, 2, 3].map { track($0, formats: formats) }
        library.artists = [UsbNamedRow(id: 1, name: "시험 아티스트")]
        library.keys = [UsbNamedRow(id: 1, name: "8A")]
        let sort = Dictionary(uniqueKeysWithValues: formats.map { ($0, 0) })
        let entries = Dictionary(uniqueKeysWithValues: formats.map { ($0, [2, 1, 2]) })
        library.playlists = playlists ?? [UsbPlaylist(id: 10, name: "시험 목록", presentIn: formats, sortOrder: sort, entries: entries)]
        return library
    }

    @MainActor
    static func store(_ host: FakeUsbHost, policy: UsbReadPolicy = .all, lists: UsbPhysicalLists.Loaded = UsbTestData.lists(),
                      local: LocalLibraryKeys? = nil) -> UsbStore {
        let store = UsbStore(host: host, readPolicy: policy, localLibrary: { local }, physicalLists: { lists })
        // 지어낸 디스크 이미지의 마운트 지점(/Volumes/…)은 없는 경로라, 편집 막힘 판정에서는 임시 폴더 아래 이미지로 본다
        store.isScratchMount = { _ in true }
        return store
    }
}

@MainActor
@Suite("USB 사이드바 상태(UsbStore)")
struct UsbStoreTests {
    // MARK: - 로컬 스냅샷 보호

    @Test("명시한 사본(--db·DJC_DB)으로 띄우면 사본 폴더가 없는 한 스냅샷을 뜨지 않는다")
    func explicitDatabaseNeverTakesSnapshot() async {
        #expect(!LibraryStore.snapshotTakeAllowed(arguments: ["--db", "/tmp/x/m.db"], environment: [:]))
        #expect(!LibraryStore.snapshotTakeAllowed(arguments: [], environment: ["DJC_DB": "/tmp/x/m.db"]))
        #expect(LibraryStore.snapshotTakeAllowed(arguments: ["--db", "/tmp/x/m.db"], environment: ["DJC_REKORDBOX_DIR": "/tmp/x/rb"]))
        #expect(LibraryStore.snapshotTakeAllowed(arguments: [], environment: [:]))
        #expect(!LibraryStore.snapshotTakeAllowed(arguments: ["--db", "/tmp/x/m.db"], environment: ["DJC_HOME": "/tmp/x/home"]))

        // 스냅샷을 뜨는 길(스냅샷 뜨기·창 복귀·곡 추가·빼기 미리 보기·복원 전 확인)이 모두 같은 판정으로 막힌다.
        // 라이브 master.db를 건드리지 않게 뜨기는 바꿔 넣고, 불린 횟수만 센다
        let store = LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.usbsnap.\(UUID())")!, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
        store.launchArguments = ["DJCrate", "--db", "/tmp/x/m.db"]
        store.launchEnvironment = ["DJC_HOME": "/tmp/x/home"]
        let taken = ThreadRecorder()
        store.takeLiveSnapshot = { _ in
            taken.record("take", main: false)
            throw CancellationError()
        }
        let refused = "명시한 사본(--db)으로 연 창에서는 스냅샷을 뜨지 않습니다. --db 없이 다시 여세요"
        func isRefusal(_ error: any Error) -> Bool {
            if case let DJCError.writeRefused(message)? = error as? DJCError { message == refused } else { false }
        }
        await store.takeSnapshot()
        if case let .failed(message) = store.phase { #expect(message == refused) } else { Issue.record("스냅샷 뜨기가 막히지 않음") }
        await store.refreshIfRekordboxChanged()
        await #expect(performing: { _ = try await store.previewTrackAdd(rows: []) }, throws: isRefusal)
        await #expect(performing: { _ = try await store.previewTrackDelete(rows: []) }, throws: isRefusal)
        #expect(store.writeStage == nil)
        let report = RekordboxWriter.Report(outcomes: [], backup: nil, dryRun: false, createdAt: "", finalUpdateCount: 1)
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/x/backup"), createdAt: .now, isWrite: true, report: report)
        #expect(await store.libraryChangedSince(backup) == nil)
        #expect(taken.calls.isEmpty)

        // 사본 rekordbox 폴더(DJC_REKORDBOX_DIR)로 띄웠으면 그 사본에서 뜬다(바꿔 넣은 뜨기가 불린다)
        store.launchEnvironment = ["DJC_REKORDBOX_DIR": "/tmp/x/rb"]
        #expect(await store.libraryChangedSince(backup) == nil)
        #expect(taken.calls.count == 1)
    }

    // MARK: - 읽기 정책

    @Test("임시 DJC_HOME·--usb-selftest로 띄운 디버그 실행은 디스크 이미지만 읽는다")
    func readPolicyDebugTempHomeIsDiskImagesOnly() {
        #expect(UsbReadPolicy.current(environment: ["DJC_HOME": "/private/tmp/x"], arguments: []) == .diskImagesOnly)
        #expect(UsbReadPolicy.current(environment: [:], arguments: ["DJCrate", "--usb-selftest"]) == .diskImagesOnly)
        #expect(UsbReadPolicy.current(environment: [:], arguments: []) == .all)
        #expect(UsbReadPolicy.current(environment: ["DJC_HOME": ""], arguments: ["DJCrate"]) == .all)
        #expect(UsbReadPolicy.diskImagesOnly.name == "diskImagesOnly")
    }

    @Test("디스크 이미지만 읽는 실행은 실물 볼륨을 목록에서 빼고 읽지 않는다")
    func diskImagesOnlySkipsPhysical() async {
        let image = FakeUsbVolume.diskImageFAT32()
        let physical = FakeUsbVolume.physicalFAT32()
        let host = FakeUsbHost([physical, image])
        host.serve(image, library: UsbTestData.library())
        host.serve(physical, library: UsbTestData.library())
        let store = UsbTestData.store(host, policy: .diskImagesOnly)
        await store.refresh()
        #expect(store.volumes.map(\.usbKey) == [image.usbKey])
        #expect(host.infoCalls == [image.usbKey])
        #expect(host.libraryCalls == [image.usbKey])
        #expect(store.shapes[physical.usbKey] == nil)
        #expect(store.shapes[image.usbKey] == .rekordbox(formats: UsbFormat.defaultSet))
    }

    // MARK: - 쓰기 금지 목록

    @Test("쓰기 금지 목록의 볼륨은 사본을 뜨지 않고 쓰기 금지 볼륨으로만 보인다")
    func deniedVolumeNotRead() async {
        let image = FakeUsbVolume.diskImageFAT32()
        let host = FakeUsbHost([image])
        host.serve(image, library: UsbTestData.library())
        let store = UsbTestData.store(host, lists: UsbTestData.lists(deny: [image.volumeUUID!.lowercased()]))
        await store.refresh()
        #expect(host.infoCalls.isEmpty && host.libraryCalls.isEmpty)
        #expect(store.refusals[image.usbKey] == "denylisted")
        #expect(store.shapes[image.usbKey] == .unsupported(reason: "쓰기 금지 목록의 USB라 읽지 않습니다"))
        #expect(store.libraries[image.usbKey] == nil)
    }

    @Test("쓰기 금지 목록 파일이 깨지면 실물은 하나도 읽지 않고 디스크 이미지만 읽는다")
    func corruptDenyListReadsNoPhysical() async {
        let image = FakeUsbVolume.diskImageFAT32()
        let physical = FakeUsbVolume.physicalFAT32()
        let host = FakeUsbHost([physical, image])
        host.serve(image, library: UsbTestData.library())
        host.serve(physical, library: UsbTestData.library())
        for lists in [UsbTestData.lists(.corrupt, entries: 0), UsbTestData.lists(.ok, entries: 1, userData: .corrupt)] {
            let store = UsbTestData.store(host, lists: lists)
            await store.refresh()
            #expect(!host.infoCalls.contains(physical.usbKey) && !host.libraryCalls.contains(physical.usbKey))
            guard case let .unsupported(reason)? = store.shapes[physical.usbKey] else {
                Issue.record("실물 볼륨이 막히지 않았다")
                continue
            }
            #expect(reason.hasPrefix("쓰기 금지 목록 파일을 읽을 수 없어"))
            #expect(store.shapes[image.usbKey] == .rekordbox(formats: UsbFormat.defaultSet))
        }
    }

    @Test("실물 볼륨은 쓰기 금지 목록이 등록돼 있을 때만 읽는다")
    func physicalReadRequiresDenyList() async {
        let image = FakeUsbVolume.diskImageFAT32()
        let physical = FakeUsbVolume.physicalFAT32()
        let notRegistered = "쓰기 금지 목록(증거용 USB)을 먼저 등록해야 실물 USB를 읽습니다"
        let cases: [(UsbPhysicalLists.Loaded, readsPhysical: Bool, reason: String?)] = [
            (UsbTestData.lists(.missing, entries: 0, deny: []), false, notRegistered),
            (UsbTestData.lists(.ok, entries: 0, deny: []), false, notRegistered),
            (UsbTestData.lists(.ok, entries: 1), true, nil),
            (UsbTestData.lists(.corrupt, entries: 0, deny: []), false, nil),
        ]
        for (lists, readsPhysical, reason) in cases {
            let host = FakeUsbHost([physical, image])
            host.serve(image, library: UsbTestData.library())
            host.serve(physical, library: UsbTestData.library())
            let store = UsbTestData.store(host, lists: lists)
            await store.refresh()
            #expect(host.infoCalls.contains(physical.usbKey) == readsPhysical)
            #expect(host.libraryCalls.contains(physical.usbKey) == readsPhysical)
            #expect(host.infoCalls.contains(image.usbKey) && host.libraryCalls.contains(image.usbKey))
            if let reason { #expect(store.shapes[physical.usbKey] == .unsupported(reason: reason)) }
            if readsPhysical { #expect(store.shapes[physical.usbKey] == .rekordbox(formats: UsbFormat.defaultSet)) }
        }
    }

    // MARK: - 갱신 상태

    @Test("로컬 곡과 견준 갱신 상태: 갱신 가능·기기에서 고침·로컬에 없음·최신")
    func syncBadges() async {
        let image = FakeUsbVolume.diskImageFAT32()
        let tracks = [
            UsbTestData.track(1, info: "3", analysis: "2", cue: "1"),
            UsbTestData.track(2, hasModified: 1),
            UsbTestData.track(3, masterContentId: 999),
            UsbTestData.track(4, info: "5", analysis: "5", cue: "5"),
        ]
        let local = LocalLibraryKeys(localDBID: UsbTestData.localDBID, tracks: [
            UsbLocalTrackKey(contentID: "11", masterSongID: "501", fileNameL: "test1.mp3"),
            UsbLocalTrackKey(contentID: "12", masterSongID: "502", fileNameL: "test2.mp3"),
            UsbLocalTrackKey(contentID: "14", masterSongID: "504", fileNameL: "test4.mp3"),
        ], counters: [
            "11": LocalTrackCounters(information: "4", analysis: "2", cue: "1"),
            "12": LocalTrackCounters(information: "3", analysis: "2", cue: "1"),
            "14": LocalTrackCounters(information: "5", analysis: "5", cue: "5"),
        ])
        let host = FakeUsbHost([image])
        host.serve(image, library: UsbTestData.library(tracks: tracks))
        let store = UsbTestData.store(host, local: local)
        await store.refresh()
        let badges = store.syncBadges[image.usbKey] ?? [:]
        #expect(badges[1] == .localNewer([.information]))
        #expect(badges[2] == .deviceModified)
        #expect(badges[3] == .missingLocal)
        #expect(badges[4] == .upToDate)
        #expect(UsbSyncText.text(.localNewer([.cue])) == "갱신 가능")
        #expect(UsbSyncText.text(.deviceModified) == "기기에서 고침")
        #expect(UsbSyncText.text(.missingLocal) == "로컬에 없음")
        #expect(UsbSyncText.text(.upToDate) == "최신")
        // 로컬 라이브러리를 모르면 배지를 달지 않는다
        let unknown = UsbTestData.store(host, local: nil)
        await unknown.refresh()
        #expect(unknown.syncBadges[image.usbKey]?.isEmpty ?? true)
    }

    // MARK: - 꺼내기

    @Test("꺼내지 못하면 할 일까지 적은 문구를 돌려주고, 꺼내면 목록에서 뺀다")
    func ejectFailureMessage() async {
        let image = FakeUsbVolume.diskImageFAT32()
        let host = FakeUsbHost([image])
        host.serveEmpty(image)
        let store = UsbTestData.store(host)
        await store.refresh()
        #expect(store.shapes[image.usbKey] == .emptyExportable)
        host.ejectError = UsbError.readFailed(detail: "busy")
        #expect(await store.eject(image.usbKey) == "USB를 꺼내지 못했습니다. 사용 중인 앱을 닫고 Finder에서 꺼내세요")
        #expect(store.volumes.count == 1)
        #expect(store.beginWrite(image, title: "시험") != nil)
        #expect(await store.eject(image.usbKey) != nil)
        #expect(host.ejectCalls.count == 1)
        store.endWrite(image.usbKey)
        host.ejectError = nil
        #expect(await store.eject(image.usbKey) == nil)
        #expect(store.volumes.isEmpty && store.shapes.isEmpty)
    }

    // MARK: - 로컬 짝짓기 키

    @Test("로컬 스냅샷 사본에서 DB ID·곡 키·갱신 횟수를 읽는다(지운 곡 제외)")
    func localLibraryKeysLoad() throws {
        let fixture = try RekordboxFixture()
        var first = TrackSpec(id: "71")
        first.cueUpdated = "4"
        first.analysisUpdated = "5"
        first.trackInfoUpdated = "6"
        try fixture.add(first)
        try fixture.add(TrackSpec(id: "72"))
        try fixture.add(TrackSpec(id: "73"))
        try fixture.execute("UPDATE djmdProperty SET DBID = '424242'")
        try fixture.execute("UPDATE djmdContent SET MasterSongID = '801', FileNameL = 'a.mp3' WHERE ID = '71'")
        try fixture.execute("UPDATE djmdContent SET MasterSongID = '802', FileNameL = 'b.mp3', CueUpdated = NULL WHERE ID = '72'")
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '73'")
        let database = try CipherDatabase(path: fixture.database.path, key: .hex(RekordboxKey.derive()), mode: .readOnly)
        defer { database.close() }
        let keys = try LocalLibraryKeys.load(database: database)
        #expect(keys.localDBID == 424_242)
        #expect(Set(keys.tracks) == [UsbLocalTrackKey(contentID: "71", masterSongID: "801", fileNameL: "a.mp3"),
                                     UsbLocalTrackKey(contentID: "72", masterSongID: "802", fileNameL: "b.mp3")])
        #expect(keys.counters["71"] == LocalTrackCounters(information: "6", analysis: "5", cue: "4"))
        #expect(keys.counters["72"]?.cue == nil)
        #expect(keys.counters["73"] == nil)
    }

    // MARK: - 백그라운드 읽기

    @Test("볼륨 읽기(정보·라이브러리)는 메인 스레드 밖에서 한다")
    func perVolumeReadIsBackground() async {
        let image = FakeUsbVolume.diskImageFAT32()
        let recorder = ThreadRecorder()
        let io = SystemUsbHost.IO(
            info: { volume in
                recorder.record("info", main: pthread_main_np() != 0)
                return UsbInfo(root: volume.mountPoint, formats: ["oneLibrary"])
            },
            library: { _ in
                recorder.record("library", main: pthread_main_np() != 0)
                return UsbTestData.library(formats: [.oneLibrary])
            },
            eject: { _ in })
        let (events, continuation) = AsyncStream.makeStream(of: [UsbVolumeInfo].self)
        let host = SystemUsbHost(io: io, events: events, current: { [image] })
        let store = UsbStore(host: host, readPolicy: .all, localLibrary: { nil }, physicalLists: { UsbTestData.lists() })
        await store.refresh()
        continuation.finish()
        #expect(store.shapes[image.usbKey] == .rekordbox(formats: [.oneLibrary]))
        #expect(recorder.calls == [ThreadRecorder.Call(name: "info", main: false), ThreadRecorder.Call(name: "library", main: false)])
    }

    @Test("읽기 직전에 그 자리의 볼륨을 다시 보고, 새 정보로 쓰기 금지 목록을 판정한다")
    func systemReadRechecksVolume() throws {
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        try UsbLibraryFixture().write(to: tree)
        let snapshots = FileManager.default.temporaryDirectory.appending(path: "djc-usbrecheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: snapshots) }
        // 목록을 훑을 때는 디스크 이미지였는데 읽기 직전 같은 자리에는 실물 볼륨이 붙어 있다(쓰기 금지 목록 미등록)
        var listed = FakeUsbVolume.diskImageFAT32()
        listed.mountPoint = tree.base.path
        var swapped = FakeUsbVolume.physicalFAT32()
        swapped.mountPoint = tree.base.path
        let unregistered = UsbTestData.lists(.missing, entries: 0)
        func refusal(_ body: () throws -> Void) -> String? {
            do { try body() } catch let UsbError.readFailed(detail) { return detail } catch { return "\(error)" }
            return nil
        }
        let stale = SystemUsbHost.IO.reading(snapshots: snapshots, lists: { unregistered }, recheck: { [swapped] _ in swapped })
        #expect(refusal { _ = try stale.info(listed) } == "denyListNotRegistered")
        #expect(refusal { _ = try stale.library(listed) } == "denyListNotRegistered")
        // 다시 보기가 볼륨이 바뀌었다고 하면 읽지 않는다
        let changed = SystemUsbHost.IO.reading(snapshots: snapshots, lists: { unregistered },
                                               recheck: { _ in throw UsbError.readFailed(detail: "volumeChanged") })
        #expect(refusal { _ = try changed.library(listed) } == "volumeChanged")
        #expect(!FileManager.default.fileExists(atPath: snapshots.path))
        // 같은 볼륨이면 그대로 사본을 떠서 읽는다
        let same = SystemUsbHost.IO.reading(snapshots: snapshots, lists: { unregistered }, recheck: { $0 })
        #expect(try same.library(listed).tracks.count == 3)
    }
}

/// 어느 스레드에서 불렸는지 모은다(여러 스레드에서 부른다)
final class ThreadRecorder: @unchecked Sendable {
    struct Call: Equatable {
        var name: String
        var main: Bool
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    func record(_ name: String, main: Bool) {
        lock.withLock { recorded.append(Call(name: name, main: main)) }
    }

    var calls: [Call] { lock.withLock { recorded } }
}
