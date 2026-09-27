import CryptoKit
import DJCDomain
import Foundation
import RekordboxKit

/// 임시 폴더에 USB 모양 트리를 만드는 시험 도우미. 내용은 합성 자료만 쓴다.
public struct UsbTreeFixture {
    public let base: URL

    public init() {
        base = FileManager.default.temporaryDirectory.appending(path: "djc-usbtree-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    public var root: UsbRoot { UsbRoot(base) }

    public func url(_ relative: String) -> URL { base.appending(path: relative) }

    /// 중간 폴더를 만들고 파일을 쓴다.
    public func write(_ relative: String, _ data: Data) {
        let target = url(relative)
        try! FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: target)
    }

    public func write(_ relative: String, _ text: String) {
        write(relative, Data(text.utf8))
    }

    public func mkdir(_ relative: String) {
        try! FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
    }

    /// `relative`에 `destination`을 가리키는 심볼릭 링크를 만든다(대상 경로는 그대로 적는다).
    public func symlink(_ relative: String, to destination: String) {
        let link = url(relative)
        try! FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
    }

    /// 상대 경로(NFC) → SHA-256(소문자 16진). 일반 파일만, 순회 코드와 따로 센다.
    public func tree() -> [String: String] {
        var result: [String: String] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys) else { return [:] }
        let prefix = base.resolvingSymlinksInPath().path + "/"
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: Set(keys)))?.isRegularFile == true,
                  let data = try? Data(contentsOf: file) else { continue }
            let path = file.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : file.lastPathComponent
            result[relative.precomposedStringWithCanonicalMapping] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    public func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
