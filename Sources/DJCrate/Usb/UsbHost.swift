import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 사이드바가 USB를 보는 창구. 시험은 가짜로 바꾼다. 읽기는 모두 사본으로 한다(USB 위에서 SQLite를 열지 않는다).
@MainActor protocol UsbHost: AnyObject {
    /// 지금 연결된 볼륨(볼륨 정보만, 파일은 읽지 않는다)
    func volumes() -> [UsbVolumeInfo]
    /// 무엇이 든 USB인지·건강한지(`UsbRead.info`)
    func info(for volume: UsbVolumeInfo) async throws -> UsbInfo
    /// 사본을 떠서 두 형식을 읽어 합친 라이브러리(`UsbRead.library`)
    func library(for volume: UsbVolumeInfo) async throws -> UsbLibrary
    func eject(_ volume: UsbVolumeInfo) async throws
    /// 볼륨이 붙거나 떨어질 때마다 새 목록
    var volumeEvents: AsyncStream<[UsbVolumeInfo]> { get }
}

extension UsbVolumeInfo {
    /// 볼륨키: 볼륨 UUID(대문자, 쓰기·백업 폴더와 같은 키). UUID가 없으면 마운트 지점으로 만든다(사본 폴더 이름 한 성분이 되게 "/"를 뺀다)
    var usbKey: String {
        if let uuid = volumeUUID?.uppercased(), !uuid.isEmpty { return uuid }
        return "mount" + mountPoint.replacingOccurrences(of: "/", with: "_")
    }
}

/// 실제 USB: DiskArbitration으로 볼륨을 지켜보고, 읽기·꺼내기는 메인 액터 밖(분리된 작업)에서 한다.
@MainActor final class SystemUsbHost: UsbHost {
    /// 볼륨 하나를 다루는 입출력. 메인 액터 밖에서 부른다
    struct IO: Sendable {
        var info: @Sendable (UsbVolumeInfo) throws -> UsbInfo
        var library: @Sendable (UsbVolumeInfo) throws -> UsbLibrary
        var eject: @Sendable (UsbVolumeInfo) async throws -> Void

        /// 사본은 DJC_HOME 아래 `usb-snapshots/<볼륨키>/`에 뜬다
        static let system = IO.reading(snapshots: DJCPaths.usbSnapshots)

        /// 읽기 직전에 그 자리의 볼륨을 다시 보고(`recheck`, 기본 `UsbRead.currentVolume`) 그 새 정보로 사본을 뜬다.
        /// 사이드바가 들고 있던 정보는 앞선 훑기 때 것이라, 그 사이 같은 자리에 다른 볼륨이 붙었을 수 있다.
        static func reading(snapshots: URL,
                            recheck: @escaping @Sendable (UsbVolumeInfo) throws -> UsbVolumeInfo = { try UsbRead.currentVolume(matching: $0) }) -> IO {
            IO(info: { listed in
                   let volume = try recheck(listed)
                   let scratch = snapshots.appending(path: volume.usbKey).appending(path: "info-\(UUID().uuidString)")
                   return try UsbRead.info(root: URL(filePath: volume.mountPoint), scratch: scratch, volume: volume)
               },
               library: { listed in
                   let volume = try recheck(listed)
                   return try UsbRead.library(root: URL(filePath: volume.mountPoint), snapshots: snapshots, volumeKey: volume.usbKey,
                                              volume: volume).library
               },
               eject: { volume in try await UsbVolumeMonitor.eject(mountPoint: volume.mountPoint) })
        }
    }

    private let io: IO
    private let current: @Sendable () -> [UsbVolumeInfo]
    /// 지켜보기를 멈추지 않게 붙들어 둔다
    private let monitor: UsbVolumeMonitor?
    let volumeEvents: AsyncStream<[UsbVolumeInfo]>

    init(io: IO, events: AsyncStream<[UsbVolumeInfo]>, current: @escaping @Sendable () -> [UsbVolumeInfo], monitor: UsbVolumeMonitor? = nil) {
        self.io = io
        self.volumeEvents = events
        self.current = current
        self.monitor = monitor
    }

    /// DiskArbitration으로 지켜보는 호스트. 디스크 이미지만 읽는 실행은 실물 볼륨을 지켜보는 목록에도 넣지 않는다
    static func system(policy: UsbReadPolicy) -> SystemUsbHost {
        let monitor = UsbVolumeMonitor(diskImagesOnly: policy == .diskImagesOnly)
        return SystemUsbHost(io: .system, events: monitor.start(), current: { monitor.volumes }, monitor: monitor)
    }

    func volumes() -> [UsbVolumeInfo] { current() }

    func info(for volume: UsbVolumeInfo) async throws -> UsbInfo {
        let io = io
        return try await Task.detached(priority: .userInitiated) { try io.info(volume) }.value
    }

    func library(for volume: UsbVolumeInfo) async throws -> UsbLibrary {
        let io = io
        return try await Task.detached(priority: .userInitiated) { try io.library(volume) }.value
    }

    func eject(_ volume: UsbVolumeInfo) async throws {
        let io = io
        try await Task.detached(priority: .userInitiated) { try await io.eject(volume) }.value
    }
}

/// 앱 시작 때 사이드바 USB 절을 붙인다
@MainActor
enum UsbAppSetup {
    /// 실제 USB 호스트로 `UsbStore`를 만들어 붙이고 지켜보기를 시작한다. 로컬 짝짓기 키는 스냅샷을 읽을 때마다 뒤에서 다시 읽는다.
    /// 끝나지 않은 쓰기가 있는 볼륨이 나타나면 알림만 띄운다(회복은 사용자가 누를 때만)
    static func attach(to store: LibraryStore) {
        guard store.usb == nil else { return }
        let policy = UsbReadPolicy.current()
        let keys = LocalLibraryKeysCache()
        let service = SystemUsbWriteService.app()
        let usb = UsbStore(host: SystemUsbHost.system(policy: policy), readPolicy: policy, localLibrary: { keys.current },
                           journal: { service.journal(volumeKey: $0) })
        usb.writeService = service
        // 초안은 DJC_HOME 아래(시험 실행이 사용자 초안을 건드리지 않게)
        usb.draftDirectory = DJCPaths.usbDrafts
        usb.syncSelectionDirectory = DJCPaths.usbSyncSelections
        usb.onPendingJournal = { [weak store] volume in
            Task { await store?.usbCoordinator?.offerRecovery(volume) }
        }
        #if DEBUG
        // 시험 실행이 어떤 볼륨을 읽는지 로그로 확인한다(버퍼 없이 바로 쓴다)
        FileHandle.standardOutput.write(Data("USB 읽기 정책: \(policy.name)\n".utf8))
        #endif
        store.usb = usb
        store.onSnapshotLoaded = { [weak store, weak usb] _ in
            // 로드가 채택한 키를 쓴다. 뒤늦은 별도 파일 읽기가 더 새 사본의 키를 덮지 않게 한다.
            keys.set(store?.historyLocalKeys)
            Task { await usb?.localLibraryChanged() }
        }
        // 보존한 기록을 먼저 읽어 둔다(USB를 읽으면 그와 견줘 새 기록만 보존한다)
        connectHistories(store: store, usb: usb,
                         historyStore: UsbHistoryStore(directory: DJCPaths.usbHistories, home: DJCPaths.userData))
        Task { await usb.watch() }
    }

    /// USB 기기 재생 기록 보존(#43)을 잇는다: 보존한 기록을 읽고, USB 라이브러리를 읽거나 로컬 짝을 다시 계산할 때마다
    /// 새 기록을 DJCrate 데이터 폴더에 보존한다(USB·rekordbox 라이브러리에는 쓰지 않는다). 시험은 임시 폴더의 저장소로 같은 연결을 쓴다
    static func connectHistories(store: LibraryStore, usb: UsbStore, historyStore: UsbHistoryStore?) {
        store.usbHistoryStore = historyStore
        store.loadArchivedHistories()
        usb.onLibraryEvaluated = { [weak store] volume, library, matches in
            store?.importUsbHistories(volume: volume, library: library, matches: matches)
        }
    }
}

extension LibraryStore {
    /// 앱의 USB 쓰기 흐름(사이드바 USB 절이 붙은 뒤에만)
    var usbCoordinator: UsbWriteCoordinator? {
        usb.map { UsbWriteCoordinator(usb: $0, host: self, service: $0.writeService) }
    }
}
