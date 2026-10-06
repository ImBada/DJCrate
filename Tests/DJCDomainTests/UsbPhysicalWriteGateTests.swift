@testable import DJCDomain
import DJCTestSupport
import Foundation
import Testing

@Suite("실물 USB 쓰기 관문")
struct UsbPhysicalWriteGateTests {
    let uuid = FakeUsbVolume.physicalUUID
    let okDeny = UsbDenyListStatus(fixedLocation: .ok, fixedPhysicalCount: 1, userData: .missing)

    /// 코드 관문과 실행 중 스위치를 모두 연 관문(시험 전용 init)
    func openGate(allow: Set<String>? = nil, deny: Set<String> = [], status: UsbDenyListStatus? = nil) -> UsbPhysicalWriteGate {
        UsbPhysicalWriteGate(allowlist: FakeUsbVolume.allowEntries(allow ?? [uuid]), denylist: deny, denyStatus: status ?? okDeny, buildEnabled: true, physicalEnabled: true)
    }

    func codes(_ blocks: [UsbBlock]) -> [String] { blocks.map(\.code) }

    @Test("실행 중 스위치(설정 › 실험실·--allow-physical)가 꺼져 있으면 허용 목록에 있어도 막는다")
    func runtimeSwitchOffBlocksPhysicalEvenIfAllowlisted() {
        let gate = UsbPhysicalWriteGate(allowlist: FakeUsbVolume.allowEntries([uuid]), denylist: [], denyStatus: okDeny)
        #expect(gate.physicalEnabled == false)
        #expect(gate.isOpen == false)
        let blocks = gate.blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")
        #expect(codes(blocks) == ["physicalDisabled"])
        #expect(blocks[0].rule == .physicalVolume)
        #expect(blocks[0].scope == .volume)
        #expect(blocks[0].message == "실물 USB 쓰기가 꺼져 있습니다. 앱은 설정 › 실험실에서 켜고, djc는 --allow-physical을 준 뒤 다시 시도하세요")
    }

    @Test("코드 관문이 닫혀 있으면 스위치를 켜도 막는다(둘 다 열려야 쓴다)")
    func buildDisabledBlocksEvenIfSwitchOn() {
        let gate = UsbPhysicalWriteGate(allowlist: FakeUsbVolume.allowEntries([uuid]), denylist: [], denyStatus: okDeny, buildEnabled: false, physicalEnabled: true)
        #expect(gate.isOpen == false)
        let blocks = gate.blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")
        #expect(codes(blocks) == ["physicalDisabled"])
        #expect(blocks[0].message == "이 판에서는 실물 USB 쓰기가 닫혀 있습니다. 디스크 이미지로만 시험할 수 있습니다")
    }

    @Test("스위치를 켜면 공개 init으로도 열린다")
    func publicInitOpensWithSwitch() {
        let gate = FakeUsbVolume.gate(allow: [uuid], physicalEnabled: true)
        #expect(gate.isOpen == UsbPhysicalWriteGate.buildEnabled)
        #expect(gate.blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS").isEmpty)
    }

    @Test("USB 메모리가 아닌 디스크(외장 SSD·Thunderbolt·연결 방식 모름)는 허용 목록에 있어도 막는다")
    func nonUsbStickBlocked() {
        var unknownProtocol = FakeUsbVolume.physicalFAT32()
        unknownProtocol.deviceProtocol = nil
        var unknownRemovable = FakeUsbVolume.physicalFAT32()
        unknownRemovable.isRemovable = nil
        for volume in [FakeUsbVolume.externalSSD(), FakeUsbVolume.thunderboltDisk(), unknownProtocol, unknownRemovable] {
            let blocks = openGate().blocks(volume, confirmName: "DJCPHYS")
            #expect(codes(blocks) == ["notUsbDevice"])
            #expect(blocks[0].message == "USB 메모리가 아닌 디스크(외장 SSD 등)에는 쓰지 않습니다. rekordbox용 USB 메모리를 연결하세요")
        }
    }

    @Test("디스크 이미지는 연결 방식과 무관하게 통과(Virtual Interface)")
    func diskImageIgnoresProtocol() {
        #expect(openGate(allow: []).blocks(FakeUsbVolume.diskImageFAT32(), confirmName: nil).isEmpty)
    }

    @Test("디스크 이미지는 거부 목록 파일 상태와 무관하게 통과")
    func diskImagePasses() {
        for status in [UsbDenyListStatus.missing, .init(fixedLocation: .corrupt, fixedPhysicalCount: 0, userData: .corrupt)] {
            let gate = UsbPhysicalWriteGate(allowlist: [:], denylist: [], denyStatus: status)
            #expect(gate.blocks(FakeUsbVolume.diskImageFAT32(), confirmName: nil).isEmpty)
        }
    }

    @Test("거부 목록의 UUID는 디스크 이미지여도 막는다")
    func deniedBlocksEvenDiskImage() {
        let image = FakeUsbVolume.diskImageFAT32()
        let gate = FakeUsbVolume.gate(deny: [image.volumeUUID!])
        let blocks = gate.blocks(image, confirmName: image.name)
        #expect(codes(blocks) == ["denied"])
        #expect(blocks[0].message == "이 USB는 쓰기 금지 목록에 있습니다")
        #expect(codes(openGate(deny: [uuid]).blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")) == ["denied"])
    }

    @Test("고정 위치 거부 목록이 깨졌으면 막는다")
    func corruptDenyBlocksPhysical() {
        let status = UsbDenyListStatus(fixedLocation: .corrupt, fixedPhysicalCount: 0, userData: .missing)
        let closed = UsbPhysicalWriteGate(allowlist: FakeUsbVolume.allowEntries([uuid]), denylist: [], denyStatus: status)
        let blocks = closed.blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")
        #expect(codes(blocks) == ["denyListUnreadable"])
        #expect(blocks[0].rule == .physicalVolume)
        #expect(codes(openGate(status: status).blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")) == ["denyListUnreadable"])
    }

    @Test("사용자 데이터 쪽 거부 목록이 깨져도 막는다")
    func corruptUserDataDenyBlocksPhysical() {
        let status = UsbDenyListStatus(fixedLocation: .ok, fixedPhysicalCount: 3, userData: .corrupt)
        let closed = UsbPhysicalWriteGate(allowlist: FakeUsbVolume.allowEntries([uuid]), denylist: [], denyStatus: status)
        #expect(codes(closed.blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")) == ["denyListUnreadable"])
    }

    @Test("고정 위치 거부 목록이 없으면 막는다")
    func missingFixedDenyBlocksPhysical() {
        let blocks = openGate(status: .missing).blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")
        #expect(codes(blocks) == ["denyListMissing"])
        #expect(blocks[0].rule == .physicalVolume)
    }

    @Test("고정 위치 거부 목록이 비었으면 막는다")
    func emptyFixedDenyBlocksPhysical() {
        let status = UsbDenyListStatus(fixedLocation: .ok, fixedPhysicalCount: 0, userData: .missing)
        #expect(codes(openGate(status: status).blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")) == ["denyListMissing"])
    }

    @Test("사용자 데이터 쪽 거부 목록만으로는 모자란다")
    func userDataOnlyDenyDoesNotCount() {
        let status = UsbDenyListStatus(fixedLocation: .missing, fixedPhysicalCount: 0, userData: .ok)
        #expect(codes(openGate(status: status).blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")) == ["denyListMissing"])
    }

    @Test func missingUUIDBlocks() {
        var volume = FakeUsbVolume.physicalFAT32()
        volume.volumeUUID = nil
        #expect(codes(openGate().blocks(volume, confirmName: "DJCPHYS")) == ["noVolumeUUID"])
    }

    @Test func notAllowlistedBlocks() {
        let blocks = openGate(allow: []).blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")
        #expect(codes(blocks) == ["notAllowlisted"])
        #expect(blocks[0].message == "이 USB에는 쓰기를 허용하지 않았습니다. 사이드바에서 이 USB의 ‘이 USB에 쓰기 허용…’을 누르거나 djc usb-allow로 등록하세요")
    }

    @Test func confirmMismatchBlocks() {
        #expect(codes(openGate().blocks(FakeUsbVolume.physicalFAT32(), confirmName: "djcphys")) == ["confirmMismatch"])
        let blocks = openGate().blocks(FakeUsbVolume.physicalFAT32(), confirmName: nil)
        #expect(codes(blocks) == ["confirmMismatch"])
        #expect(blocks[0].message == "볼륨 이름 확인이 맞지 않습니다. --confirm에 볼륨 이름(DJCPHYS)을 정확히 주세요")
    }

    @Test func allowlistedAndConfirmedPasses() {
        #expect(openGate().blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS").isEmpty)
    }

    // MARK: - 허용 지문(UUID + 용량 + USB 일련번호)

    @Test("허용할 때와 용량이 다르면 같은 UUID여도 막는다(FAT32 UUID는 32비트 일련번호에서 나와 겹칠 수 있다)")
    func capacityMismatchBlocks() {
        var bigger = FakeUsbVolume.physicalFAT32()
        bigger.capacity = 32_000_000_000
        let blocks = openGate().blocks(bigger, confirmName: "DJCPHYS")
        #expect(codes(blocks) == ["allowMismatch"])
        #expect(blocks[0].message == "이 USB는 쓰기를 허용할 때와 용량·일련번호가 다릅니다. 같은 USB가 맞으면 ‘이 USB에 쓰기 허용…’이나 djc usb-allow로 다시 허용하세요")
    }

    @Test("허용할 때 USB 일련번호를 적었으면 같은 일련번호여야 한다(못 읽으면 막는다)")
    func serialMustMatchWhenRecorded() {
        let gate = UsbPhysicalWriteGate(allowlist: FakeUsbVolume.allowEntries([uuid], serial: "SN-A"), denylist: [], denyStatus: okDeny,
                                        buildEnabled: true, physicalEnabled: true)
        var volume = FakeUsbVolume.physicalFAT32()
        #expect(codes(gate.blocks(volume, confirmName: "DJCPHYS")) == ["allowMismatch"])
        volume.deviceSerial = "SN-B"
        #expect(codes(gate.blocks(volume, confirmName: "DJCPHYS")) == ["allowMismatch"])
        volume.deviceSerial = "SN-A"
        #expect(gate.blocks(volume, confirmName: "DJCPHYS").isEmpty)
    }

    @Test("일련번호를 못 읽었던 허용은 UUID와 용량으로 본다")
    func serialUnknownAtAllowUsesUUIDAndCapacity() {
        var volume = FakeUsbVolume.physicalFAT32()
        volume.deviceSerial = "SN-LATER"
        #expect(openGate().blocks(volume, confirmName: "DJCPHYS").isEmpty)
    }

    @Test("허용 지문은 볼륨에서 UUID 밖의 값(용량·일련번호)을 적는다")
    func fingerprintFromVolume() {
        var volume = FakeUsbVolume.physicalFAT32()
        volume.deviceSerial = "SN-A"
        let fingerprint = UsbAllowFingerprint(volume)
        #expect(fingerprint == UsbAllowFingerprint(capacity: FakeUsbVolume.physicalCapacity, serial: "SN-A"))
        #expect(fingerprint.matches(volume))
        // 용량을 모르면(0) 맞는다고 보지 않는다
        volume.capacity = 0
        #expect(!UsbAllowFingerprint(volume).matches(volume))
    }

    @Test("쓰기 금지는 UUID만으로 막는다(용량·일련번호가 달라도)")
    func denyByUUIDOnly() {
        var other = FakeUsbVolume.physicalFAT32()
        other.capacity = 1_000_000
        other.deviceSerial = "SN-OTHER"
        #expect(codes(openGate(deny: [uuid]).blocks(other, confirmName: "DJCPHYS")) == ["denied"])
        #expect(codes(openGate(deny: [uuid]).consentBlocks(other)) == ["denied"])
    }

    @Test("UUID는 대소문자를 가리지 않는다")
    func uuidComparisonIsCaseInsensitive() {
        let lower = uuid.lowercased()
        #expect(openGate(allow: [lower]).blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS").isEmpty)
        #expect(openGate().blocks(FakeUsbVolume.physicalFAT32(uuid: lower), confirmName: "DJCPHYS").isEmpty)
        #expect(codes(openGate(deny: [lower]).blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")) == ["denied"])
    }

    @Test("코드 관문은 열려 있고 실행 중 스위치는 기본 끔이다")
    func buildEnabledButSwitchOffByDefault() {
        #expect(UsbPhysicalWriteGate.buildEnabled == true)
        #expect(FakeUsbVolume.gate(allow: [uuid]).buildEnabledOverride == true)
        #expect(FakeUsbVolume.gate(allow: [uuid]).isOpen == false)
    }

    // MARK: - 볼륨별 쓰기 허용(동의) 판정

    @Test("쓰기 허용을 받을 수 있는 USB: FAT32·MBR USB 메모리이고 금지 목록에 없음")
    func consentAcceptsRekordboxStick() {
        #expect(openGate(allow: []).consentBlocks(FakeUsbVolume.physicalFAT32()).isEmpty)
        // 스위치가 꺼져 있어도 허용 목록에는 넣을 수 있다(쓰기는 여전히 관문이 막는다)
        #expect(FakeUsbVolume.gate().consentBlocks(FakeUsbVolume.physicalFAT32()).isEmpty)
    }

    @Test("쓰기 허용을 받지 않는 볼륨: 금지 목록·UUID 없음·디스크 이미지·rekordbox USB 모양이 아님·USB 메모리가 아님")
    func consentRefusals() {
        var noUUID = FakeUsbVolume.physicalFAT32()
        noUUID.volumeUUID = nil
        let cases: [(UsbVolumeInfo, String)] = [
            (noUUID, "noVolumeUUID"),
            (FakeUsbVolume.diskImageFAT32(), "diskImage"),
            (FakeUsbVolume.exfat(), "notFAT32"),
            (FakeUsbVolume.gpt(), "notMBR"),
            (FakeUsbVolume.apfs(), "notMBR"),
            (FakeUsbVolume.hfsPlus(), "notMBR"),
            (FakeUsbVolume.internal(), "internal"),
            (FakeUsbVolume.rootVolume(), "rootVolume"),
            (FakeUsbVolume.readOnly(), "readOnly"),
            (FakeUsbVolume.network(), "network"),
            (FakeUsbVolume.externalSSD(), "notUsbDevice"),
            (FakeUsbVolume.thunderboltDisk(), "notUsbDevice"),
        ]
        for (volume, code) in cases {
            #expect(codes(openGate(allow: []).consentBlocks(volume)).first == code, "\(code)")
        }
        // 디스크 이미지는 허용 목록과 무관하다: 임시 폴더 아래면 시험 쓰기, 밖이면 실물로 보고 USB 메모리가 아니라 막힌다
        #expect(openGate(allow: []).consentBlocks(FakeUsbVolume.diskImageFAT32()).first?.message
            == "디스크 이미지는 쓰기 허용 대상이 아닙니다. 디스크 이미지 시험 쓰기는 임시 폴더 아래에 붙인 이미지에만 합니다")
        let outside = FakeUsbVolume.diskImageFAT32().judgedForWrite(underScratch: false)
        #expect(codes(openGate(allow: []).consentBlocks(outside)) == ["notUsbDevice"])
        let denied = openGate(allow: [], deny: [uuid]).consentBlocks(FakeUsbVolume.physicalFAT32())
        #expect(codes(denied) == ["denied"])
        #expect(denied.allSatisfy { !$0.message.isEmpty })
    }

    @Test("임시 폴더 밖에 붙은 디스크 이미지는 실물로 판정한다")
    func outsideScratchIsPhysical() {
        let image = FakeUsbVolume.diskImageFAT32()
        #expect(image.judgedForWrite(underScratch: true).isDiskImage)
        #expect(!image.judgedForWrite(underScratch: false).isDiskImage)
        #expect(!FakeUsbVolume.physicalFAT32().judgedForWrite(underScratch: true).isDiskImage)
    }
}
