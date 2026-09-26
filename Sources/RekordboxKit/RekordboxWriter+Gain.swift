import DJCDomain
import Foundation

/// 오토게인 쓰기(djmdMixerParam)
extension RekordboxWriter {
    public static func gainDrafts(in backup: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: backup.appending(path: "gain-drafts.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
    }

    /// 오토게인 한 곡(流れ行く命 −3.3→+0.65dB 실험과 같은 칸): GainHigh·GainLow·상태 256→257·rb_local_usn·updated_at
    static func applyGain(uuid: String, gainDB: Double, db: CipherDatabase, usn: inout Int,
                          stamp: (db: String, json: String)) throws -> Outcome {
        var content: (id: String, title: String)?
        try db.query("SELECT ID, Title FROM djmdContent WHERE UUID = ? AND rb_local_deleted = 0", [.text(uuid)]) { content = ($0.string(0) ?? "", $0.string(1) ?? "") }
        guard let content else { throw Blocked(title: uuid, reason: "rekordbox 컬렉션에서 곡을 찾지 못했습니다") }
        guard gainDB.isFinite, (-24...24).contains(gainDB) else { throw Blocked(title: content.title, reason: "게인이 범위를 벗어납니다") }
        var rows: [String] = []
        try db.query("SELECT ID FROM djmdMixerParam WHERE ContentID = ? AND rb_local_deleted = 0", [.text(content.id)]) { rows.append($0.string(0) ?? "") }
        guard rows.count == 1, let rowID = rows.first else {
            throw Blocked(title: content.title, reason: rows.isEmpty ? "rekordbox 오토게인 값이 없는 곡입니다(분석 전)" : "오토게인 행이 여럿입니다")
        }
        let value = Float(pow(10, gainDB / 20))
        let (high, low) = RekordboxAutoGain.halves(value)
        usn += 1
        try db.run("""
            UPDATE djmdMixerParam SET GainHigh = ?, GainLow = ?,
                rb_data_status = CASE rb_data_status WHEN 256 THEN 257 ELSE rb_data_status END,
                rb_local_usn = ?, updated_at = ? WHERE ID = ?
            """, [.int(high), .int(low), .int(usn), .text(stamp.db), .text(rowID)])
        var check: (Int, Int)?
        try db.query("SELECT GainHigh, GainLow FROM djmdMixerParam WHERE ID = ?", [.text(rowID)]) { check = ($0.int(0) ?? -1, $0.int(1) ?? -1) }
        guard check?.0 == high, check?.1 == low else { throw DJCError.writeVerificationFailed("오토게인 확인 실패 (\(content.title))") }
        return Outcome(trackUUID: uuid, title: content.title, status: .written, reason: nil, removed: 0, added: Int((gainDB * 100).rounded()))
    }
}
