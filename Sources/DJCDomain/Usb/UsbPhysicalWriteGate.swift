import Foundation

/// 거부 목록 파일 상태. 거부 목록은 fail-closed: 깨졌거나(고정 위치에) 없으면 실물 쓰기를 막는다.
public struct UsbDenyListStatus: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case ok, missing, corrupt }

    /// `DJCIdentity.supportDirectory/usb-physical-deny.json`(DJC_HOME과 무관)
    public var fixedLocation: State
    /// 고정 위치 파일의 항목 수(DJC_HOME 쪽은 세지 않는다)
    public var fixedEntryCount: Int
    /// `DJC_HOME/usb-physical-deny.json`. 없어도 문제가 아니고 깨졌을 때만 막는다
    public var userData: State

    public init(fixedLocation: State, fixedEntryCount: Int, userData: State) {
        self.fixedLocation = fixedLocation
        self.fixedEntryCount = fixedEntryCount
        self.userData = userData
    }

    public static let missing = UsbDenyListStatus(fixedLocation: .missing, fixedEntryCount: 0, userData: .missing)
}

/// 실물 USB(디스크 이미지가 아닌 것)에 쓸 수 있는지 정하는 관문. 한 번에 처음 걸린 막힘 하나만 낸다.
public struct UsbPhysicalWriteGate: Sendable {
    /// 실물(디스크 이미지가 아닌) USB 쓰기를 코드에서 연다. 사용자 승인과 실물 실험을 마친 뒤에만 true로 바꾼다.
    public static let buildEnabled = false

    /// 볼륨 UUID(대문자)
    public let allowlist: Set<String>
    /// 고정 위치 ∪ DJC_HOME
    public let denylist: Set<String>
    public let denyStatus: UsbDenyListStatus
    /// 시험 전용
    let buildEnabledOverride: Bool

    public init(allowlist: Set<String>, denylist: Set<String>, denyStatus: UsbDenyListStatus) {
        self.init(allowlist: allowlist, denylist: denylist, denyStatus: denyStatus, buildEnabled: Self.buildEnabled)
    }

    /// `@testable` 시험만 쓴다: 코드 상수와 무관하게 관문 뒤쪽 판정을 시험한다.
    init(allowlist: Set<String>, denylist: Set<String>, denyStatus: UsbDenyListStatus, buildEnabled: Bool) {
        self.allowlist = Set(allowlist.map { $0.uppercased() })
        self.denylist = Set(denylist.map { $0.uppercased() })
        self.denyStatus = denyStatus
        self.buildEnabledOverride = buildEnabled
    }

    public func blocks(_ volume: UsbVolumeInfo, confirmName: String?) -> [UsbBlock] {
        let uuid = volume.volumeUUID?.uppercased()
        func block(_ code: String, _ message: String, rule: UsbProvisionalRule? = nil) -> [UsbBlock] {
            [UsbBlock(code: code, scope: .volume, message: message, rule: rule)]
        }
        // 증거용 USB는 디스크 이미지로 떠 온 것이어도 쓰지 않는다.
        if let uuid, denylist.contains(uuid) {
            return block("denied", String(ui: "이 USB는 쓰기 금지 목록에 있습니다"))
        }
        if volume.isDiskImage { return [] }
        if denyStatus.fixedLocation == .corrupt || denyStatus.userData == .corrupt {
            return block("denyListUnreadable",
                         String(ui: "쓰기 금지 목록 파일을 읽을 수 없어 실물 USB에 쓰지 않습니다. 목록 파일을 고친 뒤 다시 시도하세요"),
                         rule: .physicalVolume)
        }
        if !buildEnabledOverride {
            return block("physicalDisabled",
                         String(ui: "실물 USB 쓰기는 아직 열리지 않았습니다. 디스크 이미지로만 시험할 수 있습니다"),
                         rule: .physicalVolume)
        }
        // 거부 목록이 비어 있으면 증거용 USB를 가려낼 수 없다.
        if denyStatus.fixedLocation == .missing || denyStatus.fixedEntryCount == 0 {
            return block("denyListMissing",
                         String(ui: "쓰기 금지 목록이 비어 있어 실물 USB에 쓰지 않습니다. 먼저 증거용 USB를 `djc usb-deny`로 등록하세요"),
                         rule: .physicalVolume)
        }
        guard let uuid else {
            return block("noVolumeUUID", String(ui: "USB의 볼륨 UUID를 읽지 못해 쓰지 않습니다. USB를 다시 연결한 뒤 시도하세요"))
        }
        if !allowlist.contains(uuid) {
            return block("notAllowlisted",
                         String(ui: "이 USB는 쓰기 허용 목록에 없습니다. 사용자가 터미널에서 `djc usb-allow`로 등록해야 합니다"))
        }
        if confirmName != volume.name {
            return block("confirmMismatch", String(ui: "`--confirm`에 볼륨 이름을 정확히 주세요"))
        }
        return []
    }
}
