import DJCDomain
import Foundation

/// 백업·되돌리기
extension RekordboxWriter {
    // MARK: - 백업·되돌리기

    public struct Backup: Sendable, Identifiable {
        public var id: String { url.path }
        public var url: URL
        public var createdAt: Date
        /// DJCrate가 쓰기 직전에 뜬 백업이면 true(큐·그리드·게인 쓰기, 곡 추가·삭제). 되돌리기 직전 상태를 떠 둔 백업은 false.
        public var isWrite: Bool
        public var report: Report?
        /// 곡 추가·삭제 보고서
        public var trackReport: RekordboxTrackWriter.Report?

        public var titles: [String] {
            // 한 곡에 큐·태그를 함께 썼으면 한 번만
            var seen: Set<String> = []
            let written = report.map { $0.written + $0.analysisWritten + $0.tagWritten + $0.artworkWritten + $0.mergeWritten } ?? []
            return written.filter { seen.insert($0.trackUUID).inserted }.map(\.title) + (report?.playlistWritten.map(\.name) ?? [])
                + (trackReport?.titles ?? [])
                + (report?.iTunesSyncWritten == true ? [String(ui: "iTunes 동기화 목록")] : [])
        }
        /// 쓴 직후 rekordbox 변경 카운터(옛 백업에는 없다)
        public var finalUpdateCount: Int? { report?.finalUpdateCount ?? trackReport?.finalUpdateCount }

        /// 쓰기 직전 백업의 이름 끝(`makeBackup`의 label)
        static let writeLabels = ["-write", "-add", "-delete"]
    }

    /// DB 파일(+WAL·SHM)을 통째로 복사한다. 복사하는 동안 원본이 바뀌면 실패한다.
    static func makeBackup(of database: URL, in directory: URL, now: Date, label: String) throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        // 같은 초에 두 번 뜨면 번호를 붙인다(이름 순서 = 시간 순서가 되게 -2, -3…)
        var name = formatter.string(from: now) + "-" + label
        var suffix = 2
        while fm.fileExists(atPath: directory.appending(path: name).path) {
            name = formatter.string(from: now) + "-" + label + "-\(suffix)"
            suffix += 1
        }
        let folder = directory.appending(path: name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(filePath: database.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let before = try fm.attributesOfItem(atPath: source.path)
            let destination = folder.appending(path: "master.db" + suffix)
            try fm.copyItem(at: source, to: destination)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let after = try fm.attributesOfItem(atPath: source.path)
            let copied = try fm.attributesOfItem(atPath: destination.path)
            guard before[.size] as? Int == after[.size] as? Int,
                  before[.modificationDate] as? Date == after[.modificationDate] as? Date,
                  copied[.size] as? Int == after[.size] as? Int
            else {
                try? fm.removeItem(at: folder)
                throw DJCError.sourceChangedDuringCopy(path: source.path)
            }
        }
        // 재생 목록 쓰기가 고치는 masterPlaylists6.xml도 둔다(되돌리면 DB와 같은 때로).
        let xml = playlistXMLURL(for: database)
        if fm.fileExists(atPath: xml.path) {
            let destination = folder.appending(path: xml.lastPathComponent)
            try fm.copyItem(at: xml, to: destination)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        return folder
    }

    static func save(_ report: Report, in backup: URL, shareRoot: URL? = nil) throws {
        var report = report
        if let paths = report.createdFiles { report.createdFiles = try backupRelativePaths(paths, shareRoot: shareRoot) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: backup.appending(path: "report.json"), options: .atomic)
    }

    static func prune(_ directory: URL) {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { fm.fileExists(atPath: $0.appending(path: "master.db").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in folders.dropFirst(backupsToKeep) { try? fm.removeItem(at: old) }
    }

    /// 백업 목록(최근 것부터)
    public static func backups(in directory: URL) -> [Backup] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { fm.fileExists(atPath: $0.appending(path: "master.db").path) }
            .map { folder in
                let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let name = folder.lastPathComponent
                return Backup(url: folder, createdAt: created, isWrite: Backup.writeLabels.contains { name.hasSuffix($0) },
                              report: contents(of: folder).report, trackReport: RekordboxTrackWriter.report(in: folder))
            }
            .sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }
    }

    /// 백업으로 되돌린다. 되돌리기 직전 상태도 따로 백업해 둔다.
    /// 버전·DB 구조는 보지 않는다(되돌리기는 DJCrate가 쓴 것을 무르는 비상구라 막지 않는다). rekordbox 실행만 막는다.
    @discardableResult
    public static func restore(_ backup: URL, to database: URL, now: Date = .now,
                               backups: URL, guard writeGuard: RekordboxWriteGuard = .system, shareRoot: URL? = nil) throws -> URL {
        let copyShare = writeGuard.isLive(database) ? nil : database.deletingLastPathComponent().appending(path: "share")
        let share = try writeGuard.resolveShareRoot(database, shareRoot: shareRoot ?? copyShare)
            ?? database.deletingLastPathComponent().appending(path: "share")
        if writeGuard.isLive(database) {
            guard !writeGuard.isRekordboxRunning() else {
                throw DJCError.writeRefused(String(ui: "rekordbox가 켜져 있습니다. rekordbox를 완전히 종료한 뒤 되돌리세요"))
            }
        }
        try checkSameLibrary(backup: backup.appending(path: "master.db"), target: database)
        if let saved = try restoreITunesSync(backup, to: database, now: now, backups: backups, guard: writeGuard) { return saved }
        // 백업이 멀쩡한지 먼저 본다.
        for name in ["master.db", "master.db-wal", "master.db-shm", "masterPlaylists6.xml"] {
            try validateBackupFile(backup.appending(path: name), under: backup, required: name == "master.db")
        }
        try checkIntegrity(of: backup.appending(path: "master.db"))
        // 한 경로라도 잘못됐으면 DB와 복원 전 백업까지 모두 그대로 둔다.
        let analysis = try analysisRestoreFiles(from: backup, shareRoot: share)
        let created = try createdRestoreFiles(from: backup, database: database, shareRoot: share)
        try rejectDuplicateTargets(analysis.map(\.target) + created)
        let saved = try makeBackup(of: database, in: backups, now: now, label: "before-restore")
        try restoreFiles(from: backup, to: database)
        try restoreAnalysis(analysis, saveCurrentTo: saved)
        try removeCreatedFiles(created, saveTo: saved, shareRoot: share)
        try checkIntegrity(of: database)
        return saved
    }

    /// 다른 라이브러리(`djmdProperty.DBID`가 다름)의 백업은 되돌리지 않는다(#182: 합성 사본의 백업이 실제 라이브러리로 되돌려졌다).
    /// 대상이 없거나 읽히지 않으면(망가진 라이브러리의 비상 복원) 막지 않는다.
    static func checkSameLibrary(backup: URL, target: URL) throws {
        guard let source = libraryID(of: backup), let current = libraryID(of: target), source != current else { return }
        throw DJCError.writeRefused(String(ui: "다른 rekordbox 라이브러리에서 뜬 백업입니다. 이 라이브러리의 백업을 고르세요"))
    }

    static func libraryID(of database: URL) -> String? {
        guard FileManager.default.fileExists(atPath: database.path),
              let db = try? CipherDatabase(path: database.path, key: RekordboxKey.derive()) else { return nil }
        defer { db.close() }
        var ids: [String] = []
        try? db.query("SELECT DBID FROM djmdProperty") { ids.append($0.string(0) ?? "") }
        return ids.count == 1 && !ids[0].isEmpty ? ids[0] : nil
    }

    /// 곡을 넣거나 분석을 붙이며 만든 분석 파일을 지운다(빈 분석 폴더도). 지우기 전 파일은 `saveTo/anlz`에 두어 그 백업으로 다시 살릴 수 있다.
    static func removeCreatedFiles(_ created: [URL], saveTo saved: URL, shareRoot: URL) throws {
        guard !created.isEmpty else { return }
        let fm = FileManager.default
        let folder = saved.appending(path: "anlz")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifestURL = folder.appending(path: "manifest.json")
        var manifest = try backupMetadata([String: String].self, at: manifestURL, in: saved) ?? [:]
        for file in created where fm.fileExists(atPath: file.path) {
            let name = "created-\(manifest.count).\(file.pathExtension)"
            try fm.copyItem(at: file, to: folder.appending(path: name))
            manifest[name] = try backupTarget(file.path, shareRoot: shareRoot).relative
        }
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        try removeOwnedFiles(created.filter { fm.fileExists(atPath: $0.path) })
    }

    /// 분석 파일 원본을 백업 폴더 `anlz/`에 둔다(원래 경로는 manifest.json).
    static func backupAnalysis(_ plans: [RekordboxGridWriter.Plan], in backup: URL, shareRoot: URL) throws {
        let folder = backup.appending(path: "anlz")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest: [String: String] = [:]
        for (i, plan) in plans.enumerated() {
            let dat = folder.appending(path: "\(i).DAT")
            try plan.originalDat.write(to: dat)
            manifest[dat.lastPathComponent] = try backupTarget(plan.datURL.path, shareRoot: shareRoot).relative
            if let extURL = plan.extURL, let originalExt = plan.originalExt {
                let ext = folder.appending(path: "\(i).EXT")
                try originalExt.write(to: ext)
                manifest[ext.lastPathComponent] = try backupTarget(extURL.path, shareRoot: shareRoot).relative
            }
        }
        try JSONEncoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
    }

    /// 백업의 분석 파일을 원래 자리로 되돌린다. 되돌리기 전 현재 파일은 `saveCurrentTo`에 둔다.
    static func restoreAnalysis(from backup: URL, saveCurrentTo: URL?, shareRoot: URL) throws {
        try restoreAnalysis(analysisRestoreFiles(from: backup, shareRoot: shareRoot), saveCurrentTo: saveCurrentTo)
    }

    static func restoreAnalysis(_ files: [AnalysisRestoreFile], saveCurrentTo: URL?) throws {
        let fm = FileManager.default
        if let saveCurrentTo, !files.isEmpty {
            let current = saveCurrentTo.appending(path: "anlz")
            try fm.createDirectory(at: current, withIntermediateDirectories: true)
            var manifest: [String: String] = [:]
            for (index, file) in files.enumerated() where fm.fileExists(atPath: file.target.path) {
                let name = "restore-\(index).\(file.target.pathExtension)"
                try fm.copyItem(at: file.target, to: current.appending(path: name))
                manifest[name] = file.relative
            }
            try JSONEncoder().encode(manifest).write(to: current.appending(path: "manifest.json"), options: .atomic)
        }
        for file in files {
            // 곡을 지우면서 폴더째 지운 경우가 있다.
            try fm.createDirectory(at: file.target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: file.target, options: .atomic)
        }
    }

    /// DB·XML 되돌리기에서 실패한 것(꼬리표를 붙여)
    struct RestoreFilesError: Error, CustomStringConvertible {
        var problems: [String]
        var description: String { problems.joined(separator: " / ") }
    }

    /// 백업의 master.db(-wal·-shm)를 되살리고, 그게 끝난 뒤에만 masterPlaylists6.xml을 되살린다(쓰기 실패 뒤 되돌리기와 "쓰기 전으로 복원…"이
    /// 같이 쓴다). XML은 원자적으로 써서 반쯤 쓰인 상태가 없으므로, DB 복원이 실패하면 XML도 지금 상태로 두어 재생 목록 구조가 DB와 어긋나지 않게 한다.
    static func restoreFiles(from backup: URL, to database: URL) throws {
        let fm = FileManager.default
        do {
            for suffix in ["", "-wal", "-shm"] {
                let target = URL(filePath: database.path + suffix)
                let source = backup.appending(path: "master.db" + suffix)
                if fm.fileExists(atPath: source.path) {
                    let partial = URL(filePath: database.path + suffix + ".djc-restore")
                    try? fm.removeItem(at: partial)
                    try fm.copyItem(at: source, to: partial)
                    _ = try fm.replaceItemAt(target, withItemAt: partial)
                } else if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
            }
        } catch {
            throw RestoreFilesError(problems: ["master.db: \(DJCError.reason(of: error))"])
        }
        // 옛 백업에는 없다(그때는 XML을 고치지 않았다).
        let xml = backup.appending(path: "masterPlaylists6.xml")
        guard fm.fileExists(atPath: xml.path) else { return }
        do {
            // 이미 같은 내용이면(쓰기가 원자적으로 실패해 원본 그대로) 다시 쓰지 않는다.
            let data = try Data(contentsOf: xml), target = playlistXMLURL(for: database)
            if (try? Data(contentsOf: target)) != data { try data.write(to: target, options: .atomic) }
        } catch {
            throw RestoreFilesError(problems: ["masterPlaylists6.xml: \(DJCError.reason(of: error))"])
        }
    }


    public static func updateCount(of database: URL) throws -> Int {
        let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
        return try localUpdateCount(db)
    }

    /// 백업에 둔 재생 목록 편집(되돌리면 초안으로 살린다)
    public static func playlistEdits(in backup: URL) -> [PlaylistEdit] {
        guard let data = try? Data(contentsOf: backup.appending(path: "playlist-edits.json")) else { return [] }
        return (try? JSONDecoder().decode([PlaylistEdit].self, from: data)) ?? []
    }

    /// 백업에 들어 있는 쓰기 보고서와 초안.
    /// 백업에 들어 있는 그리드 초안
}
