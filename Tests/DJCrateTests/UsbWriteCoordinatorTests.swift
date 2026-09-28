@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// 시험용 USB 쓰기 창구: 정해 둔 결과를 돌려주고 부른 것을 적는다(USB·Mac 파일을 건드리지 않는다).
/// 코디네이터가 메인 액터 밖에서 부르므로 모든 상태는 잠금 안에서만 바꾼다.
final class FakeUsbWriteService: UsbWriteService, @unchecked Sendable {
    struct State {
        var journal: UsbJournalInfo = .none
        var summary = UsbTestData.summary()
        /// 미리 보기 뒤 저널(실제 절차는 드라이 런 저널을 닫힌 상태로 남길 수 있다)
        var journalAfterPreview: UsbJournalInfo?
        var writeResult: Result<UsbWriteReport, UsbError> = .success(UsbWriteReport(outcome: .written, session: "s1", filesCreated: 12))
        var journalAfterWrite: UsbJournalInfo?
        /// 쓰는 동안 차례로 보낼 진행
        var writeProgress: [UsbProgress] = []
        /// 참이면 진행을 보낸 뒤 취소를 기다린다(파일 단계)
        var waitForCancel = false
        var recoverResult: Result<UsbWriteReport, UsbError> = .success(UsbWriteReport(outcome: .recovered, session: "s1"))
        var journalAfterRecover: UsbJournalInfo?
        var restoreResult: Result<UsbWriteReport, UsbError> = .success(UsbWriteReport(outcome: .restored, session: "s1"))
        /// 참이면 기기 변경을 버린다고 하지 않은 되돌리기를 `deviceChanged`로 막는다
        var deviceChanged = false
        var backup: URL?
        var calls: [String] = []
        /// USB 파일 연산 수(가짜는 끝까지 간 쓰기·회복·되돌리기만 센다)
        var fileOperations = 0
        /// DB 교체까지 갔는지
        var committed = false
    }

    private let lock = NSLock()
    private var state = State()

    func update(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }
    var current: State { lock.withLock { state } }

    func journal(volumeKey: String) -> UsbJournalInfo { lock.withLock { state.journal } }

    func preview(_ job: UsbExportJob) throws -> UsbExportSummary {
        lock.withLock {
            state.calls.append("preview")
            if let next = state.journalAfterPreview { state.journal = next }
            return state.summary
        }
    }

    func write(_ job: UsbExportJob, progress: @escaping @Sendable (UsbProgress) -> Void,
               isCancelled: @escaping @Sendable () -> Bool) throws -> UsbWriteReport {
        let (steps, wait) = lock.withLock { () -> ([UsbProgress], Bool) in
            state.calls.append("write")
            return (state.writeProgress, state.waitForCancel)
        }
        for step in steps { progress(step) }
        if wait {
            let deadline = Date().addingTimeInterval(5)
            while !isCancelled(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if isCancelled() { throw UsbError.cancelled }
        }
        return try lock.withLock {
            if let next = state.journalAfterWrite { state.journal = next }
            if case .success = state.writeResult {
                state.committed = true
                state.fileOperations += 1
            }
            return try state.writeResult.get()
        }
    }

    func recover(_ volume: UsbVolumeInfo) throws -> UsbWriteReport {
        try lock.withLock {
            state.calls.append("recover")
            let report = try state.recoverResult.get()
            state.fileOperations += 1
            if let next = state.journalAfterRecover { state.journal = next }
            return report
        }
    }

    func restore(_ volume: UsbVolumeInfo, discardDeviceChanges: Bool) throws -> UsbWriteReport {
        try lock.withLock {
            state.calls.append(discardDeviceChanges ? "restore(discard)" : "restore")
            if state.deviceChanged, !discardDeviceChanges {
                throw UsbError.writeRefused([UsbBlock(code: "deviceChanged", scope: .volume, message: "기기 변경")])
            }
            let report = try state.restoreResult.get()
            state.fileOperations += 1
            return report
        }
    }

    func latestBackup(volumeKey: String) -> URL? { lock.withLock { state.backup } }
}

/// 토스트를 받는 가짜 앱
@MainActor
final class FakeUsbWriteHost: UsbWriteHost {
    var toast: AppToast?
}

extension UsbTestData {
    /// 미리 보기 요약(곡 3·목록 1, 막힘 없음)
    static func summary(tracks: Int = 3, playlists: Int = 1, blocks: [UsbBlock] = [], rules: [UsbProvisionalRule: Int] = [:],
                        required: Int64 = 2 << 20, available: Int64 = 100 << 20, hasChanges: Bool = true,
                        testVolume: Bool = true) -> UsbExportSummary {
        UsbExportSummary(trackCount: tracks, playlistCount: playlists, blocks: blocks, ruleCounts: rules, requiredRules: Set(rules.keys),
                         requiredBytes: required, availableBytes: available, hasChanges: hasChanges, isTestVolume: testVolume)
    }

    static var physicalBlock: UsbBlock {
        UsbBlock(code: "physicalDisabled", scope: .volume,
                 message: "실물 USB 쓰기는 아직 열리지 않았습니다. 디스크 이미지로만 시험할 수 있습니다", rule: .physicalVolume)
    }
}

@MainActor
@Suite("USB 내보내기 흐름(UsbWriteCoordinator)")
struct UsbWriteCoordinatorTests {
    let image = FakeUsbVolume.diskImageFAT32(name: "B12T")
    let prompter = ScriptedPrompter()
    let service = FakeUsbWriteService()
    let host = FakeUsbWriteHost()

    func store(_ volumes: [UsbVolumeInfo]? = nil, journal: @escaping @Sendable (String) -> UsbJournalInfo = { _ in .none })
        -> (UsbStore, FakeUsbHost) {
        let usbHost = FakeUsbHost(volumes ?? [image])
        for volume in volumes ?? [image] { usbHost.serveEmpty(volume) }
        let usb = UsbStore(host: usbHost, readPolicy: .all, localLibrary: { nil }, physicalLists: { UsbTestData.lists() },
                           journal: journal)
        return (usb, usbHost)
    }

    func coordinator(_ usb: UsbStore, running: Bool = false, opened: ((URL) -> Void)? = nil) -> UsbWriteCoordinator {
        UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter, isRekordboxRunning: { running },
                            openFolder: opened ?? { _ in })
    }

    func job(_ volume: UsbVolumeInfo? = nil) -> UsbExportJob {
        UsbExportJob(database: URL(filePath: "/tmp/djc-fixture/m.db"), share: URL(filePath: "/tmp/djc-fixture/share"),
                     volume: volume ?? image, selection: .playlists(["10"]), formats: UsbFormat.defaultSet, snapshotTime: nil)
    }

    // MARK: - 확인·취소·실패 문구

    @Test("확인 창은 곡·목록 수·공간·막힘·확인 안 된 규칙을 보이고, 취소하면 쓰지 않는다. 실패는 되돌린 결과를 알린다")
    func confirmCancelFailRestoreMessages() async {
        let (usb, _) = store()
        let blocks = [UsbBlock(code: "audioSizeMismatch", scope: .track("7"), message: "rekordbox에서 다시 분석한 뒤 내보내세요"),
                      UsbBlock(code: "audioSizeMismatch", scope: .track("8"), message: "rekordbox에서 다시 분석한 뒤 내보내세요")]
        service.update { $0.summary = UsbTestData.summary(blocks: blocks, rules: [.analysisFolderNaming: 3]) }
        prompter.answer = false
        await coordinator(usb).export(job())

        let confirm = prompter.shown.last
        #expect(confirm?.title == "곡 3개·재생 목록 1개를 USB에 쓸까요?")
        #expect(confirm?.confirm == "USB에 쓰기")
        #expect(confirm?.text.contains("B12T") == true)
        #expect(confirm?.details.contains("시험 볼륨(디스크 이미지)입니다") == true)
        #expect(confirm?.details.contains("필요 공간 2MB · 여유 100MB") == true)
        #expect(confirm?.details.contains("빼고 쓰는 곡 2개:") == true)
        #expect(confirm?.details.contains("• rekordbox에서 다시 분석한 뒤 내보내세요 (2)") == true)
        #expect(confirm?.details.contains("확인 안 된 규칙 1개:") == true)
        #expect(confirm?.details.contains("• \(UsbProvisionalRule.analysisFolderNaming.summary) (3)") == true)
        #expect(service.current.calls == ["preview"])
        #expect(host.toast == nil)
        #expect(usb.busyVolumes.isEmpty)
        #expect(usb.activeWrite == nil)

        // 쓰다가 되돌림: 결과와 백업 폴더 열기
        var opened: [URL] = []
        let backup = URL(filePath: "/tmp/djc-fixture/usb-backups/B/1")
        service.update {
            $0.writeResult = .failure(.writeRolledBack(reason: "verify"))
            $0.backup = backup
        }
        prompter.answer = true
        prompter.shown = []
        await coordinator(usb, opened: { opened.append($0) }).export(job())
        let rolledBack = prompter.shown.last
        #expect(rolledBack?.title == "USB에 쓴 결과를 확인하지 못해 쓰기 전으로 되돌렸습니다")
        #expect(rolledBack?.text == "USB는 쓰기 전 그대로입니다. USB를 다시 읽은 뒤 다시 시도하세요.")
        #expect(rolledBack?.confirm == "백업 폴더 열기")
        #expect(opened == [backup])

        // 되돌리지도 못함: 기기에 꽂지 말라는 경고
        service.update { $0.writeResult = .failure(.restoreFailed(reason: "verify", restoreError: "rename", backup: backup.path)) }
        prompter.answers = [true, false]
        prompter.shown = []
        await coordinator(usb).export(job())
        let failed = prompter.shown.first { $0.title == "USB를 쓰기 전 상태로 되돌리지 못했습니다" }
        #expect(failed?.critical == true)
        #expect(failed?.text == "USB를 기기에 꽂지 마세요. USB를 다시 연결하면 나오는 알림에서 회복하세요.")
        #expect(failed?.confirm == "백업 폴더 열기")
        #expect(usb.busyVolumes.isEmpty)
    }

    @Test("DB 교체 전에 취소하면 USB는 그대로이고 취소를 알린다")
    func cancelBeforeCommitLeavesVolume() async throws {
        let (usb, _) = store()
        service.update {
            $0.writeProgress = [UsbProgress(phase: .backup, cancellable: true),
                                UsbProgress(phase: .files, completedItems: 1, totalItems: 9, completedBytes: 10, totalBytes: 90, cancellable: true)]
            $0.waitForCancel = true
        }
        let coordinator = coordinator(usb)
        let task = Task { await coordinator.export(job()) }
        for _ in 0..<500 where usb.activeWrite?.progress?.phase != .files { try await Task.sleep(for: .milliseconds(10)) }
        #expect(usb.activeWrite?.progress?.phase == .files)
        #expect(usb.busyVolumes == [image.usbKey])
        usb.cancelWrite()
        await task.value
        #expect(!service.current.committed)
        #expect(service.current.fileOperations == 0)
        #expect(host.toast?.title == "USB 쓰기를 취소했습니다")
        #expect(host.toast?.detail == "USB는 쓰기 전 그대로입니다.")
        #expect(usb.activeWrite == nil)
        #expect(usb.busyVolumes.isEmpty)
    }

    @Test("실물 볼륨은 관문 막힘을 그대로 보이고 쓰지 않는다")
    func physicalVolumeWriteDisabled() async {
        let physical = FakeUsbVolume.physicalFAT32()
        let (usb, _) = store([physical])
        service.update { $0.summary = UsbTestData.summary(blocks: [UsbTestData.physicalBlock], testVolume: false) }
        await coordinator(usb).export(job(physical))
        #expect(service.current.calls == ["preview"])
        let shown = prompter.shown.last
        #expect(shown?.confirm == nil)
        #expect(shown?.title == "USB에 쓸 수 없습니다")
        #expect(shown?.text.contains("실물 USB 쓰기는 아직 열리지 않았습니다") == true)
        let summary = service.current.summary
        #expect(summary.isPhysicalDisabled)
        #expect(!summary.canWrite)
    }

    @Test("rekordbox가 켜져 있으면 미리 보기도 하지 않는다")
    func rekordboxRunningBlocks() async {
        let (usb, _) = store()
        await coordinator(usb, running: true).export(job())
        #expect(await coordinator(usb, running: true).preview(job()) == nil)
        #expect(service.current.calls.isEmpty)
        #expect(prompter.shown.first?.title == "rekordbox가 켜져 있어 USB에 쓰지 않았습니다")
        #expect(usb.busyVolumes.isEmpty)
    }

    @Test("같은 볼륨에 쓰는 중이면 두 번째 쓰기는 막는다")
    func busyVolumeBlocksSecondWrite() async {
        let (usb, _) = store()
        await usb.refresh()
        let flag = usb.beginWrite(image, title: "시험")
        #expect(flag != nil)
        #expect(usb.beginWrite(image, title: "두 번째") == nil)
        await coordinator(usb).export(job())
        #expect(service.current.calls.isEmpty)
        #expect(prompter.shown.last?.title == "이 USB에 쓰는 중입니다")
        #expect(await usb.eject(image.usbKey) == "USB에 쓰는 중입니다. 쓰기가 끝난 뒤 꺼내세요")
        usb.endWrite(image.usbKey)
        #expect(usb.busyVolumes.isEmpty)
    }

    // MARK: - 끝나지 않은 쓰기

    @Test("끝나지 않은 쓰기 알림: 회복·되돌리기·나중에")
    func pendingJournalPrompt() async {
        let (usb, _) = store()
        service.update { $0.journal = .state(.filesWritten) }
        prompter.choices = [.confirm]
        await coordinator(usb).offerRecovery(image)
        let prompt = prompter.shown.last
        #expect(prompt?.title == "지난 USB 쓰기가 끝나지 않았습니다")
        #expect(prompt?.confirm == "회복하기")
        #expect(prompt?.alternate == "되돌리기…")
        #expect(prompt?.cancel == "나중에")
        #expect(service.current.calls == ["recover"])
        #expect(host.toast?.title == "USB 쓰기를 마저 끝냈습니다")

        // 되돌리기: 저널을 먼저 닫고(회복) 그 쓰기의 백업으로 되돌린다
        service.update { $0.calls = [] }
        prompter.choices = [.alternate]
        await coordinator(usb).offerRecovery(image)
        #expect(service.current.calls == ["recover", "restore"])
        #expect(host.toast?.title == "USB를 쓰기 전으로 되돌렸습니다")

        // 나중에: 아무것도 하지 않는다
        service.update { $0.calls = [] }
        host.toast = nil
        prompter.choices = [.cancel]
        await coordinator(usb).offerRecovery(image)
        #expect(service.current.calls.isEmpty)
        #expect(host.toast == nil)
        #expect(usb.busyVolumes.isEmpty)
    }

    @Test("미리 보기가 드라이 런 저널을 남겨도 쓰기로 가고, 끝나지 않은 쓰기로 알리지 않는다")
    func previewThenWriteNotBlocked() async {
        var appeared: [String] = []
        let journal = service
        let (usb, usbHost) = store(journal: { journal.journal(volumeKey: $0) })
        usb.onPendingJournal = { appeared.append($0.usbKey) }
        service.update { $0.journalAfterPreview = .state(.dryRun) }
        await coordinator(usb).export(job())
        #expect(service.current.calls == ["preview", "write"])
        #expect(prompter.shown.count == 1)
        #expect(prompter.shown.first?.confirm == "USB에 쓰기")
        #expect(host.toast?.title == "곡 3개를 USB에 썼습니다")
        // 미리 보기를 두 번 해도 같다. 볼륨이 다시 나타나도 알리지 않는다
        #expect(await coordinator(usb).preview(job()) != nil)
        #expect(service.current.calls == ["preview", "write", "preview"])
        usbHost.mounted = []
        await usb.refresh()
        usbHost.mounted = [image]
        await usb.refresh()
        #expect(appeared.isEmpty)
        #expect(UsbJournalInfo.state(.dryRun).isPending == false)
        #expect(UsbJournalInfo.state(.needsReplan).isPending == false)
        #expect(UsbJournalInfo.state(.committing).isPending)
    }

    @Test("회복이 다시 계획하라고 하면 다시 미리 보기를 권하고, 그 볼륨을 다시 알리지 않는다")
    func needsReplanOffersNewPreview() async {
        var appeared: [String] = []
        let journal = service
        let (usb, usbHost) = store(journal: { journal.journal(volumeKey: $0) })
        usb.onPendingJournal = { appeared.append($0.usbKey) }
        // 쓰다가 USB가 빠짐: 저널이 열린 채 남는다
        service.update {
            $0.writeResult = .failure(.volumeLost(volumeName: "B12T"))
            $0.journalAfterWrite = .state(.filesWritten)
        }
        await coordinator(usb).export(job())
        #expect(prompter.shown.last?.title == "USB 연결이 끊겼습니다")
        // 다시 나타나면 알린다(자동으로 회복하지 않는다)
        usbHost.mounted = []
        await usb.refresh()
        usbHost.mounted = [image]
        await usb.refresh()
        #expect(appeared == [image.usbKey])
        #expect(!service.current.calls.contains("recover"))

        service.update {
            $0.recoverResult = .success(UsbWriteReport(outcome: .needsReplan, session: "s1"))
            $0.journalAfterRecover = .state(.needsReplan)
        }
        prompter.choices = [.confirm]
        prompter.answers = [true, false]
        await coordinator(usb).offerRecovery(image)
        let replan = prompter.shown.first { $0.confirm == "다시 미리 보기" }
        #expect(replan?.title == "USB 쓰기를 이어 하지 않았습니다")
        #expect(replan?.text == "USB가 기기에서 바뀌어 이어 쓰지 않았습니다. 지금 USB 상태로 다시 미리 보기한 뒤 쓰세요")
        #expect(service.current.calls == ["preview", "write", "recover", "preview"])
        #expect(usb.exportSheet?.volumeKey == image.usbKey)
        #expect(usb.exportSheet?.summary != nil)

        // 닫힌 저널(다시 계획)은 볼륨이 다시 나타나도 알리지 않는다
        usbHost.mounted = []
        await usb.refresh()
        usbHost.mounted = [image]
        await usb.refresh()
        #expect(appeared == [image.usbKey])
    }

    @Test("실물 볼륨의 끝나지 않은 쓰기: 회복을 눌러도 관문 막힘 문구만 보이고 파일은 건드리지 않는다")
    func pendingJournalOnPhysicalShowsBlocked() async {
        let physical = FakeUsbVolume.physicalFAT32()
        let (usb, _) = store([physical])
        service.update {
            $0.journal = .state(.committing)
            $0.recoverResult = .failure(.writeRefused([UsbTestData.physicalBlock]))
        }
        prompter.choices = [.confirm]
        await coordinator(usb).offerRecovery(physical)
        #expect(service.current.calls == ["recover"])
        #expect(service.current.fileOperations == 0)
        let shown = prompter.shown.last
        #expect(shown?.title == "USB를 회복하지 않았습니다")
        #expect(shown?.text.contains("실물 USB 쓰기는 아직 열리지 않았습니다") == true)
        // 되돌리기도 같은 막힘에서 멈춘다(되돌리기까지 가지 않는다)
        prompter.choices = [.alternate]
        await coordinator(usb).offerRecovery(physical)
        #expect(service.current.calls == ["recover", "recover"])
        #expect(service.current.fileOperations == 0)
    }

    @Test("볼륨이 나타나도 사용자가 누르기 전에는 회복하지 않는다")
    func recoverNeverAutomatic() async {
        var appeared: [UsbVolumeInfo] = []
        let journal = service
        service.update { $0.journal = .state(.committing) }
        let (usb, _) = store(journal: { journal.journal(volumeKey: $0) })
        usb.onPendingJournal = { appeared.append($0) }
        await usb.refresh()
        #expect(appeared.map(\.usbKey) == [image.usbKey])
        // 붙어 있는 동안 다시 읽어도 또 알리지 않는다
        await usb.refresh()
        #expect(appeared.count == 1)
        #expect(service.current.calls.isEmpty)
        prompter.choices = [.cancel]
        await coordinator(usb).offerRecovery(image)
        #expect(service.current.calls.isEmpty)
        #expect(service.current.fileOperations == 0)
        // 끝난 저널이면 알리지 않는다
        service.update { $0.journal = .none }
        prompter.shown = []
        await coordinator(usb).offerRecovery(image)
        #expect(prompter.shown.isEmpty)
    }

    @Test("기기가 그 뒤에 쓴 것이 있으면 되돌리기 전에 한 번 더 묻는다")
    func discardDeviceChangesConfirm() async {
        let (usb, _) = store()
        service.update {
            $0.journal = .state(.committed)
            $0.deviceChanged = true
        }
        prompter.choices = [.alternate]
        prompter.answers = [false]
        await coordinator(usb).offerRecovery(image)
        let confirm = prompter.shown.last
        #expect(confirm?.text.contains("기기가 그 뒤에 쓴 내용을 잃습니다") == true)
        #expect(confirm?.destructive == true)
        #expect(confirm?.confirm == "되돌리기")
        #expect(service.current.calls == ["recover", "restore"])

        service.update { $0.calls = [] }
        prompter.choices = [.alternate]
        prompter.answers = [true]
        await coordinator(usb).offerRecovery(image)
        #expect(service.current.calls == ["recover", "restore", "restore(discard)"])
        #expect(host.toast?.title == "USB를 쓰기 전으로 되돌렸습니다")
    }

    // MARK: - 토스트·진행

    @Test("다 쓰면 곡 수와 꺼내기를 알리고, 꺼내기를 누르면 그 볼륨을 꺼낸다")
    func toastEjectAction() async {
        let (usb, usbHost) = store()
        await usb.refresh()
        let coordinator = coordinator(usb)
        await coordinator.export(job())
        #expect(host.toast?.kind == .success)
        #expect(host.toast?.title == "곡 3개를 USB에 썼습니다")
        #expect(host.toast?.action == .ejectUsb(volumeKey: image.usbKey))
        #expect(host.toast?.action?.title == "꺼내기")
        #expect(usb.lastExports[image.usbKey] == job())
        if let action = host.toast?.action { await coordinator.perform(action) }
        #expect(usbHost.ejectCalls == [image.usbKey])
        #expect(usb.volume(image.usbKey) == nil)
    }

    @Test("DB 교체가 시작되면 취소 단추를 숨기고 취소를 받지 않는다")
    func progressHidesCancelAfterCommit() {
        let (usb, _) = store()
        let flag = usb.beginWrite(image, title: "시험")
        usb.report(UsbProgress(phase: .files, completedItems: 2, totalItems: 8, completedBytes: 1 << 20, totalBytes: 4 << 20,
                               cancellable: true), for: image.usbKey)
        let files = UsbWriteProgressModel(usb.activeWrite!)
        #expect(files.showsCancel)
        #expect(files.items == "2/8")
        #expect(files.phase == "파일 쓰기")
        usb.report(UsbProgress(phase: .commit, completedItems: 1, totalItems: 3, cancellable: false), for: image.usbKey)
        let commit = UsbWriteProgressModel(usb.activeWrite!)
        #expect(!commit.showsCancel)
        #expect(commit.phase == "DB 교체")
        usb.cancelWrite()
        #expect(flag?.isSet == false)
        // 다른 볼륨의 진행은 받지 않는다
        usb.report(UsbProgress(phase: .files, cancellable: true), for: "other")
        #expect(usb.activeWrite?.progress?.phase == .commit)
        usb.endWrite(image.usbKey)
        #expect(usb.activeWrite == nil)
    }
}
