import DJCDomain
import Foundation

/// 태그(곡 정보) 쓰기: `djmdContent` 제자리 UPDATE + 새 이름이면 `djmdArtist`·`djmdAlbum`·`djmdGenre` 행(#1).
/// rekordbox 라이브러리만 바꾸고 음원 파일 태그는 건드리지 않는다(rekordbox는 파일 태그도 다시 쓰지만 DJCrate는 음원을 읽기만 한다).
///
/// rekordbox 7.2.18 정보 패널은 칸마다 따로 저장한다(2026-09-27 "DJC 실험곡 1~5"). DJCrate는 여러 칸을 한 번에 쓰지만
/// 결과는 그 칸들을 하나씩 저장한 것과 같게 한다: 칸마다 `TrackInfoUpdated` +1, 새 이름 행, 버려진 이름 행 삭제, 곡 행은 마지막 번호.
extension RekordboxWriter {
    /// rekordbox 실험으로 쓰기 규칙을 확인한 칸. 이 밖의 칸을 고친 초안은 곡째 막는다(docs/rekordbox-internals.md "태그 (곡 정보)").
    /// 공유 앨범 값 변경·동명 앨범 선택·미확인 상태는 `checkTags`에서 곡째 막는다.
    public static let writableTagKeys: Set<TagFields.Key> = [.title, .artist, .album, .albumArtist, .genre, .composer, .year, .trackNumber, .comment]
    /// 쓰면 그 곡이 든 재생 목록의 `masterPlaylists6.xml` Timestamp를 고치는 칸. rekordbox 실험으로 확인한 칸만이다
    /// (#173 S1 X1 아티스트, S2 U11·U12 제목, S3 V07 장르). 그 밖의 칸은 [미확인]이라 그 칸만 쓴 초안은 XML을 건드리지 않는다.
    static let playlistTimestampTagKeys: Set<TagFields.Key> = [.title, .artist, .genre]
    /// 태그 쓰기를 확인한 곡·앨범 상태(#171·#173 2026-10-04). 0 그대로, 256 → 257, 257 그대로. 그 밖의 상태는 막는다.
    static let verifiedTagStates: Set<Int> = [0, 256, 257]

    /// 쓴 뒤 곡이 가져야 할 태그
    struct TagExpectation {
        var contentID: String
        var fields: TagFields
        var trackInfoUpdated: String
        var contentUSN: Int
        /// 쓴 뒤 곡의 `rb_data_status`(256 → 257, 0·257은 그대로)
        var dataStatus: Int?
        /// 곡 행에 쓴 `AlbumID`(앨범 칸을 쓰거나 같은 이름의 새 앨범으로 옮겼을 때). 이름·앨범 아티스트가 같아도 옮겼는지 본다.
        var albumID: String?
        /// 변경 번호를 준 앨범 행(ID → 번호·상태). 같은 반영 안의 뒤 편집은 마지막 기대값을 맡는다.
        var touchedAlbums: [String: (usn: Int, status: Int)] = [:]
        /// 아무 곡도 안 쓰게 되어 지운 이름 행(표, ID). 상태 0 행이다.
        var deletedNames: [(table: String, id: String)] = []
        /// 아무 곡도 안 쓰게 되어 258로 표시한 동기화 이름·앨범 행(#173)
        var markedNames: [MarkedName] = []

        /// 버려진 앨범 행(지웠거나 258로 표시). 같은 반영의 앞 편집이 그 행에 건 기대값은 뒤 편집이 맡는다.
        var releasedAlbums: Set<String> {
            Set(deletedNames.filter { $0.table == "djmdAlbum" }.map(\.id) + markedNames.filter { $0.table == "djmdAlbum" }.map(\.id))
        }
    }

    /// 258로 표시한 행이 가져야 할 칸. 클라우드 `usn`·`rb_local_synced`는 그대로다(#173 S1 T02, 2026-10-04).
    struct MarkedName {
        var table: String
        var id: String
        var usn: Int
        /// `quote(usn)`
        var cloudUSN: String
        var synced: Int?
    }

    /// 쓰기 전 곡 행이 가리키는 이름·앨범과 곡의 앨범 행의 앨범 아티스트
    struct TagOldNames {
        var artist: String?
        var composer: String?
        var genre: String?
        var album: String?
        var albumArtist: String?
        var orgArtist: String?
        var remixer: String?
        /// 곡의 앨범 행이 살아 있는지(지운 앨범 행은 저장하지 않는다)
        var albumLive = false
        var albumName: String?

        static func read(_ db: CipherDatabase, contentID: String) throws -> TagOldNames? {
            var old: TagOldNames?
            try db.query("""
                SELECT c.ArtistID, c.ComposerID, c.GenreID, c.AlbumID, a.AlbumArtistID, c.OrgArtistID, c.RemixerID, a.rb_local_deleted, a.Name
                FROM djmdContent c LEFT JOIN djmdAlbum a ON a.ID = c.AlbumID WHERE c.ID = ?
                """, [.text(contentID)]) { r in
                old = TagOldNames(artist: r.string(0), composer: r.string(1), genre: r.string(2), album: r.string(3), albumArtist: r.string(4),
                                  orgArtist: r.string(5), remixer: r.string(6), albumLive: r.int(7) == 0, albumName: r.string(8))
            }
            return old
        }
    }

    /// 트랜잭션 안에서 확인을 통과한 곡
    struct CheckedTag {
        var id: String
        var title: String
        var trackInfoUpdated: String?
        var state: Int?
        var old: TagOldNames
        /// 아티스트를 고치며 같은 이름의 새 앨범으로 옮기는지(`checkSameNameAlbum`)
        var migratesAlbum = false
    }

    /// 백업에 둔 태그 초안(되돌리면 DJCrate에 다시 살린다)
    public static func tagDrafts(in backup: URL) -> [TagDraft] {
        let folder = backup.appending(path: "tag-drafts")
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(TagDraft.self, from: $0) }
    }

    /// 곡의 지금 태그. 라이브러리 읽기(`RekordboxLibrary.load` → `TagFields(track:)`)와 같은 규칙이라 초안의 base와 바로 비교한다.
    package static func currentTags(db: CipherDatabase, contentID: String) throws -> TagFields? {
        var fields: TagFields?
        try db.query("""
            SELECT c.Title, a.Name, al.Name, aa.Name, g.Name, cp.Name, c.ReleaseYear, c.TrackNo, c.Commnt
            FROM djmdContent c
            LEFT JOIN djmdArtist a ON a.ID = c.ArtistID
            LEFT JOIN djmdAlbum al ON al.ID = c.AlbumID
            LEFT JOIN djmdArtist aa ON aa.ID = al.AlbumArtistID
            LEFT JOIN djmdGenre g ON g.ID = c.GenreID
            LEFT JOIN djmdArtist cp ON cp.ID = c.ComposerID
            WHERE c.ID = ?
            """, [.text(contentID)]) { r in
            var f = TagFields()
            f.title = r.string(0) ?? ""
            f.artist = r.string(1) ?? ""
            f.album = r.string(2) ?? ""
            f.albumArtist = r.string(3) ?? ""
            f.genre = r.string(4) ?? ""
            f.composer = r.string(5) ?? ""
            f.year = (r.int(6)).flatMap { $0 > 0 ? String($0) : nil } ?? ""
            f.trackNumber = (r.int(7)).flatMap { $0 > 0 ? String($0) : nil } ?? ""
            f.comment = r.string(8) ?? ""
            fields = f
        }
        return fields
    }

    /// 백업 전 확인: DB를 바꾸지 않고 분명히 알 수 있는 막힘만 거른다(읽기 연결만 쓴다, 초안마다 시작 DB로). 버려질 옛 행을 어떻게 정리할지와
    /// 그 상태(257 등)로 막을지는 트랜잭션 안에서 실제로 쓴 뒤 센 참조로 정한다(`releaseNames`). 시험 실행(미리 보기)도 트랜잭션을 돌리므로
    /// 사용자에게 보이는 결과는 같다.
    static func checkTagDrafts(_ tags: [TagDraft], db: CipherDatabase, writable: Set<TagFields.Key>) throws -> (passed: [TagDraft], blocked: [Outcome]) {
        var passed: [TagDraft] = [], blocked: [Outcome] = []
        for draft in tags {
            do {
                _ = try checkTags(draft, db: db, writable: writable)
                passed.append(draft)
            } catch let error as Blocked {
                blocked.append(Outcome(trackUUID: draft.trackUUID, title: error.title, status: .blocked, reason: error.reason, removed: 0, added: 0))
            }
        }
        return (passed, blocked)
    }

    /// 쓰기 전에 막을 조건: 곡 없음·지운 곡·닫힌 칸·잘못된 값·곡·앨범 상태·앨범 조건·base 불일치·동명 앨범. 막히면 `Blocked`, 통과하면 곡 행 정보.
    /// 백업을 뜨기 전(읽기 연결, 시작 DB)과 트랜잭션 안(앞 초안을 쓴 DB)에서 같은 함수로 두 번 본다. 버려질 옛 행은 여기서 보지 않는다.
    static func checkTags(_ draft: TagDraft, db: CipherDatabase, writable: Set<TagFields.Key>) throws -> CheckedTag {
        var contents: [(id: String, title: String, deleted: Bool, trackInfoUpdated: String?, state: Int?)] = []
        try db.query("SELECT ID, Title, rb_local_deleted, TrackInfoUpdated, rb_data_status FROM djmdContent WHERE UUID = ?",
                     [.text(draft.trackUUID)]) { r in
            contents.append((r.string(0) ?? "", r.string(1) ?? "", (r.int(2) ?? 0) != 0, r.string(3), r.int(4)))
        }
        guard contents.count == 1, let content = contents.first else {
            throw Blocked(title: draft.trackUUID, reason: contents.isEmpty ? String(ui: "rekordbox 컬렉션에서 곡을 찾지 못했으니 컬렉션에서 곡을 확인한 뒤 DJCrate에서 다시 동기화하세요") : String(ui: "같은 UUID의 곡이 여럿인 구조는 지원하지 않으니 rekordbox에서 곡을 확인하고 직접 편집하세요"))
        }
        func block(_ reason: String) -> Blocked { Blocked(title: content.title, reason: reason) }
        guard !content.deleted else { throw block(String(ui: "rekordbox 컬렉션에서 지운 곡이니 컬렉션에서 곡을 확인한 뒤 DJCrate에서 다시 동기화하세요")) }
        let closed = draft.changedKeys.filter { !writable.contains($0) }
        guard closed.isEmpty else {
            throw block(String(ui: "rekordbox에 쓰는 규칙을 아직 확인하지 않은 칸(\(closed.map(\.label).joined(separator: "·")))이 있습니다. 그 칸을 되돌리면 나머지는 쓸 수 있습니다"))
        }
        if let issue = draft.issues.first { throw block(issue) }
        for key in [TagFields.Key.year, .trackNumber] where draft.changedKeys.contains(key) {
            guard (Int(draft.fields[key]) ?? 0) >= 0 else { throw block(String(ui: "\(key.label)는 0 이상이어야 합니다")) }
        }
        // 앨범을 비우면 rekordbox가 앨범 아티스트도 함께 비운다(2026-09-27 실험곡 3). 비운 앨범에 새 앨범 아티스트는 쓸 수 없다.
        if draft.changedKeys.contains(.albumArtist), draft.fields.album.isEmpty, !draft.fields.albumArtist.isEmpty {
            throw block(String(ui: "앨범이 없는 곡에는 앨범 아티스트를 쓸 수 없습니다"))
        }
        try checkTagState(draft, state: content.state, block: block)
        try checkTagAlbum(draft, contentID: content.id, db: db, block: block)
        guard try currentTags(db: db, contentID: content.id) == draft.base else {
            throw block(String(ui: "초안을 만든 뒤 rekordbox에서 곡 정보가 바뀌었습니다. DJCrate에서 다시 불러와 확인하세요"))
        }
        guard let old = try TagOldNames.read(db, contentID: content.id) else {
            throw block(String(ui: "곡 행을 다시 읽지 못했으니 rekordbox 컬렉션에서 곡을 확인한 뒤 DJCrate에서 다시 동기화하세요"))
        }
        let migrates = try checkSameNameAlbum(draft, old: old, db: db, block: block)
        return CheckedTag(id: content.id, title: content.title, trackInfoUpdated: content.trackInfoUpdated, state: content.state, old: old,
                          migratesAlbum: migrates)
    }

    /// 아티스트를 바꿀 때 곡의 앨범 이름을 살아 있는 앨범 둘 이상이 쓰면, rekordbox는 같은 이름의 새 앨범을 만들어 곡을 옮긴다
    /// (#173 S3 V02: 상태 0·앨범 아티스트 있음·이 곡만 씀·나중에 만든 행, S2 U13: 동기화·앨범 아티스트 NULL·공유·가장 먼저 만든 행. 곡 상태와
    /// 무관하다). 앨범·앨범 아티스트 칸도 고치면 그 칸을 먼저 쓰므로 옮기지 않는다. 아티스트 비우기는 확인하지 않아 막는다.
    /// 곡의 앨범이 같은 이름 앨범 중 가장 먼저 만든 행이면서 앨범 아티스트가 NULL이 아니면(값이나 '') "먼저 만든 같은 이름 행을 골라 앨범
    /// 아티스트를 비교한다"는 다른 가설과 결과가 갈려 막는다(만든 시각이 같으면 먼저 만든 행으로 본다).
    /// - Returns: 새 앨범으로 옮기는지
    private static func checkSameNameAlbum(_ draft: TagDraft, old: TagOldNames, db: CipherDatabase, block: (String) -> Blocked) throws -> Bool {
        let keys = draft.changedKeys
        guard keys.contains(.artist), !keys.contains(.album), !keys.contains(.albumArtist), old.albumLive,
              let album = old.album, !album.isEmpty, let name = old.albumName else { return false }
        guard try scalar(db, "SELECT count(*) FROM djmdAlbum WHERE Name = ? AND rb_local_deleted = 0", [.text(name)]) ?? 0 >= 2 else { return false }
        let earlier = try scalar(db, """
            SELECT count(*) FROM djmdAlbum o WHERE o.Name = ?1 AND o.rb_local_deleted = 0 AND o.ID != ?2
                AND o.created_at < (SELECT created_at FROM djmdAlbum WHERE ID = ?2)
            """, [.text(name), .text(album)]) ?? 0
        // 아티스트 비우기는 보지 못했다(V02·U13은 바꾸기). 같은 규칙으로 보이지만[추정] 확인 전에는 막는다.
        if draft.fields.artist.isEmpty || (earlier == 0 && old.albumArtist != nil) {
            throw block(String(ui: "같은 이름 앨범이 여럿인 곡이라 rekordbox 저장 규칙을 아직 확인하지 못했으므로 rekordbox에서 직접 고치세요"))
        }
        return true
    }

    /// 이 초안을 쓰면 고칠 재생 목록 XML이 있는지: 확인한 칸(제목·아티스트·장르)을 쓰고 그 곡이 든 살아 있는 목록이 있을 때만(백업 전 확인)
    static func tagTouchesPlaylistXML(_ draft: TagDraft, db: CipherDatabase) throws -> Bool {
        guard !Set(draft.changedKeys).isDisjoint(with: playlistTimestampTagKeys) else { return false }
        var id: String?
        try db.query("SELECT ID FROM djmdContent WHERE UUID = ? AND rb_local_deleted = 0", [.text(draft.trackUUID)]) { id = $0.string(0) }
        guard let id else { return false }
        return try !tagPlaylists(db, contentID: id).isEmpty
    }

    /// 곡이 든 살아 있는 재생 목록(곡 정보를 쓰면 XML Timestamp를 고친다, #173). 지운 목록·지운 곡 항목은 뺀다.
    static func tagPlaylists(_ db: CipherDatabase, contentID: String) throws -> [String] {
        var ids: [String] = []
        try db.query("""
            SELECT DISTINCT sp.PlaylistID FROM djmdSongPlaylist sp JOIN djmdPlaylist p ON p.ID = sp.PlaylistID
            WHERE sp.ContentID = ? AND sp.rb_local_deleted = 0 AND p.rb_local_deleted = 0 ORDER BY sp.PlaylistID
            """, [.text(contentID)]) { if let id = $0.string(0) { ids.append(id) } }
        return ids
    }

    // MARK: - 버려지는 이름·앨범 행

    /// 참조를 세는 곡·앨범 행
    enum ReferenceRows {
        case live, all

        /// 버려졌는지 볼 때의 범위. 동기화(256·257) **앨범**만 살아 있는 곡을 센다(#173 S2 U04, 2026-10-04: 지운 곡 여럿이 가리키는
        /// 동기화 앨범도 비우자 258이 됐다. U01·U14도 동기화 앨범). 동기화 아티스트·장르는 지운 곡·258 앨범의 참조가 있을 때를 보지 못해[미확인]
        /// 지운 곡·앨범까지 센다(그런 참조가 남으면 건드리지 않는다). 상태 0 행도 예전처럼 지운 것까지 센다(지워도 외래 키가 끊기지 않게).
        static func scope(table: String, state: Int?) -> ReferenceRows {
            table == "djmdAlbum" && (state == 256 || state == 257) ? .live : .all
        }
    }

    /// 행 하나를 가리키는 곡·앨범 수(살아 있음·지움별). 칸마다 인덱스가 있어 칸별 질의를 UNION ALL로 잇고 개수만 센다(OR는 표 전체를 훑는다).
    struct ReferenceCount {
        var live = 0
        var deleted = 0

        init(_ db: CipherDatabase, table: String, id: String) throws {
            let columns = switch table {
            case "djmdArtist": ["ArtistID", "ComposerID", "OrgArtistID", "RemixerID"]
            case "djmdAlbum": ["AlbumID"]
            default: ["GenreID"]
            }
            var parts = columns.map { "SELECT rb_local_deleted != 0 AS gone FROM djmdContent WHERE \($0) = ?1" }
            if table == "djmdArtist" { parts.append("SELECT rb_local_deleted != 0 AS gone FROM djmdAlbum WHERE AlbumArtistID = ?1") }
            var live = 0, deleted = 0
            try db.query("SELECT gone, count(*) FROM (\(parts.joined(separator: " UNION ALL "))) GROUP BY gone", [.text(id)]) {
                if $0.int(0) == 1 { deleted += $0.int(1) ?? 0 } else { live += $0.int(1) ?? 0 }
            }
            self.live = live
            self.deleted = deleted
        }

        func count(_ rows: ReferenceRows) -> Int { rows == .all ? live + deleted : live }
    }

    /// 이 초안을 쓰면 놓는 옛 이름·앨범 행(앨범 먼저: 버려진 앨범의 앨범 아티스트 참조가 먼저 빠진다).
    static func releasedNames(_ keys: Set<TagFields.Key>, old: TagOldNames, migratesAlbum: Bool) -> [(table: String, id: String)] {
        var released: [(table: String, id: String?)] = []
        if keys.contains(.album) || keys.contains(.albumArtist) || migratesAlbum { released.append(("djmdAlbum", old.album)) }
        if keys.contains(.artist) { released.append(("djmdArtist", old.artist)) }
        if keys.contains(.albumArtist), !keys.contains(.album) { released.append(("djmdArtist", old.albumArtist)) }
        if keys.contains(.composer) { released.append(("djmdArtist", old.composer)) }
        if keys.contains(.genre) { released.append(("djmdGenre", old.genre)) }
        var result: [(table: String, id: String)] = []
        for (table, id) in released {
            guard let id, !id.isEmpty, id != "0", !result.contains(where: { $0 == (table, id) }) else { continue }
            result.append((table, id))
        }
        return result
    }

    /// 버려질 행을 정리할 수 없는 상태면 막을 이유. 0(지움)·256(258 표시)만 확인했다.
    static func releaseProblem(table: String, state: Int?) -> String? {
        switch state {
        case 0, 256:
            return nil
        case 257:
            // #173 S1~S3에서 버려진 옛 행은 모두 256이었다.
            return table == "djmdAlbum"
                ? String(ui: "rekordbox에서 이미 고친 동기화 앨범이라 비우는 규칙을 확인하지 못했으므로 rekordbox에서 직접 고치세요")
                : String(ui: "rekordbox에서 이미 고친 동기화 아티스트·장르라 비우는 규칙을 확인하지 못했으므로 rekordbox에서 직접 고치세요")
        default:
            return String(ui: "이 곡이 더 쓰지 않게 될 앨범·이름의 동기화 상태에서는 정리 규칙을 확인하지 못했으므로 rekordbox에서 직접 고치세요")
        }
    }

    /// 살아 있는 이름·앨범 행의 상태(없거나 이미 지운 행이면 nil)
    static func liveNameState(_ db: CipherDatabase, table: String, id: String) throws -> Int?? {
        var state: Int??
        try db.query("SELECT rb_data_status FROM \(table) WHERE ID = ? AND rb_local_deleted = 0", [.text(id)]) { state = .some($0.int(0)) }
        return state
    }

    /// 아무도 안 쓰게 된 옛 행을 정리한다. 트랜잭션 안에서 곡 행·앨범 행·새 이름 행을 실제로 쓴 뒤 부르고, 후보마다 실제 참조 수를 센다
    /// (미리 계산하지 않는다, #173 3차 리뷰): 참조가 남으면 그대로, 상태 0이면 지우고, 256이면 258로 표시한다. 257·그 밖의 상태가 버려지면
    /// `Blocked`를 던져 부른 쪽이 그 초안만 SAVEPOINT로 되돌린다(번호도). 258을 쓰면 rekordbox처럼 곡 행이 마지막 번호를 다시 받는다(옛 행 → 곡 행).
    static func releaseNames(_ content: CheckedTag, keys: Set<TagFields.Key>, db: CipherDatabase, usn: inout Int, stamp: (db: String, json: String))
        throws -> (deleted: [(table: String, id: String)], marked: [MarkedName]) {
        var deleted: [(table: String, id: String)] = []
        var marked: [MarkedName] = []
        for (table, id) in releasedNames(keys, old: content.old, migratesAlbum: content.migratesAlbum) {
            guard let state = try liveNameState(db, table: table, id: id),
                  try ReferenceCount(db, table: table, id: id).count(ReferenceRows.scope(table: table, state: state)) == 0 else { continue }
            if let problem = releaseProblem(table: table, state: state) { throw Blocked(title: content.title, reason: problem) }
            if state == 0 {
                _ = try db.run("DELETE FROM \(table) WHERE ID = ?", [.text(id)])
                deleted.append((table, id))
            } else {
                var kept: (usn: String, synced: Int?)?
                try db.query("SELECT quote(usn), rb_local_synced FROM \(table) WHERE ID = ?", [.text(id)]) { kept = ($0.string(0) ?? "NULL", $0.int(1)) }
                usn += 1
                guard try db.run("""
                    UPDATE \(table) SET rb_data_status = 258, rb_local_deleted = 1, rb_local_usn = ?, updated_at = ? WHERE ID = ?
                    """, [.int(usn), .text(stamp.db), .text(id)]) == 1, let kept else {
                    throw DJCError.writeVerificationFailed(String(ui: "더 쓰지 않는 이름 행을 표시하지 못했으니 rekordbox를 그대로 둔 채 문제를 알려 주세요 (\(content.title))"))
                }
                marked.append(MarkedName(table: table, id: id, usn: usn, cloudUSN: kept.usn, synced: kept.synced))
            }
        }
        if !marked.isEmpty {
            usn += 1
            guard try db.run("UPDATE djmdContent SET rb_local_usn = ? WHERE ID = ?", [.int(usn), .text(content.id)]) == 1 else {
                throw DJCError.writeVerificationFailed(String(ui: "곡 행의 변경 번호를 다시 매기지 못했으니 rekordbox를 그대로 둔 채 문제를 알려 주세요 (\(content.title))"))
            }
        }
        return (deleted, marked)
    }

    /// 곡 상태 0·256·257만 쓴다. 동기화(256·257) 곡도 상태 0과 같은 칸을 쓰고 곡 행만 256 → 257로 올린다
    /// (#171 2026-10-01 코멘트, #173 2026-10-04 S1·S2: 아홉 칸 모두·코멘트 비우기). 그 밖의 상태는 확인하지 않아 막는다.
    private static func checkTagState(_ draft: TagDraft, state: Int?, block: (String) -> Blocked) throws {
        guard let state, verifiedTagStates.contains(state) else {
            throw block(String(ui: "이 곡의 동기화 상태에서는 태그 쓰기를 확인하지 못했으므로 rekordbox에서 직접 고치세요"))
        }
    }

    /// 같은 이름이 여러 개인 앨범의 선택 규칙과 선택 밖 곡의 변경은 이번 쓰기 범위에 넣지 않는다.
    private static func checkTagAlbum(_ draft: TagDraft, contentID: String, db: CipherDatabase,
                                      block: (String) -> Blocked) throws {
        let keys = draft.changedKeys
        guard keys.contains(.artist) || keys.contains(.album) || keys.contains(.albumArtist) else { return }
        var oldState = 0
        var oldAlbumArtist = ""
        try db.query("SELECT a.rb_data_status, a.AlbumArtistID FROM djmdAlbum a JOIN djmdContent c ON c.AlbumID = a.ID WHERE c.ID = ?",
                     [.text(contentID)]) { oldState = $0.int(0) ?? -1; oldAlbumArtist = $0.string(1) ?? "" }
        // 앨범 행은 자기 상태로 저장된다: 0 그대로, 256 → 257, 257 그대로(#173 S1 T02·T03·T05·X1, S2 U01·U02·U07·U14, S3 V01·V03·V05).
        guard Self.verifiedTagStates.contains(oldState) else {
            throw block(String(ui: "이 앨범의 동기화 상태에서는 태그 쓰기를 확인하지 못했으므로 rekordbox에서 직접 고치세요"))
        }
        guard keys.contains(.album) || keys.contains(.albumArtist), !draft.fields.album.isEmpty else { return }
        if keys.contains(.album) && keys.contains(.albumArtist) {
            throw block(String(ui: "앨범과 앨범 아티스트를 함께 바꾸는 규칙은 확인하지 못했으므로 한 칸씩 쓰세요"))
        }
        var albums: [(id: String, artist: String, state: Int?)] = []
        try db.query("""
            SELECT al.ID, ifnull(al.AlbumArtistID, ''), al.rb_data_status FROM djmdAlbum al
            WHERE al.Name = ? AND al.rb_local_deleted = 0
            """, [.text(draft.fields.album)]) { albums.append(($0.string(0) ?? "", $0.string(1) ?? "", $0.int(2))) }
        guard albums.count <= 1 else {
            throw block(String(ui: "같은 이름의 앨범이 여럿이라 선택 규칙을 확인하지 못했으므로 rekordbox에서 직접 고치세요"))
        }
        guard let album = albums.first else { return }
        guard let state = album.state, Self.verifiedTagStates.contains(state) else {
            throw block(String(ui: "이 앨범의 동기화 상태에서는 태그 쓰기를 확인하지 못했으므로 rekordbox에서 직접 고치세요"))
        }
        if keys.contains(.albumArtist) {
            // 동기화 앨범은 지운 곡을 세지 않는다(#173 S2 U01·U14: 지운 곡도 쓰던 동기화 앨범의 앨범 아티스트를 제자리에서 넣고 비웠다).
            // 상태 0 앨범은 예전처럼 지운 곡까지 센다.
            guard try ReferenceCount(db, table: "djmdAlbum", id: album.id).count(ReferenceRows.scope(table: "djmdAlbum", state: state)) == 1 else {
                throw block(String(ui: "여러 곡이 쓰는 앨범이라 앨범 아티스트는 rekordbox에서 직접 고치세요"))
            }
        } else if album.artist != oldAlbumArtist {
            throw block(String(ui: "기존 앨범의 앨범 아티스트가 달라 다른 곡도 바뀔 수 있으므로 rekordbox에서 직접 고치세요"))
        }
    }

    /// 태그 초안 하나를 쓴다. 트랜잭션 안에서 부르고, 막히면 `Blocked`(부른 쪽이 SAVEPOINT로 되돌린다).
    /// - Parameter writable: 쓰기를 연 칸(앱은 `writableTagKeys`, 시험만 바꾼다)
    static func applyTags(_ draft: TagDraft, db: CipherDatabase, usn: inout Int, stamp: (db: String, json: String),
                          writable: Set<TagFields.Key>) throws -> (outcome: Outcome, expectation: TagExpectation) {
        let content = try checkTags(draft, db: db, writable: writable)
        let keys = draft.changedKeys, fields = draft.fields
        let old = content.old
        // 쓴 뒤 읽힐 값(숫자 칸은 읽기 규칙대로 다듬는다. 앨범을 비우면 앨범 아티스트도 빈칸)
        var expected = draft.base
        for key in keys { expected[key] = fields[key] }
        for key in [TagFields.Key.year, .trackNumber] where keys.contains(key) {
            let number = Int(fields[key]) ?? 0
            expected[key] = number > 0 ? String(number) : ""
        }
        if fields.album.isEmpty { expected.albumArtist = "" }

        var columns: [(String, CipherDatabase.Value)] = []
        var touchedAlbums: [String: (usn: Int, status: Int)] = [:]
        func name(_ table: String, _ value: String) throws -> CipherDatabase.Value {
            .text(try RekordboxTrackWriter.findOrCreate(db, table: table, name: value, usn: &usn, stamp: stamp))
        }
        /// 기존 앨범 행 저장: 앨범 아티스트(nil이면 NULL만 ''로) + 상태 256 → 257 + 변경 번호·시각
        func saveAlbum(_ album: String, albumArtist: String?) throws {
            guard let state = try liveNameState(db, table: "djmdAlbum", id: album), let state, verifiedTagStates.contains(state) else {
                throw Blocked(title: content.title, reason: String(ui: "이 앨범의 동기화 상태에서는 태그 쓰기를 확인하지 못했으므로 rekordbox에서 직접 고치세요"))
            }
            usn += 1
            let artist = albumArtist == nil ? "ifnull(AlbumArtistID, '')" : "?"
            try db.run("UPDATE djmdAlbum SET AlbumArtistID = \(artist), \(savedStatus), rb_local_usn = ?, updated_at = ? WHERE ID = ?",
                       (albumArtist.map { [CipherDatabase.Value.text($0)] } ?? []) + [.int(usn), .text(stamp.db), .text(album)])
            touchedAlbums[album] = (usn, savedState(state))
        }
        // 정보 패널 칸 순서대로(제목 → 앨범 → 아티스트 → 장르 → 작곡가 → …). 새 이름 행과 앨범 행이 곡 행보다 먼저 번호를 받는다.
        // 앨범을 아티스트보다 먼저 쓴다(#173 명세 4.2-7): rekordbox에서 앨범 → 아티스트 순으로 저장한 결과와 같게, 아티스트가 저장하는
        // 앨범 행은 바뀐 뒤의 앨범이다(이 곡만 쓰던 옛 앨범을 저장한 뒤 버리지 않는다).
        if keys.contains(.title) { columns.append(("Title", .text(fields.title))) }
        var currentAlbum = old.albumLive ? old.album.flatMap { $0.isEmpty ? nil : $0 } : nil
        if keys.contains(.album) || keys.contains(.albumArtist) {
            if fields.album.isEmpty {
                // 비우면 '' (2026-09-27 실험곡 3)
                columns.append(("AlbumID", .text("")))
                currentAlbum = nil
            } else {
                // S1~S5: 이름이 유일한 기존 앨범은 제자리 저장, 새 앨범의 빈 아티스트는 NULL이 아니라 ''.
                let albumArtistID: String
                if keys.contains(.albumArtist) {
                    albumArtistID = fields.albumArtist.isEmpty ? ""
                        : try RekordboxTrackWriter.findOrCreate(db, table: "djmdArtist", name: fields.albumArtist, usn: &usn, stamp: stamp)
                } else {
                    albumArtistID = old.albumArtist ?? ""
                }
                var existing: String?
                try db.query("SELECT ID FROM djmdAlbum WHERE Name = ? AND rb_local_deleted = 0", [.text(fields.album)]) { existing = $0.string(0) }
                if let existing {
                    // 동기화된 대상 앨범도 256 → 257(#173 S2 U02), 제자리 앨범 아티스트도(S2 U01·U14)
                    try saveAlbum(existing, albumArtist: albumArtistID)
                    columns.append(("AlbumID", .text(existing)))
                    currentAlbum = existing
                } else {
                    let album = try RekordboxTrackWriter.findOrCreateAlbum(db, name: fields.album, albumArtistID: albumArtistID, usn: &usn, stamp: stamp)
                    columns.append(("AlbumID", .text(album)))
                    touchedAlbums[album] = (usn, 0)
                    currentAlbum = album
                }
            }
        }
        if keys.contains(.artist) {
            columns.append(("ArtistID", fields.artist.isEmpty ? .text("") : try name("djmdArtist", fields.artist)))
            // 아티스트를 고치면 곡의 앨범 행도 저장된다: NULL 앨범 아티스트는 '', 변경 번호·시각(2026-09-27 실험곡 5, 묶음 2),
            // 동기화 앨범은 256 → 257·257 그대로(#173 S1 T02·T05·X1, S2 U07, S3 V01·V03·V05)
            if content.migratesAlbum, let name = old.albumName {
                // 같은 이름 앨범이 여럿이면 옛 앨범은 저장하지 않고 같은 이름의 새 앨범으로 옮긴다(#173 S3 V02·S2 U13). (이름, 앨범 아티스트)
                // 짝이 같은 행이 있어도 늘 새로 만든다(`findOrCreateAlbum`을 쓰지 않는다). 앨범 아티스트는 이어받고 NULL이면 ''.
                let id = try RekordboxTrackWriter.insertAlbum(db, name: name, albumArtistID: old.albumArtist ?? "", usn: &usn, stamp: stamp)
                columns.append(("AlbumID", .text(id)))
                touchedAlbums[id] = (usn, 0)
            } else if let album = currentAlbum {
                try saveAlbum(album, albumArtist: nil)
            }
        }
        // 장르를 비우면 '0', 작곡가를 비우면 ''(2026-09-27 실험곡 4 세션 2)
        if keys.contains(.genre) { columns.append(("GenreID", fields.genre.isEmpty ? .text("0") : try name("djmdGenre", fields.genre))) }
        if keys.contains(.composer) { columns.append(("ComposerID", fields.composer.isEmpty ? .text("") : try name("djmdArtist", fields.composer))) }
        if keys.contains(.year) { columns.append(("ReleaseYear", .int(Int(fields.year) ?? 0))) }
        if keys.contains(.trackNumber) { columns.append(("TrackNo", .int(Int(fields.trackNumber) ?? 0))) }
        if keys.contains(.comment) { columns.append(("Commnt", .text(fields.comment))) }

        // 곡 행: 바뀐 칸 + TrackInfoUpdated(글자) 칸마다 +1 + 동기화 상태 256 → 257 + 변경 번호(마지막).
        // 앨범을 비우며 앨범 아티스트도 비우면 rekordbox에서는 한 번 저장이다.
        let saves = keys.count - (keys.contains(.album) && keys.contains(.albumArtist) && fields.album.isEmpty ? 1 : 0)
        let trackInfoUpdated = String((Int(content.trackInfoUpdated ?? "0") ?? 0) + saves)
        usn += 1
        let assignments = columns.map { "\"\($0.0)\" = ?" } + [
            "TrackInfoUpdated = ?",
            savedStatus,
            "rb_local_usn = ?", "updated_at = ?",
        ]
        let changed = try db.run("UPDATE djmdContent SET \(assignments.joined(separator: ", ")) WHERE ID = ?",
                                 columns.map(\.1) + [.text(trackInfoUpdated), .int(usn), .text(stamp.db), .text(content.id)])
        guard changed == 1 else { throw DJCError.writeVerificationFailed(String(ui: "곡 정보를 고치지 못했습니다 (\(content.title))")) }

        // 아무 곡·앨범도 안 쓰게 된 옛 행: 상태 0은 실제로 지우고(2026-09-27: 아티스트 A·작곡가·장르·앨범), 동기화(256)는 258·삭제 표시로
        // 네 칸만 바꾼다(#173 S1 T02·T04·T05, S2 U02~U05·U14, S3 V03). 지운 앨범의 앨범 아티스트 행은 rekordbox도 남겼다(앨범 칸을 고칠 때는
        // 앨범 아티스트를 놓는 것으로 보지 않는다). 쓴 뒤의 실제 참조 수로 정한다.
        let (deleted, marked) = try releaseNames(content, keys: Set(keys), db: db, usn: &usn, stamp: stamp)
        var expectation = TagExpectation(contentID: content.id, fields: expected, trackInfoUpdated: trackInfoUpdated, contentUSN: usn,
                                         dataStatus: savedState(content.state), touchedAlbums: touchedAlbums, deletedNames: deleted)
        expectation.markedNames = marked
        // 버린 앨범(지움·258)은 저장한 앨범 기대값에서 뺀다
        for id in expectation.releasedAlbums { expectation.touchedAlbums.removeValue(forKey: id) }
        if case let .text(album)? = columns.last(where: { $0.0 == "AlbumID" })?.1 { expectation.albumID = album }
        try verifyTags(db: db, expectation)
        let outcome = Outcome(trackUUID: draft.trackUUID, title: content.title, status: .written, reason: nil, removed: 0, added: keys.count,
                              fields: keys.map(\.rawValue))
        return (outcome, expectation)
    }

    /// 곡의 태그·카운터·변경 번호가 쓴 그대로인지 다시 읽어 확인한다(트랜잭션 안과 커밋 뒤).
    static func verifyTags(db: CipherDatabase, _ expected: TagExpectation) throws {
        func fail(_ reason: String) -> DJCError { .writeVerificationFailed("\(reason) (ContentID \(expected.contentID))") }
        guard try currentTags(db: db, contentID: expected.contentID) == expected.fields else { throw fail(String(ui: "곡 정보가 초안과 다릅니다")) }
        var stored: (info: String?, type: String?, usn: Int?, status: Int?)?
        try db.query("SELECT TrackInfoUpdated, typeof(TrackInfoUpdated), rb_local_usn, rb_data_status FROM djmdContent WHERE ID = ?",
                     [.text(expected.contentID)]) { stored = ($0.string(0), $0.string(1), $0.int(2), $0.int(3)) }
        guard stored?.info == expected.trackInfoUpdated, stored?.type == "text" else { throw fail(String(ui: "곡 정보 변경 횟수(TrackInfoUpdated)가 다릅니다")) }
        guard stored?.usn == expected.contentUSN else { throw fail(String(ui: "곡의 변경 번호가 다릅니다")) }
        guard let stored, stored.status == expected.dataStatus else { throw fail(String(ui: "곡의 동기화 상태(rb_data_status)가 다릅니다")) }
        if let album = expected.albumID {
            var stored: String?
            try db.query("SELECT AlbumID FROM djmdContent WHERE ID = ?", [.text(expected.contentID)]) { stored = $0.string(0) }
            guard stored == album else { throw fail(String(ui: "곡의 앨범 행이 쓴 것과 다르니 rekordbox를 그대로 둔 채 문제를 알려 주세요")) }
        }
        for (id, album) in expected.touchedAlbums {
            guard try scalar(db, "SELECT rb_local_usn FROM djmdAlbum WHERE ID = ? AND AlbumArtistID IS NOT NULL", [.text(id)]) == album.usn else {
                throw fail(String(ui: "앨범 행의 변경 번호가 다릅니다"))
            }
            guard try scalar(db, "SELECT rb_data_status FROM djmdAlbum WHERE ID = ? AND rb_local_deleted = 0", [.text(id)]) == album.status else {
                throw fail(String(ui: "앨범 행의 동기화 상태(rb_data_status)가 쓴 것과 다르니 rekordbox를 그대로 둔 채 문제를 알려 주세요"))
            }
        }
        for (table, id) in expected.deletedNames {
            guard try scalar(db, "SELECT count(*) FROM \(table) WHERE ID = ?", [.text(id)]) == 0 else { throw fail(String(ui: "지운 이름 행이 남아 있습니다")) }
        }
        for name in expected.markedNames {
            var rows: [(status: Int?, deleted: Int?, usn: Int?, cloud: String?, synced: Int?)] = []
            try db.query("SELECT rb_data_status, rb_local_deleted, rb_local_usn, quote(usn), rb_local_synced FROM \(name.table) WHERE ID = ?",
                         [.text(name.id)]) { rows.append(($0.int(0), $0.int(1), $0.int(2), $0.string(3), $0.int(4))) }
            guard rows.count == 1, let row = rows.first, row.status == 258, row.deleted == 1, row.usn == name.usn,
                  row.cloud == name.cloudUSN, row.synced == name.synced else {
                throw fail(String(ui: "더 쓰지 않는 동기화 이름 행의 표시가 쓴 것과 다르니 rekordbox를 그대로 둔 채 문제를 알려 주세요"))
            }
        }
    }
}
