import Foundation

/// 스냅샷의 재생 기록. 반복 재생은 서로 다른 기록 행으로 보존한다.
public struct RekordboxHistory: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let dateCreated: String?
    /// 위 폴더 이름(맨 위부터 바로 위 폴더까지, "root"는 빼고). rekordbox가 만든 기록은 ["2026", "8"]
    public let folderNames: [String]
    /// 같은 폴더 안 순서(djmdHistory.Seq, 없으면 0)
    public let seq: Int
    public let entries: [Entry]

    public init(id: String, name: String, dateCreated: String?, folderNames: [String] = [], seq: Int = 0, entries: [Entry]) {
        self.id = id
        self.name = name
        self.dateCreated = dateCreated
        self.folderNames = folderNames
        self.seq = seq
        self.entries = entries
    }

    public struct Entry: Sendable, Hashable, Identifiable {
        public let id: String
        public let contentID: String
        public let trackNumber: Int

        public init(id: String, contentID: String, trackNumber: Int) {
            self.id = id
            self.contentID = contentID
            self.trackNumber = trackNumber
        }
    }
}

extension RekordboxLibrary {
    /// 폴더 사슬을 따라 올라갈 최대 깊이. rekordbox는 연 › 월 두 단계라 넉넉하다(망가진 사슬에서 멈추려는 것).
    private static let historyFolderDepthLimit = 32

    static func loadHistories(_ db: CipherDatabase) throws -> [RekordboxHistory] {
        var entries: [String: [RekordboxHistory.Entry]] = [:]
        try db.query("""
            SELECT ID, HistoryID, ContentID, TrackNo FROM djmdSongHistory
            WHERE rb_local_deleted = 0 ORDER BY HistoryID, TrackNo, ID
            """) { row in
            guard let id = row.string(0), let history = row.string(1), let content = row.string(2) else { return }
            entries[history, default: []].append(.init(id: id, contentID: content, trackNumber: row.int(3) ?? 0))
        }
        // rekordbox는 기록을 연 폴더(ID "2026", 부모 root) › 월 폴더(ID "202608", 이름 "8") 아래에 둔다(Attribute 1).
        var folders: [String: HistoryFolder] = [:]
        try db.query("""
            SELECT ID, Name, ParentID FROM djmdHistory
            WHERE rb_local_deleted = 0 AND Attribute = 1
            """) { row in
            guard let id = row.string(0) else { return }
            folders[id] = HistoryFolder(name: row.string(1) ?? "", parentID: row.string(2))
        }
        var histories: [RekordboxHistory] = []
        try db.query("""
            SELECT ID, Name, NULLIF(DateCreated, ''), ParentID, Seq FROM djmdHistory
            WHERE rb_local_deleted = 0 AND COALESCE(Attribute, 0) != 1
            ORDER BY NULLIF(DateCreated, '') DESC, Seq, ID
            """) { row in
            guard let id = row.string(0) else { return }
            histories.append(.init(id: id, name: row.string(1) ?? "", dateCreated: row.string(2),
                                   folderNames: historyFolderNames(parentID: row.string(3), folders: folders), seq: row.int(4) ?? 0,
                                   entries: entries[id] ?? []))
        }
        return histories
    }

    /// 부모 사슬의 폴더 이름(맨 위부터). root·빈 값·없는(삭제된) 폴더·순환·지나친 깊이에서 멈추고 그때까지 모은 것만 준다.
    private static func historyFolderNames(parentID: String?, folders: [String: HistoryFolder]) -> [String] {
        var names: [String] = []
        var visited: Set<String> = []
        var next = parentID
        while let id = next, !id.isEmpty, id != "root", names.count < historyFolderDepthLimit,
              let folder = folders[id], visited.insert(id).inserted {
            names.append(folder.name)
            next = folder.parentID
        }
        return names.reversed()
    }

    private struct HistoryFolder {
        let name: String
        let parentID: String?
    }
}
