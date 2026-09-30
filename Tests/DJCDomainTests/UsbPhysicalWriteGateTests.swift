@testable import DJCDomain
import DJCTestSupport
import Foundation
import Testing

@Suite("실물 USB 쓰기 관문")
struct UsbPhysicalWriteGateTests {
    let uuid = FakeUsbVolume.physicalUUID
    let okDeny = UsbDenyListStatus(fixedLocation: .ok, fixedEntryCount: 1, userData: .missing)

    /// 코드 상수와 무관하게 실물 쓰기를 연 관문(시험 전용 init)
    func openGate(allow: Set<String>? = nil, deny: Set<String> = [], status: UsbDenyListStatus? = nil) -> UsbPhysicalWriteGate {
        UsbPhysicalWriteGate(allowlist: allow ?? [uuid], denylist: deny, denyStatus: status ?? okDeny, buildEnabled: true)
    }

    func codes(_ blocks: [UsbBlock]) -> [String] { blocks.map(\.code) }

    @Test("코드에서 닫혀 있으면 허용 목록에 있어도 막는다")
    func buildDisabledBlocksPhysicalEvenIfAllowlisted() {
        let gate = UsbPhysicalWriteGate(allowlist: [uuid], denylist: [], denyStatus: okDeny)
        let blocks = gate.blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")
        #expect(codes(blocks) == ["physicalDisabled"])
        #expect(blocks[0].rule == .physicalVolume)
        #expect(blocks[0].scope == .volume)
        #expect(blocks[0].message == "실물 USB 쓰기는 아직 열리지 않았습니다. 디스크 이미지로만 시험할 수 있습니다")
    }

    @Test("디스크 이미지는 거부 목록 파일 상태와 무관하게 통과")
    func diskImagePasses() {
        for status in [UsbDenyListStatus.missing, .init(fixedLocation: .corrupt, fixedEntryCount: 0, userData: .corrupt)] {
            let gate = UsbPhysicalWriteGate(allowlist: [], denylist: [], denyStatus: status)
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
        let status = UsbDenyListStatus(fixedLocation: .corrupt, fixedEntryCount: 0, userData: .missing)
        let closed = UsbPhysicalWriteGate(allowlist: [uuid], denylist: [], denyStatus: status)
        let blocks = closed.blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")
        #expect(codes(blocks) == ["denyListUnreadable"])
        #expect(blocks[0].rule == .physicalVolume)
        #expect(codes(openGate(status: status).blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")) == ["denyListUnreadable"])
    }

    @Test("사용자 데이터 쪽 거부 목록이 깨져도 막는다")
    func corruptUserDataDenyBlocksPhysical() {
        let status = UsbDenyListStatus(fixedLocation: .ok, fixedEntryCount: 3, userData: .corrupt)
        let closed = UsbPhysicalWriteGate(allowlist: [uuid], denylist: [], denyStatus: status)
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
        let status = UsbDenyListStatus(fixedLocation: .ok, fixedEntryCount: 0, userData: .missing)
        #expect(codes(openGate(status: status).blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")) == ["denyListMissing"])
    }

    @Test("사용자 데이터 쪽 거부 목록만으로는 모자란다")
    func userDataOnlyDenyDoesNotCount() {
        let status = UsbDenyListStatus(fixedLocation: .missing, fixedEntryCount: 0, userData: .ok)
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
        #expect(blocks[0].message.contains("djc usb-allow"))
    }

    @Test func confirmMismatchBlocks() {
        #expect(codes(openGate().blocks(FakeUsbVolume.physicalFAT32(), confirmName: "djcphys")) == ["confirmMismatch"])
        #expect(codes(openGate().blocks(FakeUsbVolume.physicalFAT32(), confirmName: nil)) == ["confirmMismatch"])
    }

    @Test func allowlistedAndConfirmedPasses() {
        #expect(openGate().blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS").isEmpty)
    }

    @Test("UUID는 대소문자를 가리지 않는다")
    func uuidComparisonIsCaseInsensitive() {
        let lower = uuid.lowercased()
        #expect(openGate(allow: [lower]).blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS").isEmpty)
        #expect(openGate().blocks(FakeUsbVolume.physicalFAT32(uuid: lower), confirmName: "DJCPHYS").isEmpty)
        #expect(codes(openGate(deny: [lower]).blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")) == ["denied"])
    }

    @Test("실물 쓰기는 코드에서 닫혀 있다")
    func staticBuildEnabledIsFalse() {
        #expect(UsbPhysicalWriteGate.buildEnabled == false)
        #expect(FakeUsbVolume.gate(allow: [uuid]).buildEnabledOverride == false)
    }
}
