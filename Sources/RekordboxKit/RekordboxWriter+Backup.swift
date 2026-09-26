import AnicueDomain
import Foundation

/// 백업·되돌리기
extension RekordboxWriter {
    // MARK: - 백업·되돌리기

    public struct Backup: Sendable, Identifiable {
        public var id: String { url.path }
        public var url: URL
        public var createdAt: Date
        /// anicue가 쓰기 직전에 뜬 백업이면 true(되돌리기 직전 상태를 떠 둔 백업은 false)
        public var isWrite: Bool
        public var report: Report?

        public var titles: [String] { report?.written.map(\.title) ?? [] }
    }

    /// DB 파일(+WAL·SHM)을 통째로 복사한다. 복사하는 동안 원본이 바뀌면 실패한다.
    static func makeBackup(of database: URL, in directory: URL, now: Date, label: String) throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let name = formatter.string(from: now) + "-" + label
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
                throw AnicueError.sourceChangedDuringCopy(path: source.path)
            }
        }
        return folder
    }

    static func save(_ report: Report, in backup: URL) throws {
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
                return Backup(url: folder, createdAt: created, isWrite: folder.lastPathComponent.hasSuffix("-write"),
                              report: contents(of: folder).report)
            }
            .sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }
    }

    /// 백업으로 되돌린다. 되돌리기 직전 상태도 따로 백업해 둔다.
    @discardableResult
    public static func restore(_ backup: URL, to database: URL = liveDatabase, now: Date = .now,
                               backups: URL) throws -> URL {
        if isLive(database) {
            guard !LibrarySnapshot.isRekordboxRunning() else {
                throw AnicueError.writeRefused("rekordbox가 켜져 있습니다. rekordbox를 완전히 종료한 뒤 되돌리세요")
            }
        }
        // 백업이 멀쩡한지 먼저 본다.
        try checkIntegrity(of: backup.appending(path: "master.db"))
        let saved = try makeBackup(of: database, in: backups, now: now, label: "before-restore")
        try restoreFiles(from: backup, to: database)
        try restoreAnalysis(from: backup, saveCurrentTo: saved)
        try checkIntegrity(of: database)
        return saved
    }

    /// 분석 파일 원본을 백업 폴더 `anlz/`에 둔다(원래 경로는 manifest.json).
    static func backupAnalysis(_ plans: [RekordboxGridWriter.Plan], in backup: URL) throws {
        let folder = backup.appending(path: "anlz")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest: [String: String] = [:]
        for (i, plan) in plans.enumerated() {
            let dat = folder.appending(path: "\(i).DAT")
            try plan.originalDat.write(to: dat)
            manifest[dat.lastPathComponent] = plan.datURL.path
            if let extURL = plan.extURL, let originalExt = plan.originalExt {
                let ext = folder.appending(path: "\(i).EXT")
                try originalExt.write(to: ext)
                manifest[ext.lastPathComponent] = extURL.path
            }
        }
        try JSONEncoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
    }

    /// 백업의 분석 파일을 원래 자리로 되돌린다. 되돌리기 전 현재 파일은 `saveCurrentTo`에 둔다.
    static func restoreAnalysis(from backup: URL, saveCurrentTo: URL?) throws {
        let folder = backup.appending(path: "anlz")
        guard let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
              let manifest = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        if let saveCurrentTo {
            let current = saveCurrentTo.appending(path: "anlz")
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
            for (name, path) in manifest { try? FileManager.default.copyItem(at: URL(filePath: path), to: current.appending(path: name)) }
            try JSONEncoder().encode(manifest).write(to: current.appending(path: "manifest.json"))
        }
        for (name, path) in manifest {
            try Data(contentsOf: folder.appending(path: name)).write(to: URL(filePath: path), options: .atomic)
        }
    }

    static func restoreFiles(from backup: URL, to database: URL) throws {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let target = URL(filePath: database.path + suffix)
            let source = backup.appending(path: "master.db" + suffix)
            if fm.fileExists(atPath: source.path) {
                let partial = URL(filePath: database.path + suffix + ".anicue-restore")
                try? fm.removeItem(at: partial)
                try fm.copyItem(at: source, to: partial)
                _ = try fm.replaceItemAt(target, withItemAt: partial)
            } else if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
        }
    }


    public static func updateCount(of database: URL) throws -> Int {
        let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
        return try localUpdateCount(db)
    }

    /// 백업에 들어 있는 쓰기 보고서와 초안.
    /// 백업에 들어 있는 그리드 초안
}
