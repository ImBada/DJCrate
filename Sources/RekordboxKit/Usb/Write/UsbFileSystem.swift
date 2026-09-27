import CryptoKit
import DJCDomain
import Darwin
import Foundation

/// 파일 하나의 모양(lstat)
public struct UsbFileStat: Sendable, Hashable {
    /// other = 장치·FIFO·소켓
    public enum Kind: String, Sendable { case file, directory, symlink, other }

    public var kind: Kind
    /// 파일이 아니면 0
    public var size: Int64
    public var modificationDate: Date

    public init(kind: Kind, size: Int64, modificationDate: Date) {
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
    }
}

/// 시스템 호출 실패(연산 이름·경로·errno). 쓰기 절차가 되돌릴 이유로 적는다
public struct UsbIOError: Error, CustomStringConvertible, Sendable {
    public var operation: String
    public var path: String
    public var code: Int32

    public init(_ operation: String, _ path: String, code: Int32 = errno) {
        self.operation = operation
        self.path = path
        self.code = code
    }

    public var description: String { "\(operation) \(path): \(String(cString: strerror(code)))" }
}

/// USB 쓰기가 부르는 파일 연산. 쓰기 절차는 이것만 부르고, 시험은 실패·분리를 흉내 내는 구현으로 바꾼다.
/// 맥 쪽 백업·저널 쓰기도 같은 것을 거친다(크래시 흉내가 맥 쪽 쓰기까지 멈추게).
public protocol UsbFileSystem: Sendable {
    /// nil = 없음. lstat(심볼릭 링크를 따라가지 않는다)
    func stat(_ url: URL) throws -> UsbFileStat?
    func list(_ directory: URL) throws -> [String]
    /// 한 단계, 이미 있으면 실패
    func makeDirectory(_ url: URL) throws
    /// O_CREAT|O_EXCL → write → F_FULLFSYNC → close
    func writeNew(_ data: Data, to url: URL) throws
    /// 데이터만(확장 속성·ACL 없음), O_EXCL, 끝에 F_FULLFSYNC
    func copyDataNew(from source: URL, to url: URL, progress: (Int64) -> Void) throws -> (size: Int64, sha256: String, sha1: String)
    func setModificationDate(_ url: URL, _ date: Date) throws
    /// 파일 F_FULLFSYNC
    func fullSync(_ url: URL) throws
    /// 폴더 fd F_FULLFSYNC
    func syncDirectory(_ url: URL) throws
    /// rename(2). 맞바꾸기(RENAME_SWAP)는 FAT에서 덮어쓰기라 쓰지 않는다
    func rename(_ from: URL, to: URL) throws
    /// 파일만(unlink)
    func remove(_ url: URL) throws
    func removeDirectoryIfEmpty(_ url: URL) throws -> Bool
    /// uncached: F_NOCACHE(캐시가 아니라 매체에서 다시 읽는다)
    func sha256(_ url: URL, uncached: Bool) throws -> String
    func read(_ url: URL, maxBytes: Int) throws -> Data
    /// statfs(2) f_mntonname(realpath 모양)
    func mountedOn(_ url: URL) throws -> String?
}

/// POSIX 시스템 호출로 하는 구현. 경로는 받은 그대로 쓴다(Foundation 경로 정규화를 거치지 않는다).
public struct PosixUsbFileSystem: UsbFileSystem {
    /// false면 F_FULLFSYNC를 건너뛴다(시험 속도용, 패키지 안에서만)
    let synchronizes: Bool

    public init() { synchronizes = true }

    package init(synchronizes: Bool) { self.synchronizes = synchronizes }

    static let chunk = 1 << 20

    public func stat(_ url: URL) throws -> UsbFileStat? {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw UsbIOError("lstat", url.path)
        }
        let kind: UsbFileStat.Kind = switch info.st_mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symlink
        default: .other
        }
        let date = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        return UsbFileStat(kind: kind, size: kind == .file ? Int64(info.st_size) : 0, modificationDate: date)
    }

    public func list(_ directory: URL) throws -> [String] {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw UsbIOError("opendir", directory.path) }
        guard let handle = fdopendir(descriptor) else {
            let error = UsbIOError("fdopendir", directory.path)
            close(descriptor)
            throw error
        }
        defer { closedir(handle) }
        var names: [String] = []
        while let entry = readdir(handle) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    public func makeDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o755) == 0 else { throw UsbIOError("mkdir", url.path) }
    }

    public func writeNew(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw UsbIOError("open", url.path) }
        var closed = false
        defer { if !closed { close(descriptor) } }
        try data.withUnsafeBytes { buffer in
            try writeAll(descriptor, buffer, path: url.path)
        }
        try sync(descriptor, path: url.path)
        closed = true
        guard close(descriptor) == 0 else { throw UsbIOError("close", url.path) }
    }

    public func copyDataNew(from source: URL, to url: URL, progress: (Int64) -> Void) throws -> (size: Int64, sha256: String, sha1: String) {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw UsbIOError("open", source.path) }
        defer { close(input) }
        let output = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard output >= 0 else { throw UsbIOError("open", url.path) }
        var closed = false
        defer { if !closed { close(output) } }
        var sha256 = SHA256(), sha1 = Insecure.SHA1()
        var total: Int64 = 0
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.chunk, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = Darwin.read(input, buffer.baseAddress, Self.chunk)
            if count < 0 {
                if errno == EINTR { continue }
                throw UsbIOError("read", source.path)
            }
            if count == 0 { break }
            let slice = UnsafeRawBufferPointer(rebasing: buffer[0..<count])
            sha256.update(bufferPointer: slice)
            sha1.update(bufferPointer: slice)
            try writeAll(output, slice, path: url.path)
            total += Int64(count)
            progress(total)
        }
        try sync(output, path: url.path)
        closed = true
        guard close(output) == 0 else { throw UsbIOError("close", url.path) }
        return (total, Self.hex(sha256.finalize()), Self.hex(sha1.finalize()))
    }

    public func setModificationDate(_ url: URL, _ date: Date) throws {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        let nanos = Int((date.timeIntervalSince1970 - seconds) * 1e9)
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(seconds), tv_nsec: nanos)]
        guard utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else { throw UsbIOError("utimensat", url.path) }
    }

    public func fullSync(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw UsbIOError("open", url.path) }
        defer { close(descriptor) }
        try sync(descriptor, path: url.path)
    }

    public func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw UsbIOError("open", url.path) }
        defer { close(descriptor) }
        try sync(descriptor, path: url.path)
    }

    public func rename(_ from: URL, to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else { throw UsbIOError("rename", from.path + " -> " + to.path) }
    }

    public func remove(_ url: URL) throws {
        guard unlink(url.path) == 0 else { throw UsbIOError("unlink", url.path) }
    }

    public func removeDirectoryIfEmpty(_ url: URL) throws -> Bool {
        if rmdir(url.path) == 0 { return true }
        if [ENOTEMPTY, EEXIST, ENOENT].contains(errno) { return false }
        throw UsbIOError("rmdir", url.path)
    }

    public func sha256(_ url: URL, uncached: Bool) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw UsbIOError("open", url.path) }
        defer { close(descriptor) }
        if uncached { _ = fcntl(descriptor, F_NOCACHE, 1) }
        var hasher = SHA256()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.chunk, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = Darwin.read(descriptor, buffer.baseAddress, Self.chunk)
            if count < 0 {
                if errno == EINTR { continue }
                throw UsbIOError("read", url.path)
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
        }
        return Self.hex(hasher.finalize())
    }

    public func read(_ url: URL, maxBytes: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw UsbIOError("open", url.path) }
        defer { close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(max(maxBytes, 1), Self.chunk))
        while data.count < maxBytes {
            let want = min(buffer.count, maxBytes - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, want) }
            if count < 0 {
                if errno == EINTR { continue }
                throw UsbIOError("read", url.path)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    public func mountedOn(_ url: URL) throws -> String? {
        UsbScratchRoots.mountedOn(url.path)
    }

    // MARK: -

    private func writeAll(_ descriptor: Int32, _ buffer: UnsafeRawBufferPointer, path: String) throws {
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw UsbIOError("write", path)
            }
            offset += written
        }
    }

    /// F_FULLFSYNC(매체까지). 파일 시스템이 받지 않으면 fsync로 물러선다
    private func sync(_ descriptor: Int32, path: String) throws {
        guard synchronizes else { return }
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw UsbIOError("fsync", path) }
    }

    static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
