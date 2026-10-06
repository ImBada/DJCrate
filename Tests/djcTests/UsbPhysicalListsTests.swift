import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import Testing

/// 실물 쓰기 허용·거부 목록 읽기(임시 폴더 둘을 넘긴다. 실제 DJCrate 데이터 폴더는 건드리지 않는다)
@Suite("USB 실물 목록")
struct UsbPhysicalListsTests {
    static let a = "00000000-0000-0000-0000-00000000AAA1"
    static let b = "00000000-0000-0000-0000-00000000BBB2"

    func withFolders(_ body: (URL, URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "djc-lists-\(UUID().uuidString)")
        let support = base.appending(path: "support"), user = base.appending(path: "user")
        for url in [support, user] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        try body(support, user)
    }

    func put(_ folder: URL, _ name: String, _ volumes: [String]) throws {
        let json = try JSONSerialization.data(withJSONObject: ["version": 1, "volumes": volumes])
        try json.write(to: folder.appending(path: name))
    }

    @Test("허용 목록은 고정 위치만 읽는다(DJC_HOME 쪽은 무시)")
    func allowIgnoresUserData() throws {
        try withFolders { support, user in
            try put(user, "usb-physical-allow.json", [Self.a])
            #expect(UsbPhysicalLists.load(supportDirectory: support, userData: user).allow.isEmpty)
            try put(support, "usb-physical-allow.json", [Self.a.lowercased()])
            let loaded = UsbPhysicalLists.load(supportDirectory: support, userData: user)
            #expect(loaded.allow == [Self.a])
            #expect(loaded.allowState == .ok)
        }
    }

    @Test("허용 목록이 없거나 깨지면 빈 목록")
    func missingOrCorruptAllowIsEmpty() throws {
        try withFolders { support, user in
            #expect(UsbPhysicalLists.load(supportDirectory: support, userData: user).allowState == .missing)
            try Data("{".utf8).write(to: support.appending(path: "usb-physical-allow.json"))
            let loaded = UsbPhysicalLists.load(supportDirectory: support, userData: user)
            #expect(loaded.allow.isEmpty)
            #expect(loaded.allowState == .corrupt)
        }
    }

    @Test("거부 목록은 두 곳의 합")
    func denyUnionOfBoth() throws {
        try withFolders { support, user in
            try put(support, "usb-physical-deny.json", [Self.a])
            try put(user, "usb-physical-deny.json", [Self.b])
            let loaded = UsbPhysicalLists.load(supportDirectory: support, userData: user)
            #expect(loaded.deny == [Self.a, Self.b])
            #expect(loaded.denyStatus == UsbDenyListStatus(fixedLocation: .ok, fixedEntryCount: 1, userData: .ok))
            let gate = UsbPhysicalLists.gate(supportDirectory: support, userData: user)
            #expect(gate.denylist == [Self.a, Self.b])
        }
    }

    @Test func denyFixedMissingReportsMissing() throws {
        try withFolders { support, user in
            #expect(UsbPhysicalLists.load(supportDirectory: support, userData: user).denyStatus == .missing)
        }
    }

    @Test("고정 거부 목록이 깨졌으면(JSON·UUID 모양) corrupt", arguments: ["{", #"{"version": 1, "volumes": ["not-a-uuid"]}"#, #"{"volumes": 3}"#])
    func denyFixedCorruptReportsCorrupt(text: String) throws {
        try withFolders { support, user in
            try Data(text.utf8).write(to: support.appending(path: "usb-physical-deny.json"))
            let loaded = UsbPhysicalLists.load(supportDirectory: support, userData: user)
            #expect(loaded.denyStatus.fixedLocation == .corrupt)
            // 깨진 거부 목록은 실물 쓰기를 막는다(fail-closed)
            let gate = UsbPhysicalLists.gate(supportDirectory: support, userData: user)
            #expect(gate.denyStatus.fixedLocation == .corrupt)
        }
    }

    @Test func denyUserDataCorruptReportsCorrupt() throws {
        try withFolders { support, user in
            try put(support, "usb-physical-deny.json", [Self.a])
            try Data("[".utf8).write(to: user.appending(path: "usb-physical-deny.json"))
            let loaded = UsbPhysicalLists.load(supportDirectory: support, userData: user)
            #expect(loaded.denyStatus.userData == .corrupt)
            #expect(loaded.denyStatus.fixedLocation == .ok)
        }
    }

    @Test("항목 수는 고정 위치만 센다")
    func denyEntryCountFromFixedOnly() throws {
        try withFolders { support, user in
            try put(support, "usb-physical-deny.json", [Self.a])
            try put(user, "usb-physical-deny.json", [Self.b, "00000000-0000-0000-0000-00000000CCC3"])
            #expect(UsbPhysicalLists.load(supportDirectory: support, userData: user).denyStatus.fixedEntryCount == 1)
        }
    }

    @Test("두 인자가 같은 폴더면 한 번만 읽는다")
    func sameDirectoryReadOnce() throws {
        try withFolders { support, _ in
            try put(support, "usb-physical-deny.json", [Self.a])
            let loaded = UsbPhysicalLists.load(supportDirectory: support, userData: support)
            #expect(loaded.deny == [Self.a])
            #expect(loaded.denyStatus.fixedEntryCount == 1)
            #expect(loaded.denyStatus.fixedLocation == .ok)
        }
    }

    @Test("읽기만 한다(폴더 목록·mtime 그대로)")
    func loadNeverWrites() throws {
        try withFolders { support, user in
            try put(support, "usb-physical-deny.json", [Self.a])
            func snapshot() throws -> [String: Date] {
                var result: [String: Date] = [:]
                for folder in [support, user] {
                    for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
                        let path = folder.appending(path: name).path
                        result[path] = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
                    }
                    result[folder.path] = try FileManager.default.attributesOfItem(atPath: folder.path)[.modificationDate] as? Date
                }
                return result
            }
            let before = try snapshot()
            _ = UsbPhysicalLists.load(supportDirectory: support, userData: user)
            _ = UsbPhysicalLists.gate(supportDirectory: support, userData: user)
            #expect(try snapshot() == before)
        }
    }

    // MARK: - 고치기(허용·거두기·금지)

    @Test("쓰기 허용: FAT32·MBR USB 메모리만 고정 위치 허용 목록에 더한다(이름 포함, 두 번 더해도 하나)")
    func allowAddsVolume() throws {
        try withFolders { support, user in
            let stick = FakeUsbVolume.physicalFAT32()
            try UsbPhysicalLists.allow(stick, supportDirectory: support, userData: user)
            try UsbPhysicalLists.allow(stick, supportDirectory: support, userData: user)
            let loaded = UsbPhysicalLists.load(supportDirectory: support, userData: user)
            #expect(loaded.allow == [FakeUsbVolume.physicalUUID])
            #expect(loaded.names[FakeUsbVolume.physicalUUID] == "DJCPHYS")
            #expect(loaded.allowState == .ok)
            // DJC_HOME 쪽에는 쓰지 않는다
            #expect(!FileManager.default.fileExists(atPath: user.appending(path: "usb-physical-allow.json").path))
            try UsbPhysicalLists.revoke(uuid: FakeUsbVolume.physicalUUID.lowercased(), supportDirectory: support)
            #expect(UsbPhysicalLists.load(supportDirectory: support, userData: user).allow.isEmpty)
        }
    }

    @Test("쓰기 허용을 받지 않는 볼륨은 목록 파일을 만들지 않는다", arguments: ["exfat", "gpt", "ssd", "image", "denied", "internal"])
    func allowRefuses(kind: String) throws {
        try withFolders { support, user in
            var volume = FakeUsbVolume.physicalFAT32()
            switch kind {
            case "exfat": volume = FakeUsbVolume.exfat()
            case "gpt": volume = FakeUsbVolume.gpt()
            case "ssd": volume = FakeUsbVolume.externalSSD()
            case "image": volume = FakeUsbVolume.diskImageFAT32()
            case "internal": volume = FakeUsbVolume.internal()
            default: try put(support, "usb-physical-deny.json", [FakeUsbVolume.physicalUUID])
            }
            #expect(throws: UsbError.self) { try UsbPhysicalLists.allow(volume, supportDirectory: support, userData: user) }
            #expect(!FileManager.default.fileExists(atPath: support.appending(path: "usb-physical-allow.json").path))
        }
    }

    @Test("목록 파일이 깨졌으면 고치지 않는다(빈 목록으로 덮지 않는다)")
    func corruptListNotOverwritten() throws {
        try withFolders { support, user in
            let corrupt = Data("{".utf8)
            try corrupt.write(to: support.appending(path: "usb-physical-allow.json"))
            #expect(throws: UsbError.self) { try UsbPhysicalLists.allow(FakeUsbVolume.physicalFAT32(), supportDirectory: support, userData: user) }
            #expect(try Data(contentsOf: support.appending(path: "usb-physical-allow.json")) == corrupt)
            try corrupt.write(to: support.appending(path: "usb-physical-deny.json"))
            #expect(throws: UsbError.self) { try UsbPhysicalLists.deny(FakeUsbVolume.physicalFAT32(), supportDirectory: support) }
            #expect(try Data(contentsOf: support.appending(path: "usb-physical-deny.json")) == corrupt)
            // 거부 목록이 깨졌으면 허용도 하지 않는다
            try FileManager.default.removeItem(at: support.appending(path: "usb-physical-allow.json"))
            #expect(throws: UsbError.self) { try UsbPhysicalLists.allow(FakeUsbVolume.physicalFAT32(), supportDirectory: support, userData: user) }
        }
    }

    @Test("쓰기 금지: 고정 위치 목록에 넣고 허용 목록에서 뺀다. 디스크 이미지도 받는다. 넣으면 실물 읽기·쓰기 목록이 등록된 것으로 본다")
    func denyAddsAndRevokes() throws {
        try withFolders { support, user in
            try UsbPhysicalLists.allow(FakeUsbVolume.physicalFAT32(), supportDirectory: support, userData: user)
            try UsbPhysicalLists.deny(FakeUsbVolume.physicalFAT32(), supportDirectory: support)
            try UsbPhysicalLists.deny(FakeUsbVolume.diskImageFAT32(), supportDirectory: support)
            let loaded = UsbPhysicalLists.load(supportDirectory: support, userData: user)
            #expect(loaded.deny == [FakeUsbVolume.physicalUUID, FakeUsbVolume.diskImageFAT32().volumeUUID!])
            #expect(loaded.allow.isEmpty)
            #expect(loaded.denyStatus.fixedEntryCount == 2)
            var noUUID = FakeUsbVolume.physicalFAT32()
            noUUID.volumeUUID = nil
            #expect(throws: UsbError.self) { try UsbPhysicalLists.deny(noUUID, supportDirectory: support) }
            // 실행 중 스위치를 켠 관문: 거부 목록 USB는 막고 다른 USB는 허용 목록이 필요하다
            let gate = loaded.gate(physicalEnabled: true)
            #expect(gate.blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS").map(\.code) == ["denied"])
            let other = FakeUsbVolume.physicalFAT32(uuid: Self.b, name: "OTHER")
            #expect(gate.blocks(other, confirmName: "OTHER").map(\.code) == ["notAllowlisted"])
            try UsbPhysicalLists.allow(other, supportDirectory: support, userData: user)
            let opened = UsbPhysicalLists.gate(supportDirectory: support, userData: user, physicalEnabled: true)
            #expect(opened.blocks(other, confirmName: "OTHER").isEmpty == UsbPhysicalWriteGate.buildEnabled)
        }
    }
}
