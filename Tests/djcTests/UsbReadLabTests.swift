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

        // 기본 모드는 있는 형식 모두(여기서는 OneLibrary만)
        let (bothStatus, both) = try run(["usb-diff", tree.base.path, tree.base.path])
        #expect(bothStatus == 0)
        #expect(both.split(separator: "\n").last == "차이 0")
        let (usageStatus, usage) = try run(["usb-diff", tree.base.path])
        #expect(usageStatus == 0)
        #expect(usage.contains("사용법"))
    }

    /// 합성 Device Library(곡 2·목록 1·태그 1). 모든 값은 지어낸 것이다.
    static func pdbFiles(brokenGenres: Bool = false) -> (export: Data, exportExt: Data) {
        var export = PdbBuilder(kind: .export)
        for id in [1, 2] { export.add(.tracks, PdbBuilder.trackRow(PdbTrackSpec(id: id))) }
        var dead = PdbBuilder.trackRow(PdbTrackSpec(id: 9))
        dead.live = false
        export.add(.tracks, dead)
        export.add(.genres, PdbBuilder.idNameRow(1, "시험 장르"))
        export.add(.playlistTree, PdbBuilder.playlistTreeRow(id: 10, name: "시험 목록"))
        export.add(.playlistEntries, PdbBuilder.playlistEntryRow(index: 1, trackID: 2, playlistID: 10))
        export.add(.history19, PdbBuilder.propertyRow(count: 2, date: "2026-01-03"))
        var ext = PdbBuilder(kind: .exportExt)
        ext.add(.tags, PdbBuilder.tagRow(id: 7, name: "시험 분류", position: 0, isCategory: true))
        ext.add(.myTagProperty, PdbBuilder.myTagPropertyRow(masterDBID: 123_456))
        var built = export.build()
        if brokenGenres {
            let genres = PdbTableType.genres.rawValue
            built.setU32(page: built.dataPages[genres]![0], offset: 0x04, 999)
        }
        return (built.data, ext.build().data)
    }

    @Test func pdbDumpPrintsCountsWithoutValues() throws {
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        let files = Self.pdbFiles()
        tree.write(UsbLayout.exportPdb, files.export)
        tree.write(UsbLayout.exportExtPdb, files.exportExt)
        let before = tree.tree()

        let (status, output) = try run(["pdb-dump", tree.url(UsbLayout.exportPdb).path])
        #expect(status == 0)
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.last == "issues 0")
        #expect(lines.contains { $0.contains("tables 20") && $0.contains("flag10 5") })
        #expect(lines.contains { $0.hasPrefix("table 0 tracks") && $0.contains("2/3") })
        #expect(lines.contains { $0.hasPrefix("table 19 history19") && $0.contains("1/1") })
        #expect(!output.contains("시험") && !output.contains("test1"))

        let (_, ext) = try run(["pdb-dump", tree.url(UsbLayout.exportExtPdb).path])
        #expect(ext.split(separator: "\n").contains { $0.hasPrefix("table 3 exportExt.tags") && $0.contains("1/1") })
        #expect(ext.split(separator: "\n").last == "issues 0")

        let (_, pages) = try run(["pdb-dump", tree.url(UsbLayout.exportPdb).path, "--pages"])
        #expect(pages.contains("flags 0x64") && pages.contains("flags 0x34"))

        let (_, rows) = try run(["pdb-dump", tree.url(UsbLayout.exportPdb).path, "--rows", "tracks"])
        let rowLines = rows.split(separator: "\n").filter { $0.contains("slot ") }
        #expect(rowLines.count == 3)
        #expect(rowLines.contains { $0.contains("dead") } && rowLines.contains { $0.contains("shift 0x0020") })
        #expect(rowLines.contains { $0.contains("utf16LE") && $0.contains("shortASCII") })
        #expect(!rows.contains("시험") && !rows.contains("test1"))
        // 원본은 그대로
        #expect(tree.tree() == before)
    }

    @Test func pdbDumpReportsIssueKindsAndPages() throws {
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        tree.write(UsbLayout.exportPdb, Self.pdbFiles(brokenGenres: true).export)
        let (status, output) = try run(["pdb-dump", tree.url(UsbLayout.exportPdb).path])
        #expect(status == 0)
        let last = try #require(output.split(separator: "\n").last.map(String.init))
        #expect(last.hasPrefix("issues 1"))
        #expect(last.contains("pageIndexMismatch"))
    }

    @Test func pdbDumpRefusesPathOutsideScratch() throws {
        let (status, output) = try run(["pdb-dump", "/etc/hosts"])
        #expect(status != 0)
        #expect(output.contains("outsideScratch"))
    }

    @Test func usbDiffDeviceLibraryAndBoth() throws {
        let fixture = try OneLibraryFixture()
        try fixture.add(track: OneLibraryTrackSpec(id: 1))
        try fixture.add(track: OneLibraryTrackSpec(id: 2))
        fixture.close()
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        let files = Self.pdbFiles()
        tree.write(UsbLayout.exportPdb, files.export)
        tree.write(UsbLayout.exportExtPdb, files.exportExt)
        tree.write(UsbLayout.oneLibrary, try Data(contentsOf: fixture.url))
        let before = tree.tree()

        let (status, output) = try run(["usb-diff", "--device-library", tree.base.path, tree.base.path])
        #expect(status == 0)
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.last == "차이 0")
        #expect(lines.contains("content 2/2행 일치"))
        #expect(lines.contains("deadIDs 1/1행 일치"))
        #expect(!output.contains("시험"))

        let (bothStatus, both) = try run(["usb-diff", tree.base.path, tree.base.path])
        #expect(bothStatus == 0)
        let bothLines = both.split(separator: "\n").map(String.init)
        #expect(bothLines.last == "차이 0")
        #expect(bothLines.contains("content 2/2행 일치"))
        #expect(bothLines.contains { $0.hasPrefix("형식 불일치 A") })
        #expect(tree.tree() == before)

        // Device Library가 없는 쪽은 알려 준다
        let empty = UsbTreeFixture()
        defer { empty.remove() }
        empty.mkdir("PIONEER/rekordbox")
        let (_, missing) = try run(["usb-diff", "--device-library", empty.base.path, tree.base.path])
        #expect(missing.contains("export.pdb"))
    }
}
