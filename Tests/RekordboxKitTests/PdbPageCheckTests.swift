import DJCDomain
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// 있는 파일의 쪽을 칸 값만으로 다시 만들어 비교한다(lab pdb-verify)
@Suite("Device Library 쪽 다시 만들기 비교")
struct PdbPageCheckTests {
    @Test func writerOutputIsReproducedPageByPage() throws {
        var model = PdbWriterTests.model()
        model.myTags = PdbLayoutTests.tags(categories: 2, tags: 5)
        model.labels = [UsbNamedRow(id: 1, name: "시험 레이블")]
        model.tracks[0].labelID = 1
        let files = try PdbWriter.files(model, mode: .edit(previousExportSequence: 40, previousExtSequence: 3))
        for data in [files.export, files.exportExt] {
            let report = try PdbPageCheck.check(data)
            #expect(report.compared.filter { !$0.isSame }.isEmpty)
            #expect(report.excluded.isEmpty)
            #expect(report.compared.count == report.pageCount)
            #expect(report.count(.header).same == 1 && report.count(.header).total == 1)
            #expect(report.count(.zero).total > 0 && report.count(.data).total > 0)
        }
        let index = try PdbPageCheck.check(files.exportExt).count(.index)
        #expect(index.same == 9 && index.total == 9)
    }

    @Test func reportsDifferingRowsAndExcludedPages() throws {
        var files = try PdbWriter.files(PdbWriterTests.model(), mode: .fresh)
        let export = try PdbFile(data: files.export)
        // 트랙 행 하나의 할당 끝 빈 바이트를 채운다(칸 값은 그대로라 다시 만든 행은 0이다)
        let page = try #require(PdbWriterTests.dataPages(export, 0).first)
        let row = page.row(page.slots[1])
        let at = Int(page.header.pageIndex) * PdbPage.size + PdbPage.heapStart + page.slots[1].offset + row.count - 1
        files.export[at] = 0x01
        let report = try PdbPageCheck.check(files.export)
        let differing = report.compared.filter { !$0.isSame }
        #expect(differing.map(\.number) == [Int(page.header.pageIndex)])
        #expect(differing.first?.table == "tracks" && differing.first?.category == .data)
        #expect(differing.first?.firstDifference == PdbPage.heapStart + page.slots[1].offset + row.count - 1)
        #expect(differing.first?.rows == [PdbPageCheck.RowDifference(slot: 1, originalSize: row.count, rebuiltSize: row.count,
                                                                      firstDifference: row.count - 1)])

        // 제자리 수정 이력(지운 행)이 있는 쪽과 지운 쪽 목록이 있는 인덱스 쪽은 뺀다
        let edited = PdbReadTests.sampleExport(tracks: PdbRoundTripTests.sampleTracks()) { builder in
            var dead = PdbTrackSpec(id: 9)
            dead[.fileName] = "test9.mp3"
            builder.add(.tracks, PdbBuilder.Row(PdbBuilder.trackRow(dead).bytes, live: false, hasIndexShift: true))
        }.build()
        let editedReport = try PdbPageCheck.check(edited.data)
        #expect(editedReport.excluded.map(\.reason).sorted() == ["deadRows", "indexEntries"])
        #expect(editedReport.excluded.allSatisfy { $0.table == "tracks" })
    }

    @Test func differentAllocationIsReportedPerRow() throws {
        // 합성 조립기는 행을 4바이트 경계까지만 할당한다(작성기 규칙보다 작다) → 행 크기가 다르다고 보고한다
        let built = PdbReadTests.sampleExport(tracks: PdbRoundTripTests.sampleTracks()).build()
        let report = try PdbPageCheck.check(built.data)
        let tracks = try #require(report.compared.first { $0.table == "tracks" && $0.category == .data })
        #expect(!tracks.isSame)
        #expect(tracks.rows.contains { $0.originalSize != $0.rebuiltSize })
        // 해석할 수 없는 행은 -1
        var broken = PdbReadTests.sampleExport(tracks: PdbRoundTripTests.sampleTracks())
        broken.tables[PdbTableType.genres.rawValue] = [PdbBuilder.opaqueRow(8, fill: 0xFF)]
        let brokenReport = try PdbPageCheck.check(broken.build().data)
        #expect(brokenReport.compared.contains { $0.table == "genres" && $0.firstDifference == -1 })
    }
}
