@testable import djc
import DJCDomain
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

@Suite("USB 읽기 실험 명령")
struct UsbReadLabTests {
    func run(_ arguments: [String]) throws -> (Int32, String) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-labhome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["lab"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["DJC_HOME": home.path, "DJC_LANG": "ko"]) { _, new in new }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func renderPrintsCountsAndFieldNamesOnly() {
        let summaries = [
            UsbLibraryDiff.TableSummary(table: "content", matchedRows: 2, leftRows: 3, rightRows: 3, differingFields: ["title": 1]),
            UsbLibraryDiff.TableSummary(table: "artist", matchedRows: 5, leftRows: 5, rightRows: 5, differingFields: [:]),
        ]
        let lines = UsbReadLab.render((summaries, [UsbLibraryDiff.Difference(table: "content", key: "3", field: "title")]))
        #expect(lines == ["content 2/3행 일치, 다른 칸: title×1", "artist 5/5행 일치", "차이 1"])
    }

    @Test func oneLibrarySQLReadsTemporaryCopyAndBlocksCredentials() throws {
        let marker = "synthetic-private-value"
        let fixture = try OneLibraryFixture(statements: OneLibrarySchema.ddl() + ["CREATE TABLE uuidIDMap(value varchar)"])
        try fixture.add(track: OneLibraryTrackSpec(id: 1))
        try fixture.add(track: OneLibraryTrackSpec(id: 2))
        try fixture.execute("INSERT INTO uuidIDMap VALUES ('\(marker)')")
        fixture.close()
        let before = try Data(contentsOf: fixture.url)

        let (status, output) = try run(["onelib-sql", fixture.url.path, "SELECT count(*) FROM content"])
        #expect(status == 0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
        let (_, integrity) = try run(["onelib-sql", fixture.url.path, "PRAGMA cipher_integrity_check"])
        #expect(integrity.isEmpty)
        // key 표의 칸 보기는 키 PRAGMA가 아니다
        let (_, keyTable) = try run(["onelib-sql", fixture.url.path, "PRAGMA table_info(key)"])
        #expect(keyTable.split(separator: "\n").count == 2)
        for sql in ["SELECT * FROM uuidIDMap", "SELECT * FROM agentRegistry", "PRAGMA rekey = 'x'", "PRAGMA key='x'", " pragma hexkey = \"x\""] {
            let (_, refused) = try run(["onelib-sql", fixture.url.path, sql])
            #expect(!refused.contains(marker))
            #expect(refused.contains("허용하지 않는 쿼리"))
        }
        // 원본은 그대로
        #expect(try Data(contentsOf: fixture.url) == before)
    }

    @Test func oneLibrarySQLRefusesPathOutsideScratch() throws {
        let (status, output) = try run(["onelib-sql", "/etc/hosts", "SELECT 1"])
        #expect(status != 0)
        #expect(output.contains("outsideScratch"))
    }

    @Test func usbDiffOfSameTreeIsZero() throws {
        let fixture = try OneLibraryFixture()
        try fixture.add(track: OneLibraryTrackSpec(id: 1))
        try fixture.add(playlist: 10, name: "시험 목록", entries: [1])
        fixture.close()
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        tree.write("PIONEER/rekordbox/exportLibrary.db", try Data(contentsOf: fixture.url))
        let before = tree.tree()
        let (status, output) = try run(["usb-diff", "--onelibrary", tree.base.path, tree.base.path])
        #expect(status == 0)
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.last == "차이 0")
        #expect(lines.contains("content 1/1행 일치"))
        #expect(lines.contains("playlist 1/1행 일치"))
        #expect(!output.contains("시험"))
        #expect(tree.tree() == before)

        let (usageStatus, usage) = try run(["usb-diff", tree.base.path, tree.base.path])
        #expect(usageStatus == 0)
        #expect(usage.contains("사용법"))
    }
}
