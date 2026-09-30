import DJCDomain
import Foundation
import RekordboxKit

/// 이미 라이브러리가 있는 USB 수정. 편집(`UsbLibraryEdit`)을 계획하고 한 번에 쓴다.
/// 순서: 원본 확인 → 볼륨(정책·보호 경로·관문, 막히면 USB를 열거하지 않는다) → 저널 → USB DB 사본 → (곡 더하기·갱신이면) 세션 전용 로컬 사본
/// → 계획(`UsbEditEngine`) → 확인 안 된 규칙 → `UsbWriter.write`. 사본·준비 폴더는 세션이 끝나면 지운다.
public final class UsbEditSession {
    let root: URL
    let database: URL?
    let share: URL?
    let writeGuard: UsbWriteGuard
    let paths: UsbWritePaths
    let fileSystem: any UsbFileSystem
    let localCopy: @Sendable (_ database: URL, _ into: URL) throws -> URL
    let localCopies: URL
    let drafts: UsbDraftStore
    let appVersion: () -> String?
    let liveDatabases: [URL]

    /// 세션 사본 뜨기: 원본은 넘겨받은 사본이라 실행 중 확인·WAL 거부 없이 곁의 WAL을 사본 안에서 합친다(원본은 읽기만)
    public static let defaultLocalCopy: @Sendable (_ database: URL, _ into: URL) throws -> URL = { try LibrarySnapshot.take(from: $0, into: $1, force: true) }

    /// 마지막 계획(막혀 던졌을 때도 CLI·앱이 요약을 읽는다)
    public private(set) var lastResult: UsbEditResult?

    /// - database: 로컬 스냅샷 사본(곡 더하기·갱신·음원 지우기 확인에 쓴다. 라이브 master.db는 거부)
    /// - share: 로컬 rekordbox share(읽기만)
    /// - fileSystem: 시험은 마운트를 흉내 내는 파일 시스템을 넘긴다
    /// - localCopy: 세션 사본 뜨기. 원본은 넘겨받은 사본이라 실행 중 확인·WAL 거부 없이 곁의 WAL을 사본 안에서 합친다(원본은 읽기만).
    ///   그 함수 안의 옛 사본 정리는 목적지(세션 전용 `local-<세션>/`)만 본다
    /// - localCopies: 세션 사본(`local-<세션>/`)·USB DB 사본(`usb-<세션>/`)을 둘 곳
    public init(root: URL, database: URL?, share: URL?, guard writeGuard: UsbWriteGuard = .system, paths: UsbWritePaths = .default,
                fileSystem: any UsbFileSystem = PosixUsbFileSystem(),
                localCopy: @escaping @Sendable (_ database: URL, _ into: URL) throws -> URL = UsbEditSession.defaultLocalCopy,
                localCopies: URL = DJCPaths.usbSnapshots, drafts: UsbDraftStore = UsbDraftStore(),
                appVersion: @escaping () -> String? = { RekordboxCompatibility.installedAppVersion() }, liveDatabases: [URL] = []) {
        self.root = root
        self.database = database
        self.share = share
        self.writeGuard = writeGuard
        self.paths = paths
        self.fileSystem = fileSystem
        self.localCopy = localCopy
        self.localCopies = localCopies
        self.drafts = drafts
        self.appVersion = appVersion
        self.liveDatabases = liveDatabases
    }

    /// 계획만(USB에 쓰지 않는다). 준비 폴더는 지운다
    public func preview(_ edits: [UsbLibraryEdit], options: UsbWriteOptions, snapshotTime: String? = nil) throws -> UsbEditResult {
        let prepared = try prepare(.edits(edits), options: options, snapshotTime: snapshotTime, progress: { _ in }, isCancelled: { false })
        if let staging = prepared.staging { try? FileManager.default.removeItem(at: staging) }
        lastResult = prepared.result
        return prepared.result
    }

    /// 계획하고 쓴다(`options.dryRun`이면 준비·저널까지). 쓸 것이 없으면 보고서 nil. USB 전체가 막히면 `writeRefused`
    public func write(_ edits: [UsbLibraryEdit], options: UsbWriteOptions, snapshotTime: String? = nil,
                      progress: @escaping @Sendable (UsbProgress) -> Void, isCancelled: @escaping @Sendable () -> Bool) throws -> (UsbEditResult, UsbWriteReport?) {
        try run(.edits(edits), options: options, snapshotTime: snapshotTime, progress: progress, isCancelled: isCancelled)
    }

    /// 이 USB의 초안을 쓴다. 초안을 만든 뒤 USB가 바뀌었으면 지금 상태에 다시 계획한다.
    /// 쓴 뒤(또는 쓸 것이 없을 때) 초안에는 막힌 편집만 남기고(base는 그때 USB DB 지문), 막힌 것이 없으면 초안을 지운다
    public func writeDraft(options: UsbWriteOptions, snapshotTime: String? = nil, progress: @escaping @Sendable (UsbProgress) -> Void,
                           isCancelled: @escaping @Sendable () -> Bool) throws -> (UsbEditResult, UsbWriteReport?) {
        try run(.draft, options: options, snapshotTime: snapshotTime, progress: progress, isCancelled: isCancelled)
    }

    /// 편집 하나를 이 USB의 초안에 더한다(초안이 없으면 지금 USB DB 지문을 base로 만든다)
    public func addToDraft(_ edit: UsbLibraryEdit) throws {
        let volume = try writeGuard.volume(root)
        let blocks = environmentBlocks(volume, required: [], options: UsbWriteOptions())
        guard blocks.isEmpty else { throw UsbError.writeRefused(blocks) }
        try drafts.append(edit, volumeKey: try Self.volumeKey(volume),
                          base: UsbWriter.databaseFingerprint(root: UsbRoot(root), fileSystem: fileSystem))
    }

    // MARK: - 순서

    enum Edits {
        case edits([UsbLibraryEdit])
        case draft
    }

    struct Prepared {
        var result: UsbEditResult
        var staging: URL?
        var draftKey: String?
        /// 계획한 편집(적힌 순서, 결과 번호 1부터와 짝)
        var edits: [UsbLibraryEdit] = []
    }

    func run(_ edits: Edits, options: UsbWriteOptions, snapshotTime: String?, progress: @escaping @Sendable (UsbProgress) -> Void,
             isCancelled: @escaping @Sendable () -> Bool) throws -> (UsbEditResult, UsbWriteReport?) {
        let prepared = try prepare(edits, options: options, snapshotTime: snapshotTime, progress: progress, isCancelled: isCancelled)
        lastResult = prepared.result
        // 끝나지 않은 쓰기(볼륨이 사라짐·되돌리기 실패)는 회복이 준비 폴더를 쓸 수 있어 남긴다
        var keepStaging = false
        defer { if !keepStaging, let staging = prepared.staging { try? FileManager.default.removeItem(at: staging) } }
        let result = prepared.result
        guard result.blocks.isEmpty else { throw UsbError.writeRefused(result.blocks) }
        guard let changes = result.changes else {
            if !options.dryRun, let key = prepared.draftKey { try keepBlockedEdits(prepared, volumeKey: key) }
            return (result, nil)
        }
        // 쓰기 직전 USB의 `._*`(사용자·macOS가 둔 것)는 검증이 이 쓰기가 남긴 것으로 세지 않게
        let preexisting = try UsbInvariantVerifier.appleDoubles(on: UsbRoot(root))
        do {
            var report = try UsbWriter.write(changes, root: UsbRoot(root), paths: paths, guard: writeGuard, fileSystem: fileSystem,
                                             verifiers: result.verifiers(preexistingAppleDoubles: preexisting), inspectors: [UsbEditInspector()],
                                             options: options, ppthReader: UsbExportAssembly.ppthReader, progress: progress,
                                             isCancelled: isCancelled)
            report.blocks += result.trackBlocks
            if report.outcome == .written, let key = prepared.draftKey { try keepBlockedEdits(prepared, volumeKey: key) }
            return (result, report)
        } catch let error as UsbError {
            switch error {
            case .volumeLost, .restoreFailed, .restorePending: keepStaging = true
            default: break
            }
            throw error
        }
    }

    func prepare(_ edits: Edits, options: UsbWriteOptions, snapshotTime: String?, progress: @escaping @Sendable (UsbProgress) -> Void,
                 isCancelled: @escaping @Sendable () -> Bool) throws -> Prepared {
        // 1. 원본: 라이브 master.db면 열지 않고 거부
        if let database { try UsbExportSession.refuseLive(database, liveDatabases: liveDatabases) }
        progress(UsbProgress(phase: .planning, cancellable: true))
        // 2. 볼륨(정책·보호 경로·관문). 막히면 USB를 열거하지도 사본을 뜨지도 않는다
        let volume = try writeGuard.volume(root)
        let environment = environmentBlocks(volume, required: [], options: options)
        guard environment.isEmpty else { return Prepared(result: UsbEditResult(blocks: environment)) }
        let volumeKey = try Self.volumeKey(volume)

        // 3. 편집(초안이면 base와 지금 USB를 견준다)
        var notes: [String] = []
        let list: [UsbLibraryEdit]
        var draftKey: String?
        switch edits {
        case let .edits(given): list = given
        case .draft:
            guard let draft = try drafts.load(volumeKey: volumeKey) else {
                return Prepared(result: UsbEditResult(blocks: [UsbBlock(code: "noDraft", scope: .volume,
                                                                        message: String(ui: "이 USB에 쌓인 초안이 없습니다. 편집을 먼저 더하세요"))]))
            }
            list = draft.edits
            draftKey = volumeKey
            if !(try UsbWriter.databaseFingerprint(root: UsbRoot(root), fileSystem: fileSystem)).sameContent(as: draft.base) {
                notes.append(Self.replannedNote)
            }
        }

        // 4. 저널: 끝나지 않은 쓰기는 막고, 닫힌 저널의 ID highWater를 이어 쓴다. 기기가 바꿔 다시 계획하라고 닫힌 볼륨은 지금 상태로 계획한다
        var highWater: [String: Int] = [:]
        switch UsbWriter.journalStatus(paths: paths, volumeKey: volumeKey) {
        case .open:
            return Prepared(result: UsbEditResult(blocks: [UsbBlock(code: "recoveryNeeded", scope: .volume,
                                                                    message: String(ui: "지난 USB 쓰기가 끝나지 않았습니다. `djc usb-recover`로 먼저 회복하세요"))]))
        case .corrupt:
            return Prepared(result: UsbEditResult(blocks: [UsbBlock(code: "journalUnreadable", scope: .volume,
                                                                    message: String(ui: "회복 기록 파일을 읽지 못했습니다. DJCrate 데이터 폴더의 usb-sessions를 확인하세요"))]))
        case let .closed(journal):
            highWater = journal.changes.idHighWater
            if journal.state == .needsReplan, !notes.contains(Self.replannedNote) { notes.append(Self.replannedNote) }
        case .missing: break
        }

        // 5. 스냅샷 시각은 세션 사본을 뜨기 전에 원본에서 푼다(곡 더하기·갱신이 쓰고, 요약 첫 줄에 출처를 적는다)
        let needsLocal = list.contains {
            switch $0 {
            case .addTracks, .refreshTracks: true
            case .removeTracks, .playlist: false
            }
        }
        var snapshot: (date: Date, source: UsbSnapshotTime.Source)?
        if let database { snapshot = try UsbSnapshotTime.resolve(explicit: snapshotTime, database: database) }

        // 6. USB DB 사본 → 읽기·합치기·전제
        let session = UsbLayout.newSessionID()
        let usbCopy = localCopies.appending(path: "usb-\(session)")
        defer { try? FileManager.default.removeItem(at: usbCopy) }
        let source = try UsbEditEngine.load(root: UsbRoot(root), into: usbCopy)

        // 7. 세션 전용 로컬 사본(곡 더하기·갱신이 있을 때만). 끝나면(성공·실패·취소) 지운다
        let copyFolder = localCopies.appending(path: "local-\(session)")
        defer { try? FileManager.default.removeItem(at: copyFolder) }
        var localDatabase: CipherDatabase?
        defer { localDatabase?.close() }
        if needsLocal, let database, source.blocks.isEmpty {
            let copy = try localCopy(database, copyFolder)
            localDatabase = try CipherDatabase.diagnostic(path: copy.path, key: RekordboxKey.derive())
        }

        // 8. 계획·준비
        let staging = paths.staging.appending(path: session)
        var result: UsbEditResult
        do {
            result = try UsbEditEngine.plan(
                source: source, edits: list, localDatabase: localDatabase, share: share, volume: volume, existingFiles: UsbRoot(root),
                fileSystem: fileSystem, staging: staging, session: session, highWater: highWater, snapshotTakenAt: snapshot?.date,
                localAppVersion: appVersion(),
                progress: { done, total in progress(UsbProgress(phase: .staging, completedItems: done, totalItems: total, cancellable: true)) },
                isCancelled: isCancelled)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        result.snapshotTakenAt = snapshot?.date
        result.snapshotSource = snapshot?.source
        result.notes = notes + result.notes
        // 9. 확인 안 된 규칙(실물 볼륨이면 관문이 막는다)
        if let changes = result.changes {
            let late = environmentBlocks(volume, required: changes.requiredRules, options: options)
            if !late.isEmpty {
                result.blocks += late
                result.changes = nil
            }
        }
        guard result.changes != nil else {
            try? FileManager.default.removeItem(at: staging)
            return Prepared(result: result, draftKey: draftKey, edits: list)
        }
        return Prepared(result: result, staging: staging, draftKey: draftKey, edits: list)
    }

    static var replannedNote: String { String(ui: "USB가 그 사이 바뀌어 다시 계획했습니다") }

    /// 초안에 막힌 편집만 남긴다(적힌 순서). 막힌 편집은 새 스냅샷·기기 변경 가져오기 등으로 풀릴 수 있어 사용자가 다시 만들지 않게 두고,
    /// 쓴 편집·바꿀 것이 없던 편집은 뺀다. 새 base는 지금 USB DB 지문이다. 남는 것이 없으면 초안을 지운다
    func keepBlockedEdits(_ prepared: Prepared, volumeKey: String) throws {
        let blocked = prepared.result.outcomes.compactMap { entry -> UsbLibraryEdit? in
            guard case .blocked = entry.outcome, prepared.edits.indices.contains(entry.edit - 1) else { return nil }
            return Self.resolveCreatedPlaylists(in: prepared.edits[entry.edit - 1], ids: prepared.result.createdPlaylistIDs)
        }
        guard !blocked.isEmpty else {
            try drafts.discard(volumeKey: volumeKey)
            return
        }
        let createdAt = try drafts.load(volumeKey: volumeKey)?.createdAt ?? Date()
        try drafts.save(UsbDraft(volumeKey: volumeKey, base: UsbWriter.databaseFingerprint(root: UsbRoot(root), fileSystem: fileSystem),
                                 edits: blocked, createdAt: createdAt))
    }

    /// 성공한 생성 편집은 초안에서 빠지므로 그 목록을 가리키는 참조는 실제 번호로 남긴다. 아직 만들지 못한 key는 그대로 둔다
    private static func resolveCreatedPlaylists(in edit: UsbLibraryEdit, ids: [String: Int]) -> UsbLibraryEdit {
        func ref(_ value: PlaylistRef) -> PlaylistRef {
            guard case let .new(key) = value, let id = ids[key] else { return value }
            return .id(String(id))
        }
        switch edit {
        case let .addTracks(localContentIDs, playlist):
            return .addTracks(localContentIDs: localContentIDs, playlist: playlist.map(ref))
        case .removeTracks, .refreshTracks: return edit
        case let .playlist(edit):
            let resolved: PlaylistEdit
            switch edit {
            case let .create(key, name, isFolder, parent):
                resolved = .create(key: key, name: name, isFolder: isFolder, parent: ref(parent))
            case let .rename(playlist, name): resolved = .rename(playlist: ref(playlist), name: name)
            case let .move(playlist, into): resolved = .move(playlist: ref(playlist), into: ref(into))
            case let .reorder(playlist, index): resolved = .reorder(playlist: ref(playlist), index: index)
            case let .delete(playlist): resolved = .delete(playlist: ref(playlist))
            case let .addTracks(playlist, contentIDs): resolved = .addTracks(playlist: ref(playlist), contentIDs: contentIDs)
            case let .removeTracks(playlist, entries): resolved = .removeTracks(playlist: ref(playlist), entries: entries)
            case let .moveTracks(playlist, entries, to): resolved = .moveTracks(playlist: ref(playlist), entries: entries, to: to)
            }
            return .playlist(edit: resolved)
        }
    }

    /// 볼륨 정책(수정)·보호 경로·실물 관문·확인 안 된 규칙(쓰기 절차의 A 단계와 같은 판정)
    func environmentBlocks(_ volume: UsbVolumeInfo, required: Set<UsbProvisionalRule>, options: UsbWriteOptions) -> [UsbBlock] {
        UsbExportSession.environmentBlocks(volume, root: root, required: required, allowProvisional: options.allowProvisional,
                                           confirmName: options.confirmName, purpose: .edit, guard: writeGuard)
    }

    /// 볼륨 UUID(대문자) — 저널·초안 파일 이름. 읽지 못하면 막는다
    public static func volumeKey(_ volume: UsbVolumeInfo) throws -> String {
        guard let uuid = volume.volumeUUID?.uppercased(), !uuid.isEmpty, uuid.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
            throw UsbError.writeRefused([UsbBlock(code: "noVolumeUUID", scope: .volume,
                                                  message: String(ui: "이 USB의 볼륨 번호를 읽지 못했습니다. 다시 연결한 뒤 시도하세요"))])
        }
        return uuid
    }
}
