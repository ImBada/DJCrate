import DJCDomain
import Darwin
import Foundation
import RekordboxKit

/// 빈 USB 내보내기 선택
public struct UsbExportOptions: Sendable {
    public var formats: Set<UsbFormat> = UsbFormat.defaultSet
    public var naming: any UsbAnalysisNaming = IdentifierAnalysisNaming()
    /// 기기 설정 파일을 옮길 로컬 rekordbox 설정 폴더(MYSETTING 등, 확인 안 된 규칙 `settingFiles`). nil이면 옮기지 않는다(기본)
    public var settingsFolder: URL? = nil
    public var verifyAudio = false
    public var confirmName: String? = nil
    public var allowProvisional: Set<UsbProvisionalRule> = []
    public var dryRun = false
    /// `--snapshot-time`(ISO 8601). nil이면 사본 이름 → mtime(`UsbSnapshotTime`)
    public var snapshotTime: String? = nil

    public init() {}

    /// 기기 설정 파일을 옮기는지
    public var settings: Bool { settingsFolder != nil }
}

/// 무엇을 내보낼지. 목록이 폴더면 그 안까지 간다
public enum UsbSelection: Sendable, Hashable {
    case playlists([String])
    case tracks([String])
    case both(playlists: [String], tracks: [String])

    public var playlistIDs: [String] {
        switch self {
        case let .playlists(ids), let .both(ids, _): ids
        case .tracks: []
        }
    }

    public var trackIDs: [String] {
        switch self {
        case let .tracks(ids), let .both(_, ids): ids
        case .playlists: []
        }
    }
}

/// 미리 보기(드라이 런·앱 미리 보기도 이것)
public struct UsbExportPreview: Sendable {
    public var plan: UsbExportPlan
    /// 막는 것이 없을 때만 있다. 준비 폴더는 세션이 끝나면 지운다
    public var changes: UsbChangeSet?
    /// 막힘 전부. 곡·목록 단위는 그 곡·목록만 빼고 쓰고, 그 밖(`stopping`)이 하나라도 있으면 쓰지 않는다
    public var blocks: [UsbBlock]
    /// 막지 않는 알림(그림 없음·빼고 쓰는 큐 등)
    public var warnings: [UsbBlock]
    /// 확인 안 된 규칙별 곡 수(계획 규칙 + Device Library 문자열 규칙, 같은 곡은 한 번)
    public var ruleCounts: [UsbProvisionalRule: Int]
    public var requiredRules: Set<UsbProvisionalRule>
    public var requiredBytes: Int64
    public var availableBytes: Int64
    public var snapshotTakenAt: Date
    public var snapshotSource: UsbSnapshotTime.Source

    public init(plan: UsbExportPlan, changes: UsbChangeSet?, blocks: [UsbBlock], warnings: [UsbBlock], ruleCounts: [UsbProvisionalRule: Int],
                requiredRules: Set<UsbProvisionalRule>, requiredBytes: Int64, availableBytes: Int64, snapshotTakenAt: Date,
                snapshotSource: UsbSnapshotTime.Source) {
        self.plan = plan
        self.changes = changes
        self.blocks = blocks
        self.warnings = warnings
        self.ruleCounts = ruleCounts
        self.requiredRules = requiredRules
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
        self.snapshotTakenAt = snapshotTakenAt
        self.snapshotSource = snapshotSource
    }

    /// 쓰기를 멈추는 막힘(볼륨·형식·파일 단위)
    public var stopping: [UsbBlock] {
        blocks.filter {
            switch $0.scope {
            case .track, .playlist: false
            case .volume, .format, .file: true
            }
        }
    }

    /// 막힌 곡 수(같은 곡은 한 번)
    public var blockedTrackCount: Int {
        Set(blocks.compactMap { block -> String? in if case let .track(id) = block.scope { id } else { nil } }).count
    }
}

/// 로컬 스냅샷 사본의 곡·목록을 빈 FAT32·MBR USB에 OneLibrary + Device Library로 내보낸다.
/// 순서: 원본 확인 → 로컬 rekordbox 버전·볼륨 → 세션 전용 로컬 사본 → 후보·계획 → 빌더(행 크기 막힘) → 준비 → `UsbWriter.write`.
/// 로컬 사본은 넘겨받은 `database`에서만 뜨고(사용자 스냅샷 폴더는 읽지도 쓰지도 않는다) 세션이 끝나면 지운다.
public final class UsbExportSession {
    let database: URL
    let share: URL
    let root: URL
    let writeGuard: UsbWriteGuard
    let paths: UsbWritePaths
    let fileSystem: any UsbFileSystem
    let localCopy: @Sendable (_ database: URL, _ into: URL) throws -> URL
    let localCopies: URL
    let appVersion: () -> String?
    let liveDatabases: [URL]

    /// 마지막 미리 보기·쓰기의 계획(앱·CLI 요약이 읽는다)
    public private(set) var lastPreview: UsbExportPreview?

    /// 세션 사본 뜨기: 원본은 넘겨받은 사본이라 실행 중 확인·WAL 거부 없이 WAL을 사본 안에서 합친다(원본은 읽기만).
    /// 사본 안의 옛 사본 정리는 목적지(세션 전용 폴더)만 본다
    public static let defaultLocalCopy: @Sendable (_ database: URL, _ into: URL) throws -> URL = { database, into in
        try LibrarySnapshot.take(from: database, into: into, force: true)
    }

    /// - database: 로컬 스냅샷 사본(라이브 master.db는 거부)
    /// - share: 로컬 rekordbox share(읽기만)
    /// - root: USB 마운트 지점
    /// - fileSystem: 시험은 마운트를 흉내 내는 파일 시스템을 넘긴다
    /// - localCopy: 세션 사본을 뜨는 함수(시험이 호출을 기록한다)
    /// - localCopies: 세션 사본 폴더(`local-<세션>/`)를 둘 곳
    /// - appVersion: 이 Mac의 rekordbox 버전
    /// - liveDatabases: 라이브 master.db 말고도 거부할 경로(시험용)
    public init(database: URL, share: URL, root: URL, guard writeGuard: UsbWriteGuard = .system, paths: UsbWritePaths = .default,
                fileSystem: any UsbFileSystem = PosixUsbFileSystem(),
                localCopy: @escaping @Sendable (_ database: URL, _ into: URL) throws -> URL = UsbExportSession.defaultLocalCopy,
                localCopies: URL = DJCPaths.usbSnapshots, appVersion: @escaping () -> String? = { RekordboxCompatibility.installedAppVersion() },
                liveDatabases: [URL] = []) {
        self.database = database
        self.share = share
        self.root = root
        self.writeGuard = writeGuard
        self.paths = paths
        self.fileSystem = fileSystem
        self.localCopy = localCopy
        self.localCopies = localCopies
        self.appVersion = appVersion
        self.liveDatabases = liveDatabases
    }

    /// 계획·막힘·준비까지(USB에 쓰지 않는다). 막는 것이 없으면 준비한 변경 묶음을 담고 준비 폴더는 지운다
    public func preview(selection: UsbSelection, options: UsbExportOptions) throws -> UsbExportPreview {
        let prepared = try prepare(selection: selection, options: options, progress: { _ in }, isCancelled: { false })
        if let staging = prepared.staging { try? FileManager.default.removeItem(at: staging) }
        lastPreview = prepared.preview
        return prepared.preview
    }

    /// 미리 보기와 같은 계획으로 쓴다(`options.dryRun`이면 준비·저널까지만). 막는 것이 있으면 `writeRefused`
    public func write(selection: UsbSelection, options: UsbExportOptions, progress: @escaping @Sendable (UsbProgress) -> Void,
                      isCancelled: @escaping @Sendable () -> Bool) throws -> UsbWriteReport {
        let prepared = try prepare(selection: selection, options: options, progress: progress, isCancelled: isCancelled)
        lastPreview = prepared.preview
        // 끝나지 않은 쓰기(볼륨이 사라짐·되돌리기 실패)는 회복이 준비 폴더를 쓸 수 있어 남긴다
        var keepStaging = false
        defer { if !keepStaging, let staging = prepared.staging { try? FileManager.default.removeItem(at: staging) } }
        let stopping = prepared.preview.stopping
        guard stopping.isEmpty, let changes = prepared.preview.changes, let assembled = prepared.assembled else {
            throw UsbError.writeRefused(stopping.isEmpty ? prepared.preview.blocks : stopping)
        }
        let writeOptions = UsbWriteOptions(dryRun: options.dryRun, confirmName: options.confirmName, allowProvisional: options.allowProvisional,
                                           verifyAudio: options.verifyAudio)
        do {
            var report = try UsbWriter.write(changes, root: UsbRoot(root), paths: paths, guard: writeGuard, fileSystem: fileSystem,
                                             verifiers: UsbExportAssembly.verifiers(for: assembled), inspectors: [UsbEmptyVolumeInspector()],
                                             options: writeOptions, ppthReader: UsbExportAssembly.ppthReader, progress: progress,
                                             isCancelled: isCancelled)
            report.blocks += prepared.preview.blocks
            return report
        } catch let error as UsbError {
            switch error {
            case .volumeLost, .restoreFailed, .restorePending: keepStaging = true
            default: break
            }
            throw error
        }
    }

    // MARK: - 순서

    struct Prepared {
        var preview: UsbExportPreview
        var assembled: UsbExportAssembled?
        /// 만든 준비 폴더(없으면 nil)
        var staging: URL?
    }

    func prepare(selection: UsbSelection, options: UsbExportOptions, progress: @escaping @Sendable (UsbProgress) -> Void,
                 isCancelled: @escaping @Sendable () -> Bool) throws -> Prepared {
        // 1. 원본: 라이브 master.db면 열지 않고 거부. 스냅샷 시각은 세션 사본을 뜨기 전에 원본에서 푼다(사본은 이름·시각이 바뀐다)
        try refuseLive()
        let snapshot = try UsbSnapshotTime.resolve(explicit: options.snapshotTime, database: database)
        progress(UsbProgress(phase: .planning, cancellable: true))
        let usb = UsbRoot(root)
        var preview = UsbExportPreview(plan: UsbExportPlanner.plan(UsbExportRequest(candidates: [], snapshotTakenAt: snapshot.date)),
                                       changes: nil, blocks: [], warnings: [], ruleCounts: [:], requiredRules: [], requiredBytes: 0,
                                       availableBytes: 0, snapshotTakenAt: snapshot.date, snapshotSource: snapshot.source)

        // 2·3. 로컬 rekordbox 버전, 볼륨(정책·빈 USB·관문). 여기서 막히면 로컬 사본도 뜨지 않는다
        let volume = try writeGuard.volume(root)
        preview.availableBytes = volume.available
        preview.blocks = try volumeBlocks(volume, usb: usb, options: options)
        guard preview.blocks.isEmpty else { return Prepared(preview: preview) }
        let existing = try UsbExportAssembly.existingContents(root: usb)

        // 세션 사본: 넘겨받은 사본 → 세션 전용 폴더. 끝나면(성공·실패·취소) 지운다(클라우드 토큰이 든 사본을 남기지 않게)
        let session = UsbLayout.newSessionID()
        let copyFolder = localCopies.appending(path: "local-\(session)")
        defer { try? FileManager.default.removeItem(at: copyFolder) }
        let copy = try localCopy(database, copyFolder)
        let db = try CipherDatabase.diagnostic(path: copy.path, key: RekordboxKey.derive())
        defer { db.close() }

        // 4. 후보 → 목록 트리 → 계획, 5·6. 빌더(행 크기 막힘으로 뺀 곡은 다시 계획)
        let tree = selection.playlistIDs.isEmpty ? [] : try UsbExportCandidates.playlistTree(database: db, rootIDs: selection.playlistIDs)
        var seen: Set<String> = []
        let ids = (tree.flatMap(\.trackLocalIDs) + selection.trackIDs).filter { seen.insert($0).inserted }
        let candidates = try UsbExportCandidates.load(database: db, share: share, contentIDs: ids)
        let sources = Dictionary(candidates.map { ($0.localContentID, $0.sourcePath ?? "") }) { first, _ in first }
        let rootURL = root
        let request = UsbExportRequest(
            candidates: candidates, playlists: tree, existing: existing, formats: options.formats, naming: options.naming,
            snapshotTakenAt: snapshot.date, clusterSize: volume.clusterSize ?? 32_768,
            sameContent: { id, relative in
                // 이름이 겹칠 때만 USB 쪽 파일을 읽어 해시한다
                UsbExportCandidates.sameContent(sourcePath: sources[id] ?? "", usbFile: rootURL.appending(path: relative))
            })
        let build = try UsbExportAssembly.planAndBuild(request, local: UsbLocalSource(database: db), share: share,
                                                       myTagMasterDBID: UsbLibraryBuilder.randomMyTagMasterDBID(), createdDate: Self.today())
        preview.plan = build.plan
        preview.blocks = build.blocks
        preview.warnings = build.plan.warnings
        preview.requiredRules = build.plan.requiredRules
        preview.ruleCounts = build.plan.ruleCounts
        if !build.volumeBlocks.isEmpty { return Prepared(preview: preview) }
        if build.plan.tracks.isEmpty {
            preview.blocks.append(UsbBlock(code: "noTracks", scope: .volume,
                                           message: String(ui: "내보낼 곡이 없습니다. 막힌 곡의 이유를 확인한 뒤 다시 시도하세요")))
            return Prepared(preview: preview)
        }

        // 7. 준비 폴더에 DB 셋·분석 파일·아트워크를 만들고 변경 묶음을 얻는다
        let staging = paths.staging.appending(path: session)
        let assembled: UsbExportAssembled
        do {
            assembled = try UsbExportAssembly.assembled(
                model: build.model, plan: build.plan, localDatabase: db, share: share, staging: staging, formats: options.formats,
                session: session, settingsFolder: options.settingsFolder,
                progress: { done, total in progress(UsbProgress(phase: .staging, completedItems: done, totalItems: total, cancellable: true)) },
                isCancelled: isCancelled)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        preview.changes = assembled.changes
        preview.warnings = assembled.warnings
        preview.requiredRules = assembled.changes.requiredRules
        preview.ruleCounts = assembled.ruleCounts
        preview.requiredBytes = Self.requiredBytes(assembled.changes, volume: volume)
        // 확인 안 된 규칙(Device Library 작성기 규칙까지 합친 뒤)과 용량
        var late = Self.environmentBlocks(volume, required: assembled.changes.requiredRules, options: options, gate: writeGuard.gate)
        if preview.requiredBytes > volume.available { late.append(Self.spaceBlock(needed: preview.requiredBytes, available: volume.available)) }
        preview.blocks += late
        if !late.isEmpty {
            preview.changes = nil
            try? FileManager.default.removeItem(at: staging)
            return Prepared(preview: preview)
        }
        return Prepared(preview: preview, assembled: assembled, staging: staging)
    }

    // MARK: - 막힘

    /// 라이브 master.db(링크·같은 inode 포함)면 거부한다. 파일은 열지 않는다(경로·stat만)
    func refuseLive() throws {
        let live = [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer/rekordbox/master.db"),
                    LibrarySnapshot.rekordboxDirectory.appending(path: "master.db")] + liveDatabases
        let target = UsbScratchRoots.realPath(database.path)
        var mine = Darwin.stat()
        let mineExists = stat(database.path, &mine) == 0
        for url in live {
            var other = Darwin.stat()
            let sameFile = mineExists && stat(url.path, &other) == 0 && mine.st_dev == other.st_dev && mine.st_ino == other.st_ino
            let sameName = target != nil && target == UsbScratchRoots.realPath(url.path)
            if sameFile || sameName || database.standardizedFileURL.path == url.standardizedFileURL.path {
                throw UsbError.writeRefused([UsbBlock(code: "liveDatabase", scope: .volume,
                                                      message: String(ui: "라이브 master.db는 열 수 없습니다. djc snapshot으로 사본을 만든 뒤 읽으세요"))])
            }
        }
    }

    /// 로컬 rekordbox 버전, 볼륨 정책, 이미 라이브러리가 있는 USB, `PIONEER/`에 남은 것, 실물 관문
    func volumeBlocks(_ volume: UsbVolumeInfo, usb: UsbRoot, options: UsbExportOptions) throws -> [UsbBlock] {
        var blocks: [UsbBlock] = []
        let version = appVersion()
        if !Self.isVerified(version) {
            let shown = version ?? String(ui: "찾지 못함")
            blocks.append(UsbBlock(code: "localVersionUnverified", scope: .volume,
                                   message: String(ui: "로컬 rekordbox 버전(\(shown))은 USB 내보내기를 확인하지 않았습니다. 확인한 버전(7.2.x)의 rekordbox에서 분석한 라이브러리로 내보내세요")))
        }
        blocks += Self.environmentBlocks(volume, required: [], options: options, gate: writeGuard.gate)
        if try hasLibrary(usb) {
            blocks.append(UsbBlock(code: "libraryExists", scope: .volume,
                                   message: String(ui: "이 USB에는 이미 rekordbox 라이브러리가 있습니다. USB 수정(`djc usb-edit`)으로 곡을 더하세요")))
        } else if UsbEmptyVolumeInspector.pioneerNames(usb) > 0 {
            blocks.append(UsbEmptyVolumeInspector.leftoverBlock)
        }
        return blocks
    }

    /// 볼륨 정책·실물 관문·확인 안 된 규칙(쓰기 절차의 A 단계와 같은 판정, rekordbox 실행은 쓰기 때 본다)
    static func environmentBlocks(_ volume: UsbVolumeInfo, required: Set<UsbProvisionalRule>, options: UsbExportOptions,
                                  gate: UsbPhysicalWriteGate) -> [UsbBlock] {
        var blocks = UsbVolumePolicy.blocks(volume, purpose: .export)
        blocks += UsbRuleCheck.blocks(required: required, volume: volume, allowProvisional: options.allowProvisional, gate: gate,
                                      confirmName: options.confirmName)
        if !volume.isDiskImage, !UsbPhysicalWriteGate.buildEnabled, !blocks.contains(where: { $0.code == "physicalDisabled" }) {
            blocks.append(UsbBlock(code: "physicalDisabled", scope: .volume,
                                   message: String(ui: "실물 USB 쓰기는 아직 열리지 않았습니다. 디스크 이미지로만 시험할 수 있습니다"),
                                   rule: .physicalVolume))
        }
        return blocks
    }

    /// `PIONEER/rekordbox/`(철자 무관) 바로 아래에 DB 파일 이름이 하나라도 있는지. 이름만 본다
    func hasLibrary(_ usb: UsbRoot) throws -> Bool {
        func child(_ url: URL, _ name: String) throws -> URL? {
            guard let info = try fileSystem.stat(url), info.kind == .directory else { return nil }
            return try fileSystem.list(url).first { UsbLayout.collisionKey($0) == UsbLayout.collisionKey(name) }.map { url.appending(path: $0) }
        }
        guard let pioneer = try child(usb.url, "PIONEER"), let folder = try child(pioneer, "rekordbox"),
              let info = try fileSystem.stat(folder), info.kind == .directory else { return false }
        let databases = Set([UsbLayout.oneLibrary, UsbLayout.exportPdb, UsbLayout.exportExtPdb]
            .map { UsbLayout.collisionKey(($0 as NSString).lastPathComponent) })
        return try fileSystem.list(folder).contains { databases.contains(UsbLayout.collisionKey($0)) }
    }

    static func isVerified(_ version: String?) -> Bool {
        guard let version else { return false }
        return (try? RekordboxCompatibility.checkApp(version: version)) != nil
    }

    /// 쓰기 절차의 용량 확인과 같은 셈: 새로 쓸 크기(클러스터 올림) + 가장 큰 DB × 2 + 여유
    static func requiredBytes(_ changes: UsbChangeSet, volume: UsbVolumeInfo) -> Int64 {
        let cluster = volume.clusterSize ?? 32_768
        func rounded(_ size: Int64) -> Int64 { UsbSpaceEstimate.roundUp(max(size, 0), cluster: max(cluster, 512)) }
        var needed = changes.copies.filter { $0.disposition == .create }.reduce(Int64(0)) { $0 + rounded($1.size) }
        needed += changes.writes.filter { $0.disposition != .reuse }.reduce(Int64(0)) { $0 + rounded($1.size) }
        needed += changes.databases.reduce(Int64(0)) { $0 + rounded($1.size) }
        needed += 2 * (changes.databases.map(\.size).max() ?? 0)
        return needed + UsbSpaceEstimate.margin(available: volume.available)
    }

    static func spaceBlock(needed: Int64, available: Int64) -> UsbBlock {
        let megabyte: Int64 = 1024 * 1024
        let need = (needed + megabyte - 1) / megabyte, free = available / megabyte
        return UsbBlock(code: "insufficientSpace", scope: .volume,
                        message: String(ui: "USB 여유 공간이 모자랍니다(필요 \(need)MB, 여유 \(free)MB). 곡을 줄이거나 공간이 더 있는 USB를 쓰세요"))
    }

    /// 오늘(이 Mac의 시간대) "YYYY-MM-DD"
    static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
