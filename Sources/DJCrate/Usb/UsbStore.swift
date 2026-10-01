import DJCDomain
import DJCStorage
import Foundation
import Observation
import RekordboxKit

/// 사이드바 USB 절 상태: 연결된 볼륨마다 모양(빈 FAT32·rekordbox USB·쓸 수 없는 모양)과 사본으로 읽은 라이브러리.
/// 여기서는 USB에 쓰지 않는다. 읽기는 호스트가 메인 액터 밖에서 사본으로 하고, 여기서는 결과만 받는다.
/// 쓰기(`UsbWriteCoordinator`)가 쥐는 볼륨별 잠금·진행과, 끝나지 않은 쓰기가 있는 볼륨이 나타났다는 알림도 여기 둔다.
/// USB 초안(편집·빠진 볼륨의 초안)도 여기서 본다. 초안 파일은 `UsbEditActions`·초안 쓰기가 볼륨마다 한 줄(`draftQueue`)로 고친다.
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
    /// 볼륨별 잠금(쓰기 중 표시). 잠긴 볼륨은 다시 읽거나 꺼내지 않는다. `beginWrite`·`endWrite`로만 바꾼다
    private(set) var busyVolumes: Set<String> = []
    private(set) var ejecting: Set<String> = []
    /// 지금 쓰는 볼륨과 진행(덮개가 읽는다). 앱은 한 번에 한 볼륨에만 쓴다
    private(set) var activeWrite: UsbActiveWrite?
    /// 열 내보내기 시트(볼륨·다시 미리 보기 결과)
    var exportSheet: UsbExportSheetRequest?
    let readPolicy: UsbReadPolicy
    /// 볼륨키 → 초안 편집 수(없으면 nil)
    private(set) var draftCounts: [String: Int] = [:]
    /// 볼륨키 → 초안이 바뀐 횟수(쓰기 대기 목록이 초안을 다시 읽는다)
    private(set) var draftRevisions: [String: Int] = [:]
    /// 초안이 남은 채 빠진 볼륨(이번 실행에서 읽은 것만): 그때 볼륨 정보와 라이브러리. 다시 붙으면 뺀다
    private(set) var absentDrafts: [String: UsbAbsentVolume] = [:]
    /// USB 초안 폴더(`usb-drafts`). nil이면 초안을 다루지 않는다(시험·캡처의 기본 — 사용자 폴더를 읽지 않게)
    @ObservationIgnored var draftDirectory: URL?
    /// 볼륨키 → 초안 편집(파일에서 읽은 그대로). 순서 옮기기처럼 초안 위에서 판정하는 메뉴가 읽는다
    private(set) var draftEdits: [String: [UsbLibraryEdit]] = [:]
    /// 마운트 지점이 임시 폴더 뿌리 아래인지(realpath). 실물 쓰기가 닫힌 동안 그 밖의 디스크 이미지는 쓰기 때 막힌다(편집 막힘 미리 판정).
    /// 시험은 지어낸 마운트 지점을 넘긴다
    @ObservationIgnored var isScratchMount: (String) -> Bool = UsbEditActions.isScratchMount
    /// 볼륨키 → 초안 고치기 줄(읽고-고치고-쓰기가 겹쳐 편집을 잃지 않게, 누른 차례대로)
    @ObservationIgnored private var draftChains: [String: Task<Void, Never>] = [:]
    /// 볼륨키 → 그 줄에 선 일 수(돌고 있는 일 포함)
    @ObservationIgnored private var draftQueueLengths: [String: Int] = [:]

    /// 볼륨키 → 마지막 내보내기(다시 미리 보기에 쓴다)
    @ObservationIgnored var lastExports: [String: UsbExportJob] = [:]
    /// 앱의 USB 쓰기 창구(`LibraryStore.usbCoordinator`가 쓴다. 저널 알림과 같은 창구를 붙인다)
    @ObservationIgnored var writeService: any UsbWriteService = SystemUsbWriteService.app()
    /// 끝나지 않은 쓰기가 있는 볼륨이 나타났을 때. 알림만 띄운다 — 회복은 사용자가 누를 때만 한다
    @ObservationIgnored var onPendingJournal: ((UsbVolumeInfo) -> Void)?
    @ObservationIgnored private let host: any UsbHost
    @ObservationIgnored private let localLibrary: @Sendable () -> LocalLibraryKeys?
    @ObservationIgnored private let physicalLists: @Sendable () -> UsbPhysicalLists.Loaded
    @ObservationIgnored private let journal: @Sendable (String) -> UsbJournalInfo
    @ObservationIgnored private var cancelFlag: UsbCancelFlag?
    /// 이번에 붙어 있는 동안 저널을 본 볼륨(떨어지면 지운다: 다시 나타나면 또 본다)
    @ObservationIgnored private var journalChecked: Set<String> = []
    /// 목록·라이브러리·배지가 바뀐 뒤(보고 있는 USB 목록을 다시 만든다)
    @ObservationIgnored var onChange: (() -> Void)?
    /// 다 읽은 볼륨의 그때 정보(같으면 알림 때 다시 읽지 않는다)
    @ObservationIgnored private var readVolumes: [String: UsbVolumeInfo] = [:]
    /// 새로 읽기를 한 줄로 세운다(알림과 새로고침이 겹쳐도 차례로)
    @ObservationIgnored private var chain: Task<Void, Never>?

    /// - localLibrary: 로컬 짝짓기 키(앱이 연 스냅샷에서 미리 읽어 둔 값). 메인 액터 밖에서 부른다
    /// - physicalLists: 쓰기 금지·허용 목록 상태(시험은 가짜 값). 메인 액터 밖에서 부른다
    /// - journal: 볼륨키 → 그 볼륨의 쓰기 저널 상태(앱은 `UsbWriteService.journal`, 기본은 저널을 보지 않는다). 메인 액터 밖에서 부른다
    init(host: any UsbHost, readPolicy: UsbReadPolicy = .current(), localLibrary: @escaping @Sendable () -> LocalLibraryKeys?,
         physicalLists: @escaping @Sendable () -> UsbPhysicalLists.Loaded = { UsbPhysicalLists.load() },
         journal: @escaping @Sendable (String) -> UsbJournalInfo = { _ in .none }) {
        self.host = host
        self.readPolicy = readPolicy
        self.localLibrary = localLibrary
        self.physicalLists = physicalLists
        self.journal = journal
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
        let previous = volumes
        volumes = visible
        let keys = Set(visible.map(\.usbKey))
        // 초안이 있는 볼륨은 빠져도 쓰기 대기 목록을 남긴다(다시 붙으면 그 볼륨 아래로 돌아간다)
        for volume in previous where !keys.contains(volume.usbKey) { rememberDraft(volume) }
        for key in keys { absentDrafts[key] = nil }
        for key in Set(shapes.keys).union(refusals.keys).subtracting(keys) {
            forget(key)
            shapes[key] = nil
            refusals[key] = nil
        }
        journalChecked.formIntersection(keys)
        // 연 내보내기 시트의 볼륨이 빠지면 닫는다(닫을 단추 없는 빈 창으로 남지 않게)
        if let sheet = exportSheet, !keys.contains(sheet.volumeKey) { exportSheet = nil }
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
            await checkJournal(volume)
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
                await reloadDraft(key)
            }
            readVolumes[key] = volume
        } catch {
            forget(key)
            shapes[key] = .failed(Self.message(for: error))
        }
    }

    /// 읽는 볼륨이 나타나면 한 번 저널을 본다. 끝나지 않은 쓰기(닫힌 상태가 아닌 저널)만 알린다 — 드라이 런·다시 계획은 닫힌 상태다
    private func checkJournal(_ volume: UsbVolumeInfo) async {
        let key = volume.usbKey
        guard journalChecked.insert(key).inserted else { return }
        let journal = journal
        let info = await Task.detached(priority: .utility) { journal(key) }.value
        // 기다리는 동안 떨어졌거나 쓰기가 시작됐으면 알리지 않는다
        guard info.isPending, journalChecked.contains(key), !busyVolumes.contains(key), self.volume(key) != nil else { return }
        onPendingJournal?(volume)
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
        rememberDraft(volume)
        volumes.removeAll { $0.usbKey == volumeKey }
        journalChecked.remove(volumeKey)
        forget(volumeKey)
        shapes[volumeKey] = nil
        refusals[volumeKey] = nil
        if exportSheet?.volumeKey == volumeKey { exportSheet = nil }
        onChange?()
        return nil
    }

    // MARK: - 초안

    /// 초안 편집을 받는 볼륨: 읽은 rekordbox USB(다시 읽는 중 포함, 볼륨 번호가 있어야 한다)와 초안이 남은 채 빠진 볼륨.
    /// 쓰기 금지 목록·읽지 못한 볼륨은 받지 않는다(초안 메뉴 자체를 보이지 않는다)
    func acceptsEdits(_ key: String) -> Bool {
        guard draftDirectory != nil, refusals[key] == nil else { return false }
        if let volume = volume(key) {
            return libraries[key] != nil && (try? UsbEditSession.volumeKey(volume)) == key
        }
        return absentDrafts[key] != nil
    }

    /// 편집 대상 볼륨 이름(빠진 볼륨도)
    func editName(_ key: String) -> String? { volume(key)?.name ?? absentDrafts[key]?.volume.name }

    /// 편집 대상 라이브러리(빠진 볼륨은 마지막으로 읽은 것)
    func editLibrary(_ key: String) -> UsbLibrary? { libraries[key] ?? absentDrafts[key]?.library }

    /// 그 볼륨의 초안 고치기를 한 줄로 세운다: 앞서 넣은 일이 끝난 뒤에 body를 돌린다(볼륨마다 따로).
    /// 초안 파일을 읽고 고쳐 쓰는 일(편집 더하기·빼기·버리기, 초안 쓰기)과 편집 수 다시 읽기는 모두 이 줄로 한다.
    /// body 안에서 같은 볼륨의 줄을 다시 기다리지 않는다(스스로를 기다려 멈춘다)
    func draftQueue<T: Sendable>(_ key: String, _ body: @escaping @MainActor () async -> T) async -> T {
        let previous = draftChains[key]
        draftQueueLengths[key, default: 0] += 1
        let task = Task { @MainActor () -> T in
            await previous?.value
            let value = await body()
            let left = (draftQueueLengths[key] ?? 1) - 1
            draftQueueLengths[key] = left > 0 ? left : nil
            return value
        }
        draftChains[key] = Task { _ = await task.value }
        return await task.value
    }

    /// 그 볼륨의 초안 줄에 선 일 수(돌고 있는 일 포함). 시험이 뒤 일이 줄에 선 것을 시간 대신 이것으로 기다린다
    func draftQueueLength(_ key: String) -> Int { draftQueueLengths[key] ?? 0 }

    /// 그 볼륨의 초안을 다시 읽는다(메인 액터 밖에서 파일을 읽는다)
    func reloadDraft(_ key: String) async {
        guard let directory = draftDirectory else { return }
        await draftQueue(key) { [weak self] in
            let edits = await Task.detached(priority: .utility) { () -> [UsbLibraryEdit] in
                ((try? UsbDraftStore(directory: directory).load(volumeKey: key)) ?? nil)?.edits ?? []
            }.value
            self?.setDraft(edits, for: key)
        }
    }

    /// 초안이 바뀌었다(편집 동작·쓰기 뒤). 빠진 볼륨의 초안이 비면 사이드바에서 뺀다
    func setDraft(_ edits: [UsbLibraryEdit], for key: String) {
        let count = edits.count
        draftEdits[key] = edits.isEmpty ? nil : edits
        draftCounts[key] = count > 0 ? count : nil
        draftRevisions[key, default: 0] += 1
        if count == 0, absentDrafts[key] != nil {
            absentDrafts[key] = nil
            // 그 볼륨의 쓰기 대기 목록을 보던 중이면 라이브러리로 돌아간다
            onChange?()
        }
    }

    /// 빠지는 볼륨에 초안이 있으면 기억한다(쓰기 금지 목록 볼륨은 빼고)
    private func rememberDraft(_ volume: UsbVolumeInfo) {
        let key = volume.usbKey
        guard draftDirectory != nil, (draftCounts[key] ?? 0) > 0, refusals[key] == nil, libraries[key] != nil,
              (try? UsbEditSession.volumeKey(volume)) == key else { return }
        absentDrafts[key] = UsbAbsentVolume(volume: volume, library: libraries[key])
    }

    // MARK: - 쓰기 잠금·진행

    /// 볼륨을 잠그고 쓰기를 시작한다. 그 볼륨이 이미 잠겼거나 다른 볼륨에 쓰는 중이면 nil.
    /// 잠근 볼륨은 다시 읽기·꺼내기·끝나지 않은 쓰기 알림에서 빠진다
    /// - cancellable: 취소를 받는 일인지(회복·되돌리기는 받지 않는다)
    func beginWrite(_ volume: UsbVolumeInfo, title: String, cancellable: Bool = true) -> UsbCancelFlag? {
        let key = volume.usbKey
        guard !busyVolumes.contains(key), activeWrite == nil else { return nil }
        busyVolumes.insert(key)
        // 이 쓰기가 연 저널을 "나타난 볼륨의 끝나지 않은 쓰기"로 다시 알리지 않는다(다시 붙이면 본다)
        journalChecked.insert(key)
        let flag = UsbCancelFlag()
        cancelFlag = flag
        activeWrite = UsbActiveWrite(volumeKey: key, volumeName: volume.name, title: title, cancellable: cancellable, progress: nil)
        return flag
    }

    /// 덮개 제목(미리 보기 → 쓰기처럼 단계가 바뀔 때)
    func setWriteTitle(_ title: String, for key: String) {
        guard activeWrite?.volumeKey == key else { return }
        activeWrite?.title = title
        activeWrite?.progress = nil
    }

    /// 쓰기 절차의 진행. 지금 쓰는 볼륨의 것만 받는다
    func report(_ progress: UsbProgress, for key: String) {
        guard activeWrite?.volumeKey == key else { return }
        activeWrite?.progress = progress
    }

    func endWrite(_ key: String) {
        busyVolumes.remove(key)
        guard activeWrite?.volumeKey == key else { return }
        activeWrite = nil
        cancelFlag = nil
    }

    /// 취소를 청한다. 취소를 받지 않는 일이거나 DB 교체가 시작된 뒤(`cancellable == false`)에는 받지 않는다
    func cancelWrite() {
        guard let cancelFlag, let activeWrite, activeWrite.cancellable, activeWrite.progress?.cancellable != false else { return }
        cancelFlag.set()
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

    /// 대상이 아직 보이는지(볼륨이 빠지거나 목록이 없어지면 거짓). 쓰기 대기 목록은 초안이 남은 채 빠진 볼륨에도 있다
    func contains(_ target: UsbSidebarTarget) -> Bool {
        if case let .pending(key) = target { return acceptsEdits(key) }
        guard volume(target.volumeKey) != nil else { return false }
        switch target {
        case .collection: return libraries[target.volumeKey] != nil || shapes[target.volumeKey] == .reading
        case let .playlist(key, id): return libraries[key]?.playlists.contains { $0.id == id } ?? (shapes[key] == .reading)
        case .pending: return false
        }
    }

    /// 목록 제목
    func title(for target: UsbSidebarTarget) -> String {
        let name = editName(target.volumeKey) ?? "USB"
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
    /// USB 쓰기 대기(그 볼륨의 초안)
    case pending(volumeKey: String)

    var volumeKey: String {
        switch self {
        case let .collection(key), let .playlist(key, _), let .pending(key): key
        }
    }
}

/// 초안이 남은 채 빠진 볼륨: 빠질 때의 정보와 마지막으로 읽은 라이브러리
struct UsbAbsentVolume: Equatable {
    var volume: UsbVolumeInfo
    var library: UsbLibrary?
}

/// 지금 쓰는 볼륨과 진행
struct UsbActiveWrite: Equatable {
    var volumeKey: String
    var volumeName: String
    /// 덮개 제목(미리 보기·쓰기·회복·되돌리기)
    var title: String
    /// 취소를 받는 일인지(내보내기만)
    var cancellable: Bool
    var progress: UsbProgress?
}

/// 내보내기 시트를 열 때 넘기는 것: 대상 볼륨(연 때의 정보)과, 다시 미리 보기면 그 내보내기·요약
struct UsbExportSheetRequest: Equatable, Identifiable {
    var volume: UsbVolumeInfo
    var job: UsbExportJob?
    var summary: UsbExportSummary?

    var volumeKey: String { volume.usbKey }
    var id: String { volumeKey }
}
