import Foundation

/// 스냅샷의 재생 기록. 반복 재생은 서로 다른 기록 행으로 보존한다.
public struct RekordboxHistory: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let dateCreated: String?
    public let entries: [Entry]

    public struct Entry: Sendable, Hashable, Identifiable {
        public let id: String
        public let contentID: String
        public let trackNumber: Int
    }
}

extension RekordboxLibrary {
    static func loadHistories(_ db: CipherDatabase) throws -> [RekordboxHistory] {
        var entries: [String: [RekordboxHistory.Entry]] = [:]
        try db.query("""
            SELECT ID, HistoryID, ContentID, TrackNo FROM djmdSongHistory
            WHERE rb_local_deleted = 0 ORDER BY HistoryID, TrackNo, ID
            """) { row in
            guard let id = row.string(0), let history = row.string(1), let content = row.string(2) else { return }
            entries[history, default: []].append(.init(id: id, contentID: content, trackNumber: row.int(3) ?? 0))
        }
        var histories: [RekordboxHistory] = []
        try db.query("""
            SELECT ID, Name, NULLIF(DateCreated, '') FROM djmdHistory
            WHERE rb_local_deleted = 0 AND COALESCE(Attribute, 0) != 1
            ORDER BY NULLIF(DateCreated, '') DESC, Seq, ID
            """) { row in
            guard let id = row.string(0) else { return }
            histories.append(.init(id: id, name: row.string(1) ?? "", dateCreated: row.string(2), entries: entries[id] ?? []))
        }
        return histories
    }
}
