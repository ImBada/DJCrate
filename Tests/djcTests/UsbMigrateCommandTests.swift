import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing
@testable import djc

/// `djc usb-migrate` 인자·요약 줄
@Suite("USB OneLibrary로 옮기기 명령")
struct UsbMigrateCommandTests {
    @Test("인자: 볼륨·드라이 런·확인·규칙")
    func parsesArguments() throws {
        let request = try UsbCommands.migrateRequest(["usb-migrate", "--volume", "/tmp/v", "--dry-run", "--confirm", "DJCTEST",
                                                      "--allow-provisional", "deviceLibraryMigration,myTagLinks"])
        #expect(request == UsbCommands.MigrateRequest(volume: "/tmp/v", dryRun: true, confirmName: "DJCTEST",
                                                      allowProvisional: [.deviceLibraryMigration, .myTagLinks]))
        #expect(try UsbCommands.migrateRequest(["usb-migrate", "--volume", "/tmp/v"]) == UsbCommands.MigrateRequest(volume: "/tmp/v"))
    }

    @Test("잘못된 인자는 사용법, 실물 볼륨 규칙·라이브 라이브러리는 거부")
    func rejectsBadArguments() {
        for args in [
            ["usb-migrate"],
            ["usb-migrate", "--volume"],
            ["usb-migrate", "--volume", "/v", "--confirm"],
            ["usb-migrate", "--volume", "/v", "--unknown"],
            ["usb-migrate", "--volume", "/v", "/tmp/a.json"],
        ] {
            #expect(throws: UsageError.self) { try UsbCommands.migrateRequest(args) }
        }
        #expect(throws: UsbError.self) {
            try UsbCommands.migrateRequest(["usb-migrate", "--volume", "/v", "--allow-provisional", "physicalVolume"])
        }
        #expect(throws: UsbError.self) {
            try UsbCommands.migrateRequest(["usb-migrate", "--volume", NSHomeDirectory() + "/Library/Pioneer/rekordbox"])
        }
    }

    @Test("요약 줄: 막힘·옮길 수·확인 안 된 규칙·쓰기 결과. 곡 제목·경로는 찍지 않는다")
    func summaryLines() throws {
        let usb = UsbChangeSetFixture()
        defer { usb.remove() }
        var fixture = UsbLibraryFixture()
        fixture.formats = [.deviceLibrary]
        fixture.myTagLinks = []
        try fixture.write(to: UsbTreeFixture(base: usb.usbURL))
        let session = UsbMigrateSession(root: usb.usbURL, guard: usb.writeGuard(), paths: usb.paths, fileSystem: usb.fileSystem(),
                                        copies: usb.home.appending(path: "usb-snapshots"))
        let (result, report) = try session.write(options: UsbWriteOptions(), progress: { _ in }, isCancelled: { false })
        let lines = UsbCommands.migrateLines(result: result, report: report)
        #expect(lines.contains("옮길 것: 곡 3 · 재생 목록 1 · OneLibrary 아트워크 6"))
        #expect(lines.contains { $0.hasPrefix("확인 안 된 규칙: ") && $0.contains("deviceLibraryMigration") })
        #expect(lines.contains("결과: 썼습니다"))
        #expect(!lines.joined().contains("Contents/") && !lines.joined().contains("시험 목록"))

        var blocked = UsbMigrationResult()
        blocked.blocks = [UsbMigration.Blocks.oneLibraryExists]
        let refused = UsbCommands.migrateLines(result: blocked, report: nil)
        #expect(refused.first?.hasPrefix("막힘 oneLibraryExists:") == true)
        #expect(!refused.contains { $0.hasPrefix("옮길 것:") })
    }
}
