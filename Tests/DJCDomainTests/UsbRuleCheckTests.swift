import DJCDomain
import DJCTestSupport
import Foundation
import Testing

@Suite("USB 규칙 확인")
struct UsbRuleCheckTests {
    let physical = FakeUsbVolume.physicalFAT32()
    let image = FakeUsbVolume.diskImageFAT32()

    @Test("실물이면 실물 볼륨 규칙을 더해 관문 결과를 낸다")
    func physicalAddsPhysicalVolume() {
        let gate = FakeUsbVolume.gate(allow: [FakeUsbVolume.physicalUUID])
        let blocks = UsbRuleCheck.blocks(required: [], volume: physical, allowProvisional: [], gate: gate, confirmName: physical.name)
        #expect(blocks.map(\.code) == ["physicalDisabled"])
        #expect(blocks.map(\.rule) == [.physicalVolume])
    }

    @Test("디스크 이미지는 기기 기록 행 옮기기 말고 모두 통과")
    func diskImagePassesAllExceptCarriedDeviceRows() {
        let all = Set(UsbProvisionalRule.allCases)
        let blocks = UsbRuleCheck.blocks(required: all, volume: image, allowProvisional: [], gate: FakeUsbVolume.gate(), confirmName: nil)
        #expect(blocks.map(\.code) == ["provisional"])
        #expect(blocks.map(\.rule) == [.carriedDeviceRows])
        #expect(blocks[0].scope == .volume)
        #expect(blocks[0].message == "확인하지 않은 규칙(\(UsbProvisionalRule.carriedDeviceRows.summary))이 필요해 이 USB에 쓸 수 없습니다")
        // 허용해도 디스크 이미지에서 막는 규칙은 풀리지 않는다.
        let allowed = UsbRuleCheck.blocks(required: [.carriedDeviceRows], volume: image, allowProvisional: [.carriedDeviceRows],
                                          gate: FakeUsbVolume.gate(), confirmName: nil)
        #expect(allowed.map(\.rule) == [.carriedDeviceRows])
        #expect(UsbRuleCheck.blocks(required: [.cueVariant, .settingFiles], volume: image, allowProvisional: [],
                                    gate: FakeUsbVolume.gate(), confirmName: nil).isEmpty)
    }

    @Test("실물은 규칙마다 허용이 필요하다")
    func physicalRequiresAllowProvisionalPerRule() {
        let gate = FakeUsbVolume.gate(allow: [FakeUsbVolume.physicalUUID])
        let blocks = UsbRuleCheck.blocks(required: [.cueVariant, .pathCollision], volume: physical,
                                         allowProvisional: [.cueVariant], gate: gate, confirmName: physical.name)
        // 관문 막힘이 먼저, 그다음 규칙 선언 순서
        #expect(blocks.map(\.code) == ["physicalDisabled", "provisional"])
        #expect(blocks.map(\.rule) == [.physicalVolume, .pathCollision])
        let both = UsbRuleCheck.blocks(required: [.cueVariant, .pathCollision], volume: physical,
                                       allowProvisional: [], gate: gate, confirmName: physical.name)
        #expect(both.map(\.rule) == [.physicalVolume, .pathCollision, .cueVariant])
    }

    @Test("허용 목록으로 실물 볼륨 규칙은 풀리지 않는다")
    func allowProvisionalCannotUnlockPhysicalVolume() {
        let gate = FakeUsbVolume.gate(allow: [FakeUsbVolume.physicalUUID])
        let blocks = UsbRuleCheck.blocks(required: [.physicalVolume], volume: physical,
                                         allowProvisional: Set(UsbProvisionalRule.allCases), gate: gate, confirmName: physical.name)
        #expect(blocks.map(\.code) == ["physicalDisabled"])
    }

    @Test("거부 목록의 디스크 이미지도 막는다")
    func deniedDiskImageBlocked() {
        let gate = FakeUsbVolume.gate(deny: [image.volumeUUID!])
        let blocks = UsbRuleCheck.blocks(required: [], volume: image, allowProvisional: [], gate: gate, confirmName: nil)
        #expect(blocks.map(\.code) == ["denied"])
    }

    @Test("허용 목록 파싱은 모르는 이름과 실물 볼륨을 거부한다")
    func parseAllowListRejectsUnknownAndPhysicalVolume() throws {
        #expect(try UsbRuleCheck.parseAllowList("cueVariant,pathCollision") == [.cueVariant, .pathCollision])
        #expect(try UsbRuleCheck.parseAllowList(" cueVariant , settingFiles ") == [.cueVariant, .settingFiles])
        #expect(try UsbRuleCheck.parseAllowList("") == [])
        #expect(throws: UsbError.self) { try UsbRuleCheck.parseAllowList("cueVariant,noSuchRule") }
        #expect(throws: UsbError.self) { try UsbRuleCheck.parseAllowList("physicalVolume") }
        do {
            _ = try UsbRuleCheck.parseAllowList("physicalVolume")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.message) == ["physicalVolume은 --allow-provisional로 풀 수 없습니다"])
        }
        do {
            _ = try UsbRuleCheck.parseAllowList("noSuchRule")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.first?.message.contains("noSuchRule") == true)
        }
    }
}
