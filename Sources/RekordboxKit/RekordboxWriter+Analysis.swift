import DJCDomain
import Foundation

/// 분석 전 곡(분석 파일 없음)에 DJCrate가 분석 파일을 만들어 붙인다(#6).
///
/// 곡 넣기(분석 포함) 레시피를 그대로 쓴다(`RekordboxTrackWriter.prepare`·`insertAnalysisRows`):
/// - 분석 파일 `.DAT`·`.EXT`·`.2EX`를 곡 UUID 폴더(`/PIONEER/USBANLZ/<앞 3자>/<나머지>`)에 만든다.
/// - `djmdContent`: 분석 칸(BPM·Length 버림·BitRate·BitDepth·SampleRate·AnalysisDataPath·Analysed 105·ContentLink·
///   AnalysisUpdated·TrackInfoUpdated)과 상태 256→257·변경 번호·`updated_at`.
/// - `contentFile` 행(파일마다)과 `djmdMixerParam` 행(오토게인)을 새로 넣는다. 변경 번호는 곡 행 → 파일 행 → 오토게인 행.
/// 같은 쓰기의 큐·게인 초안은 분석을 붙인 뒤에 쓴다(rekordbox에서 분석한 곡을 고치는 순서).
///
/// 대상은 분석 경로가 빈 곡이다(자동 분석을 끄고 넣은 곡 Analysed 0, XML로 들어온 곡 Analysed 41).
/// `.DAT`만 있고 `.EXT`가 없는 반쪽 곡(rekordbox 분석이 실패한 곡)은 기존 파일·행을 어떻게 바꾸는지 몰라 그리드 쓰기에서 막는다.
/// 기존 곡을 rekordbox가 분석했을 때의 AnalysisUpdated·TrackInfoUpdated·변경 번호 순서는 아직 실험으로 확인하지 않아
/// `attachesAnalysis`로 막아 둔다.
extension RekordboxWriter {
    /// 분석 붙이기를 연다. rekordbox 실험(기존 분석 전 곡을 rekordbox가 분석한 전후 비교)으로 칸을 확인하기 전에는 닫아 둔다.
    public static let attachesAnalysis = false

    /// 분석을 붙일 곡의 음원 길이·음량(앱이 AVFoundation·음량 분석으로 잰다)
    public struct AnalysisInput: Sendable, Equatable {
        /// AVFoundation 길이(초). 곡 넣기처럼 버림해 `Length`에 적는다.
        public var duration: Double
        /// 통합 음량(LUFS). nil이면 오토게인 0dB.
        public var loudness: Double?
        /// 샘플 피크(선형, 0~1)
        public var peak: Double

        public init(duration: Double, loudness: Double?, peak: Double) {
            self.duration = duration
            self.loudness = loudness
            self.peak = peak
        }
    }

    /// 분석 파일이 없는 곡인지(분석 경로가 비었다). 분석을 붙이는 대상이다.
    public static func needsAnalysis(_ analysisDataPath: String?) -> Bool { (analysisDataPath ?? "").isEmpty }

    /// 분석을 붙일 곡 하나(파일 바이트까지 미리 만든다)
    struct AttachPlan {
        var trackUUID: String
        var contentID: String
        var title: String
        var ready: RekordboxTrackWriter.PreparedAnalysis
        /// 넣은 행(커밋 뒤 다시 읽어 비교)
        var inserted: [RekordboxTrackWriter.InsertedRow] = []
    }

    /// 계획(읽기만 한다). 막히면 `Blocked`.
    static func attachPlan(draft: GridDraft, content: (id: String, title: String, path: String, fileName: String), input: AnalysisInput?,
                           share: URL, reader: CipherDatabase, enabled: Bool) throws -> AttachPlan {
        func block(_ reason: String) -> Blocked { Blocked(title: content.title, reason: reason) }
        guard enabled else { throw block("rekordbox 분석 전 곡입니다. rekordbox에서 트랙 분석을 먼저 한 뒤 쓰세요") }
        guard draft.base.isEmpty else { throw block("초안을 만든 뒤 rekordbox에서 그리드가 바뀌었습니다. DJCrate에서 다시 불러와 확인하세요") }
        guard FileManager.default.fileExists(atPath: content.path) else { throw block("음원 파일이 없습니다. rekordbox에서 파일 위치를 확인하세요") }
        guard let input else { throw block("음원 길이를 재지 못해 분석을 붙이지 않습니다. 음원 파일을 확인한 뒤 다시 쓰세요") }
        // 분석 파일·오토게인 기록이 이미 있으면 rekordbox가 무엇을 기대하는지 모른다(곡 넣기와 달리 새 행을 넣는다).
        guard try scalar(reader, "SELECT count(*) FROM djmdMixerParam WHERE ContentID = ? AND rb_local_deleted = 0", [.text(content.id)]) == 0 else {
            throw block("오토게인 행이 이미 있는 곡이라 분석을 붙이지 않습니다. rekordbox에서 트랙 분석을 하세요")
        }
        guard try scalar(reader, "SELECT count(*) FROM contentFile WHERE ContentID = ? AND Path LIKE '/PIONEER/USBANLZ/%'", [.text(content.id)]) == 0 else {
            throw block("분석 파일 기록이 이미 있는 곡이라 분석을 붙이지 않습니다. rekordbox에서 트랙 분석을 하세요")
        }
        let folder = share.appending(path: String(RekordboxTrackWriter.analysisFolder(uuid: draft.trackUUID).dropFirst()))
        guard ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty else {
            throw block("분석 폴더에 파일이 이미 있어 분석을 붙이지 않습니다. rekordbox에서 트랙 분석을 하세요")
        }
        let analysis = RekordboxTrackWriter.Analysis(segments: draft.segments, loudness: input.loudness, peak: input.peak)
        let ready: RekordboxTrackWriter.PreparedAnalysis
        do {
            ready = try RekordboxTrackWriter.prepare(path: content.path, fileName: content.fileName, duration: input.duration,
                                                     uuid: draft.trackUUID, analysis: analysis, share: share)
        } catch {
            throw block("분석 파일을 만들지 못했습니다: \(DJCError.reason(of: error))")
        }
        if let reason = ready.blocked { throw block(reason) }
        return AttachPlan(trackUUID: draft.trackUUID, contentID: content.id, title: content.title, ready: ready)
    }

    /// 트랜잭션 안에서 곡 행 분석 칸을 채우고 파일 행·오토게인 행을 넣은 뒤 다시 읽어 비교한다.
    static func applyAttach(_ plan: inout AttachPlan, db: CipherDatabase, usn: inout Int, stamp: (db: String, json: String)) throws {
        var status: Int?
        try db.query("""
            SELECT rb_data_status FROM djmdContent WHERE ID = ? AND rb_local_deleted = 0 AND ifnull(AnalysisDataPath, '') = ''
            """, [.text(plan.contentID)]) { status = $0.int(0) ?? 0 }
        guard let status else { throw Blocked(title: plan.title, reason: "초안을 만든 뒤 rekordbox에서 곡이 바뀌었습니다. DJCrate에서 다시 불러와 확인하세요") }
        usn += 1
        var columns = plan.ready.columns
        columns["rb_data_status"] = .int(status == 256 ? 257 : status)
        columns["rb_local_usn"] = .int(usn)
        columns["updated_at"] = .text(stamp.db)
        let keys = columns.keys.sorted()
        let changed = try db.run("UPDATE djmdContent SET \(keys.map { "\"\($0)\" = ?" }.joined(separator: ", ")) WHERE ID = ?",
                                 keys.map { columns[$0]! } + [.text(plan.contentID)])
        guard changed == 1 else { throw DJCError.writeVerificationFailed("곡 행에 분석 칸을 쓰지 못했습니다 (\(plan.title))") }
        try RekordboxTrackWriter.verify(db, table: "djmdContent", id: plan.contentID, columns)
        plan.inserted = try RekordboxTrackWriter.insertAnalysisRows(db, plan.ready, contentID: plan.contentID, usn: &usn, stamp: stamp)
        for row in plan.inserted { try RekordboxTrackWriter.verify(db, table: row.table, id: row.id, row.values) }
    }

    /// 커밋 뒤 다시 읽기. 같은 쓰기의 큐·게인 초안이 곡 행 변경 번호·오토게인 칸을 다시 바꾸므로 그 칸은 빼고 본다.
    static func verifyAttach(_ plan: AttachPlan, db: CipherDatabase) throws {
        try RekordboxTrackWriter.verify(db, table: "djmdContent", id: plan.contentID, plan.ready.columns)
        for row in plan.inserted {
            let values = row.table == "djmdMixerParam"
                ? row.values.filter { !["GainHigh", "GainLow", "rb_data_status", "rb_local_usn", "updated_at"].contains($0.key) }
                : row.values
            try RekordboxTrackWriter.verify(db, table: row.table, id: row.id, values)
        }
    }

    /// 커밋 뒤 분석 파일을 만든다(없던 파일만). 만든 파일은 `created`에 더한다(실패하면 되돌릴 때 지운다).
    static func writeAnalysisFiles(_ plan: AttachPlan, created: inout [URL]) throws {
        let fm = FileManager.default
        for (url, data) in plan.ready.files {
            guard !fm.fileExists(atPath: url.path) else { throw DJCError.writeVerificationFailed("분석 파일이 이미 있습니다: \(url.lastPathComponent)") }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            created.append(url)
            guard try Data(contentsOf: url) == data else {
                throw DJCError.writeVerificationFailed("분석 파일 확인 실패: \(url.lastPathComponent) (\(plan.title))")
            }
        }
    }

    /// 만든 분석 파일을 지우고, 비게 된 `USBANLZ/<3자>/<나머지>` 폴더도 지운다(rekordbox가 곡을 지울 때처럼).
    static func removeAnalysisFiles(_ created: [URL]) throws {
        let fm = FileManager.default
        try each(created.filter { fm.fileExists(atPath: $0.path) }) { try fm.removeItem(at: $0) }
        for directory in Set(created.map { $0.deletingLastPathComponent() }) where directory.path.contains("/USBANLZ/") {
            var current = directory
            while current.lastPathComponent != "USBANLZ", (try? fm.contentsOfDirectory(atPath: current.path))?.isEmpty == true {
                try? fm.removeItem(at: current)
                current = current.deletingLastPathComponent()
            }
        }
    }
}
