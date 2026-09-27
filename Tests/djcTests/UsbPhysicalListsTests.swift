import DJCDomain
import DJCStorage
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
}
