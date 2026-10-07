import AppKit
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 앱의 USB 내보내기 한 번: 로컬 스냅샷 사본의 목록·곡을 어느 볼륨에 어떤 형식으로
struct UsbExportJob: Sendable, Equatable {
    /// 로컬 스냅샷 사본(라이브 master.db는 세션이 거부한다)
    var database: URL
    /// 로컬 rekordbox share(읽기만)
    var share: URL
    var volume: UsbVolumeInfo
    var selection: UsbSelection
    var formats: Set<UsbFormat>
    /// ISO 8601 스냅샷 시각(nil이면 사본 이름 → mtime)
    var snapshotTime: String?

    var volumeKey: String { volume.usbKey }
    var root: URL { URL(filePath: volume.mountPoint) }

    var options: UsbExportOptions {
        var options = UsbExportOptions()
        options.formats = formats
        options.snapshotTime = snapshotTime
        // 앱은 쓰기 확인 창(볼륨 이름을 보인다)이 CLI의 --confirm을 대신하고, 확인한 볼륨의 UUID를 넘긴다
        options.confirmName = volume.name
        options.expectedVolumeUUID = SystemUsbWriteService.confirmedUUID(volume)
        return options
    }
}

/// 볼륨 쓰기 저널 상태. 닫힌 상태(`UsbJournal.closedStates`)가 아닌 저널만 끝나지 않은 쓰기로 본다
enum UsbJournalInfo: Equatable, Sendable {
    case none
    case state(UsbJournal.State)
    /// 저널 파일을 읽지 못함(쓰기·회복 모두 막힌다)
    case unreadable

    /// 끝나지 않은 쓰기. 드라이 런·다시 계획은 닫힌 상태라 알리지 않는다
    var isPending: Bool {
        if case let .state(state) = self { !UsbJournal.closedStates.contains(state) } else { false }
    }
}

/// 코디네이터가 USB 쓰기 절차에 닿는 창구. 모두 메인 액터 밖에서 부른다. 앱은 `SystemUsbWriteService`, 시험은 가짜
protocol UsbWriteService: Sendable {
    func journal(volumeKey: String) -> UsbJournalInfo
    /// 계획·막힘·준비까지(USB에 쓰지 않는다)
    func preview(_ job: UsbExportJob) throws -> UsbExportSummary
    func write(_ job: UsbExportJob, progress: @escaping @Sendable (UsbProgress) -> Void,
               isCancelled: @escaping @Sendable () -> Bool) throws -> UsbWriteReport
    func previewMigration(_ volume: UsbVolumeInfo) throws -> UsbMigrationSummary
    func writeMigration(_ volume: UsbVolumeInfo, progress: @escaping @Sendable (UsbProgress) -> Void,
                        isCancelled: @escaping @Sendable () -> Bool) throws -> UsbMigrationWritten
    func recover(_ volume: UsbVolumeInfo) throws -> UsbWriteReport
    /// backup: 되돌릴 쓰기의 백업 폴더(nil이면 이 볼륨의 가장 최근 백업)
    func restore(_ volume: UsbVolumeInfo, backup: URL?, discardDeviceChanges: Bool) throws -> UsbWriteReport
    /// 이 볼륨의 가장 최근 백업 폴더(실패 알림의 "백업 폴더 열기")
    func latestBackup(volumeKey: String) -> URL?
    /// 초안을 처음 만들 때의 base: 지금 USB DB 지문(DB 파일의 크기·해시만 읽는다)
    func draftBase(_ volume: UsbVolumeInfo) throws -> UsbFingerprint
    /// 이 볼륨 초안의 계획·막힘·준비까지(USB에 쓰지 않는다)
    func previewEdit(_ job: UsbEditJob) throws -> UsbEditSummary
    /// 초안을 쓴다. 쓴 뒤 초안에는 막힌 편집만 남는다(`UsbEditSession.writeDraft`)
    func writeEdit(_ job: UsbEditJob, progress: @escaping @Sendable (UsbProgress) -> Void,
                   isCancelled: @escaping @Sendable () -> Bool) throws -> UsbEditWritten
}

/// 실제 창구: 내보내기는 `UsbExportSession`, 수정(초안)은 `UsbEditSession`, 옮기기는 `UsbMigrateSession`, 회복·되돌리기는 `UsbWriter`.
/// Mac 쪽 폴더(백업·저널·준비·세션 사본·초안)는 DJC_HOME 아래
struct SystemUsbWriteService: UsbWriteService {
    var paths: UsbWritePaths
    /// 세션 로컬 사본(`local-<세션>/`)을 둘 곳
    var localCopies: URL
    /// 부를 때마다 새로 만든다. 앱의 쓰기는 모두 쓰기 확인 창을 거친 뒤에 부르므로 그 확인을 실물 쓰기 동의로 본다
    var writeGuard: @Sendable () -> UsbWriteGuard = { .system(physicalWrite: SystemUsbWriteService.physicalWriteSwitch()) }
    /// USB 파일 연산(자가 테스트는 지운 `._`를 적는 것을 넘긴다)
    var fileSystem: any UsbFileSystem = PosixUsbFileSystem()
    /// USB 초안 폴더(`usb-drafts/<볼륨키>.json`)
    var drafts: URL = DJCPaths.usbDrafts
    /// USB를 읽기 직전에 그 자리의 볼륨을 다시 본다(사이드바 읽기 `SystemUsbHost.IO.reading`과 같다)
    var recheck: @Sendable (UsbVolumeInfo) throws -> UsbVolumeInfo = { try UsbRead.currentVolume(matching: $0) }
    /// 실물 쓰기 동의: 앱의 쓰기 확인 창. 디스크 이미지만 읽는 실행(자가 테스트·DJC_HOME 시험 실행)은 실물에 쓰지 않는다
    static func physicalWriteSwitch(policy: UsbReadPolicy = .current()) -> Bool {
        policy == .all
    }

    /// 앱이 쓰는 창구. 폴더는 USB에 쓸 때 만든다(저널을 보기만 할 때는 만들지 않는다)
    static func app() -> SystemUsbWriteService {
        SystemUsbWriteService(paths: UsbWritePaths(backups: DJCPaths.usbBackups, sessions: DJCPaths.usbSessions, staging: DJCPaths.usbStaging),
                              localCopies: DJCPaths.usbSnapshots)
    }

    func journal(volumeKey: String) -> UsbJournalInfo {
        switch UsbWriter.journalStatus(paths: paths, volumeKey: volumeKey) {
        case .missing: .none
        case let .open(journal), let .closed(journal): .state(journal.state)
        case .corrupt: .unreadable
        }
    }

    func preview(_ job: UsbExportJob) throws -> UsbExportSummary {
        try makeFolders()
        let preview = try session(job).preview(selection: job.selection, options: job.options)
        return UsbExportSummary(preview: preview, volume: job.volume)
    }

    func write(_ job: UsbExportJob, progress: @escaping @Sendable (UsbProgress) -> Void,
               isCancelled: @escaping @Sendable () -> Bool) throws -> UsbWriteReport {
        try makeFolders()
        return try session(job).write(selection: job.selection, options: job.options, progress: progress, isCancelled: isCancelled)
    }

    func previewMigration(_ volume: UsbVolumeInfo) throws -> UsbMigrationSummary {
        try makeFolders()
        let result = try migrationSession(volume).preview(options: UsbWriteOptions(confirmName: volume.name))
        return UsbMigrationSummary(result: result, volume: volume)
    }

    func writeMigration(_ volume: UsbVolumeInfo, progress: @escaping @Sendable (UsbProgress) -> Void,
                        isCancelled: @escaping @Sendable () -> Bool) throws -> UsbMigrationWritten {
        try makeFolders()
        let (result, report) = try migrationSession(volume).write(options: Self.writeOptions(volume), progress: progress,
                                                                  isCancelled: isCancelled)
        return UsbMigrationWritten(summary: UsbMigrationSummary(result: result, volume: volume), report: report)
    }

    private func migrationSession(_ volume: UsbVolumeInfo) -> UsbMigrateSession {
        UsbMigrateSession(root: URL(filePath: volume.mountPoint), guard: writeGuard(), paths: paths, fileSystem: fileSystem, copies: localCopies)
    }

    func recover(_ volume: UsbVolumeInfo) throws -> UsbWriteReport {
        try makeFolders()
        return try UsbWriter.recover(root: UsbRoot(URL(filePath: volume.mountPoint)), paths: paths, guard: writeGuard(), fileSystem: fileSystem,
                                     confirmName: volume.name, expectedVolumeUUID: Self.confirmedUUID(volume))
    }

    func restore(_ volume: UsbVolumeInfo, backup: URL?, discardDeviceChanges: Bool) throws -> UsbWriteReport {
        try makeFolders()
        return try UsbWriter.restore(root: UsbRoot(URL(filePath: volume.mountPoint)), paths: paths, backup: backup, guard: writeGuard(),
                                     fileSystem: fileSystem, discardDeviceChanges: discardDeviceChanges, confirmName: volume.name,
                                     expectedVolumeUUID: Self.confirmedUUID(volume))
    }

    /// 사용자가 확인한 볼륨의 UUID. 쓰기 절차가 열 때 지금 그 자리의 볼륨과 비교한다(그 사이 다른 USB가 붙었으면 막는다).
    /// 볼륨 UUID가 없는 볼륨은 쓰기 절차가 `noVolumeUUID`로 막으므로 비교할 것이 없다
    static func confirmedUUID(_ volume: UsbVolumeInfo) -> String? { volume.volumeUUID }

    /// 앱의 쓰기 선택: 쓰기 확인 창(볼륨 이름을 보인다)이 CLI의 --confirm을 대신하고, 확인한 볼륨의 UUID를 넘긴다
    static func writeOptions(_ volume: UsbVolumeInfo) -> UsbWriteOptions {
        UsbWriteOptions(confirmName: volume.name, expectedVolumeUUID: confirmedUUID(volume))
    }

    func latestBackup(volumeKey: String) -> URL? {
        UsbWriter.backups(paths: paths, volumeKey: volumeKey).first
    }

    /// 사이드바가 들고 있던 볼륨 정보는 앞선 훑기 때 것이라, 같은 자리에 다른 볼륨이 붙었으면 읽지 않는다(사이드바 읽기와 같은 다시 보기)
    func draftBase(_ volume: UsbVolumeInfo) throws -> UsbFingerprint {
        let current = try recheck(volume)
        return try UsbWriter.databaseFingerprint(root: UsbRoot(URL(filePath: current.mountPoint)), fileSystem: fileSystem)
    }

    func previewEdit(_ job: UsbEditJob) throws -> UsbEditSummary {
        try makeFolders()
        let key = try UsbEditSession.volumeKey(job.volume)
        guard let draft = try UsbDraftStore(directory: drafts).load(volumeKey: key), !draft.edits.isEmpty else {
            return .noDraft(isTestVolume: job.volume.isDiskImage)
        }
        var result = try editSession(job).preview(draft.edits, options: UsbWriteOptions(confirmName: job.volume.name), snapshotTime: job.snapshotTime)
        // 초안을 만든 뒤 USB가 바뀌었으면 쓸 때도 지금 상태로 다시 계획한다(막힌 볼륨은 USB를 더 읽지 않는다)
        if result.blocks.isEmpty, let now = try? draftBase(job.volume), !now.sameContent(as: draft.base) {
            result.notes.insert(String(ui: "USB가 그 사이 바뀌어 다시 계획했습니다"), at: 0)
        }
        return UsbEditSummary(result: result, edits: draft.edits, volume: job.volume)
    }

    func writeEdit(_ job: UsbEditJob, progress: @escaping @Sendable (UsbProgress) -> Void,
                   isCancelled: @escaping @Sendable () -> Bool) throws -> UsbEditWritten {
        try makeFolders()
        let key = try UsbEditSession.volumeKey(job.volume)
        let edits = try UsbDraftStore(directory: drafts).load(volumeKey: key)?.edits ?? []
        let (result, report) = try editSession(job).writeDraft(options: Self.writeOptions(job.volume), snapshotTime: job.snapshotTime,
                                                               progress: progress, isCancelled: isCancelled)
        return UsbEditWritten(summary: UsbEditSummary(result: result, edits: edits, volume: job.volume), report: report)
    }

    /// 로컬 사본은 앱이 연 스냅샷 사본을 넘긴다. 세션이 곡 더하기·갱신 때만 `local-<세션>/`에 따로 뜨고 끝나면 지운다
    private func editSession(_ job: UsbEditJob) -> UsbEditSession {
        UsbEditSession(root: job.root, database: job.database, share: job.share, guard: writeGuard(), paths: paths, fileSystem: fileSystem,
                       localCopies: localCopies, drafts: UsbDraftStore(directory: drafts))
    }

    private func session(_ job: UsbExportJob) -> UsbExportSession {
        UsbExportSession(database: job.database, share: job.share, root: job.root, guard: writeGuard(), paths: paths, fileSystem: fileSystem,
                         localCopies: localCopies)
    }

    private func makeFolders() throws {
        for url in [paths.backups, paths.sessions, paths.staging, localCopies] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

/// 쓰기 취소 표지. 메인 액터에서 켜고 쓰기 절차(메인 액터 밖)가 읽는다
final class UsbCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// 코디네이터 결과를 보이는 곳(토스트). 앱은 `LibraryStore`
@MainActor
protocol UsbWriteHost: AnyObject {
    var toast: AppToast? { get set }
}

extension LibraryStore: UsbWriteHost {}

/// USB 내보내기·회복·되돌리기 흐름(`ReflectionCoordinator` 본보기):
/// rekordbox·Agent 꺼짐 확인 → 볼륨 잠금 → 미리 보기(준비까지) → 확인 창 → 쓰기(진행·DB 교체 전 취소) → 토스트([꺼내기]).
/// 끝나지 않은 쓰기는 알림만 띄우고, 회복·되돌리기는 사용자가 누를 때만 한다. 파일 입출력은 모두 메인 액터 밖에서 한다.
@MainActor
struct UsbWriteCoordinator {
    let usb: UsbStore
    let host: any UsbWriteHost
    let service: any UsbWriteService
    var prompter: any ReflectionPrompter = AlertPrompter()
    var isRekordboxRunning: @Sendable () -> Bool = { LibrarySnapshot.isRekordboxRunning() }
    var openFolder: (URL) -> Void = { NSWorkspace.shared.open($0) }

    // MARK: - 내보내기

    /// 시트의 미리 보기. 막히면(rekordbox·잠금·끝나지 않은 쓰기·오류) 알리고 nil
    func preview(_ job: UsbExportJob) async -> UsbExportSummary? {
        guard await ready(job.volume) else { return nil }
        guard let flag = begin(job.volume, title: String(ui: "USB에 쓸 내용을 확인하는 중…")) else { return nil }
        let service = service
        let result = await Task.detached(priority: .userInitiated) { Result { try service.preview(job) } }.value
        usb.endWrite(job.volumeKey)
        switch result {
        case let .success(summary):
            return flag.isSet ? nil : summary
        case let .failure(error):
            fail(String(ui: "USB 미리 보기를 하지 못했습니다"), error)
            return nil
        }
    }

    /// 미리 보기 → 확인 창 → 쓰기 → 토스트. `reusing`이 있으면(시트에서 방금 본 미리 보기) 다시 미리 보지 않는다.
    /// `consented`면 시트가 볼륨 줄(이름·용량·형식·"실물 USB입니다")과 미리 보기를 보인 뒤 누른 [USB에 쓰기]가 쓰기 동의라
    /// 확인 창을 다시 띄우지 않는다(#212). 미리 본 결과가 없으면 지금처럼 확인 창으로 묻는다
    func export(_ job: UsbExportJob, reusing reused: UsbExportSummary? = nil, consented: Bool = false) async {
        guard await ready(job.volume) else { return }
        let key = job.volumeKey
        guard let flag = begin(job.volume, title: String(ui: "USB에 쓸 내용을 확인하는 중…")) else { return }
        usb.lastExports[key] = job
        usb.lastMigrations.remove(key)
        let outcome = await run(job, reused: reused, consented: consented && reused != nil, flag: flag)
        usb.endWrite(key)
        switch outcome {
        case .stopped:
            break
        case let .written(summary):
            usb.migrationBackups[key] = nil
            host.toast = AppToast(kind: .success, title: String(ui: "곡 \(summary.trackCount)개를 USB에 썼습니다"),
                                  detail: String(ui: "\(job.volume.name) · 재생 목록 \(summary.playlistCount)개"),
                                  action: .ejectUsb(volumeKey: key), isUsb: true)
            await usb.refresh()
        case .cancelled:
            host.toast = AppToast(kind: .success, title: String(ui: "USB 쓰기를 취소했습니다"), detail: String(ui: "USB는 쓰기 전 그대로입니다."),
                                  isUsb: true)
        case .recoveryNeeded:
            await offerRecovery(job.volume)
        case let .failed(error):
            await failWrite(error, volumeKey: key, otherwise: String(ui: "USB에 쓰지 않았습니다"))
        }
    }

    /// 잠근 채 한 쓰기의 결과(내보내기·수정 요약)
    private enum Outcome<Summary> {
        case stopped, cancelled, recoveryNeeded
        case written(Summary)
        case failed(any Error)
    }

    /// 잠근 채로 미리 보기·확인·쓰기. 잠금은 부르는 쪽이 푼다
    private func run(_ job: UsbExportJob, reused: UsbExportSummary?, consented: Bool, flag: UsbCancelFlag) async -> Outcome<UsbExportSummary> {
        let service = service, key = job.volumeKey
        let summary: UsbExportSummary
        if let reused {
            summary = reused
        } else {
            switch await Task.detached(priority: .userInitiated, operation: { Result { try service.preview(job) } }).value {
            case let .success(value): summary = value
            case let .failure(error): return .failed(error)
            }
        }
        if flag.isSet { return .cancelled }
        guard summary.canWrite else {
            inform(String(ui: "USB에 쓸 수 없습니다"), Self.stoppingText(summary), details: Self.blockLines(summary))
            return .stopped
        }
        guard consented || prompter.show(Self.confirmation(summary, job: job)) else { return .stopped }
        // 미리 보기가 남긴 저널(드라이 런)은 닫힌 상태라 막지 않는다. 그 사이 끝나지 않은 쓰기가 생겼으면 회복부터
        if let stop: Outcome<UsbExportSummary> = await journalStop(key) { return stop }
        let result = await perform(key) { progress in try service.write(job, progress: progress, isCancelled: { flag.isSet }) }
        switch result {
        case .success: return .written(summary)
        case let .failure(error): return Self.outcome(of: error)
        }
    }

    /// 쓰기 절차를 메인 액터 밖에서 돌린다. 진행은 순서대로 받아 메인 액터에서 덮개에 보인다
    private func perform<T: Sendable>(_ key: String, _ body: @escaping @Sendable (_ progress: @escaping @Sendable (UsbProgress) -> Void) throws -> T)
        async -> Result<T, any Error> {
        usb.setWriteTitle(String(ui: "USB에 쓰는 중…"), for: key)
        let (stream, continuation) = AsyncStream.makeStream(of: UsbProgress.self)
        let usb = usb
        let consumer = Task { @MainActor in
            for await progress in stream { usb.report(progress, for: key) }
        }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try body { continuation.yield($0) } }
        }.value
        continuation.finish()
        await consumer.value
        return result
    }

    /// 쓰기 실패 → 결과(취소·회복 필요·실패)
    private static func outcome<Summary>(of error: any Error) -> Outcome<Summary> {
        switch error as? UsbError {
        case .cancelled?: .cancelled
        case .recoveryNeeded?: .recoveryNeeded
        // 확인 뒤·쓰기 전에 다른 곳(CLI 등)이 저널을 열었다: 쓰기 절차는 막힘으로 알린다
        case let .writeRefused(blocks)? where blocks.contains(where: { $0.code == "recoveryNeeded" }): .recoveryNeeded
        default: .failed(error)
        }
    }

    /// 확인 창 뒤: 그 사이 끝나지 않은 쓰기가 생겼으면 회복부터, 저널을 읽지 못하면 멈춘다. 쓰러 가도 되면 nil
    private func journalStop<Summary>(_ key: String) async -> Outcome<Summary>? {
        let service = service
        let journal = await Task.detached(priority: .userInitiated) { service.journal(volumeKey: key) }.value
        if journal.isPending { return .recoveryNeeded }
        if journal == .unreadable {
            inform(String(ui: "USB에 쓰지 않았습니다"), Self.journalUnreadableText)
            return .stopped
        }
        return nil
    }

    // MARK: - Device Library → OneLibrary

    func previewMigration(_ volume: UsbVolumeInfo) async -> UsbMigrationSummary? {
        guard await ready(volume), let flag = begin(volume, title: String(ui: "USB에 쓸 내용을 확인하는 중…")) else { return nil }
        let service = service
        let result = await Task.detached(priority: .userInitiated) { Result { try service.previewMigration(volume) } }.value
        usb.endWrite(volume.usbKey)
        switch result {
        case let .success(summary):
            usb.migrationBlockReasons[volume.usbKey] = summary.stopping.isEmpty ? nil : summary.stopping
            return flag.isSet ? nil : summary
        case let .failure(error):
            fail(String(ui: "USB 미리 보기를 하지 못했습니다"), error)
            return nil
        }
    }

    /// CLI와 같은 옮기기 세션: 미리 보기 → 확인 → 쓰기 → 다시 읽기. 원래 파일은 세션의 검증기가 확인한다.
    func migrate(_ volume: UsbVolumeInfo) async {
        guard await ready(volume), let flag = begin(volume, title: String(ui: "USB에 쓸 내용을 확인하는 중…")) else { return }
        let key = volume.usbKey
        usb.lastMigrations.insert(key)
        usb.lastExports[key] = nil
        let outcome = await runMigration(volume, flag: flag)
        usb.endWrite(key)
        switch outcome {
        case .stopped: break
        case let .written(written):
            if let backup = written.report?.backup { usb.migrationBackups[key] = URL(filePath: backup) }
            host.toast = AppToast(kind: .success, title: String(ui: "USB에 OneLibrary를 더했습니다"),
                                  detail: String(ui: "\(volume.name) · 곡 \(written.summary.trackCount)개 · 재생 목록 \(written.summary.playlistCount)개"),
                                  action: .ejectUsb(volumeKey: key), isUsb: true)
            await usb.refresh()
        case .cancelled:
            host.toast = AppToast(kind: .success, title: String(ui: "USB 쓰기를 취소했습니다"), detail: String(ui: "USB는 쓰기 전 그대로입니다."), isUsb: true)
        case .recoveryNeeded: await offerRecovery(volume)
        case let .failed(error):
            if case let UsbError.writeRefused(blocks) = error {
                var seen: Set<String> = []
                usb.migrationBlockReasons[key] = blocks.map(\.message).filter { seen.insert($0).inserted }.joined(separator: "\n")
            }
            await failWrite(error, volumeKey: key, otherwise: String(ui: "USB에 쓰지 않았습니다"))
        }
    }

    private func runMigration(_ volume: UsbVolumeInfo, flag: UsbCancelFlag) async -> Outcome<UsbMigrationWritten> {
        let service = service, key = volume.usbKey
        let result = await Task.detached(priority: .userInitiated) { Result { try service.previewMigration(volume) } }.value
        let summary: UsbMigrationSummary
        switch result {
        case let .success(value): summary = value
        case let .failure(error): return .failed(error)
        }
        if flag.isSet { return .cancelled }
        usb.migrationBlockReasons[key] = summary.stopping.isEmpty ? nil : summary.stopping
        guard summary.canWrite else {
            inform(String(ui: "OneLibrary를 더할 수 없습니다"), summary.stopping.isEmpty
                   ? String(ui: "옮길 곡이 없습니다. USB를 다시 읽은 뒤 확인하세요") : summary.stopping)
            return .stopped
        }
        guard prompter.show(Self.migrationConfirmation(summary, volume: volume)) else { return .stopped }
        if let stop: Outcome<UsbMigrationWritten> = await journalStop(key) { return stop }
        switch await perform(key, { progress in try service.writeMigration(volume, progress: progress, isCancelled: { flag.isSet }) }) {
        case let .success(written):
            guard written.report?.outcome == .written else { return .stopped }
            return .written(written)
        case let .failure(error): return Self.outcome(of: error)
        }
    }

    /// 이 실행에서 옮긴 쓰기의 백업으로만 되돌린다. 다른 쓰기 뒤에는 메뉴를 숨긴다.
    func restoreMigration(_ volume: UsbVolumeInfo) async {
        guard let backup = usb.migrationBackups[volume.usbKey], await ready(volume) else { return }
        guard prompter.show(ReflectionPrompt(title: String(ui: "USB를 쓰기 전으로 되돌릴까요?"),
                                            text: String(ui: "\(volume.name)에 OneLibrary를 더하기 전의 백업으로 되돌립니다. 끝날 때까지 USB를 뽑지 마세요."),
                                            confirm: String(ui: "되돌리기"), destructive: true)) else { return }
        guard begin(volume, title: String(ui: "USB를 되돌리는 중…"), cancellable: false) != nil else { return }
        await restore(volume, backup: backup)
    }

    static func migrationConfirmation(_ summary: UsbMigrationSummary, volume: UsbVolumeInfo) -> ReflectionPrompt {
        var details = [String(ui: "곡 \(summary.trackCount)개 · 재생 목록 \(summary.playlistCount)개 · 새 앨범아트 파일 \(summary.artworkFiles)개")]
        details += volumeLines(volume, isTestVolume: summary.isTestVolume)
        details += summary.notes
        details += deviceCheckLines(summary.rules.map { ($0, 0) }, trackCount: 0)
        return ReflectionPrompt(title: String(ui: "OneLibrary를 더할까요?"),
                                text: String(ui: "\(volume.name)의 Device Library를 읽어 OneLibrary를 더합니다. 쓰기 전에 Mac에 백업하고 쓴 뒤 USB에서 다시 읽어 확인합니다. 끝날 때까지 USB를 뽑지 마세요."),
                                confirm: String(ui: "OneLibrary 더하기"), details: details)
    }

    // MARK: - 수정(초안)

    /// 쓸 볼륨. 빠져 있으면 초안은 그대로 두고 연결하라고 알린다
    private func editJob(_ volumeKey: String, database: URL?, share: URL?, snapshotTime: String?) -> UsbEditJob? {
        guard let volume = usb.volume(volumeKey) else {
            notify(String(ui: "USB에 쓰지 않았습니다"), String(ui: "USB를 연결한 뒤 쓰세요"))
            return nil
        }
        return UsbEditJob(database: database, share: share, volume: volume, snapshotTime: snapshotTime)
    }

    /// 쓰기 대기 목록의 미리 보기. 볼륨이 빠졌거나 막히면(rekordbox·잠금·끝나지 않은 쓰기·오류) 알리고 nil
    /// - database: 앱이 연 로컬 스냅샷 사본(새로 뜨지 않는다)
    func previewDraft(volumeKey: String, database: URL?, share: URL?, snapshotTime: String? = nil) async -> UsbEditSummary? {
        guard let job = editJob(volumeKey, database: database, share: share, snapshotTime: snapshotTime), await ready(job.volume) else { return nil }
        guard let flag = begin(job.volume, title: String(ui: "USB에 쓸 내용을 확인하는 중…")) else { return nil }
        let service = service
        let result = await Task.detached(priority: .userInitiated) { Result { try service.previewEdit(job) } }.value
        usb.endWrite(job.volumeKey)
        switch result {
        case let .success(summary):
            return flag.isSet ? nil : summary
        case let .failure(error):
            fail(String(ui: "USB 미리 보기를 하지 못했습니다"), error)
            return nil
        }
    }

    /// 초안 쓰기: 미리 보기 → 확인 창 → 쓰기(진행·DB 교체 전 취소) → 토스트([꺼내기]). 내보내기와 같은 잠금·회복 흐름을 탄다.
    /// `reusing`이 있으면(대기 목록에서 방금 본 미리 보기) 다시 미리 보지 않는다. 쓴 뒤에는 초안 수를 다시 읽는다(막힌 편집만 남는다)
    func writeDraft(volumeKey: String, database: URL?, share: URL?, snapshotTime: String? = nil, reusing reused: UsbEditSummary? = nil) async {
        guard let job = editJob(volumeKey, database: database, share: share, snapshotTime: snapshotTime), await ready(job.volume) else { return }
        guard let flag = begin(job.volume, title: String(ui: "USB에 쓸 내용을 확인하는 중…")) else { return }
        usb.lastMigrations.remove(volumeKey)
        let outcome = await runEdit(job, reused: reused, flag: flag)
        usb.endWrite(volumeKey)
        switch outcome {
        case .stopped:
            break
        case let .written(summary):
            usb.migrationBackups[volumeKey] = nil
            let blocked = summary.blockedCount
            host.toast = AppToast(kind: .success, title: String(ui: "USB에 편집 \(summary.writtenCount)건을 썼습니다"),
                                  detail: blocked > 0 ? String(ui: "\(job.volume.name) · 막힌 편집 \(blocked)건은 초안에 남겼습니다") : job.volume.name,
                                  action: .ejectUsb(volumeKey: volumeKey), isUsb: true)
            await usb.refresh()
        case .cancelled:
            host.toast = AppToast(kind: .success, title: String(ui: "USB 쓰기를 취소했습니다"), detail: String(ui: "USB는 쓰기 전 그대로입니다."),
                                  isUsb: true)
        case .recoveryNeeded:
            await offerRecovery(job.volume)
        case let .failed(error):
            await failWrite(error, volumeKey: volumeKey, otherwise: String(ui: "USB에 쓰지 않았습니다"))
        }
        await usb.reloadDraft(volumeKey)
    }

    /// 잠근 채로 미리 보기·확인·쓰기. 잠금은 부르는 쪽이 푼다.
    /// 미리 보기는 초안 줄 밖이라 확인하는 동안 초안이 바뀔 수 있다. 쓰기 줄에서 초안이 확인한 편집과 다르면 쓰지 않고 지금 초안으로 다시 미리 보고 묻는다
    private func runEdit(_ job: UsbEditJob, reused: UsbEditSummary?, flag: UsbCancelFlag) async -> Outcome<UsbEditSummary> {
        let service = service, key = job.volumeKey
        var summary: UsbEditSummary
        if let reused {
            summary = reused
        } else {
            switch await editPreview(job) {
            case let .success(value): summary = value
            case let .failure(error): return .failed(error)
            }
        }
        var draftChanged = false
        while true {
            if flag.isSet { return .cancelled }
            guard summary.stopping.isEmpty else {
                inform(String(ui: "USB에 쓸 수 없습니다"), summary.stopping.joined(separator: "\n"), details: Self.editLines(summary))
                return .stopped
            }
            guard summary.hasChanges else {
                notify(String(ui: "USB에 쓸 것이 없습니다"), String(ui: "바꿀 것이 없거나 모든 편집이 막혔습니다. 쓰기 대기 목록에서 이유를 확인하세요"))
                return .stopped
            }
            guard prompter.show(Self.editConfirmation(summary, volume: job.volume, draftChanged: draftChanged)) else { return .stopped }
            if let stop: Outcome<UsbEditSummary> = await journalStop(key) { return stop }
            // 세션이 초안을 읽고 막힌 편집만 남겨 다시 저장하는 동안 더한 편집을 잃지 않게, 초안 고치기와 한 줄로 선다(그 편집은 쓰기 뒤에 더한다).
            // 세션은 줄 안에서 초안을 다시 읽어 쓰므로, 확인한 것과 다르면(미리 보기 뒤 더하거나 뺌) 확인 창에 없던 편집을 쓰지 않게 멈춘다
            let confirmed = summary.edits
            let result = await usb.draftQueue(key) { () -> Result<UsbEditWritten, any Error>? in
                guard (await draftEdits(key) ?? confirmed) == confirmed else { return nil }
                return await perform(key) { progress in try service.writeEdit(job, progress: progress, isCancelled: { flag.isSet }) }
            }
            guard let result else {
                switch await editPreview(job) {
                case let .success(value): summary = value
                case let .failure(error): return .failed(error)
                }
                draftChanged = true
                continue
            }
            switch result {
            case let .success(written):
                guard written.report != nil else {
                    // 확인 뒤 USB가 바뀌어 다시 계획하니 쓸 것이 없었다
                    notify(String(ui: "USB에 쓸 것이 없습니다"), String(ui: "바꿀 것이 없거나 모든 편집이 막혔습니다. 쓰기 대기 목록에서 이유를 확인하세요"))
                    return .stopped
                }
                return .written(written.summary)
            case let .failure(error): return Self.outcome(of: error)
            }
        }
    }

    /// 지금 초안으로 미리 보기(메인 액터 밖)
    private func editPreview(_ job: UsbEditJob) async -> Result<UsbEditSummary, any Error> {
        let service = service
        return await Task.detached(priority: .userInitiated) { Result { try service.previewEdit(job) } }.value
    }

    /// 지금 초안 파일의 편집(메인 액터 밖에서 읽는다). 읽지 못하면 빈 목록 — 확인한 것과 달라 다시 미리 보며 오류를 알린다.
    /// 초안 폴더가 없으면(초안을 다루지 않는 시험·캡처) nil
    private func draftEdits(_ key: String) async -> [UsbLibraryEdit]? {
        guard let directory = usb.draftDirectory else { return nil }
        return await Task.detached(priority: .userInitiated) {
            ((try? UsbDraftStore(directory: directory).load(volumeKey: key)) ?? nil)?.edits ?? []
        }.value
    }

    /// 시작 전 확인: rekordbox·Agent, 볼륨 잠금, 끝나지 않은 쓰기(회복 알림), 읽지 못한 저널
    private func ready(_ volume: UsbVolumeInfo) async -> Bool {
        let running = isRekordboxRunning
        if await Task.detached(priority: .userInitiated, operation: { running() }).value {
            notify(String(ui: "rekordbox가 켜져 있어 USB에 쓰지 않았습니다"), String(ui: "rekordbox와 rekordboxAgent를 완전히 종료한 뒤 다시 누르세요."))
            return false
        }
        guard !isBusy(volume) else { return false }
        let service = service, key = volume.usbKey
        let journal = await Task.detached(priority: .userInitiated) { service.journal(volumeKey: key) }.value
        if journal.isPending {
            await offerRecovery(volume)
            return false
        }
        if journal == .unreadable {
            inform(String(ui: "USB에 쓰지 않았습니다"), Self.journalUnreadableText)
            return false
        }
        return true
    }

    /// 잠겨 있으면 알리고 true. 쓰기 단추는 쓰는 동안 막혀 있어, 그 사이 다른 입구로 누른 것만 토스트로 알린다(#230)
    private func isBusy(_ volume: UsbVolumeInfo) -> Bool {
        if usb.busyVolumes.contains(volume.usbKey) {
            notify(String(ui: "이 USB에 쓰는 중입니다"), String(ui: "쓰기가 끝난 뒤 다시 시도하세요."))
            return true
        }
        if usb.activeWrite != nil {
            notify(String(ui: "다른 USB에 쓰는 중입니다"), String(ui: "쓰기가 끝난 뒤 다시 시도하세요."))
            return true
        }
        return false
    }

    private func begin(_ volume: UsbVolumeInfo, title: String, cancellable: Bool = true) -> UsbCancelFlag? {
        guard !isBusy(volume) else { return nil }
        return usb.beginWrite(volume, title: title, cancellable: cancellable)
    }

    // MARK: - 끝나지 않은 쓰기

    /// 끝나지 않은 쓰기 알림: [회복하기] [되돌리기] [나중에]. 누를 때만 USB에 손댄다
    func offerRecovery(_ volume: UsbVolumeInfo) async {
        guard !usb.busyVolumes.contains(volume.usbKey), usb.activeWrite == nil else { return }
        let service = service, key = volume.usbKey
        guard await Task.detached(priority: .userInitiated, operation: { service.journal(volumeKey: key) }).value.isPending else { return }
        switch prompter.choose(Self.pendingPrompt(volume)) {
        case .confirm: await recover(volume)
        case .alternate: await revert(volume)
        case .cancel: return
        }
    }

    /// 회복: USB의 DB를 보고 마저 쓰거나 되돌린다(쓰기와 같은 확인·실물 관문을 먼저 거친다)
    private func recover(_ volume: UsbVolumeInfo) async {
        guard begin(volume, title: String(ui: "USB를 회복하는 중…"), cancellable: false) != nil else { return }
        let service = service
        let result = await Task.detached(priority: .userInitiated) { Result { try service.recover(volume) } }.value
        usb.endWrite(volume.usbKey)
        switch result {
        case let .success(report):
            switch report.outcome {
            case .needsReplan:
                await offerReplan(volume)
                return
            case .rolledBack:
                host.toast = AppToast(kind: .success, title: String(ui: "끊긴 USB 쓰기를 되돌렸습니다"), detail: String(ui: "USB는 쓰기 전 그대로입니다."),
                                      isUsb: true)
            // 끊긴 되돌리기를 마쳤다
            case .restored:
                host.toast = AppToast(kind: .success, title: String(ui: "USB를 쓰기 전으로 되돌렸습니다"), isUsb: true)
            // 저널이 없었다(session이 빔): 다른 곳에서 이미 닫았다
            case .recovered where !report.session.isEmpty:
                host.toast = AppToast(kind: .success, title: String(ui: "USB 쓰기를 마저 끝냈습니다"), action: .ejectUsb(volumeKey: volume.usbKey),
                                      isUsb: true)
            default:
                host.toast = AppToast(kind: .success, title: String(ui: "회복할 USB 쓰기가 없습니다"), isUsb: true)
            }
        case let .failure(error):
            await failWrite(error, volumeKey: volume.usbKey, otherwise: String(ui: "USB를 회복하지 않았습니다"))
        }
        await usb.refresh()
    }

    /// 되돌리기: 끝나지 않은 저널을 먼저 닫고(회복) 그 쓰기의 백업으로 되돌린다(되돌리기는 열린 저널을 받지 않는다).
    /// 기기가 그 뒤에 USB를 바꿨으면 한 번 더 묻는다
    private func revert(_ volume: UsbVolumeInfo) async {
        let key = volume.usbKey, service = service
        guard begin(volume, title: String(ui: "USB를 되돌리는 중…"), cancellable: false) != nil else { return }
        let recovered = await Task.detached(priority: .userInitiated) { Result { try service.recover(volume) } }.value
        let backup: URL
        switch recovered {
        case let .failure(error):
            usb.endWrite(key)
            await failWrite(error, volumeKey: key, otherwise: String(ui: "USB를 되돌리지 않았습니다"))
            return
        // 회복이 이미 쓰기 전으로 되돌렸다(끊긴 쓰기 되돌림·끊긴 되돌리기 마침)
        case let .success(report) where report.outcome == .rolledBack || report.outcome == .restored:
            usb.endWrite(key)
            host.toast = AppToast(kind: .success, title: String(ui: "USB를 쓰기 전으로 되돌렸습니다"), isUsb: true)
            await usb.refresh()
            return
        case let .success(report):
            // 그 쓰기의 백업으로만 되돌린다. 저널이 없었거나(session이 빔) 백업이 없으면 다른 쓰기의 백업을 고르지 않는다
            guard !report.session.isEmpty, let path = report.backup, !path.isEmpty else {
                usb.endWrite(key)
                inform(String(ui: "USB를 되돌리지 않았습니다"), String(ui: "이 쓰기의 백업을 찾지 못했습니다. USB를 다시 읽어 지금 상태를 확인하세요"))
                await usb.refresh()
                return
            }
            backup = URL(filePath: path)
        }
        await restore(volume, backup: backup)
    }

    private func restore(_ volume: UsbVolumeInfo, backup: URL) async {
        let key = volume.usbKey, service = service
        var discard = false
        while true {
            let flagged = discard
            let result = await Task.detached(priority: .userInitiated) {
                Result { try service.restore(volume, backup: backup, discardDeviceChanges: flagged) }
            }.value
            switch result {
            case .success:
                usb.endWrite(key)
                host.toast = AppToast(kind: .success, title: String(ui: "USB를 쓰기 전으로 되돌렸습니다"), isUsb: true)
                usb.migrationBackups[key] = nil
                await usb.refresh()
                return
            case let .failure(UsbError.writeRefused(blocks)) where !discard && blocks.contains(where: { $0.code == "deviceChanged" }):
                usb.endWrite(key)
                guard prompter.show(Self.discardDeviceChangesPrompt(volume)) else { return }
                guard begin(volume, title: String(ui: "USB를 되돌리는 중…"), cancellable: false) != nil else { return }
                discard = true
            case let .failure(error):
                usb.endWrite(key)
                await failWrite(error, volumeKey: key, otherwise: String(ui: "USB를 되돌리지 않았습니다"))
                return
            }
        }
    }

    /// 회복이 다시 계획하라고 했을 때: 누르면 USB를 다시 읽고 새로 미리 본 뒤 내보내기 시트를 연다
    private func offerReplan(_ volume: UsbVolumeInfo) async {
        let prompt = ReflectionPrompt(title: String(ui: "USB 쓰기를 이어 하지 않았습니다"),
                                      text: String(ui: "USB가 기기에서 바뀌어 이어 쓰지 않았습니다. 지금 USB 상태로 다시 미리 보기한 뒤 쓰세요"),
                                      confirm: String(ui: "다시 미리 보기"), cancel: String(ui: "닫기"))
        guard prompter.show(prompt) else { return }
        await usb.refresh()
        let key = volume.usbKey
        if usb.lastMigrations.contains(key), let current = usb.volume(key) {
            await migrate(current)
            return
        }
        guard var job = usb.lastExports[key] else {
            usb.exportSheet = usb.volume(key).map { UsbExportSheetRequest(volume: $0) }
            return
        }
        // 다시 붙었으면 마운트 지점이 바뀌었을 수 있다
        job.volume = usb.volume(key) ?? job.volume
        let summary = await preview(job)
        usb.exportSheet = UsbExportSheetRequest(volume: job.volume, job: job, summary: summary)
    }

    // MARK: - 토스트 동작

    func perform(_ action: AppToast.Action) async {
        switch action {
        case let .ejectUsb(volumeKey):
            if host.toast?.action == action { host.toast = nil }
            if let message = await usb.eject(volumeKey) { notify(String(ui: "USB를 꺼내지 못했습니다"), message) }
        }
    }

    // MARK: - 알림

    private func inform(_ title: String, _ text: String, details: [String] = []) {
        _ = prompter.show(ReflectionPrompt(title: title, text: text, details: details))
    }

    /// USB에 손대지 않은 안내(지금은 못 함·할 것 없음): 창 대신 닫을 때까지 남는 경고 토스트(#230)
    private func notify(_ title: String, _ text: String) {
        host.toast = .notice(title, text, isUsb: true)
    }

    /// 막힘·오류 알림. 막힘(`writeRefused`)은 그 문구(이유와 할 일)를 그대로, 그 밖의 USB 오류는 그 설명을 보인다
    private func fail(_ title: String, _ error: any Error) {
        let text: String
        if case let UsbError.writeRefused(blocks)? = error as? UsbError, !blocks.isEmpty {
            var seen: Set<String> = []
            text = blocks.map(\.message).filter { seen.insert($0).inserted }.joined(separator: "\n")
        } else if let usbError = error as? UsbError, let description = usbError.errorDescription {
            // UsbError는 DJCError가 아니라 AppErrorMessage가 일반 문구로 바꾼다
            AppErrorMessage.log(error)
            text = description
        } else {
            text = AppErrorMessage.message(for: error)
        }
        _ = prompter.show(ReflectionPrompt(title: title, text: text, critical: true))
    }

    /// USB에 손댄 뒤(쓰기·회복·되돌리기)의 실패: 되돌린 결과와 할 일. 백업 폴더가 있으면 열 수 있다.
    /// 반쯤 쓰였을 수 있는 경우가 아니면 `otherwise` 제목으로 알린다
    private func failWrite(_ error: any Error, volumeKey: String, otherwise title: String) async {
        let backup: URL?
        let prompt: ReflectionPrompt
        switch error as? UsbError {
        case .writeRolledBack?:
            // 백업 폴더 찾기는 폴더를 열거하고 manifest를 읽는다: 메인 액터 밖에서
            let service = service
            backup = await Task.detached(priority: .userInitiated) { service.latestBackup(volumeKey: volumeKey) }.value
            prompt = ReflectionPrompt(title: String(ui: "USB에 쓴 결과를 확인하지 못해 쓰기 전으로 되돌렸습니다"),
                                      text: String(ui: "USB는 쓰기 전 그대로입니다. USB를 다시 읽은 뒤 다시 시도하세요."), critical: true)
        case let .restoreFailed(_, _, folder)?:
            backup = folder.isEmpty ? nil : URL(filePath: folder)
            prompt = ReflectionPrompt(title: String(ui: "USB를 쓰기 전 상태로 되돌리지 못했습니다"),
                                      text: String(ui: "USB를 기기에 꽂지 마세요. USB를 다시 연결하면 나오는 알림에서 회복하세요."), critical: true)
        case .restorePending?:
            backup = nil
            prompt = ReflectionPrompt(title: String(ui: "rekordbox가 켜져 있어 USB 복원을 미뤘습니다"),
                                      text: String(ui: "USB를 기기에 꽂지 마세요. rekordbox를 종료한 뒤 USB를 다시 연결하면 나오는 알림에서 회복하세요."),
                                      critical: true)
        case .volumeLost?:
            backup = nil
            prompt = ReflectionPrompt(title: String(ui: "USB 연결이 끊겼습니다"),
                                      text: String(ui: "USB를 기기에 꽂지 말고 다시 연결하세요. 다시 연결하면 나오는 알림에서 회복할 수 있습니다."),
                                      critical: true)
        case .volumeChanged?:
            backup = nil
            prompt = ReflectionPrompt(title: String(ui: "쓰는 도중 USB가 바뀌어 멈췄습니다"),
                                      text: String(ui: "지금 붙은 USB에는 쓰지 않았습니다. 처음 USB를 기기에 꽂지 말고 다시 연결하세요. 다시 연결하면 나오는 알림에서 회복할 수 있습니다."),
                                      critical: true)
        default:
            fail(title, error)
            return
        }
        AppErrorMessage.log(error)
        var shown = prompt
        if backup != nil {
            shown.confirm = String(ui: "백업 폴더 열기")
            shown.cancel = String(ui: "닫기")
        }
        if prompter.show(shown), let backup { openFolder(backup) }
    }

    // MARK: - 창 문구

    /// 쓰기 전 확인 창·내보내기 시트의 볼륨 줄. 실물이면 이름·용량·형식과 "실물 USB입니다"를 보이고(이 줄을 보인 창·시트의 쓰기 버튼이 쓰기 동의다),
    /// 기기가 읽지 못할 수 있는 형식(exFAT·GPT)은 한 줄씩 알린다
    static func volumeLines(_ volume: UsbVolumeInfo, isTestVolume: Bool) -> [String] {
        if isTestVolume { return [String(ui: "시험 볼륨(디스크 이미지)입니다")] }
        let capacity = volume.capacity.formatted(ByteCountFormatStyle(style: .file))
        let scheme = volume.partitionScheme == .gpt ? "GPT" : "MBR"
        var lines = [String(ui: "실물 USB입니다: \(volume.name) · \(capacity) · \(volume.fileSystem.displayName) · \(scheme)"),
                     String(ui: "쓰기 전 바꿀 파일을 Mac에 백업합니다. 기기에 꽂기 전에 결과를 확인하세요")]
        lines += UsbVolumePolicy.warnings(volume).map(\.message)
        return lines
    }

    /// CDJ에서 확인하지 않은 항목 줄(막지 않고 알리기만 한다). trackCount가 0보다 크면 곡 수로 적는다
    nonisolated static func deviceCheckLines(_ rules: [(rule: UsbProvisionalRule, count: Int)], trackCount: Int) -> [String] {
        guard !rules.isEmpty else { return [] }
        var lines = [trackCount > 0 ? String(ui: "CDJ에서 확인하지 않은 항목이 있는 곡 \(trackCount)개:")
            : String(ui: "CDJ에서 확인하지 않은 항목 \(rules.count)개:")]
        lines += rules.map { $0.count > 0 ? "• \($0.rule.summary) (\($0.count))" : "• \($0.rule.summary)" }
        lines.append(String(ui: "쓰기는 막지 않습니다. 쓴 뒤 기기에서 확인하세요"))
        return lines
    }

    static var journalUnreadableText: String {
        String(ui: "회복 기록 파일을 읽지 못했습니다. DJCrate 데이터 폴더의 usb-sessions를 확인하세요")
    }

    /// 쓰기 전 확인 창: 곡·목록 수, 대상·형식, 시험 볼륨, 공간, 빼고 쓰는 곡(이유별 수), CDJ에서 확인하지 않은 항목
    static func confirmation(_ summary: UsbExportSummary, job: UsbExportJob) -> ReflectionPrompt {
        let formats = UsbFormat.allCases.filter(job.formats.contains).map(\.displayName).joined(separator: " · ")
        var details: [String] = []
        details += volumeLines(job.volume, isTestVolume: summary.isTestVolume)
        details.append(summary.spaceText)
        details += blockLines(summary)
        return ReflectionPrompt(title: String(ui: "곡 \(summary.trackCount)개·재생 목록 \(summary.playlistCount)개를 USB에 쓸까요?"),
                                text: String(ui: "\(job.volume.name)에 \(formats)로 씁니다. 쓰기 전에 Mac에 백업하고 쓴 뒤 USB에서 다시 읽어 확인합니다. 끝날 때까지 USB를 뽑지 마세요."),
                                confirm: String(ui: "USB에 쓰기"), details: details)
    }

    /// 빼고 쓰는 곡·재생 목록(이유별 수)과 CDJ에서 확인하지 않은 항목 줄. 쓰기를 멈추는 막힘(볼륨·형식·파일)은 `stopping`으로만 보인다
    static func blockLines(_ summary: UsbExportSummary) -> [String] {
        var lines: [String] = []
        let tracks = summary.blockCounts.filter { $0.kind == .track }
        if summary.blockedTrackCount > 0, !tracks.isEmpty {
            lines.append(String(ui: "빼고 쓰는 곡 \(summary.blockedTrackCount)개:"))
            lines += tracks.map { "• \($0.message) (\($0.count))" }
        }
        let playlists = summary.blockCounts.filter { $0.kind == .playlist }
        if summary.blockedPlaylistCount > 0, !playlists.isEmpty {
            lines.append(String(ui: "빼고 쓰는 재생 목록 \(summary.blockedPlaylistCount)개:"))
            lines += playlists.map { "• \($0.message) (\($0.count))" }
        }
        lines += deviceCheckLines(summary.rules.map { ($0.rule, $0.count) }, trackCount: summary.unverifiedTrackCount)
        return lines
    }

    /// 쓰지 못하는 까닭(볼륨 단위 막힘 → 공간 → 곡 없음)
    static func stoppingText(_ summary: UsbExportSummary) -> String {
        if !summary.stopping.isEmpty { return summary.stopping.joined(separator: "\n") }
        if summary.isShortOfSpace { return String(ui: "USB 여유 공간이 모자랍니다. 곡을 줄이거나 공간이 더 있는 USB를 쓰세요") }
        return String(ui: "내보낼 곡이 없습니다. 막힌 곡의 이유를 확인한 뒤 다시 시도하세요")
    }

    /// 수정 쓰기 전 확인 창: 쓸 편집 수, 막힌 편집, 빼고 쓰는 곡, 형식별 결과, 지울 파일·미룸, CDJ에서 확인하지 않은 항목.
    /// draftChanged면 확인하는 동안 초안이 바뀌어 다시 묻는다는 것을 맨 앞에 알린다
    static func editConfirmation(_ summary: UsbEditSummary, volume: UsbVolumeInfo, draftChanged: Bool = false) -> ReflectionPrompt {
        var details: [String] = []
        details += volumeLines(volume, isTestVolume: summary.isTestVolume)
        details += editLines(summary)
        let text = String(ui: "\(volume.name)의 rekordbox 라이브러리를 고칩니다. 쓰기 전에 Mac에 백업하고 쓴 뒤 USB에서 다시 읽어 확인합니다. 끝날 때까지 USB를 뽑지 마세요.")
        return ReflectionPrompt(title: String(ui: "USB에 편집 \(summary.writtenCount)건을 쓸까요?"),
                                text: draftChanged ? draftChangedText + "\n\n" + text : text,
                                confirm: String(ui: "USB에 쓰기"), details: details)
    }

    static var draftChangedText: String {
        String(ui: "쓰기 대기가 그 사이 바뀌어 다시 계획했으니 바뀐 내용을 확인한 뒤 쓰세요")
    }

    /// 수정 요약 줄(확인 창·쓰기 대기 목록). blockedEdits가 거짓이면 막힌 편집 줄은 뺀다(대기 목록은 편집마다 보인다)
    nonisolated static func editLines(_ summary: UsbEditSummary, blockedEdits: Bool = true) -> [String] {
        var lines: [String] = []
        if blockedEdits {
            let blocked = summary.outcomes.sorted { $0.key < $1.key }.compactMap { number, outcome -> String? in
                if case let .blocked(reason) = outcome { "• " + String(ui: "편집 \(number): \(reason)") } else { nil }
            }
            if !blocked.isEmpty {
                lines.append(String(ui: "막힌 편집 \(blocked.count)건(초안에 남깁니다):"))
                lines += blocked
            }
        }
        if summary.skippedTrackCount > 0 {
            lines.append(String(ui: "빼고 쓰는 곡 \(summary.skippedTrackCount)개:"))
            lines += summary.skipped.map { "• \($0.message) (\($0.count))" }
        }
        for result in summary.formats {
            if let reason = result.blocked {
                lines.append(String(ui: "\(result.format.displayName): 고치지 않음 — \(reason)"))
            } else if result.written {
                lines.append(String(ui: "\(result.format.displayName): 고침"))
            }
        }
        if summary.removals > 0 { lines.append(String(ui: "USB에서 지울 파일 \(summary.removals)개")) }
        lines += summary.deferred.map { String(ui: "파일 지우기를 미룸: \($0)") }
        if summary.formatDrift {
            lines.append(String(ui: "Device Library를 고치지 못해 두 형식의 곡이 달라집니다. 다음부터 이 USB를 고치려면 rekordbox에서 다시 내보내세요"))
        }
        lines += summary.notes.filter { !summary.deferred.contains($0) }
        lines += summary.warnings
        lines += deviceCheckLines(summary.rules.map { ($0, 0) }, trackCount: 0)
        return lines
    }

    static func pendingPrompt(_ volume: UsbVolumeInfo) -> ReflectionPrompt {
        ReflectionPrompt(title: String(ui: "지난 USB 쓰기가 끝나지 않았습니다"),
                         text: String(ui: "\(volume.name)에 쓰다가 끊긴 기록이 있습니다. 회복하면 USB를 보고 마저 쓰거나 쓰기 전으로 되돌립니다. 되돌리기는 그 쓰기를 백업으로 되돌립니다. 기기에 꽂기 전에 하세요."),
                         confirm: String(ui: "회복하기"), alternate: String(ui: "되돌리기"), cancel: String(ui: "나중에"))
    }

    static func discardDeviceChangesPrompt(_ volume: UsbVolumeInfo) -> ReflectionPrompt {
        ReflectionPrompt(title: String(ui: "USB를 쓰기 전으로 되돌릴까요?"),
                         text: String(ui: "\(volume.name)은 DJCrate가 쓴 뒤 기기에서 바뀌었습니다. 되돌리면 기기가 그 뒤에 쓴 내용을 잃습니다(재생 기록 등)."),
                         confirm: String(ui: "되돌리기"), critical: true, destructive: true)
    }
}

extension UsbProgress.Phase {
    /// 진행 덮개에 보일 단계 이름
    var displayName: String {
        switch self {
        case .planning: String(ui: "계획")
        case .staging: String(ui: "준비(분석 파일·앨범아트·DB)")
        case .backup: String(ui: "백업")
        case .files: String(ui: "파일 쓰기")
        case .commit: String(ui: "DB 교체")
        case .cleanup: String(ui: "정리")
        case .verify: String(ui: "검증")
        case .restore: String(ui: "되돌리기")
        case .recover: String(ui: "회복")
        }
    }
}

/// 쓰는 동안 덮개에 보일 것(순수)
struct UsbWriteProgressModel: Equatable {
    var title: String
    var volumeName: String
    var phase: String?
    /// "3/12"
    var items: String?
    var bytes: String?
    var fraction: Double?
    /// DB 교체가 시작되면(`cancellable == false`) 숨긴다
    var showsCancel: Bool

    init(_ write: UsbActiveWrite) {
        title = write.title
        volumeName = write.volumeName
        guard let progress = write.progress else {
            phase = nil
            items = nil
            bytes = nil
            fraction = nil
            showsCancel = write.cancellable
            return
        }
        phase = progress.phase.displayName
        items = progress.totalItems > 0 ? "\(progress.completedItems)/\(progress.totalItems)" : nil
        if progress.totalBytes > 0 {
            let format = ByteCountFormatStyle(style: .file)
            bytes = "\(progress.completedBytes.formatted(format)) / \(progress.totalBytes.formatted(format))"
            fraction = min(1, Double(progress.completedBytes) / Double(progress.totalBytes))
        } else {
            bytes = nil
            fraction = progress.totalItems > 0 ? min(1, Double(progress.completedItems) / Double(progress.totalItems)) : nil
        }
        showsCancel = write.cancellable && progress.cancellable
    }
}
