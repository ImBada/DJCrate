import DJCDomain
import Foundation

/// 실물 USB 쓰기 허용·거부 목록. 읽기는 관문·읽기 판정이, 고치기는 사용자가 고른 볼륨 하나씩(`allow`·`revoke`·`deny`)만 한다.
/// 파일 모양: `{"version": 1, "volumes": ["<볼륨 UUID>", …], "names": {"<UUID>": "<볼륨 이름>"}}`. UUID는 대문자로 맞춘다.
/// `names`는 화면에 보일 이름일 뿐이고 판정에 쓰지 않는다.
public enum UsbPhysicalLists {
    public struct Loaded: Sendable {
        public var allow: Set<String>
        public var deny: Set<String>
        public var denyStatus: UsbDenyListStatus
        public var allowState: UsbDenyListStatus.State
        /// UUID → 등록할 때의 볼륨 이름(허용·거부 목록 모두)
        public var names: [String: String]

        /// UUID는 대문자로 맞춘다(읽기·쓰기 판정이 대문자 UUID로 찾는다)
        public init(allow: Set<String>, deny: Set<String>, denyStatus: UsbDenyListStatus, allowState: UsbDenyListStatus.State,
                    names: [String: String] = [:]) {
            self.allow = Set(allow.map { $0.uppercased() })
            self.deny = Set(deny.map { $0.uppercased() })
            self.denyStatus = denyStatus
            self.allowState = allowState
            self.names = names
        }

        /// 이 목록 상태로 만든 관문. physicalEnabled는 실행 중 스위치(앱 설정 › 실험실, CLI `--allow-physical`)
        public func gate(physicalEnabled: Bool) -> UsbPhysicalWriteGate {
            UsbPhysicalWriteGate(allowlist: allow, denylist: deny, denyStatus: denyStatus, physicalEnabled: physicalEnabled)
        }
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
        let names = user.names.merging(fixed.names) { _, new in new }.merging(allow.names) { _, new in new }
        return Loaded(allow: allow.volumes, deny: fixed.volumes.union(user.volumes),
                      denyStatus: UsbDenyListStatus(fixedLocation: fixed.state, fixedEntryCount: fixed.volumes.count,
                                                    userData: user.state),
                      allowState: allow.state, names: names)
    }

    /// physicalEnabled는 실행 중 스위치(앱 설정 › 실험실, CLI `--allow-physical`). 기본 끔
    public static func gate(supportDirectory: URL = DJCIdentity.supportDirectory, userData: URL = DJCPaths.userData,
                            physicalEnabled: Bool = false) -> UsbPhysicalWriteGate {
        load(supportDirectory: supportDirectory, userData: userData).gate(physicalEnabled: physicalEnabled)
    }

    // MARK: - 고치기(사용자가 고른 볼륨 하나씩)

    /// 이 USB에 쓰기를 허용한다(사용자 동의). 쓰기 금지 목록·rekordbox USB 모양·USB 메모리 조건(`UsbPhysicalWriteGate.consentBlocks`)을
    /// 지나야 더한다. 허용 목록 파일이 깨졌으면 덮지 않고 막는다. 이미 있으면 이름만 새로 적는다
    public static func allow(_ volume: UsbVolumeInfo, supportDirectory: URL = DJCIdentity.supportDirectory,
                             userData: URL = DJCPaths.userData) throws {
        let loaded = load(supportDirectory: supportDirectory, userData: userData)
        if loaded.denyStatus.fixedLocation == .corrupt || loaded.denyStatus.userData == .corrupt {
            throw UsbError.writeRefused([unreadable(String(ui: "쓰기 금지 목록 파일을 읽을 수 없어 허용하지 않았습니다. 목록 파일을 고친 뒤 다시 시도하세요"))])
        }
        let blocks = loaded.gate(physicalEnabled: false).consentBlocks(volume)
        if !blocks.isEmpty { throw UsbError.writeRefused(blocks) }
        let url = supportDirectory.appending(path: allowName)
        var file = try editable(url)
        let uuid = volume.volumeUUID!.uppercased()
        file.insert(uuid, name: volume.name)
        try save(file, to: url)
    }

    /// 쓰기 허용을 거둔다(UUID로). 목록에 없으면 아무것도 하지 않는다
    public static func revoke(uuid: String, supportDirectory: URL = DJCIdentity.supportDirectory) throws {
        let url = supportDirectory.appending(path: allowName)
        var file = try editable(url)
        guard file.remove(uuid.uppercased()) else { return }
        try save(file, to: url)
    }

    /// 쓰기 금지 목록(고정 위치)에 넣는다. 디스크 이미지도 받는다(증거 사본). 허용 목록에 있으면 함께 뺀다.
    /// 목록에서 빼는 명령은 두지 않는다(빼려면 사용자가 파일을 직접 고친다)
    public static func deny(_ volume: UsbVolumeInfo, supportDirectory: URL = DJCIdentity.supportDirectory) throws {
        guard let uuid = volume.volumeUUID?.uppercased(), !uuid.isEmpty, UUID(uuidString: uuid) != nil else {
            throw UsbError.writeRefused([UsbBlock(code: "noVolumeUUID", scope: .volume,
                                                  message: String(ui: "USB의 볼륨 UUID를 읽지 못해 목록에 넣지 않았습니다. USB를 다시 연결한 뒤 시도하세요"))])
        }
        let url = supportDirectory.appending(path: denyName)
        var file = try editable(url)
        file.insert(uuid, name: volume.name)
        try save(file, to: url)
        // 거부 목록이 늘 이기지만, 허용 목록에 남겨 두면 화면이 헷갈린다. 허용 목록이 깨졌으면 그대로 둔다(거부가 이미 막는다)
        try? revoke(uuid: uuid, supportDirectory: supportDirectory)
    }

    // MARK: - 파일

    private struct ListFile: Codable {
        var version: Int?
        var volumes: [String]
        var names: [String: String]?

        mutating func insert(_ uuid: String, name: String) {
            if !volumes.contains(uuid) { volumes.append(uuid) }
            var all = names ?? [:]
            all[uuid] = name
            names = all
        }

        mutating func remove(_ uuid: String) -> Bool {
            guard volumes.contains(uuid) else { return false }
            volumes.removeAll { $0 == uuid }
            names?[uuid] = nil
            return true
        }
    }

    private static func read(_ url: URL) -> (state: UsbDenyListStatus.State, volumes: Set<String>, names: [String: String]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (.missing, [], [:]) }
        guard let file = decode(url) else { return (.corrupt, [], [:]) }
        var names: [String: String] = [:]
        for (key, value) in file.names ?? [:] { names[key.uppercased()] = value }
        return (.ok, Set(file.volumes.map { $0.uppercased() }), names)
    }

    /// 한 항목이라도 UUID 모양이 아니면 목록 전체를 믿지 않는다
    private static func decode(_ url: URL) -> ListFile? {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(ListFile.self, from: data),
              file.volumes.allSatisfy({ UUID(uuidString: $0) != nil }) else { return nil }
        return file
    }

    /// 고칠 파일: 없으면 새 목록, 깨졌으면 덮지 않고 막는다(fail-closed — 깨진 목록을 빈 목록으로 바꾸지 않는다)
    private static func editable(_ url: URL) throws -> ListFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return ListFile(version: 1, volumes: [], names: [:]) }
        guard var file = decode(url) else {
            throw UsbError.writeRefused([unreadable(String(ui: "\(url.lastPathComponent)을 읽을 수 없어 고치지 않았습니다. 파일을 고치거나 지운 뒤 다시 시도하세요"))])
        }
        file.volumes = file.volumes.map { $0.uppercased() }
        return file
    }

    private static func save(_ file: ListFile, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var saved = file
        saved.version = 1
        try encoder.encode(saved).write(to: url, options: .atomic)
    }

    private static func unreadable(_ message: String) -> UsbBlock {
        UsbBlock(code: "listUnreadable", scope: .volume, message: message)
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
