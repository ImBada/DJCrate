import DJCDomain
import Foundation

/// Device Library를 고쳐 쓰기 전의 왕복 검사: 읽기 → 모델 → 쓰기 → 다시 읽기.
/// 작성기가 이 파일의 모든 알려진 칸을 다시 만들 수 있을 때만 통과한다.
public enum PdbRoundTrip {
    /// 읽기(B2) → 모델 → 쓰기 → 다시 읽기. 알려진 표의 칸이 같고 상수 칸(bitmask 0x000C0700, u5 0x29, u7 3, 빈 문자열 칸 5·8·9·13·18)이
    /// 관찰값과 같아야 통과. 칸 비교는 `UsbLibraryDiff.Options(formats: [.deviceLibrary])`로 한다.
    /// 문제는 영어 고정 표기(표·id·칸 이름·수)만 넣고 글자 값은 넣지 않는다. 빈 배열 = 통과.
    /// - 원본의 구조 문제·먼 오프셋 행, 작성기가 막는 행(기록·모르는 표·My Tag 연결 등)도 문제로 남긴다.
    /// - 지운 행 id(`deadIDs`)는 다시 쓰면 사라지는 것이 정상이라 비교하지 않는다(ID를 다시 쓰지 않게 지키는 것은 편집 쪽 몫).
    /// - 파일 머리를 읽을 수 없으면 던진다.
    public static func check(export: Data, exportExt: Data?) throws -> [String] {
        let (model, report) = try PdbReader.read(export: export, exportExt: exportExt)
        var problems = report.issues.map { "structure \($0)" }
        problems += report.farShapeRows.sorted { $0.key < $1.key }.filter { $0.value > 0 }.map { "far_shape_rows \($0.key) \($0.value)" }
        problems += constantProblems(model)
        let files: PdbFiles
        do {
            files = try PdbWriter.files(model, mode: .edit(previousExportSequence: report.exportHeader.sequence,
                                                         previousExtSequence: report.extHeader?.sequence ?? 0))
        } catch let UsbError.writeRefused(blocks) {
            return problems + blocks.map { "refused \($0.code)" }
        }
        let (reread, rereadReport) = try PdbReader.read(export: files.export, exportExt: files.exportExt)
        problems += rereadReport.issues.map { "reread structure \($0)" }
        let differences = UsbLibraryDiff.compare(model, reread, options: .init(skipTables: ["deadIDs"], formats: [.deviceLibrary])).differences
        return problems + differences.map { "\($0.table) \($0.key) \($0.field)" }
    }

    /// 트랙 행 상수 칸이 작성기가 쓰는 관찰값과 다른 곡
    /// rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    static func constantProblems(_ model: UsbLibrary) -> [String] {
        let observed = PdbWriter.observedExtras([])
        var problems: [String] = []
        for (id, extras) in model.trackRowExtras.sorted(by: { $0.key < $1.key }) {
            if extras.subtype != observed.subtype { problems.append(String(format: "content %d subtype 0x%04X", id, extras.subtype)) }
            if extras.bitmask != observed.bitmask { problems.append(String(format: "content %d bitmask 0x%08X", id, extras.bitmask)) }
            if extras.u5 != observed.u5 { problems.append(String(format: "content %d u5 0x%04X", id, extras.u5)) }
            if extras.u7 != observed.u7 { problems.append("content \(id) u7 \(extras.u7)") }
            for (index, value) in extras.unknownStrings.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
                problems.append("content \(id) unknownString\(index) not empty")
            }
        }
        return problems
    }
}
