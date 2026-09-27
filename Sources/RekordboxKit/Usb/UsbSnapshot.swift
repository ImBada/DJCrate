import CryptoKit
import DJCDomain
import Darwin
import Foundation

/// 사본 뜨기에 쓰는 파일의 크기·시각
public struct SnapshotFileStamp: Sendable, Hashable {
    public var size: Int64
    public var modificationDate: Date
    /// lstat 기준(심볼릭 링크·장치는 false → 복사하지 않고 readFailed)
    public var isRegularFile: Bool

    public init(size: Int64, modificationDate: Date, isRegularFile: Bool) {
        self.size = size
        self.modificationDate = modificationDate
        self.isRegularFile = isRegularFile
    }
}

/// 사본 뜨기에 쓰는 파일 접근. 시험에서 가짜로 바꿔 "복사 중 바뀜"을 흉내 낸다.
/// 원본은 읽기만 하고, 새 파일 만들기·지우기는 사본 폴더 안에서만 한다.
public struct SnapshotFileAccess: Sendable {
    /// nil = 없음. lstat
    public var stat: @Sendable (URL) throws -> SnapshotFileStamp?
    /// 데이터만, 대상은 새 파일(O_CREAT|O_EXCL), 원본은 O_RDONLY
    public var copyData: @Sendable (_ from: URL, _ to: URL) throws -> Void
    /// 원본 지문용(O_RDONLY)
    public var sha256: @Sendable (URL) throws -> String
    /// 사본 폴더 안에서만 부른다(-shm 사본 지우기)
    public var remove: @Sendable (URL) throws -> Void

    public init(stat: @escaping @Sendable (URL) throws -> SnapshotFileStamp?,
                copyData: @escaping @Sendable (_ from: URL, _ to: URL) throws -> Void,
                sha256: @escaping @Sendable (URL) throws -> String,
                remove: @escaping @Sendable (URL) throws -> Void) {
        self.stat = stat
        self.copyData = copyData
        self.sha256 = sha256
        self.remove = remove
    }

    public static let posix = SnapshotFileAccess(
        stat: { url in
            var info = Darwin.stat()
            guard lstat(url.path, &info) == 0 else {
                let code = errno
                if code == ENOENT { return nil }
                throw UsbError.readFailed(detail: "lstat \(url.lastPathComponent): \(String(cString: strerror(code)))")
            }
            let time = info.st_mtimespec
            return SnapshotFileStamp(size: Int64(info.st_size),
                                     modificationDate: Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9),
                                     isRegularFile: info.st_mode & S_IFMT == S_IFREG)
        },
        copyData: { from, to in
            let input = open(from.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard input >= 0 else { throw posixFailure("open", from) }
            defer { close(input) }
            let output = open(to.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw posixFailure("create", to) }
            var finished = false
            defer {
                close(output)
                // 다 쓰지 못한 사본은 남기지 않는다
                if !finished { unlink(to.path) }
            }
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixFailure("read", from)
                }
                if count == 0 { break }
                var written = 0
                while written < count {
                    let result = buffer.withUnsafeBytes { write(output, $0.baseAddress! + written, count - written) }
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw posixFailure("write", to)
                    }
                    written += result
                }
            }
            guard fsync(output) == 0 else { throw posixFailure("fsync", to) }
            finished = true
        },
        sha256: { url in
            let input = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard input >= 0 else { throw posixFailure("open", url) }
            defer { close(input) }
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixFailure("read", url)
                }
                if count == 0 { break }
                buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        },
        remove: { url in
            guard unlink(url.path) == 0 || errno == ENOENT else { throw posixFailure("unlink", url) }
        })

    private static func posixFailure(_ call: String, _ url: URL) -> UsbError {
        .readFailed(detail: "\(call) \(url.lastPathComponent): \(String(cString: strerror(errno)))")
    }
}

/// USB 라이브러리 DB 파일(OneLibrary와 사이드카, pdb 둘)의 사본. USB 원본은 읽기만 하고 모든 읽기는 이 사본에서 한다.
public struct UsbSnapshot: Sendable {
    /// 사본 폴더
    public let directory: URL
    /// 병합까지 끝난 사본 db
    public let oneLibrary: URL?
    public let exportPdb: URL?
    public let exportExtPdb: URL?
    /// 원본(USB)의 크기·mtime·SHA-256(db·사이드카·pdb 둘)
    public let fingerprint: UsbFingerprint
    public let flags: Flags

    public struct Flags: Sendable, Hashable {
        public var walPresent: Bool
        public var journalPresent: Bool
        public var shmPresent: Bool
        public var walMerged: Bool
        public var journalRolledBack: Bool
        public var headerMode: HeaderMode?

        public init(walPresent: Bool, journalPresent: Bool, shmPresent: Bool, walMerged: Bool, journalRolledBack: Bool,
                    headerMode: HeaderMode?) {
            self.walPresent = walPresent
            self.journalPresent = journalPresent
            self.shmPresent = shmPresent
            self.walMerged = walMerged
            self.journalRolledBack = journalRolledBack
            self.headerMode = headerMode
        }
    }

    public enum HeaderMode: Sendable, Hashable {
        /// 머리 18·19 = 2/2(rekordbox가 만든 모양)
        case wal
        /// 1/1(기기가 연 뒤)
        case rollback
    }

    /// root에서 DB 파일과 사이드카만 복사한다. 열지 않는 경로(`UsbLayout.neverRead`)는 건드리지 않는다.
    /// 복사 전후 크기·mtime이 다르면 `DJCError.sourceChangedDuringCopy`, 사본이 온전하지 않으면 `UsbError.readFailed`.
    public static func take(root: UsbRoot, into directory: URL, fileSystem: SnapshotFileAccess = .posix) throws -> UsbSnapshot {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let database = UsbLayout.oneLibrary
        let candidates = [database] + UsbLayout.oneLibrarySidecarSuffixes.map { database + $0 } + [UsbLayout.exportPdb, UsbLayout.exportExtPdb]
        var stamps: [String: UsbFingerprint.Stamp] = [:], copies: [String: URL] = [:]
        func discard() {
            for copy in copies.values { try? fileSystem.remove(copy) }
        }

        // ① 있는 파일만 복사. 파일마다 복사 전후 크기·mtime이 같아야 한다.
        for relative in candidates {
            // 본 DB 없이 남은 사이드카는 뜻이 없다
            if relative != database, relative.hasPrefix(database), copies[database] == nil { continue }
            let source: URL
            let before: SnapshotFileStamp
            do {
                source = try root.url(for: relative)
                guard let found = try fileSystem.stat(source) else { continue }
                before = found
            } catch {
                discard()
                throw error
            }
            guard before.isRegularFile else {
                discard()
                throw UsbError.readFailed(detail: "not a regular file: \(relative)")
            }
            let target = directory.appending(path: (relative as NSString).lastPathComponent)
            do {
                let hash = try fileSystem.sha256(source)
                try fileSystem.copyData(source, target)
                copies[relative] = target
                let after = try fileSystem.stat(source)
                guard let after, after.size == before.size, after.modificationDate == before.modificationDate, after.isRegularFile else {
                    throw DJCError.sourceChangedDuringCopy(path: source.path)
                }
                stamps[relative] = UsbFingerprint.Stamp(size: before.size, mtime: before.modificationDate, sha256: hash)
            } catch {
                discard()
                throw error
            }
        }

        var flags = Flags(walPresent: copies[database + "-wal"] != nil, journalPresent: copies[database + "-journal"] != nil,
                          shmPresent: copies[database + "-shm"] != nil, walMerged: false, journalRolledBack: false, headerMode: nil)
        if let copy = copies[database] {
            do {
                // ② -shm 사본은 지운다(SQLite가 WAL에서 다시 만든다)
                if let shm = copies[database + "-shm"] { try fileSystem.remove(shm) }
                let key = CipherKey.passphrase(try RekordboxKey.oneLibrary())
                // ③ WAL 합치기·hot journal 롤백은 쓰기 가능한 연결에서만 된다
                if flags.walPresent || flags.journalPresent {
                    let settled = try settle(copyAt: copy, key: key)
                    flags.walMerged = settled.walMerged
                    flags.journalRolledBack = settled.journalRolledBack
                }
                // ④ 읽기 전용으로 다시 열어 무결성 확인, ⑤ 머리는 암호화돼 있어 journal_mode로 모양을 본다
                flags.headerMode = try verify(copyAt: copy, key: key)
            } catch let error as UsbError {
                throw error
            } catch {
                throw UsbError.readFailed(detail: "\(copy.lastPathComponent): \(error)")
            }
        }
        return UsbSnapshot(directory: directory, oneLibrary: copies[database], exportPdb: copies[UsbLayout.exportPdb],
                           exportExtPdb: copies[UsbLayout.exportExtPdb], fingerprint: UsbFingerprint(files: stamps), flags: flags)
    }

    /// 사본에 딸린 -wal·-journal을 사본 안에서 정리한다: 쓰기 가능하게 한 번 열어(hot journal 롤백) WAL을 합치고 닫는다.
    /// USB 원본에는 절대 부르지 않는다.
    public static func settle(copyAt url: URL, key: CipherKey) throws -> (walMerged: Bool, journalRolledBack: Bool) {
        let fm = FileManager.default
        let wal = url.path + "-wal", journal = url.path + "-journal"
        let hadWAL = fm.fileExists(atPath: wal), hadJournal = fm.fileExists(atPath: journal)
        // 여는 동안 sqlite_master를 읽어 hot journal이 있으면 롤백한다
        let db = try CipherDatabase(path: url.path, key: key, mode: .readWrite)
        var busy = 0
        do {
            try db.query("PRAGMA wal_checkpoint(TRUNCATE)") { busy = $0.int(0) ?? 0 }
        } catch {
            db.close()
            throw error
        }
        db.close()
        guard busy == 0 else { throw UsbError.readFailed(detail: "wal_checkpoint busy: \(url.lastPathComponent)") }
        // 마지막 연결이 닫히면 합친 -wal은 지워지고, 롤백한 -journal도 지워진다
        return (hadWAL && !fm.fileExists(atPath: wal), hadJournal && !fm.fileExists(atPath: journal))
    }

    /// 읽기 전용으로 열어 integrity_check = "ok", cipher_integrity_check = 0줄인지 보고 머리 모양을 돌려준다
    static func verify(copyAt url: URL, key: CipherKey) throws -> HeaderMode {
        let db = try CipherDatabase(path: url.path, key: key, mode: .readOnly)
        defer { db.close() }
        var integrity: [String] = []
        try db.query("PRAGMA integrity_check") { integrity.append($0.string(0) ?? "") }
        guard integrity == ["ok"] else {
            throw UsbError.readFailed(detail: "integrity_check: \(integrity.prefix(3).joined(separator: "; "))")
        }
        var cipherProblems = 0
        try db.query("PRAGMA cipher_integrity_check") { _ in cipherProblems += 1 }
        guard cipherProblems == 0 else { throw UsbError.readFailed(detail: "cipher_integrity_check: \(cipherProblems)") }
        var mode = ""
        try db.query("PRAGMA journal_mode") { mode = $0.string(0) ?? "" }
        return mode.lowercased() == "wal" ? .wal : .rollback
    }
}
