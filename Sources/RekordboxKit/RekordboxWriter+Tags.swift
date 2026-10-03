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
    /// 저장하는 앨범 행의 상태로 확인한 것(#173 2026-10-04). 0 그대로, 256 → 257, 257 그대로.
    static let verifiedAlbumStates: Set<Int> = [0, 256, 257]

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
        /// 쓴 뒤 버릴 옛 행과 방법(`planReleases`)
        var releases: [TagRelease] = []
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

    /// 백업 전 확인: 막힐 태그 초안을 트랜잭션과 같은 순서로 거른다(읽기 연결만 쓴다). 앞 초안이 통과하면 그 초안이 옮길 참조를
    /// 쌓아 뒤 초안의 버려짐 예측에 얹는다(트랜잭션 안에서 앞 초안을 쓴 DB를 보는 것과 같게, #173 리뷰).
    static func checkTagDrafts(_ tags: [TagDraft], db: CipherDatabase, writable: Set<TagFields.Key>) throws -> (passed: [TagDraft], blocked: [Outcome]) {
        var passed: [TagDraft] = [], blocked: [Outcome] = []
        var batch = TagBatch()
        for draft in tags {
            do {
                _ = try checkTags(draft, db: db, writable: writable, batch: &batch)
                passed.append(draft)
            } catch let error as Blocked {
                blocked.append(Outcome(trackUUID: draft.trackUUID, title: error.title, status: .blocked, reason: error.reason, removed: 0, added: 0))
            }
        }
        return (passed, blocked)
    }

    /// 쓰기 전에 막을 조건: 곡 없음·지운 곡·닫힌 칸·잘못된 값·base 불일치·정리할 수 없는 옛 행. 막히면 `Blocked`, 통과하면 곡 행 정보.
    /// 백업을 뜨기 전(읽기 연결, 앞 초안을 쌓은 `batch`)과 트랜잭션 안(빈 `batch`)에서 두 번 본다. 통과할 때만 `batch`가 바뀐다.
    static func checkTags(_ draft: TagDraft, db: CipherDatabase, writable: Set<TagFields.Key>, batch: inout TagBatch) throws -> CheckedTag {
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
        guard let old = try TagOldNames.read(db, contentID: content.id) else { throw block(String(ui: "곡 행을 다시 읽지 못했습니다 (\(content.title))")) }
        let migrates = try checkSameNameAlbum(draft, old: old, db: db, batch: batch, block: block)
        let releases = try planReleases(draft, contentID: content.id, old: old, migratesAlbum: migrates, db: db, batch: &batch, block: block)
        return CheckedTag(id: content.id, title: content.title, trackInfoUpdated: content.trackInfoUpdated, state: content.state, old: old,
                          migratesAlbum: migrates, releases: releases)
    }

    /// 아티스트를 바꿀 때 곡의 앨범 이름을 살아 있는 앨범 둘 이상이 쓰면, rekordbox는 같은 이름의 새 앨범을 만들어 곡을 옮긴다
    /// (#173 S3 V02: 상태 0·앨범 아티스트 있음·이 곡만 씀·나중에 만든 행, S2 U13: 동기화·앨범 아티스트 NULL·공유·가장 먼저 만든 행. 곡 상태와
    /// 무관하다). 앨범·앨범 아티스트 칸도 고치면 그 칸을 먼저 쓰므로 옮기지 않는다. 아티스트 비우기는 확인하지 않아 막는다.
    /// 곡의 앨범이 같은 이름 앨범 중 가장 먼저 만든 행이면서 앨범 아티스트가 NULL이 아니면(값이나 '') "먼저 만든 같은 이름 행을 골라 앨범
    /// 아티스트를 비교한다"는 다른 가설과 결과가 갈려 막는다(만든 시각이 같으면 먼저 만든 행으로 본다).
    /// - Returns: 새 앨범으로 옮기는지
    private static func checkSameNameAlbum(_ draft: TagDraft, old: TagOldNames, db: CipherDatabase, batch: TagBatch,
                                           block: (String) -> Blocked) throws -> Bool {
        let keys = draft.changedKeys
        guard keys.contains(.artist), !keys.contains(.album), !keys.contains(.albumArtist), old.albumLive,
              let album = old.album, !album.isEmpty, let name = old.albumName else { return false }
        // 같은 이름의 살아 있는 앨범(앞 초안이 버릴 앨범은 빼고, 앞 초안이 만들 새 앨범은 더한다. 새 앨범은 가장 늦게 만든 행이다)
        var albums: [(id: String, created: String?)] = []
        try db.query("SELECT ID, created_at FROM djmdAlbum WHERE Name = ? AND rb_local_deleted = 0", [.text(name)]) {
            if let id = $0.string(0), !batch.released("djmdAlbum", id) { albums.append((id, $0.string(1))) }
        }
        guard albums.count + batch.newAlbums.filter({ $0.name == name }).count >= 2 else { return false }
        let mine = albums.first { $0.id == album }?.created
        let earlier = albums.filter { other in
            guard other.id != album, let theirs = other.created, let mine else { return false }
            return theirs < mine
        }.count
        // 아티스트 비우기는 보지 못했다(V02·U13은 바꾸기). 같은 규칙으로 보이지만[추정] 확인 전에는 막는다.
        if draft.fields.artist.isEmpty || (earlier == 0 && old.albumArtist != nil) {
            throw block(String(ui: "같은 이름 앨범이 여럿인 곡이라 rekordbox 저장 규칙을 아직 확인하지 못했으므로 rekordbox에서 직접 고치세요"))
        }
        return true
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

        /// 버려졌는지 볼 때의 범위. 동기화(256·257) 행은 살아 있는 곡·앨범만 센다(#173 S2 U01·U04·U14, 2026-10-04: 지운 곡 여럿이 가리키는
        /// 동기화 앨범도 비우자 258이 됐다). 상태 0과 그 밖의 행은 예전처럼 지운 곡·앨범까지 센다(지워도 외래 키가 끊기지 않게, 상태 0의 근거는 없다).
        static func scope(of state: Int?) -> ReferenceRows { state == 256 || state == 257 ? .live : .all }
    }

    /// 행 하나를 가리키는 곡·앨범(가리키는 칸마다 한 줄, 지운 행인지). 칸마다 인덱스가 있어 칸별 질의를 UNION ALL로 잇는다(OR는 표 전체를 훑는다).
    struct Referrers {
        var contents: [(id: String, deleted: Bool)] = []
        var albums: [(id: String, deleted: Bool)] = []

        init(_ db: CipherDatabase, table: String, id: String) throws {
            let columns = switch table {
            case "djmdArtist": ["ArtistID", "ComposerID", "OrgArtistID", "RemixerID"]
            case "djmdAlbum": ["AlbumID"]
            default: ["GenreID"]
            }
            let sql = columns.map { "SELECT ID, rb_local_deleted FROM djmdContent WHERE \($0) = ?1" }.joined(separator: " UNION ALL ")
            try db.query(sql, [.text(id)]) { contents.append(($0.string(0) ?? "", ($0.int(1) ?? 0) != 0)) }
            if table == "djmdArtist" {
                try db.query("SELECT ID, rb_local_deleted FROM djmdAlbum WHERE AlbumArtistID = ?", [.text(id)]) {
                    albums.append(($0.string(0) ?? "", ($0.int(1) ?? 0) != 0))
                }
            }
        }

        /// 지금 DB의 참조 수(쓴 뒤 다시 셀 때·앨범 아티스트 유일성)
        func count(_ rows: ReferenceRows) -> Int {
            (contents + albums).filter { rows == .all || !$0.deleted }.count
        }
    }

    /// 쓴 뒤 곡 행이 가리킬 것(아티스트·작곡가·원곡 아티스트·리믹서, 앨범, 장르). 아직 없는 새 이름은 nil.
    struct TagRefs {
        var artists: [String?]
        var album: String?
        var genre: String?

        func count(_ table: String, _ id: String) -> Int {
            switch table {
            case "djmdArtist": artists.filter { $0 == id }.count
            case "djmdAlbum": album == id ? 1 : 0
            default: genre == id ? 1 : 0
            }
        }
    }

    /// 쓴 뒤 앨범 행(앨범 아티스트·상태·버려졌는지). 258로 표시한 앨범도 앨범 아티스트 칸은 그대로 가리킨다.
    struct AlbumAfter {
        enum Fate { case live, marked, deleted }
        var artist: String?
        var state: Int?
        var fate: Fate
    }

    /// 같은 반영에서 앞 초안들이 바꿀 것. 백업 전 확인이 초안 순서대로 쌓아 뒤 초안의 예측에 쓴다(트랜잭션 안에서는 DB가 이미 반영해 비어 있다).
    /// 버려짐 판단에 드는 것만 담는다: 곡 행의 쓴 뒤 참조, 저장·버릴 앨범, 새 앨범, 버릴 아티스트·장르. 같은 곡의 초안이 둘이거나 앞 초안이 만든
    /// 새 앨범에 붙이는 것 같은 드문 조합은 트랜잭션 안의 확인이 기준이다.
    struct TagBatch {
        var contents: [String: TagRefs] = [:]
        var albums: [String: AlbumAfter] = [:]
        var newAlbums: [(name: String, artist: String?)] = []
        var releasedNames: Set<String> = []

        func released(_ table: String, _ id: String) -> Bool {
            table == "djmdAlbum" ? albums[id].map { $0.fate != .live } ?? false : releasedNames.contains("\(table):\(id)")
        }
    }

    /// 버릴 행과 방법(상태 0은 지우고, 256은 258로 표시한다)
    struct TagRelease: Equatable {
        var table: String
        var id: String
        var state: Int?
        var deletes: Bool { state == 0 }
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

    /// 이 초안을 쓴 뒤의 참조로 버릴 행과 방법을 정한다. 백업 전 확인(앞 초안들을 쌓은 `batch`)과 트랜잭션 안(빈 `batch`)이 이 함수 하나를 쓰고,
    /// 쓰기는 이 결과대로 정리한 뒤 다시 세어 같은지 본다(`applyReleases`). 정리할 수 없는 상태면 `Blocked`. 통과하면 `batch`에 이 초안의 결과를 더한다.
    /// 앨범 칸을 아티스트보다 먼저 쓰는 것, 아티스트 저장이 바뀐 뒤의 앨범을 저장하는 것, 동명 앨범이면 새 앨범으로 옮기는 것은 `applyTags`와 같다.
    static func planReleases(_ draft: TagDraft, contentID: String, old: TagOldNames, migratesAlbum: Bool, db: CipherDatabase,
                             batch: inout TagBatch, block: (String) -> Blocked) throws -> [TagRelease] {
        let keys = Set(draft.changedKeys), fields = draft.fields
        var next = batch
        /// 이미 있는 이름이면 쓰기가 고를 행(`findOrCreate`와 같은 순서, 앞 초안이 버릴 행은 건너뜀), 빈 값은 "", 새 이름은 nil
        func resolve(_ table: String, _ name: String) throws -> String? {
            guard !name.isEmpty else { return "" }
            var ids: [String] = []
            try db.query("SELECT ID FROM \(table) WHERE Name = ? AND rb_local_deleted = 0 ORDER BY created_at", [.text(name)]) {
                if let id = $0.string(0) { ids.append(id) }
            }
            return ids.first { !next.released(table, $0) }
        }
        /// 살아 있는 앨범의 쓰기 전(앞 초안을 얹은) 앨범 아티스트·상태
        func album(_ id: String) throws -> (artist: String?, state: Int?)? {
            if let after = next.albums[id] { return after.fate == .live ? (after.artist, after.state) : nil }
            var row: (artist: String?, state: Int?)?
            try db.query("SELECT AlbumArtistID, rb_data_status FROM djmdAlbum WHERE ID = ? AND rb_local_deleted = 0", [.text(id)]) { row = ($0.string(0), $0.int(1)) }
            return row
        }
        func saved(_ state: Int?) -> Int? { state == 256 ? 257 : state }

        // 쓴 뒤 곡 행과 앨범 행(applyTags와 같은 순서: 앨범 → 아티스트)
        var after = TagRefs(artists: [keys.contains(.artist) ? try resolve("djmdArtist", fields.artist) : old.artist,
                                      keys.contains(.composer) ? try resolve("djmdArtist", fields.composer) : old.composer,
                                      old.orgArtist, old.remixer],
                            album: nil, genre: keys.contains(.genre) ? try resolve("djmdGenre", fields.genre) : old.genre)
        var current = old.albumLive ? old.album.flatMap { $0.isEmpty ? nil : $0 } : nil
        if keys.contains(.album) || keys.contains(.albumArtist) {
            let artist = keys.contains(.albumArtist) ? try resolve("djmdArtist", fields.albumArtist) : (old.albumArtist ?? "")
            if fields.album.isEmpty {
                current = nil
            } else {
                var existing: String?
                try db.query("SELECT ID FROM djmdAlbum WHERE Name = ? AND rb_local_deleted = 0", [.text(fields.album)]) {
                    if let id = $0.string(0), !next.released("djmdAlbum", id) { existing = id }
                }
                if let existing, let now = try album(existing) {
                    next.albums[existing] = AlbumAfter(artist: artist, state: saved(now.state), fate: .live)
                    current = existing
                } else {
                    next.newAlbums.append((fields.album, artist))
                    current = nil
                }
            }
        }
        if keys.contains(.artist) {
            if migratesAlbum, let name = old.albumName {
                next.newAlbums.append((name, old.albumArtist ?? ""))
                current = nil
            } else if let id = current, let now = try album(id) {
                next.albums[id] = AlbumAfter(artist: now.artist ?? "", state: saved(now.state), fate: .live)
            }
        }
        after.album = current

        /// 쓴 뒤 행 하나를 가리킬 곡·앨범 수(앞 초안·이 초안이 바꾼 행은 쓴 뒤 값으로)
        func references(_ table: String, _ id: String, _ rows: ReferenceRows) throws -> Int {
            let found = try Referrers(db, table: table, id: id)
            var contents = next.contents
            contents[contentID] = after
            var total = found.contents.filter { contents[$0.id] == nil && (rows == .all || !$0.deleted) }.count
            total += contents.values.reduce(0) { $0 + $1.count(table, id) }
            guard table == "djmdArtist" else { return total }
            total += found.albums.filter { next.albums[$0.id] == nil && (rows == .all || !$0.deleted) }.count
            for album in next.albums.values where album.artist == id {
                switch album.fate {
                case .live: total += 1
                case .marked: total += rows == .all ? 1 : 0
                case .deleted: break
                }
            }
            return total + next.newAlbums.filter { $0.artist == id }.count
        }

        var releases: [TagRelease] = []
        for (table, id) in releasedNames(keys, old: old, migratesAlbum: migratesAlbum) {
            let state: Int?
            if table == "djmdAlbum" {
                guard let now = try album(id) else { continue }
                state = now.state
            } else {
                guard !next.released(table, id), let live = try liveNameState(db, table: table, id: id) else { continue }
                state = live
            }
            guard try references(table, id, ReferenceRows.scope(of: state)) == 0 else { continue }
            if let problem = releaseProblem(table: table, state: state) { throw block(problem) }
            let release = TagRelease(table: table, id: id, state: state)
            releases.append(release)
            if table == "djmdAlbum" {
                next.albums[id] = AlbumAfter(artist: try album(id)?.artist, state: release.deletes ? nil : 258, fate: release.deletes ? .deleted : .marked)
            } else {
                next.releasedNames.insert("\(table):\(id)")
            }
        }
        next.contents[contentID] = after
        batch = next
        return releases
    }

    /// 계획한 대로 옛 행을 정리한다(트랜잭션 안, 곡 행을 쓴 뒤). 정리하기 전과 남길 행을 다시 세어 계획과 다르면 계산이 틀린 것이라
    /// 쓰기 전체를 되돌린다(`writeVerificationFailed`). 258을 쓰면 rekordbox처럼 곡 행이 마지막 번호를 다시 받는다(옛 행 → 곡 행).
    static func applyReleases(_ content: CheckedTag, keys: Set<TagFields.Key>, db: CipherDatabase, usn: inout Int, stamp: (db: String, json: String))
        throws -> (deleted: [(table: String, id: String)], marked: [MarkedName]) {
        func mismatch() -> DJCError {
            .writeVerificationFailed(String(ui: "버리거나 남길 이름 행의 참조가 계산과 다릅니다 (\(content.title))"))
        }
        var deleted: [(table: String, id: String)] = []
        var marked: [MarkedName] = []
        for release in content.releases {
            guard try Referrers(db, table: release.table, id: release.id).count(ReferenceRows.scope(of: release.state)) == 0 else { throw mismatch() }
            if release.deletes {
                guard try db.run("DELETE FROM \(release.table) WHERE ID = ?", [.text(release.id)]) == 1 else { throw mismatch() }
                deleted.append((release.table, release.id))
            } else {
                var kept: (usn: String, synced: Int?)?
                try db.query("SELECT quote(usn), rb_local_synced FROM \(release.table) WHERE ID = ?", [.text(release.id)]) {
                    kept = ($0.string(0) ?? "NULL", $0.int(1))
                }
                usn += 1
                guard try db.run("""
                    UPDATE \(release.table) SET rb_data_status = 258, rb_local_deleted = 1, rb_local_usn = ?, updated_at = ? WHERE ID = ?
                    """, [.int(usn), .text(stamp.db), .text(release.id)]) == 1, let kept else {
                    throw DJCError.writeVerificationFailed(String(ui: "더 쓰지 않는 이름 행을 표시하지 못했습니다 (\(content.title))"))
                }
                marked.append(MarkedName(table: release.table, id: release.id, usn: usn, cloudUSN: kept.usn, synced: kept.synced))
            }
        }
        // 남기기로 한 옛 행은 정말 누가 쓰고 있어야 한다(rekordbox는 아무도 안 쓰는 이름 행을 남기지 않는다).
        for (table, id) in releasedNames(keys, old: content.old, migratesAlbum: content.migratesAlbum)
            where !content.releases.contains(where: { $0.table == table && $0.id == id }) {
            guard let state = try liveNameState(db, table: table, id: id) else { continue }
            guard try Referrers(db, table: table, id: id).count(ReferenceRows.scope(of: state)) > 0 else { throw mismatch() }
        }
        if !marked.isEmpty {
            usn += 1
            guard try db.run("UPDATE djmdContent SET rb_local_usn = ? WHERE ID = ?", [.int(usn), .text(content.id)]) == 1 else {
                throw DJCError.writeVerificationFailed(String(ui: "곡 정보를 고치지 못했습니다 (\(content.title))"))
            }
        }
        return (deleted, marked)
    }

    /// 곡 상태 0·256·257만 쓴다. 동기화(256·257) 곡도 상태 0과 같은 칸을 쓰고 곡 행만 256 → 257로 올린다
    /// (#171 2026-10-01 코멘트, #173 2026-10-04 S1·S2: 아홉 칸 모두·코멘트 비우기). 그 밖의 상태는 확인하지 않아 막는다.
    private static func checkTagState(_ draft: TagDraft, state: Int?, block: (String) -> Blocked) throws {
        guard let state, [0, 256, 257].contains(state) else {
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
        guard Self.verifiedAlbumStates.contains(oldState) else {
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
        guard let state = album.state, Self.verifiedAlbumStates.contains(state) else {
            throw block(String(ui: "이 앨범의 동기화 상태에서는 태그 쓰기를 확인하지 못했으므로 rekordbox에서 직접 고치세요"))
        }
        if keys.contains(.albumArtist) {
            // 동기화 앨범은 지운 곡을 세지 않는다(#173 S2 U01·U14: 지운 곡도 쓰던 동기화 앨범의 앨범 아티스트를 제자리에서 넣고 비웠다).
            // 상태 0 앨범은 예전처럼 지운 곡까지 센다.
            guard try Referrers(db, table: "djmdAlbum", id: album.id).count(ReferenceRows.scope(of: state)) == 1 else {
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
        // 트랜잭션 안에서는 앞 초안을 쓴 DB를 그대로 보므로 쌓을 것이 없다(빈 batch).
        var batch = TagBatch()
        let content = try checkTags(draft, db: db, writable: writable, batch: &batch)
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
            guard let state = try liveNameState(db, table: "djmdAlbum", id: album), let state, verifiedAlbumStates.contains(state) else {
                throw Blocked(title: content.title, reason: String(ui: "이 앨범의 동기화 상태에서는 태그 쓰기를 확인하지 못했으므로 rekordbox에서 직접 고치세요"))
            }
            usn += 1
            let artist = albumArtist == nil ? "ifnull(AlbumArtistID, '')" : "?"
            try db.run("UPDATE djmdAlbum SET AlbumArtistID = \(artist), \(savedStatus), rb_local_usn = ?, updated_at = ? WHERE ID = ?",
                       (albumArtist.map { [CipherDatabase.Value.text($0)] } ?? []) + [.int(usn), .text(stamp.db), .text(album)])
            touchedAlbums[album] = (usn, state == 256 ? 257 : state)
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
                let id = try RekordboxTrackWriter.newID(db, table: "djmdAlbum", range: 1..<(1 << 32))
                usn += 1
                try RekordboxTrackWriter.insert(db, table: "djmdAlbum", [
                    "ID": .text(id), "Name": .text(name), "AlbumArtistID": .text(old.albumArtist ?? ""), "ImagePath": .null, "Compilation": .int(0),
                    "SearchStr": .null, "UUID": .text(UUID().uuidString.lowercased()),
                ].merging(RekordboxTrackWriter.syncColumns(usn: usn, stamp: stamp)) { a, _ in a })
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
        // 앨범 아티스트를 놓는 것으로 보지 않는다). 무엇을 버릴지는 확인 때 정했고(`planReleases`), 여기서는 그대로 하고 다시 센다.
        let (deleted, marked) = try applyReleases(content, keys: Set(keys), db: db, usn: &usn, stamp: stamp)
        for name in deleted where name.table == "djmdAlbum" { touchedAlbums.removeValue(forKey: name.id) }
        for name in marked where name.table == "djmdAlbum" { touchedAlbums.removeValue(forKey: name.id) }

        var expectation = TagExpectation(contentID: content.id, fields: expected, trackInfoUpdated: trackInfoUpdated, contentUSN: usn,
                                         dataStatus: content.state == 256 ? 257 : content.state,
                                         touchedAlbums: touchedAlbums, deletedNames: deleted)
        expectation.markedNames = marked
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
            guard stored == album else { throw fail(String(ui: "곡의 앨범 행이 다릅니다")) }
        }
        for (id, album) in expected.touchedAlbums {
            guard try scalar(db, "SELECT rb_local_usn FROM djmdAlbum WHERE ID = ? AND AlbumArtistID IS NOT NULL", [.text(id)]) == album.usn else {
                throw fail(String(ui: "앨범 행의 변경 번호가 다릅니다"))
            }
            guard try scalar(db, "SELECT rb_data_status FROM djmdAlbum WHERE ID = ? AND rb_local_deleted = 0", [.text(id)]) == album.status else {
                throw fail(String(ui: "앨범 행의 동기화 상태(rb_data_status)가 다릅니다"))
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
                throw fail(String(ui: "더 쓰지 않는 동기화 이름 행의 표시가 다릅니다"))
            }
        }
    }
}
