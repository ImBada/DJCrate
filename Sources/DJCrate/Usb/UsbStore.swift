import DJCDomain
import DJCStorage
import Foundation
import Observation
import RekordboxKit

/// 사이드바 USB 절 상태: 연결된 볼륨마다 모양(빈 FAT32·rekordbox USB·쓸 수 없는 모양)과 사본으로 읽은 라이브러리.
/// USB에는 쓰지 않는다. 읽기는 호스트가 메인 액터 밖에서 사본으로 하고, 여기서는 결과만 받는다.
@MainActor @Observable final class UsbStore {
    enum Shape: Equatable {
        /// 내보낼 수 있는 빈 FAT32·MBR(rekordbox 라이브러리 없음)
        case emptyExportable
        case rekordbox(formats: Set<UsbFormat>)
        /// 읽지 않았다(볼륨 모양·쓰기 금지 목록). 이유와 할 일
        case unsupported(reason: String)
        case reading
        case failed(String)

        /// 다시 읽을 필요가 없는 결과
        var isSettled: Bool {
            switch self {
            case .emptyExportable, .rekordbox: true
            case .unsupported, .reading, .failed: false
            }
        }
    }

    private(set) var volumes: [UsbVolumeInfo] = []
    /// 볼륨키 → 모양
    private(set) var shapes: [String: Shape] = [:]
    private(set) var libraries: [String: UsbLibrary] = [:]
    private(set) var infos: [String: UsbInfo] = [:]
    /// 볼륨키 → 읽기 막힘 code(`UsbRead.readRefusal`)
    private(set) var refusals: [String: String] = [:]
    /// 볼륨키 → content_id → 상태
    private(set) var syncBadges: [String: [Int: UsbSyncStatus]] = [:]
    /// 볼륨별 잠금(쓰기 중 표시). 잠긴 볼륨은 다시 읽거나 꺼내지 않는다
    var busyVolumes: Set<String> = []
    private(set) var ejecting: Set<String> = []
    let readPolicy: UsbReadPolicy

    @ObservationIgnored private let host: any UsbHost
    @ObservationIgnored private let localLibrary: @Sendable () -> LocalLibraryKeys?
    @ObservationIgnored private let physicalLists: @Sendable () -> UsbPhysicalLists.Loaded
    /// 목록·라이브러리·배지가 바뀐 뒤(보고 있는 USB 목록을 다시 만든다)
    @ObservationIgnored var onChange: (() -> Void)?
    /// 다 읽은 볼륨의 그때 정보(같으면 알림 때 다시 읽지 않는다)
    @ObservationIgnored private var readVolumes: [String: UsbVolumeInfo] = [:]
    /// 새로 읽기를 한 줄로 세운다(알림과 새로고침이 겹쳐도 차례로)
    @ObservationIgnored private var chain: Task<Void, Never>?

    /// - localLibrary: 로컬 짝짓기 키(앱이 연 스냅샷에서 미리 읽어 둔 값). 메인 액터 밖에서 부른다
    /// - physicalLists: 쓰기 금지·허용 목록 상태(시험은 가짜 값). 메인 액터 밖에서 부른다
    init(host: any UsbHost, readPolicy: UsbReadPolicy = .current(), localLibrary: @escaping @Sendable () -> LocalLibraryKeys?,
         physicalLists: @escaping @Sendable () -> UsbPhysicalLists.Loaded = { UsbPhysicalLists.load() }) {
        self.host = host
        self.readPolicy = readPolicy
        self.localLibrary = localLibrary
        self.physicalLists = physicalLists
    }

    // MARK: - 읽기

    /// 볼륨을 모두 다시 본다(이미 읽은 USB도 다시 사본을 떠서 읽는다)
    func refresh() async {
        await enqueue(force: true)
    }

    /// 볼륨이 붙거나 떨어질 때마다 새로 본다. 새 볼륨·바뀐 볼륨만 읽는다
    func watch() async {
        await enqueue(force: false)
        for await _ in host.volumeEvents {
            await enqueue(force: false)
        }
    }

    private func enqueue(force: Bool) async {
        let previous = chain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.update(force: force)
        }
        chain = task
        await task.value
    }

    private func update(force: Bool) async {
        let all = host.volumes()
        // 시험 실행은 실물 볼륨을 이름도 보이지 않게 뺀다(화면 캡처에 남지 않게)
        let visible = (readPolicy == .diskImagesOnly ? all.filter(\.isDiskImage) : all).sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.mountPoint < rhs.mountPoint : order == .orderedAscending
        }
        volumes = visible
        let keys = Set(visible.map(\.usbKey))
        for key in Set(shapes.keys).union(refusals.keys).subtracting(keys) {
            forget(key)
            shapes[key] = nil
            refusals[key] = nil
        }
        defer { onChange?() }
        guard !visible.isEmpty else { return }
        let lists = await Task.detached(priority: .userInitiated) { [physicalLists] in physicalLists() }.value
        for volume in visible {
            let key = volume.usbKey
            guard !busyVolumes.contains(key) else { continue }
            // 쓰기 금지 목록 판정이 먼저다: 막힌 볼륨은 모양 판정도 사본 뜨기도 하지 않는다
            if let code = UsbRead.readRefusal(volume: volume, lists: lists) {
                forget(key)
                refusals[key] = code
                shapes[key] = .unsupported(reason: UsbRead.refusalMessage(code))
                continue
            }
            refusals[key] = nil
            if let problem = UsbVolumePolicy.problems(volume, purpose: .export).first {
                forget(key)
                shapes[key] = .unsupported(reason: problem.message)
                continue
            }
            if !force, readVolumes[key] == volume, shapes[key]?.isSettled == true { continue }
            await read(volume)
        }
    }

    private func read(_ volume: UsbVolumeInfo) async {
        let key = volume.usbKey
        // 다시 읽는 동안에도 앞서 읽은 라이브러리는 보여 두고, 새 결과가 오면 한 번에 바꾼다
        shapes[key] = .reading
        do {
            let info = try await host.info(for: volume)
            let formats = Set(info.formats.compactMap(UsbFormat.init(rawValue:)))
            if formats.isEmpty {
                forget(key)
                infos[key] = info
                shapes[key] = .emptyExportable
            } else {
                let library = try await host.library(for: volume)
                let badges = await badges(for: library)
                infos[key] = info
                libraries[key] = library
                syncBadges[key] = badges
                shapes[key] = .rekordbox(formats: formats)
            }
            readVolumes[key] = volume
        } catch {
            forget(key)
            shapes[key] = .failed(Self.message(for: error))
        }
    }

    private func forget(_ key: String) {
        libraries[key] = nil
        infos[key] = nil
        syncBadges[key] = nil
        readVolumes[key] = nil
    }

    /// 로컬 스냅샷을 새로 읽었을 때 배지만 다시 계산한다
    func localLibraryChanged() async {
        for (key, library) in libraries {
            let badges = await badges(for: library)
            // 기다리는 동안 볼륨이 빠졌거나 다시 읽혔으면 버린다
            if libraries[key] == library { syncBadges[key] = badges }
        }
        onChange?()
    }

    private func badges(for library: UsbLibrary) async -> [Int: UsbSyncStatus] {
        let localLibrary = localLibrary
        return await Task.detached(priority: .utility) { UsbSyncBadges.compute(library: library, local: localLibrary()) }.value
    }

    static func message(for error: any Error) -> String {
        if case let UsbError.readFailed(detail)? = error as? UsbError, UsbRead.refusalCodes.contains(detail) {
            return UsbRead.refusalMessage(detail)
        }
        AppErrorMessage.log(error)
        if let error = error as? UsbError, let description = error.errorDescription { return description }
        return String(ui: "USB 라이브러리를 읽지 못했습니다. USB를 다시 연결한 뒤 다시 시도하세요")
    }

    // MARK: - 꺼내기

    /// 볼륨을 꺼낸다. 실패하면 이유와 할 일(nil = 성공)
    func eject(_ volumeKey: String) async -> String? {
        guard let volume = volumes.first(where: { $0.usbKey == volumeKey }) else { return nil }
        guard !busyVolumes.contains(volumeKey) else { return String(ui: "USB에 쓰는 중입니다. 쓰기가 끝난 뒤 꺼내세요") }
        guard !ejecting.contains(volumeKey) else { return nil }
        ejecting.insert(volumeKey)
        defer { ejecting.remove(volumeKey) }
        do {
            try await host.eject(volume)
        } catch {
            AppErrorMessage.log(error)
            return String(ui: "USB를 꺼내지 못했습니다. 사용 중인 앱을 닫고 Finder에서 꺼내세요")
        }
        // 떨어짐 알림을 기다리지 않고 바로 뺀다
        volumes.removeAll { $0.usbKey == volumeKey }
        forget(volumeKey)
        shapes[volumeKey] = nil
        refusals[volumeKey] = nil
        onChange?()
        return nil
    }

    // MARK: - 목록 줄

    func volume(_ key: String) -> UsbVolumeInfo? { volumes.first { $0.usbKey == key } }

    /// 사이드바 대상의 곡 줄(읽기 전용)
    func rows(for target: UsbSidebarTarget) -> [TrackRow] {
        guard let volume = volume(target.volumeKey), let library = libraries[target.volumeKey] else { return [] }
        let badges = syncBadges[target.volumeKey] ?? [:]
        switch target {
        case .collection:
            return UsbLibraryRows.collection(library: library, volumeKey: target.volumeKey, mountPoint: volume.mountPoint, badges: badges)
        case let .playlist(_, id):
            return UsbLibraryRows.playlist(id, library: library, volumeKey: target.volumeKey, mountPoint: volume.mountPoint, badges: badges)
        case .pending:
            return []
        }
    }

    /// 대상이 아직 보이는지(볼륨이 빠지거나 목록이 없어지면 거짓)
    func contains(_ target: UsbSidebarTarget) -> Bool {
        guard volume(target.volumeKey) != nil else { return false }
        switch target {
        case .collection: return libraries[target.volumeKey] != nil || shapes[target.volumeKey] == .reading
        case let .playlist(key, id): return libraries[key]?.playlists.contains { $0.id == id } ?? (shapes[key] == .reading)
        case .pending: return true
        }
    }

    /// 목록 제목
    func title(for target: UsbSidebarTarget) -> String {
        let name = volume(target.volumeKey)?.name ?? "USB"
        switch target {
        case .collection: return String(ui: "\(name) · 컬렉션")
        case let .playlist(key, id): return libraries[key]?.playlists.first { $0.id == id }?.name ?? name
        case .pending: return String(ui: "\(name) · USB 쓰기 대기")
        }
    }
}

/// 사이드바 USB 절에서 고르는 대상
public enum UsbSidebarTarget: Hashable, Sendable {
    case collection(volumeKey: String)
    case playlist(volumeKey: String, id: Int)
    /// USB 쓰기 대기(뒤 판에서 쓴다)
    case pending(volumeKey: String)

    var volumeKey: String {
        switch self {
        case let .collection(key), let .playlist(key, _), let .pending(key): key
        }
    }
}
