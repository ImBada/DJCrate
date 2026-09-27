import DJCDomain
import Foundation

/// 실물 USB 쓰기 허용·거부 목록 읽기(읽기만 한다 — 목록을 만들거나 고치지 않는다).
/// 파일 모양: `{"version": 1, "volumes": ["<볼륨 UUID>", …]}`. UUID는 대문자로 맞춘다.
public enum UsbPhysicalLists {
    public struct Loaded: Sendable {
        public var allow: Set<String>
        public var deny: Set<String>
        public var denyStatus: UsbDenyListStatus
        public var allowState: UsbDenyListStatus.State
    }

    static let allowName = "usb-physical-allow.json"
    static let denyName = "usb-physical-deny.json"

    /// 허용: supportDirectory 쪽만(DJC_HOME 쪽은 무시). 없거나 깨지면 빈 집합.
    /// 거부: supportDirectory(고정) ∪ userData. 고정 쪽이 없거나 깨졌는지를 상태로 알린다(관문이 fail-closed로 막는다)
    public static func load(supportDirectory: URL = DJCIdentity.supportDirectory, userData: URL = DJCPaths.userData) -> Loaded {
        let allow = read(supportDirectory.appending(path: allowName))
        let fixed = read(supportDirectory.appending(path: denyName))
        let same = UsbScratchRootsPath.same(supportDirectory, userData)
        let user = same ? fixed : read(userData.appending(path: denyName))
        return Loaded(allow: allow.volumes, deny: fixed.volumes.union(user.volumes),
                      denyStatus: UsbDenyListStatus(fixedLocation: fixed.state, fixedEntryCount: fixed.volumes.count,
                                                    userData: user.state),
                      allowState: allow.state)
    }

    public static func gate(supportDirectory: URL = DJCIdentity.supportDirectory, userData: URL = DJCPaths.userData) -> UsbPhysicalWriteGate {
        let loaded = load(supportDirectory: supportDirectory, userData: userData)
        return UsbPhysicalWriteGate(allowlist: loaded.allow, denylist: loaded.deny, denyStatus: loaded.denyStatus)
    }

    private struct ListFile: Decodable {
        var version: Int?
        var volumes: [String]
    }

    private static func read(_ url: URL) -> (state: UsbDenyListStatus.State, volumes: Set<String>) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (.missing, []) }
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(ListFile.self, from: data) else {
            return (.corrupt, [])
        }
        // 한 항목이라도 UUID 모양이 아니면 목록 전체를 믿지 않는다
        guard file.volumes.allSatisfy({ UUID(uuidString: $0) != nil }) else { return (.corrupt, []) }
        return (.ok, Set(file.volumes.map { $0.uppercased() }))
    }
}

/// 두 폴더가 같은 곳인지(realpath로)
enum UsbScratchRootsPath {
    static func same(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = UsbScratchPath.realPath(lhs.path) ?? lhs.path
        let right = UsbScratchPath.realPath(rhs.path) ?? rhs.path
        return left == right
    }
}
