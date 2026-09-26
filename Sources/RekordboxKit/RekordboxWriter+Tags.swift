import DJCDomain
import Foundation

/// 태그(곡 정보) 쓰기: `djmdContent` 제자리 UPDATE + 새 이름이면 `djmdArtist`·`djmdAlbum`·`djmdGenre` 행(#1).
/// rekordbox 라이브러리만 바꾸고 음원 파일 태그는 건드리지 않는다(rekordbox는 파일 태그도 다시 쓰지만 DJCrate는 음원을 읽기만 한다).
extension RekordboxWriter {
    /// rekordbox 실험으로 쓰기 규칙을 확인한 칸. 이 밖의 칸을 고친 초안은 곡째 막는다(docs/rekordbox-internals.md "태그").
    public static let writableTagKeys: Set<TagFields.Key> = []

    /// 쓴 뒤 곡이 가져야 할 태그
    struct TagExpectation {
        var contentID: String
        var fields: TagFields
        var trackInfoUpdated: String
        var contentUSN: Int
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
        var contents: [(id: String, title: String, deleted: Bool, trackInfoUpdated: String?)] = []
        try db.query("SELECT ID, Title, rb_local_deleted, TrackInfoUpdated FROM djmdContent WHERE UUID = ?", [.text(draft.trackUUID)]) { r in
            contents.append((r.string(0) ?? "", r.string(1) ?? "", (r.int(2) ?? 0) != 0, r.string(3)))
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
        if draft.changedKeys.contains(where: { $0 == .album || $0 == .albumArtist }), draft.fields.album.isEmpty, !draft.fields.albumArtist.isEmpty {
            throw block("앨범이 없는 곡에는 앨범 아티스트를 쓸 수 없습니다")
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
        let keys = draft.changedKeys
        // 쓴 뒤 읽힐 값(숫자 칸은 읽기 규칙대로 다듬는다)
        var expected = draft.base
        var columns: [(String, CipherDatabase.Value)] = []
        for key in keys {
            let value = draft.fields[key]
            switch key {
            case .title:
                columns.append(("Title", .text(value)))
            case .year, .trackNumber:
                let number = Int(value) ?? 0
                columns.append((key == .year ? "ReleaseYear" : "TrackNo", .int(number)))
                expected[key] = number > 0 ? String(number) : ""
                continue
            case .comment:
                columns.append(("Commnt", .text(value)))
            case .artist, .album, .albumArtist, .genre, .composer:
                // 이름 칸은 아래에서 한꺼번에(앨범은 앨범 아티스트와 짝)
                break
            }
            expected[key] = value
        }
        // 새 이름 행은 곡 행보다 먼저 변경 번호를 받는다(곡 넣기와 같은 순서: 아티스트 → 앨범 아티스트 → 앨범 → 장르 → 작곡가).
        func artistID(_ name: String) throws -> CipherDatabase.Value {
            name.isEmpty ? .null : .text(try RekordboxTrackWriter.findOrCreate(db, table: "djmdArtist", name: name, usn: &usn, stamp: stamp))
        }
        if keys.contains(.artist) {
            columns.append(("ArtistID", try artistID(draft.fields.artist)))
            expected.artist = draft.fields.artist
        }
        if keys.contains(.album) || keys.contains(.albumArtist) {
            let albumArtist = draft.fields.albumArtist, album = draft.fields.album
            let albumArtistID: String? = albumArtist.isEmpty ? nil
                : try RekordboxTrackWriter.findOrCreate(db, table: "djmdArtist", name: albumArtist, usn: &usn, stamp: stamp)
            let albumID: CipherDatabase.Value = album.isEmpty ? .null
                : .text(try RekordboxTrackWriter.findOrCreateAlbum(db, name: album, albumArtistID: albumArtistID, usn: &usn, stamp: stamp))
            columns.append(("AlbumID", albumID))
            expected.album = album
            expected.albumArtist = albumArtist
        }
        if keys.contains(.genre) {
            let name = draft.fields.genre
            columns.append(("GenreID", name.isEmpty ? .null
                : .text(try RekordboxTrackWriter.findOrCreate(db, table: "djmdGenre", name: name, usn: &usn, stamp: stamp))))
            expected.genre = name
        }
        if keys.contains(.composer) {
            columns.append(("ComposerID", try artistID(draft.fields.composer)))
            expected.composer = draft.fields.composer
        }

        // 곡 행: 바뀐 칸 + TrackInfoUpdated(글자) +1 + 상태 256→257 + 변경 번호(마지막)
        let trackInfoUpdated = String((Int(content.trackInfoUpdated ?? "0") ?? 0) + 1)
        usn += 1
        let assignments = columns.map { "\"\($0.0)\" = ?" } + [
            "TrackInfoUpdated = ?",
            "rb_data_status = CASE rb_data_status WHEN 256 THEN 257 ELSE rb_data_status END",
            "rb_local_usn = ?", "updated_at = ?",
        ]
        let changed = try db.run("UPDATE djmdContent SET \(assignments.joined(separator: ", ")) WHERE ID = ?",
                                 columns.map(\.1) + [.text(trackInfoUpdated), .int(usn), .text(stamp.db), .text(content.id)])
        guard changed == 1 else { throw DJCError.writeVerificationFailed("곡 정보를 고치지 못했습니다 (\(content.title))") }
        let expectation = TagExpectation(contentID: content.id, fields: expected, trackInfoUpdated: trackInfoUpdated, contentUSN: usn)
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
    }
}
