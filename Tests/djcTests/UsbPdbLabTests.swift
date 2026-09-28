@testable import djc
import DJCDomain
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

@Suite("Device Library 쓰기 실험 명령")
struct UsbPdbLabTests {
    func run(_ arguments: [String]) throws -> (Int32, String) {
        try UsbReadLabTests().run(arguments)
    }

    @Test func pdbVerifyReproducesWriterOutput() throws {
        let source = UsbReadLabTests.pdbFiles()
        let model = try PdbReader.read(export: source.export, exportExt: source.exportExt).0
        let files = try PdbWriter.files(model, mode: .fresh)
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        tree.write(UsbLayout.exportPdb, files.export)
        tree.write(UsbLayout.exportExtPdb, files.exportExt)
        let before = tree.tree()

        let (status, output) = try run(["pdb-verify", tree.base.path])
        #expect(status == 0)
        let lines = output.split(separator: "\n").map(String.init)
        let extPages = files.exportExt.count / PdbPage.size
        #expect(lines.contains("exportExt \(extPages)/\(extPages)쪽 바이트 같음"))
        #expect(lines.contains { $0.hasPrefix("export 머리 1/1 + 데이터 쪽") })
        #expect(!output.contains("다른 쪽") && !output.contains("뺀 쪽("))
        #expect(!output.contains("시험") && !output.contains("test1"))
        #expect(tree.tree() == before)
    }

    @Test func pdbVerifyReportsDifferencesAndExcludedPages() throws {
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        // 합성 조립기의 파일: 지운 행이 있는 쪽은 빼고, 행 할당이 작성기 규칙과 다른 쪽은 자리·크기를 찍는다
        tree.write(UsbLayout.exportPdb, UsbReadLabTests.pdbFiles().export)
        let (status, output) = try run(["pdb-verify", tree.base.path])
        #expect(status == 0)
        #expect(output.contains("뺀 쪽(지운 행이 있는 데이터 쪽) 1"))
        #expect(output.contains("뺀 쪽(지운 쪽 목록이 있는 인덱스 쪽) 1"))
        #expect(!output.contains("exportExt"))
        #expect(!output.contains("시험"))

        // 지운 행 없는 트랙 쪽: 조립기는 행을 4바이트 경계까지만 할당해 작성기 규칙과 크기가 다르다
        let live = UsbTreeFixture()
        defer { live.remove() }
        var export = PdbBuilder(kind: .export)
        for id in [1, 2] { export.add(.tracks, PdbBuilder.trackRow(PdbTrackSpec(id: id))) }
        export.add(.history19, PdbBuilder.propertyRow(count: 2, date: "2026-01-03"))
        live.write(UsbLayout.exportPdb, export.build().data)
        let (_, differing) = try run(["pdb-verify", live.base.path])
        #expect(differing.contains("다른 쪽") && differing.contains("data tracks") && differing.contains("크기"))
        #expect(!differing.contains("시험") && !differing.contains("test1"))

        let empty = UsbTreeFixture()
        defer { empty.remove() }
        empty.write("PIONEER/rekordbox/README", Data("x".utf8))
        let (_, missing) = try run(["pdb-verify", empty.base.path])
        #expect(missing.contains("export.pdb)가 없다"))
    }

    @Test func pdbCommandsRefusePathsOutsideScratch() throws {
        let (status, output) = try run(["pdb-verify", "/usr"])
        #expect(status != 0 && output.contains("outsideScratch"))
        let (exportStatus, exportOutput) = try run(["pdb-export", "--db", "/etc/hosts", "--share", "/tmp", "--tracks", "1", "--out", "/tmp/x"])
        #expect(exportStatus != 0 && exportOutput.contains("outsideScratch"))
        let (_, usage) = try run(["pdb-verify"])
        #expect(usage.contains("사용법"))
    }

    @Test func verifyLinesPrintNumbersOnly() {
        let report = PdbPageCheck.Report(
            kind: .export, pageCount: 5,
            compared: [
                PdbPageCheck.Page(number: 0, category: .header, table: "", firstDifference: nil),
                PdbPageCheck.Page(number: 1, category: .index, table: "tracks", firstDifference: nil),
                PdbPageCheck.Page(number: 2, category: .data, table: "tracks", firstDifference: 0x1C,
                                  rows: [PdbPageCheck.RowDifference(slot: 3, originalSize: 588, rebuiltSize: 444, firstDifference: 0x115)]),
                PdbPageCheck.Page(number: 4, category: .zero, table: "", firstDifference: nil),
            ],
            excluded: [PdbPageCheck.Excluded(number: 3, table: "genres", reason: "deadRows")])
        let lines = UsbExportLab.pdbVerifyLines(report)
        #expect(lines == [
            "export.pdb 3/4쪽 바이트 같음(파일 5쪽, 뺀 쪽 1)",
            "  머리 1/1 · 인덱스 쪽 1/1 · 빈 쪽 1/1 · 데이터 쪽 0/1",
            "  뺀 쪽(지운 행이 있는 데이터 쪽) 1: 3",
            "  다른 쪽 2 data tracks 오프셋 0x01C",
            "    자리 3: 크기 588 → 444, 행 안 처음 다른 자리 0x115",
        ])
        #expect(UsbExportLab.pdbVerifySummary(report) == "export 머리 1/1 + 데이터 쪽 0/1개 바이트 같음(쪽 번호·next·seq는 원본 값)")
    }
}
