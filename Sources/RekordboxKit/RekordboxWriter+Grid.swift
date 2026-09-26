import AnicueDomain
import Foundation

/// 그리드 BPM 변경 때 DB(contentFile 해시·크기, djmdContent BPM) 고치기
extension RekordboxWriter {
    /// BPM이 바뀌는 그리드의 DB 쪽(BPM 244→245 실험과 같은 칸):
    /// `contentFile`(.DAT): Hash·Size·상태 256→257·rb_local_usn·updated_at /
    /// `djmdContent`: BPM·AnalysisUpdated+1·TrackInfoUpdated+1·상태 256→257·rb_local_usn·updated_at.
    static func applyGridDatabase(_ plan: RekordboxGridWriter.Plan, db: CipherDatabase, usn: inout Int,
                                  stamp: (db: String, json: String)) throws {
        guard let bpm100 = plan.newBPM100 else { return }
        func fail(_ reason: String) -> AnicueError { .writeVerificationFailed("\(reason) (\(plan.title))") }
        var contentID: String?
        try db.query("SELECT ID FROM djmdContent WHERE UUID = ? AND rb_local_deleted = 0", [.text(plan.trackUUID)]) { contentID = $0.string(0) }
        guard let contentID else { throw fail("곡을 찾지 못했습니다") }
        usn += 1
        let fileUSN = usn
        let files = try db.run("""
            UPDATE contentFile SET Hash = ?, Size = ?,
                rb_data_status = CASE rb_data_status WHEN 256 THEN 257 ELSE rb_data_status END,
                rb_local_usn = ?, updated_at = ? WHERE ContentID = ? AND Path = ?
            """, [.text(plan.newDatMD5), .int(plan.newDat.count), .int(fileUSN), .text(stamp.db), .text(contentID), .text(plan.analysisDataPath)])
        guard files <= 1 else { throw fail("분석 파일 기록이 여럿입니다") }
        usn += 1
        let contentUSN = usn
        let changed = try db.run("""
            UPDATE djmdContent SET BPM = ?,
                AnalysisUpdated = CAST(ifnull(AnalysisUpdated, '0') AS INTEGER) + 1,
                TrackInfoUpdated = CAST(ifnull(TrackInfoUpdated, '0') AS INTEGER) + 1,
                rb_data_status = CASE rb_data_status WHEN 256 THEN 257 ELSE rb_data_status END,
                rb_local_usn = ?, updated_at = ? WHERE ID = ?
            """, [.int(bpm100), .int(contentUSN), .text(stamp.db), .text(contentID)])
        guard changed == 1 else { throw fail("곡 BPM을 고치지 못했습니다") }
        // rekordbox는 두 칸을 글자로 둔다.
        try db.run("UPDATE djmdContent SET AnalysisUpdated = CAST(AnalysisUpdated AS TEXT), TrackInfoUpdated = CAST(TrackInfoUpdated AS TEXT) WHERE ID = ?",
                   [.text(contentID)])
        var check: (Int, String?)?
        try db.query("SELECT BPM, typeof(AnalysisUpdated) FROM djmdContent WHERE ID = ?", [.text(contentID)]) { check = ($0.int(0) ?? 0, $0.string(1)) }
        guard check?.0 == bpm100, check?.1 == "text" else { throw fail("곡 BPM 확인 실패") }
    }

    /// DB 사본의 rekordbox 변경 카운터(읽기 전용).

    public static func gridDrafts(in backup: URL) -> [GridDraft] {
        let folder = backup.appending(path: "grid-drafts")
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(GridDraft.self, from: $0) }
    }

    public static func contents(of backup: URL) -> (report: Report?, drafts: [CueDraft]) {
        let report = (try? Data(contentsOf: backup.appending(path: "report.json")))
            .flatMap { try? JSONDecoder().decode(Report.self, from: $0) }
        let folder = backup.appending(path: "cue-drafts")
        let drafts = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(CueDraft.self, from: $0) }
        return (report, drafts)
    }
}
