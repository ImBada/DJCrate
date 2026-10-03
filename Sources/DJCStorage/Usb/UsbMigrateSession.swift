import DJCDomain
import Foundation
import RekordboxKit

/// Device Library(`export.pdb`)만 있는 USB에 OneLibrary(`exportLibrary.db`)를 더한다(#46, `djc usb-migrate`).
/// 순서: 볼륨(정책·보호 경로·관문, 막히면 USB를 열거하지 않는다) → 저널 → USB DB 사본 → 계획(`UsbMigration.plan`, 준비 폴더)
/// → 확인 안 된 규칙 → `UsbWriter.write`(검사기 `UsbMigrationInspector`, 검증기 목표 지문·새 OneLibrary·불변식).
/// 원래 파일(pdb 둘·분석 파일·음원·a 그림)은 바꾸지 않는다. 사본·준비 폴더는 세션이 끝나면 지운다.
public final class UsbMigrateSession {
    let root: URL
    let writeGuard: UsbWriteGuard
    let paths: UsbWritePaths
    let fileSystem: any UsbFileSystem
    let copies: URL

    /// - copies: USB DB 사본(`usb-<세션>/`)을 둘 곳
    public init(root: URL, guard writeGuard: UsbWriteGuard = .system, paths: UsbWritePaths = .default,
                fileSystem: any UsbFileSystem = PosixUsbFileSystem(), copies: URL = DJCPaths.usbSnapshots) {
        self.root = root
        self.writeGuard = writeGuard
        self.paths = paths
        self.fileSystem = fileSystem
        self.copies = copies
    }

    /// 계획만(USB에 쓰지 않는다). 준비 폴더는 지운다
    public func preview(options: UsbWriteOptions) throws -> UsbMigrationResult {
        let (result, staging) = try prepare(options: options)
        if let staging { try? FileManager.default.removeItem(at: staging) }
        return result
    }

    /// 계획하고 쓴다(`options.dryRun`이면 준비·저널까지). 막히면 `writeRefused`
    public func write(options: UsbWriteOptions, progress: @escaping @Sendable (UsbProgress) -> Void,
                      isCancelled: @escaping @Sendable () -> Bool) throws -> (UsbMigrationResult, UsbWriteReport?) {
        progress(UsbProgress(phase: .planning, cancellable: true))
        let (result, staging) = try prepare(options: options)
        // 끝나지 않은 쓰기(볼륨이 사라짐·되돌리기 실패)는 회복이 준비 폴더를 쓸 수 있어 남긴다
        var keepStaging = false
        defer { if !keepStaging, let staging { try? FileManager.default.removeItem(at: staging) } }
        guard result.blocks.isEmpty, let changes = result.changes else { throw UsbError.writeRefused(result.blocks) }
        // 쓰기 직전 USB의 `._*`(사용자·macOS가 둔 것)는 검증이 이 쓰기가 남긴 것으로 세지 않게
        let preexisting = try UsbInvariantVerifier.appleDoubles(on: UsbRoot(root))
        do {
            let report = try UsbWriter.write(changes, root: UsbRoot(root), paths: paths, guard: writeGuard, fileSystem: fileSystem,
                                             verifiers: result.verifiers(preexistingAppleDoubles: preexisting),
                                             inspectors: [UsbMigrationInspector()], options: options, ppthReader: UsbExportAssembly.ppthReader,
                                             progress: progress, isCancelled: isCancelled)
            return (result, report)
        } catch let error as UsbError {
            switch error {
            case .volumeLost, .restoreFailed, .restorePending: keepStaging = true
            default: break
            }
            throw error
        }
    }

    // MARK: - 순서

    func prepare(options: UsbWriteOptions) throws -> (UsbMigrationResult, URL?) {
        // 1. 볼륨(정책·보호 경로·관문). 막히면 USB를 열거하지도 사본을 뜨지도 않는다
        let volume = try writeGuard.volume(root)
        var result = UsbMigrationResult()
        result.blocks = environmentBlocks(volume, required: [], options: options)
        guard result.blocks.isEmpty else { return (result, nil) }
        let volumeKey = try UsbEditSession.volumeKey(volume)

        // 2. 저널: 끝나지 않은 쓰기는 막는다
        switch UsbWriter.journalStatus(paths: paths, volumeKey: volumeKey) {
        case .open:
            result.blocks = [UsbBlock(code: "recoveryNeeded", scope: .volume,
                                      message: String(ui: "지난 USB 쓰기가 끝나지 않았습니다. `djc usb-recover`로 먼저 회복하세요"))]
            return (result, nil)
        case .corrupt:
            result.blocks = [UsbBlock(code: "journalUnreadable", scope: .volume,
                                      message: String(ui: "회복 기록 파일을 읽지 못했습니다. DJCrate 데이터 폴더의 usb-sessions를 확인하세요"))]
            return (result, nil)
        case .closed, .missing: break
        }

        // 3. USB DB 사본 → 계획·준비. OneLibrary가 이미 있으면 사본을 뜨지 않고 막는다(손상된 사본을 열지 않게)
        let usbRoot = UsbRoot(root)
        if try UsbWriter.databaseFingerprint(root: usbRoot, fileSystem: fileSystem).files.keys.contains(where: { $0.hasPrefix(UsbLayout.oneLibrary) }) {
            result.blocks = [UsbMigration.Blocks.oneLibraryExists]
            return (result, nil)
        }
        let session = UsbLayout.newSessionID()
        let usbCopy = copies.appending(path: "usb-\(session)")
        defer { try? FileManager.default.removeItem(at: usbCopy) }
        let snapshot = try UsbSnapshot.take(root: usbRoot, into: usbCopy)
        let staging = paths.staging.appending(path: session)
        result = try UsbMigration.plan(snapshot: snapshot, root: usbRoot, fileSystem: fileSystem, staging: staging, session: session)

        // 4. 확인 안 된 규칙(실물 볼륨이면 관문이 막는다)
        if let changes = result.changes {
            let late = environmentBlocks(volume, required: changes.requiredRules, options: options)
            if !late.isEmpty {
                result.blocks += late
                result.changes = nil
            }
        }
        guard result.changes != nil else {
            try? FileManager.default.removeItem(at: staging)
            return (result, nil)
        }
        return (result, staging)
    }

    /// 볼륨 정책(수정)·보호 경로·실물 관문·확인 안 된 규칙(쓰기 절차의 A 단계와 같은 판정)
    func environmentBlocks(_ volume: UsbVolumeInfo, required: Set<UsbProvisionalRule>, options: UsbWriteOptions) -> [UsbBlock] {
        UsbExportSession.environmentBlocks(volume, root: root, required: required, allowProvisional: options.allowProvisional,
                                           confirmName: options.confirmName, purpose: .edit, guard: writeGuard)
    }
}
