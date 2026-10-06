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
///
/// 실물에 쓰려면 모두 지나야 한다: 쓰기 금지 목록에 없음 → 목록 파일이 온전함 → 코드 관문(`buildEnabled`)과
/// 실행 중 스위치(앱 설정 › 실험실 "실물 USB 쓰기", CLI `--allow-physical`)가 둘 다 열림 → 쓰기 금지 목록이 등록돼 있음 →
/// 볼륨 UUID가 있음 → USB 메모리(연결 USB·이동식 매체) → 사용자가 이 USB에 쓰기를 허용함(허용 목록) → 볼륨 이름 확인.
public struct UsbPhysicalWriteGate: Sendable {
    /// 코드 관문. 실기기에서 문제가 나오면 이 값 하나로 모든 실물 쓰기를 닫는다(설정·인자와 무관).
    /// 열려 있어도 실행 중 스위치가 꺼져 있으면 쓰지 않는다
    public static let buildEnabled = true

    /// 실물로 받는 연결 방식. 내장 SD 슬롯은 내장(`isInternal`)이라 볼륨 정책이 먼저 막는다
    public static let usbProtocols: Set<String> = ["USB"]

    /// 볼륨 UUID(대문자)
    public let allowlist: Set<String>
    /// 고정 위치 ∪ DJC_HOME
    public let denylist: Set<String>
    public let denyStatus: UsbDenyListStatus
    /// 실행 중 스위치: 앱 설정 › 실험실 "실물 USB 쓰기" 또는 CLI `--allow-physical`. 기본 끔
    public let physicalEnabled: Bool
    /// 시험 전용
    let buildEnabledOverride: Bool

    public init(allowlist: Set<String>, denylist: Set<String>, denyStatus: UsbDenyListStatus, physicalEnabled: Bool = false) {
        self.init(allowlist: allowlist, denylist: denylist, denyStatus: denyStatus, buildEnabled: Self.buildEnabled,
                  physicalEnabled: physicalEnabled)
    }

    /// `@testable` 시험만 쓴다: 코드 상수와 무관하게 관문 뒤쪽 판정을 시험한다.
    init(allowlist: Set<String>, denylist: Set<String>, denyStatus: UsbDenyListStatus, buildEnabled: Bool, physicalEnabled: Bool = false) {
        self.allowlist = Set(allowlist.map { $0.uppercased() })
        self.denylist = Set(denylist.map { $0.uppercased() })
        self.denyStatus = denyStatus
        self.physicalEnabled = physicalEnabled
        self.buildEnabledOverride = buildEnabled
    }

    /// 코드 관문과 실행 중 스위치가 둘 다 열렸는지(볼륨별 판정은 `blocks`)
    public var isOpen: Bool { buildEnabledOverride && physicalEnabled }

    /// 실물 쓰기가 닫혀 있을 때의 막힘(코드 관문 → 실행 중 스위치 순)
    public var closedBlock: UsbBlock? {
        if !buildEnabledOverride {
            return UsbBlock(code: "physicalDisabled", scope: .volume,
                            message: String(ui: "이 판에서는 실물 USB 쓰기가 닫혀 있습니다. 디스크 이미지로만 시험할 수 있습니다"),
                            rule: .physicalVolume)
        }
        if !physicalEnabled {
            return UsbBlock(code: "physicalDisabled", scope: .volume,
                            message: String(ui: "실물 USB 쓰기가 꺼져 있습니다. 앱은 설정 › 실험실에서 켜고, djc는 --allow-physical을 준 뒤 다시 시도하세요"),
                            rule: .physicalVolume)
        }
        return nil
    }

    public func blocks(_ volume: UsbVolumeInfo, confirmName: String?) -> [UsbBlock] {
        let uuid = volume.volumeUUID?.uppercased()
        func block(_ code: String, _ message: String, rule: UsbProvisionalRule? = nil) -> [UsbBlock] {
            [UsbBlock(code: code, scope: .volume, message: message, rule: rule)]
        }
        // 증거용 USB는 디스크 이미지로 떠 온 것이어도 쓰지 않는다.
        if let uuid, denylist.contains(uuid) { return [Self.deniedBlock] }
        if volume.isDiskImage { return [] }
        if denyStatus.fixedLocation == .corrupt || denyStatus.userData == .corrupt {
            return block("denyListUnreadable",
                         String(ui: "쓰기 금지 목록 파일을 읽을 수 없어 실물 USB에 쓰지 않습니다. 목록 파일을 고친 뒤 다시 시도하세요"),
                         rule: .physicalVolume)
        }
        if let closedBlock { return [closedBlock] }
        // 거부 목록이 비어 있으면 증거용 USB를 가려낼 수 없다.
        if denyStatus.fixedLocation == .missing || denyStatus.fixedEntryCount == 0 {
            return block("denyListMissing",
                         String(ui: "쓰기 금지 목록이 비어 있어 실물 USB에 쓰지 않습니다. 쓰면 안 되는 USB를 사이드바의 ‘쓰기 금지 목록에 넣기…’나 djc usb-deny로 먼저 등록하세요"),
                         rule: .physicalVolume)
        }
        guard let uuid else { return [Self.noUUIDBlock] }
        if !Self.isUsbStick(volume) { return [Self.notUsbDeviceBlock] }
        if !allowlist.contains(uuid) {
            return block("notAllowlisted",
                         String(ui: "이 USB에는 쓰기를 허용하지 않았습니다. 사이드바에서 이 USB의 ‘이 USB에 쓰기 허용…’을 누르거나 djc usb-allow로 등록하세요"))
        }
        if confirmName != volume.name {
            return block("confirmMismatch", String(ui: "볼륨 이름 확인이 맞지 않습니다. --confirm에 볼륨 이름(\(volume.name))을 정확히 주세요"))
        }
        return []
    }

    /// 이 볼륨을 쓰기 허용 목록에 넣어도 되는지(사용자 동의 전 판정). 실행 중 스위치·목록 등록과 무관하다(쓰기 때 관문이 다시 본다).
    /// 볼륨 모양은 rekordbox USB 조건(`UsbVolumePolicy`, 내보내기 목적)을 모두 낸다
    public func consentBlocks(_ volume: UsbVolumeInfo) -> [UsbBlock] {
        guard let uuid = volume.volumeUUID?.uppercased(), !uuid.isEmpty else { return [Self.noUUIDBlock] }
        if denylist.contains(uuid) { return [Self.deniedBlock] }
        if volume.isDiskImage {
            return [UsbBlock(code: "diskImage", scope: .volume,
                             message: String(ui: "디스크 이미지는 허용 없이 시험 쓰기를 합니다. 실물 USB를 고르세요"))]
        }
        var blocks = UsbVolumePolicy.blocks(volume, purpose: .export)
        if !Self.isUsbStick(volume) { blocks.append(Self.notUsbDeviceBlock) }
        return blocks
    }

    /// USB로 연결된 이동식 매체인지. 모르면(DA 값이 없으면) 아니라고 본다
    static func isUsbStick(_ volume: UsbVolumeInfo) -> Bool {
        usbProtocols.contains(volume.deviceProtocol ?? "") && volume.isRemovable == true
    }

    static var deniedBlock: UsbBlock {
        UsbBlock(code: "denied", scope: .volume, message: String(ui: "이 USB는 쓰기 금지 목록에 있습니다"))
    }

    static var noUUIDBlock: UsbBlock {
        UsbBlock(code: "noVolumeUUID", scope: .volume, message: String(ui: "USB의 볼륨 UUID를 읽지 못해 쓰지 않습니다. USB를 다시 연결한 뒤 시도하세요"))
    }

    static var notUsbDeviceBlock: UsbBlock {
        UsbBlock(code: "notUsbDevice", scope: .volume,
                 message: String(ui: "USB 메모리가 아닌 디스크(외장 SSD 등)에는 쓰지 않습니다. rekordbox용 USB 메모리를 연결하세요"))
    }
}
