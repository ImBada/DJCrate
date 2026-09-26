import AnicueDomain
import Foundation

/// 쓰기 도움 함수(변경 카운터·새 큐 ID·Kind·ms·검증 키)
extension RekordboxWriter {
    // MARK: - 도움

    static func localUpdateCount(_ db: CipherDatabase) throws -> Int {
        var values: [Int] = []
        try db.query("SELECT int_1 FROM agentRegistry WHERE registry_id = 'localUpdateCount'") { values.append($0.int(0) ?? -1) }
        guard values.count == 1, let value = values.first, value > 0 else {
            throw AnicueError.writeRefused("rekordbox 변경 카운터를 찾지 못했습니다")
        }
        // 카운터는 지금까지 나눠 준 번호보다 작으면 안 된다.
        let issued = max(try scalar(db, "SELECT ifnull(max(rb_local_usn), 0) FROM djmdContent", []) ?? 0,
                         try scalar(db, "SELECT ifnull(max(rb_local_usn), 0) FROM contentCue", []) ?? 0)
        guard issued <= value else { throw AnicueError.writeRefused("rekordbox 변경 카운터가 예상과 다릅니다") }
        return value
    }

    static func scalar(_ db: CipherDatabase, _ sql: String, _ values: [CipherDatabase.Value]) throws -> Int? {
        var result: Int?
        try db.query(sql, values) { result = $0.int(0) }
        return result
    }

    /// rekordbox처럼 32비트 난수 ID(겹치지 않게).
    static func newCueID(_ db: CipherDatabase) throws -> String {
        for _ in 0..<100 {
            let id = String(UInt32.random(in: 1...UInt32.max))
            if try scalar(db, "SELECT count(*) FROM djmdCue WHERE ID = ?", [.text(id)]) == 0 { return id }
        }
        throw AnicueError.writeVerificationFailed("새 큐 ID를 만들지 못했습니다")
    }

    /// 편집 큐 종류 → rekordbox Kind(메모리 0, 핫큐 A…H = 1,2,3,5,6,7,8,9)
    static func kind(for kind: EditableCue.Kind) -> Int {
        switch kind {
        case .memory: 0
        case let .hot(slot): [1, 2, 3, 5, 6, 7, 8, 9][slot]
        }
    }

    static func msec(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }

    /// 큐 목록 비교용 열쇠(순서 무관)
    public static func key(_ cues: [EditableCue], withSource: Bool) -> [String] {
        cues.map { cue in
            let kind = switch cue.kind { case .memory: "m"; case let .hot(slot): "h\(slot)" }
            // 루프는 끝·활성·박 수까지 (루프가 아니면 예전과 같은 키)
            let loop = cue.loop.map { "|L\(msec($0.end))|\($0.active ? "a" : "-")|\(EditableCue.Loop.beatLoopSize(beats: $0.beats))" } ?? ""
            return (withSource ? (cue.sourceID ?? "-") + "|" : "") + "\(kind)|\(msec(cue.time))|\(cue.name)" + loop
        }.sorted()
    }
}
