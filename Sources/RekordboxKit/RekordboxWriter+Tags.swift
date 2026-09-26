import DJCDomain
import Foundation

/// 태그(곡 정보) 쓰기: `djmdContent` 제자리 UPDATE + 새 이름이면 `djmdArtist`·`djmdAlbum`·`djmdGenre` 행(#1).
/// rekordbox 라이브러리만 바꾸고 음원 파일 태그는 건드리지 않는다(rekordbox는 파일 태그도 다시 쓰지만 DJCrate는 음원을 읽기만 한다).
///
/// rekordbox 7.2.18 정보 패널은 칸마다 따로 저장한다(2026-09-27 "DJC 실험곡 1~5"). DJCrate는 여러 칸을 한 번에 쓰지만
/// 결과는 그 칸들을 하나씩 저장한 것과 같게 한다: 칸마다 `TrackInfoUpdated` +1, 새 이름 행, 버려진 이름 행 삭제, 곡 행은 마지막 번호.
extension RekordboxWriter {
    /// rekordbox 실험으로 쓰기 규칙을 확인한 칸. 이 밖의 칸을 고친 초안은 곡째 막는다(docs/rekordbox-internals.md "태그 (곡 정보)").
    /// 앨범·앨범 아티스트는 새 앨범 행의 `AlbumArtistID`, 같은 이름 앨범이 여럿일 때, 여러 곡이 쓰는 앨범의 앨범 아티스트를 아직 모른다.
    public static let writableTagKeys: Set<TagFields.Key> = [.title, .artist, .genre, .composer, .year, .trackNumber, .comment]

    /// 쓴 뒤 곡이 가져야 할 태그
    struct TagExpectation {
        var contentID: String
        var fields: TagFields
        var trackInfoUpdated: String
        var contentUSN: Int
        /// 아티스트를 고쳐 변경 번호를 준 앨범 행(ID, 번호)
        var touchedAlbum: (id: String, usn: Int)?
        /// 아무 곡도 안 쓰게 되어 지운 이름 행(표, ID)
        var deletedNames: [(table: String, id: String)] = []
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

    /// 쓰기 전에 막을 조건: 곡 없음·지운 곡·닫힌 칸·잘못된 값·base 불일치. 막히면 `Blocked`, 통과하면 곡 행 정보.
    /// 백업을 뜨기 전(읽기 연결)과 트랜잭션 안에서 두 번 본다.
    static func checkTags(_ draft: TagDraft, db: CipherDatabase,
                          writable: Set<TagFields.Key>) throws -> (id: String, title: String, trackInfoUpdated: String?) {
        var contents: [(id: String, title: String, deleted: Bool, trackInfoUpdated: String?, releaseDate: String?)] = []
        try db.query("SELECT ID, Title, rb_local_deleted, TrackInfoUpdated, ReleaseDate FROM djmdContent WHERE UUID = ?",
                     [.text(draft.trackUUID)]) { r in
            contents.append((r.string(0) ?? "", r.string(1) ?? "", (r.int(2) ?? 0) != 0, r.string(3), r.string(4)))
        }
        guard contents.count == 1, let content = contents.first else {
            throw Blocked(title: draft.trackUUID, reason: contents.isEmpty ? "rekordbox 컬렉션에서 곡을 찾지 못했습니다" : "같은 UUID의 곡이 여럿입니다")
        }
        func block(_ reason: String) -> Blocked { Blocked(title: content.title, reason: reason) }
        guard !content.deleted else { throw block("rekordbox 컬렉션에서 지운 곡입니다") }
        let closed = draft.changedKeys.filter { !writable.contains($0) }
        guard closed.isEmpty else {
            throw block("rekordbox에 쓰는 규칙을 아직 확인하지 않은 칸(\(closed.map(\.label).joined(separator: "·")))이 있습니다. 그 칸을 되돌리면 나머지는 쓸 수 있습니다")
        }
        if let issue = draft.issues.first { throw block(issue) }
        for key in [TagFields.Key.year, .trackNumber] where draft.changedKeys.contains(key) {
            guard (Int(draft.fields[key]) ?? 0) >= 0 else { throw block("\(key.label)는 0 이상이어야 합니다") }
        }
        // 앨범을 비우면 rekordbox가 앨범 아티스트도 함께 비운다(2026-09-27 실험곡 3). 비운 앨범에 새 앨범 아티스트는 쓸 수 없다.
        if draft.changedKeys.contains(.albumArtist), draft.fields.album.isEmpty, !draft.fields.albumArtist.isEmpty {
            throw block("앨범이 없는 곡에는 앨범 아티스트를 쓸 수 없습니다")
        }
        // 실험하지 않은 경우: 아티스트 비우기(작곡가는 '', 장르는 '0'으로 비워 짐작할 수 없다), 발매일이 있는 곡의 연도
        if draft.changedKeys.contains(.artist), draft.fields.artist.isEmpty {
            throw block("아티스트를 비우는 rekordbox 규칙은 아직 확인하지 않았습니다. 아티스트는 rekordbox에서 비우세요")
        }
        if draft.changedKeys.contains(.year), !(content.releaseDate ?? "").isEmpty {
            throw block("발매일이 있는 곡의 연도를 고치는 rekordbox 규칙은 아직 확인하지 않았습니다. 연도는 rekordbox에서 고치세요")
        }
        guard try currentTags(db: db, contentID: content.id) == draft.base else {
            throw block("초안을 만든 뒤 rekordbox에서 곡 정보가 바뀌었습니다. DJCrate에서 다시 불러와 확인하세요")
        }
        return (content.id, content.title, content.trackInfoUpdated)
    }

    /// 태그 초안 하나를 쓴다. 트랜잭션 안에서 부르고, 막히면 `Blocked`(부른 쪽이 SAVEPOINT로 되돌린다).
    /// - Parameter writable: 쓰기를 연 칸(앱은 `writableTagKeys`, 시험만 바꾼다)
    static func applyTags(_ draft: TagDraft, db: CipherDatabase, usn: inout Int, stamp: (db: String, json: String),
                          writable: Set<TagFields.Key>) throws -> (outcome: Outcome, expectation: TagExpectation) {
        let content = try checkTags(draft, db: db, writable: writable)
        let keys = draft.changedKeys, fields = draft.fields
        var old: (artist: String?, composer: String?, genre: String?, album: String?)?
        try db.query("SELECT ArtistID, ComposerID, GenreID, AlbumID FROM djmdContent WHERE ID = ?", [.text(content.id)]) {
            old = ($0.string(0), $0.string(1), $0.string(2), $0.string(3))
        }
        guard let old else { throw DJCError.writeVerificationFailed("곡 행을 다시 읽지 못했습니다 (\(content.title))") }
        // 쓴 뒤 읽힐 값(숫자 칸은 읽기 규칙대로 다듬는다. 앨범을 비우면 앨범 아티스트도 빈칸)
        var expected = draft.base
        for key in keys { expected[key] = fields[key] }
        for key in [TagFields.Key.year, .trackNumber] where keys.contains(key) {
            let number = Int(fields[key]) ?? 0
            expected[key] = number > 0 ? String(number) : ""
        }
        if fields.album.isEmpty { expected.albumArtist = "" }

        var columns: [(String, CipherDatabase.Value)] = []
        var touchedAlbum: (id: String, usn: Int)?
        func name(_ table: String, _ value: String) throws -> CipherDatabase.Value {
            .text(try RekordboxTrackWriter.findOrCreate(db, table: table, name: value, usn: &usn, stamp: stamp))
        }
        // 정보 패널 칸 순서대로(제목 → 아티스트 → 앨범 → 장르 → 작곡가 → …). 새 이름 행과 앨범 행이 곡 행보다 먼저 번호를 받는다.
        if keys.contains(.title) { columns.append(("Title", .text(fields.title))) }
        if keys.contains(.artist) {
            columns.append(("ArtistID", try name("djmdArtist", fields.artist)))
            // 아티스트를 고치면 곡의 앨범 행도 저장된다: NULL 앨범 아티스트는 '', 변경 번호·시각(2026-09-27 실험곡 5, 묶음 2)
            if let album = old.album, !album.isEmpty,
               try scalar(db, "SELECT count(*) FROM djmdAlbum WHERE ID = ? AND rb_local_deleted = 0", [.text(album)]) == 1 {
                usn += 1
                try db.run("""
                    UPDATE djmdAlbum SET AlbumArtistID = ifnull(AlbumArtistID, ''),
                        rb_data_status = CASE rb_data_status WHEN 256 THEN 257 ELSE rb_data_status END,
                        rb_local_usn = ?, updated_at = ? WHERE ID = ?
                    """, [.int(usn), .text(stamp.db), .text(album)])
                touchedAlbum = (album, usn)
            }
        }
        if keys.contains(.album) || keys.contains(.albumArtist) {
            if fields.album.isEmpty {
                // 비우면 '' (2026-09-27 실험곡 3)
                columns.append(("AlbumID", .text("")))
            } else {
                // 확인 전 가정(앱에서는 닫힌 칸): 곡 넣기처럼 (이름, 앨범 아티스트) 짝으로 찾거나 만든다.
                let albumArtistID = fields.albumArtist.isEmpty ? nil
                    : try RekordboxTrackWriter.findOrCreate(db, table: "djmdArtist", name: fields.albumArtist, usn: &usn, stamp: stamp)
                columns.append(("AlbumID", .text(try RekordboxTrackWriter.findOrCreateAlbum(db, name: fields.album, albumArtistID: albumArtistID,
                                                                                               usn: &usn, stamp: stamp))))
            }
        }
        // 장르를 비우면 '0', 작곡가를 비우면 ''(2026-09-27 실험곡 4 세션 2)
        if keys.contains(.genre) { columns.append(("GenreID", fields.genre.isEmpty ? .text("0") : try name("djmdGenre", fields.genre))) }
        if keys.contains(.composer) { columns.append(("ComposerID", fields.composer.isEmpty ? .text("") : try name("djmdArtist", fields.composer))) }
        if keys.contains(.year) { columns.append(("ReleaseYear", .int(Int(fields.year) ?? 0))) }
        if keys.contains(.trackNumber) { columns.append(("TrackNo", .int(Int(fields.trackNumber) ?? 0))) }
        if keys.contains(.comment) { columns.append(("Commnt", .text(fields.comment))) }

        // 곡 행: 바뀐 칸 + TrackInfoUpdated(글자) 칸마다 +1 + 상태 256→257 + 변경 번호(마지막).
        // 앨범을 비우며 앨범 아티스트도 비우면 rekordbox에서는 한 번 저장이다.
        let saves = keys.count - (keys.contains(.album) && keys.contains(.albumArtist) && fields.album.isEmpty ? 1 : 0)
        let trackInfoUpdated = String((Int(content.trackInfoUpdated ?? "0") ?? 0) + saves)
        usn += 1
        let assignments = columns.map { "\"\($0.0)\" = ?" } + [
            "TrackInfoUpdated = ?",
            "rb_data_status = CASE rb_data_status WHEN 256 THEN 257 ELSE rb_data_status END",
            "rb_local_usn = ?", "updated_at = ?",
        ]
        let changed = try db.run("UPDATE djmdContent SET \(assignments.joined(separator: ", ")) WHERE ID = ?",
                                 columns.map(\.1) + [.text(trackInfoUpdated), .int(usn), .text(stamp.db), .text(content.id)])
        guard changed == 1 else { throw DJCError.writeVerificationFailed("곡 정보를 고치지 못했습니다 (\(content.title))") }

        // 아무 곡도 안 쓰게 된 옛 이름 행은 지운다(2026-09-27: 아티스트 A·작곡가·장르·앨범). 지운 앨범의 앨범 아티스트 행은 rekordbox도 남겼다.
        var deleted: [(table: String, id: String)] = []
        var released: [(table: String, id: String?)] = []
        if keys.contains(.artist) { released.append(("djmdArtist", old.artist)) }
        if keys.contains(.composer) { released.append(("djmdArtist", old.composer)) }
        if keys.contains(.genre) { released.append(("djmdGenre", old.genre)) }
        if keys.contains(.album) || keys.contains(.albumArtist) { released.append(("djmdAlbum", old.album)) }
        for (table, id) in released {
            guard let id, !id.isEmpty, id != "0", !deleted.contains(where: { $0 == (table, id) }) else { continue }
            let references = switch table {
            case "djmdArtist": try RekordboxTrackWriter.referenceCount(db, artist: id)
            case "djmdAlbum": try RekordboxTrackWriter.referenceCount(db, album: id)
            default: try scalar(db, "SELECT count(*) FROM djmdContent WHERE GenreID = ?", [.text(id)]) ?? 1
            }
            guard references == 0 else { continue }
            _ = try db.run("DELETE FROM \(table) WHERE ID = ?", [.text(id)])
            deleted.append((table, id))
        }

        let expectation = TagExpectation(contentID: content.id, fields: expected, trackInfoUpdated: trackInfoUpdated, contentUSN: usn,
                                         touchedAlbum: touchedAlbum, deletedNames: deleted)
        try verifyTags(db: db, expectation)
        let outcome = Outcome(trackUUID: draft.trackUUID, title: content.title, status: .written, reason: nil, removed: 0, added: keys.count,
                              fields: keys.map(\.rawValue))
        return (outcome, expectation)
    }

    /// 곡의 태그·카운터·변경 번호가 쓴 그대로인지 다시 읽어 확인한다(트랜잭션 안과 커밋 뒤).
    static func verifyTags(db: CipherDatabase, _ expected: TagExpectation) throws {
        func fail(_ reason: String) -> DJCError { .writeVerificationFailed("\(reason) (ContentID \(expected.contentID))") }
        guard try currentTags(db: db, contentID: expected.contentID) == expected.fields else { throw fail("곡 정보가 초안과 다릅니다") }
        var stored: (info: String?, type: String?, usn: Int?)?
        try db.query("SELECT TrackInfoUpdated, typeof(TrackInfoUpdated), rb_local_usn FROM djmdContent WHERE ID = ?",
                     [.text(expected.contentID)]) { stored = ($0.string(0), $0.string(1), $0.int(2)) }
        guard stored?.info == expected.trackInfoUpdated, stored?.type == "text" else { throw fail("곡 정보 변경 횟수(TrackInfoUpdated)가 다릅니다") }
        guard stored?.usn == expected.contentUSN else { throw fail("곡의 변경 번호가 다릅니다") }
        if let album = expected.touchedAlbum {
            guard try scalar(db, "SELECT rb_local_usn FROM djmdAlbum WHERE ID = ? AND AlbumArtistID IS NOT NULL", [.text(album.id)]) == album.usn else {
                throw fail("앨범 행의 변경 번호가 다릅니다")
            }
        }
        for (table, id) in expected.deletedNames {
            guard try scalar(db, "SELECT count(*) FROM \(table) WHERE ID = ?", [.text(id)]) == 0 else { throw fail("지운 이름 행이 남아 있습니다") }
        }
    }
}
