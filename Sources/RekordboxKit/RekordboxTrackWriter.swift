import DJCDomain
import Foundation

/// rekordbox 컬렉션에 곡을 넣고 뺀다(rekordbox를 켜지 않고).
///
/// rekordbox 7.2.18 실험(2026-09-26, 묶음 1·2)에서 확인한 모양을 따른다:
/// - 추가(분석 전): `djmdContent` 행 하나 + 새 이름이면 `djmdArtist`·`djmdAlbum`·`djmdGenre` 행. 분석 파일·파일 행·오토게인 행은 없다.
///   곡 ID는 1~2^28 난수, 아티스트 등은 32비트 난수. 관련 행 번호(usn)를 먼저 받고 곡 행이 마지막 번호를 받는다.
/// - 삭제: 행을 실제로 지운다(삭제 표시가 아님). 곡 행·큐(`djmdCue`·`contentCue`)·파일 행·오토게인 행·재생 목록·재생 이력 항목.
///   같은 목록·이력의 뒤 순번은 하나씩 당기고(한 번호로 몰아서), 그 곡만 쓰던 아티스트·앨범 행도 지운다. 분석 폴더·아트워크 파일도 지운다.
///   재생 목록 순번 당기기는 재생 이력에서 본 것을 따른 추정이다.
/// - 확인하지 않은 표(MyTag·핫큐 뱅크·샘플러·관련 곡·신청곡·검열 구간·클라우드 내보내기)에 걸린 곡은 지우지 않는다.
///
/// 안전장치는 큐 쓰기(`RekordboxWriter`)와 같다: 사전 확인 → 전체 백업 → 한 트랜잭션 → 다시 읽어 검증 → 무결성 검사 → 실패 시 복원.
public enum RekordboxTrackWriter {
    public struct Outcome: Codable, Hashable, Sendable {
        public var path: String
        public var contentID: String?
        public var title: String
        public var written: Bool
        public var reason: String?
    }

    public struct Report: Codable, Sendable {
        public var added: [Outcome] = []
        public var deleted: [Outcome] = []
        public var backup: String?
        public var dryRun: Bool
        /// 지운 곡의 분석·아트워크 파일(백업 폴더 `anlz/`로 옮겨 두었다가 되돌릴 때 살린다)
        public var removedFiles: [String] = []
    }

    /// 지울 곡을 막는 표(아직 rekordbox 실험으로 확인하지 않음)
    static let unverifiedReferenceTables = ["contentActiveCensor", "djmdActiveCensor", "djmdCloudExportSongPlaylist", "djmdSongHotCueBanklist",
                                            "djmdSongMyTag", "djmdSongRelatedTracks", "djmdSongRequestList", "djmdSongSampler", "djmdSongTagList"]

    // MARK: - 추가

    public static func add(_ plans: [TrackAddPlan], to database: URL = RekordboxWriter.liveDatabase, dryRun: Bool, now: Date = .now,
                           backups: URL, guard writeGuard: RekordboxWriteGuard = .system) throws -> Report {
        var report = Report(dryRun: dryRun)
        guard !plans.isEmpty else { return report }
        try preflight(database, dryRun: dryRun, guard: writeGuard)
        let stamp = CueJSON.timestamps(now)
        let backup = dryRun ? nil : try RekordboxWriter.makeBackup(of: database, in: backups, now: now, label: "add")
        report.backup = backup?.path
        var inserted: [(id: String, expected: [String: CipherDatabase.Value])] = []
        try transaction(database, dryRun: dryRun) { db, usn in
            let library = try libraryIdentity(db)
            for plan in plans {
                try db.execute("SAVEPOINT djc_add")
                do {
                    guard FileManager.default.fileExists(atPath: plan.path) else { throw Blocked("음원 파일이 없습니다") }
                    guard try RekordboxWriter.scalar(db, "SELECT count(*) FROM djmdContent WHERE FolderPath = ? AND rb_local_deleted = 0",
                                                     [.text(plan.path)]) == 0 else { throw Blocked("이미 rekordbox 컬렉션에 있는 파일입니다") }
                    let artistID = try plan.artist.map { try findOrCreate(db, table: "djmdArtist", name: $0, usn: &usn, stamp: stamp) }
                    let albumArtistID = try plan.albumArtist.map { try findOrCreate(db, table: "djmdArtist", name: $0, usn: &usn, stamp: stamp) }
                    let albumID = try plan.album.map { try findOrCreateAlbum(db, name: $0, albumArtistID: albumArtistID, usn: &usn, stamp: stamp) }
                    let genreID = try plan.genre.map { try findOrCreate(db, table: "djmdGenre", name: $0, usn: &usn, stamp: stamp) }
                    let composerID = try plan.composer.map { try findOrCreate(db, table: "djmdArtist", name: $0, usn: &usn, stamp: stamp) }
                    let id = try newID(db, table: "djmdContent", range: 1..<(1 << 28))
                    usn += 1
                    let row = contentRow(plan, id: id, uuid: UUID().uuidString.lowercased(), artistID: artistID, albumID: albumID,
                                         genreID: genreID, composerID: composerID, library: library, usn: usn, stamp: stamp)
                    try insert(db, table: "djmdContent", row)
                    try verify(db, table: "djmdContent", id: id, row)
                    try db.execute("RELEASE djc_add")
                    inserted.append((id, row))
                    report.added.append(Outcome(path: plan.path, contentID: id, title: plan.title, written: true, reason: nil))
                } catch let blocked as Blocked {
                    try db.execute("ROLLBACK TO djc_add")
                    try db.execute("RELEASE djc_add")
                    report.added.append(Outcome(path: plan.path, contentID: nil, title: plan.title, written: false, reason: blocked.reason))
                }
            }
            return !inserted.isEmpty
        }
        if !dryRun, !inserted.isEmpty {
            try afterCommit(database, backup: backup) { db in
                for item in inserted { try verify(db, table: "djmdContent", id: item.id, item.expected) }
            }
        }
        if let backup { try? save(report, in: backup) }
        return report
    }

    /// 분석 전 곡 행(78칸). 칸 형식(글자·정수·NULL)까지 rekordbox 7.2.18과 같게.
    static func contentRow(_ plan: TrackAddPlan, id: String, uuid: String, artistID: String?, albumID: String?, genreID: String?,
                           composerID: String?, library: (masterDBID: String, deviceID: String), usn: Int,
                           stamp: (json: String, db: String)) -> [String: CipherDatabase.Value] {
        func text(_ s: String?) -> CipherDatabase.Value { s.map { .text($0) } ?? .null }
        return [
            "ID": .text(id), "FolderPath": .text(plan.path), "FileNameL": .text(plan.fileName), "FileNameS": .text(""),
            "Title": .text(plan.title), "ArtistID": text(artistID), "AlbumID": text(albumID), "GenreID": text(genreID),
            "BPM": .int(0), "Length": .int(plan.length), "TrackNo": .int(plan.trackNumber), "BitRate": .int(0), "BitDepth": .int(0),
            "Commnt": .text(plan.comment), "FileType": .int(plan.fileType), "Rating": .int(0), "ReleaseYear": .int(plan.year),
            "RemixerID": .null, "LabelID": .null, "OrgArtistID": .null, "KeyID": .text("0"), "StockDate": .text(plan.stockDate),
            "ColorID": .text("0"), "DJPlayCount": .int(0), "ImagePath": .text(""), "MasterDBID": .text(library.masterDBID),
            "MasterSongID": .text(id), "AnalysisDataPath": .text(""), "SearchStr": .null, "FileSize": .int(plan.fileSize),
            "DiscNo": .int(plan.discNumber), "ComposerID": text(composerID), "Subtitle": .text(""), "SampleRate": .int(0),
            "DisableQuantize": .null, "Analysed": .int(0), "ReleaseDate": .text(""), "DateCreated": .text(plan.dateCreated),
            "ContentLink": .int(14), "Tag": .null, "ModifiedByRBM": .text(""), "HotCueAutoLoad": .text("on"), "DeliveryControl": .text("on"),
            "DeliveryComment": .text(""), "CueUpdated": .null, "AnalysisUpdated": .null, "TrackInfoUpdated": .null,
            "Lyricist": .text(plan.lyricist), "ISRC": .text(plan.isrc), "SamplerTrackInfo": .int(0), "SamplerPlayOffset": .int(0),
            "SamplerGain": .real(0), "VideoAssociate": .text("0"), "LyricStatus": .int(0), "ServiceID": .int(0), "OrgFolderPath": .text(""),
            "Reserved1": .text(""), "Reserved2": .null, "Reserved3": .null, "Reserved4": .null, "ExtInfo": .text("null"),
            "rb_file_id": .text(plan.fileID), "DeviceID": .text(library.deviceID), "rb_LocalFolderPath": .null, "SrcID": .null,
            "SrcTitle": .null, "SrcArtistName": .null, "SrcAlbumName": .null, "SrcLength": .null, "UUID": .text(uuid),
            "rb_data_status": .int(0), "rb_local_data_status": .int(0), "rb_local_deleted": .int(0), "rb_local_synced": .int(0),
            "usn": .null, "rb_local_usn": .int(usn), "created_at": .text(stamp.db), "updated_at": .text(stamp.db),
        ]
    }

    /// 이 라이브러리의 공통값(곡 행마다 같은 값)
    static func libraryIdentity(_ db: CipherDatabase) throws -> (masterDBID: String, deviceID: String) {
        var result: (String, String)?
        try db.query("""
            SELECT MasterDBID, DeviceID, count(*) AS n FROM djmdContent
            WHERE rb_local_deleted = 0 AND MasterDBID IS NOT NULL AND DeviceID IS NOT NULL AND DeviceID != ''
            GROUP BY MasterDBID, DeviceID ORDER BY n DESC LIMIT 1
            """) { result = ($0.string(0) ?? "", $0.string(1) ?? "") }
        guard let result, !result.0.isEmpty else {
            throw DJCError.writeRefused("컬렉션에 곡이 하나도 없어 이 라이브러리의 기기 정보를 알 수 없습니다. rekordbox에서 곡을 하나 넣은 뒤 다시 시도하세요")
        }
        return result
    }

    static func findOrCreate(_ db: CipherDatabase, table: String, name: String, usn: inout Int, stamp: (json: String, db: String)) throws -> String {
        var existing: String?
        try db.query("SELECT ID FROM \(table) WHERE Name = ? AND rb_local_deleted = 0 ORDER BY created_at LIMIT 1", [.text(name)]) { existing = $0.string(0) }
        if let existing { return existing }
        let id = try newID(db, table: table, range: 1..<(1 << 32))
        usn += 1
        var row: [String: CipherDatabase.Value] = ["ID": .text(id), "Name": .text(name), "UUID": .text(UUID().uuidString.lowercased())]
        if table == "djmdArtist" { row["SearchStr"] = .null }
        try insert(db, table: table, row.merging(syncColumns(usn: usn, stamp: stamp)) { a, _ in a })
        return id
    }

    static func findOrCreateAlbum(_ db: CipherDatabase, name: String, albumArtistID: String?, usn: inout Int,
                                  stamp: (json: String, db: String)) throws -> String {
        var existing: String?
        try db.query("SELECT ID FROM djmdAlbum WHERE Name = ? AND AlbumArtistID IS ? AND rb_local_deleted = 0 ORDER BY created_at LIMIT 1",
                     [.text(name), albumArtistID.map { .text($0) } ?? .null]) { existing = $0.string(0) }
        if let existing { return existing }
        let id = try newID(db, table: "djmdAlbum", range: 1..<(1 << 32))
        usn += 1
        let row: [String: CipherDatabase.Value] = ["ID": .text(id), "Name": .text(name), "AlbumArtistID": albumArtistID.map { .text($0) } ?? .null,
                                                   "ImagePath": .null, "Compilation": .int(0), "SearchStr": .null,
                                                   "UUID": .text(UUID().uuidString.lowercased())]
        try insert(db, table: "djmdAlbum", row.merging(syncColumns(usn: usn, stamp: stamp)) { a, _ in a })
        return id
    }

    static func syncColumns(usn: Int, stamp: (json: String, db: String)) -> [String: CipherDatabase.Value] {
        ["rb_data_status": .int(0), "rb_local_data_status": .int(0), "rb_local_deleted": .int(0), "rb_local_synced": .int(0),
         "usn": .null, "rb_local_usn": .int(usn), "created_at": .text(stamp.db), "updated_at": .text(stamp.db)]
    }

    // MARK: - 삭제

    public static func delete(contentIDs: [String], from database: URL = RekordboxWriter.liveDatabase, shareRoot: URL? = nil,
                              dryRun: Bool, now: Date = .now, backups: URL, guard writeGuard: RekordboxWriteGuard = .system) throws -> Report {
        var report = Report(dryRun: dryRun)
        guard !contentIDs.isEmpty else { return report }
        try preflight(database, dryRun: dryRun, guard: writeGuard)
        let share = shareRoot ?? (writeGuard.isLive(database) ? RekordboxShare.directory : nil)
        let stamp = CueJSON.timestamps(now)
        let backup = dryRun ? nil : try RekordboxWriter.makeBackup(of: database, in: backups, now: now, label: "delete")
        report.backup = backup?.path
        var gone: [String] = []
        var files: [URL] = []
        try transaction(database, dryRun: dryRun) { db, usn in
            for id in contentIDs {
                try db.execute("SAVEPOINT djc_delete")
                var title = id
                do {
                    var found: (title: String, path: String, artists: [String], album: String?, analysis: String?, image: String?)?
                    try db.query("""
                        SELECT Title, FolderPath, ArtistID, ComposerID, OrgArtistID, RemixerID, AlbumID, AnalysisDataPath, ImagePath
                        FROM djmdContent WHERE ID = ? AND rb_local_deleted = 0
                        """, [.text(id)]) { r in
                        found = (r.string(0) ?? "", r.string(1) ?? "", [2, 3, 4, 5].compactMap { r.string(Int32($0)) }, r.string(6), r.string(7), r.string(8))
                    }
                    guard let track = found else { throw Blocked("rekordbox 컬렉션에서 곡을 찾지 못했습니다") }
                    title = track.title
                    for table in unverifiedReferenceTables where try RekordboxWriter.scalar(db, "SELECT count(*) FROM \(table) WHERE ContentID = ?", [.text(id)]) ?? 0 > 0 {
                        throw Blocked("\(table)에도 들어 있는 곡이라 아직 지우지 않습니다(rekordbox에서 지우세요)")
                    }
                    usn += 1
                    for (table, list) in [("djmdSongPlaylist", "PlaylistID"), ("djmdSongHistory", "HistoryID")] {
                        var entries: [(list: String, trackNo: Int)] = []
                        try db.query("SELECT \(list), TrackNo FROM \(table) WHERE ContentID = ?", [.text(id)]) { entries.append(($0.string(0) ?? "", $0.int(1) ?? 0)) }
                        _ = try db.run("DELETE FROM \(table) WHERE ContentID = ?", [.text(id)])
                        // 같은 목록의 뒤 순번을 하나씩 당긴다(한 번호로 몰아서). 뒤에서부터 지운 순번만큼.
                        for entry in entries.sorted(by: { $0.trackNo > $1.trackNo }) {
                            _ = try db.run("UPDATE \(table) SET TrackNo = TrackNo - 1, rb_local_usn = ?, updated_at = ? WHERE \(list) = ? AND TrackNo > ?",
                                           [.int(usn), .text(stamp.db), .text(entry.list), .int(entry.trackNo)])
                        }
                    }
                    for table in ["djmdCue", "contentCue", "contentFile", "djmdMixerParam"] {
                        _ = try db.run("DELETE FROM \(table) WHERE ContentID = ?", [.text(id)])
                    }
                    guard try db.run("DELETE FROM djmdContent WHERE ID = ?", [.text(id)]) == 1 else { throw Blocked("곡 행을 지우지 못했습니다") }
                    // 그 곡만 쓰던 앨범·아티스트
                    if let album = track.album, try referenceCount(db, album: album) == 0 {
                        var albumArtist: String?
                        try db.query("SELECT AlbumArtistID FROM djmdAlbum WHERE ID = ?", [.text(album)]) { albumArtist = $0.string(0) }
                        _ = try db.run("DELETE FROM djmdAlbum WHERE ID = ?", [.text(album)])
                        if let albumArtist, try referenceCount(db, artist: albumArtist) == 0 { _ = try db.run("DELETE FROM djmdArtist WHERE ID = ?", [.text(albumArtist)]) }
                    }
                    for artist in Set(track.artists) where try referenceCount(db, artist: artist) == 0 {
                        _ = try db.run("DELETE FROM djmdArtist WHERE ID = ?", [.text(artist)])
                    }
                    guard try RekordboxWriter.scalar(db, "SELECT count(*) FROM djmdContent WHERE ID = ?", [.text(id)]) == 0 else {
                        throw DJCError.writeVerificationFailed("곡 행이 남아 있습니다")
                    }
                    try db.execute("RELEASE djc_delete")
                    gone.append(id)
                    if let share {
                        if let analysis = track.analysis, let dat = RekordboxShare.analysisURL(analysis, root: share) { files.append(dat.deletingLastPathComponent()) }
                        if let image = track.image, !image.isEmpty, let art = RekordboxShare.analysisURL(image, root: share) { files.append(art.deletingLastPathComponent()) }
                    }
                    report.deleted.append(Outcome(path: track.path, contentID: id, title: track.title, written: true, reason: nil))
                } catch let blocked as Blocked {
                    try db.execute("ROLLBACK TO djc_delete")
                    try db.execute("RELEASE djc_delete")
                    report.deleted.append(Outcome(path: "", contentID: id, title: title, written: false, reason: blocked.reason))
                }
            }
            return !gone.isEmpty
        }
        guard !dryRun, !gone.isEmpty else { return report }
        try afterCommit(database, backup: backup) { db in
            for id in gone where try RekordboxWriter.scalar(db, "SELECT count(*) FROM djmdContent WHERE ID = ?", [.text(id)]) != 0 {
                throw DJCError.writeVerificationFailed("지운 곡이 다시 읽혔습니다")
            }
        }
        // 분석 폴더·아트워크 파일: 백업 폴더로 옮겨 두고(되돌리기 때 살림) 원래 자리에서 지운다. 아트워크 폴더는 rekordbox처럼 남긴다.
        if let backup {
            var manifest: [String: String] = [:]
            let folder = backup.appending(path: "anlz")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for directory in files {
                let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                for item in items {
                    let name = "\(manifest.count).\(item.pathExtension)"
                    try FileManager.default.copyItem(at: item, to: folder.appending(path: name))
                    manifest[name] = item.path
                }
            }
            try JSONEncoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
            for path in manifest.values { try? FileManager.default.removeItem(atPath: path) }
            for directory in files where directory.path.contains("/USBANLZ/") { try? FileManager.default.removeItem(at: directory) }
            report.removedFiles = manifest.values.sorted()
            try? save(report, in: backup)
        }
        return report
    }

    static func referenceCount(_ db: CipherDatabase, artist: String) throws -> Int {
        let content = try RekordboxWriter.scalar(db, """
            SELECT count(*) FROM djmdContent WHERE ArtistID = ?1 OR ComposerID = ?1 OR OrgArtistID = ?1 OR RemixerID = ?1
            """, [.text(artist)]) ?? 1
        let albums = try RekordboxWriter.scalar(db, "SELECT count(*) FROM djmdAlbum WHERE AlbumArtistID = ?", [.text(artist)]) ?? 1
        return content + albums
    }

    static func referenceCount(_ db: CipherDatabase, album: String) throws -> Int {
        try RekordboxWriter.scalar(db, "SELECT count(*) FROM djmdContent WHERE AlbumID = ?", [.text(album)]) ?? 1
    }

    // MARK: - 공통

    struct Blocked: Error {
        var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// 라이브 DB면 rekordbox 꺼짐·WAL·버전, 어느 DB든 구조·카운터(백업 전에).
    static func preflight(_ database: URL, dryRun: Bool, guard writeGuard: RekordboxWriteGuard) throws {
        if writeGuard.isLive(database) { try writeGuard.checkLive(database, dryRun: dryRun) }
        let reader = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
        defer { reader.close() }
        try RekordboxCompatibility.checkSchema(reader)
        let counters = try RekordboxCompatibility.updateCounters(reader)
        if let local = counters.local { try RekordboxCompatibility.checkCounters(local: local, cloud: counters.cloud) }
    }

    /// 한 트랜잭션 안에서 `body`를 돌린다. 변경 카운터를 올려 적고, 시험 실행이거나 바뀐 게 없으면 되돌린다.
    static func transaction(_ database: URL, dryRun: Bool, _ body: (CipherDatabase, inout Int) throws -> Bool) throws {
        let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive(), writable: true)
        defer { db.close() }
        try db.execute("BEGIN IMMEDIATE")
        var finished = false
        defer { if !finished { try? db.execute("ROLLBACK") } }
        var usn = try RekordboxWriter.localUpdateCount(db)
        let start = usn
        let changed = try body(db, &usn)
        if usn != start {
            guard try db.run("UPDATE agentRegistry SET int_1 = ? WHERE registry_id = 'localUpdateCount'", [.int(usn)]) == 1 else {
                throw DJCError.writeVerificationFailed("변경 카운터를 올리지 못했습니다")
            }
        }
        if dryRun || !changed {
            try db.execute("ROLLBACK")
        } else {
            try db.execute("COMMIT")
            try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        finished = true
    }

    /// 커밋 뒤 무결성 검사와 다시 읽기. 실패하면 백업으로 되돌린다.
    static func afterCommit(_ database: URL, backup: URL?, _ check: (CipherDatabase) throws -> Void) throws {
        do {
            try RekordboxWriter.checkIntegrity(of: database)
            let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
            defer { db.close() }
            try check(db)
        } catch {
            if let backup { try? RekordboxWriter.restoreFiles(from: backup, to: database) }
            throw DJCError.writeVerificationFailed("\(error)")
        }
    }

    static func newID(_ db: CipherDatabase, table: String, range: Range<Int>) throws -> String {
        for _ in 0..<100 {
            let id = String(Int.random(in: range))
            if try RekordboxWriter.scalar(db, "SELECT count(*) FROM \(table) WHERE ID = ?", [.text(id)]) == 0 { return id }
        }
        throw DJCError.writeVerificationFailed("\(table) 새 ID를 만들지 못했습니다")
    }

    static func insert(_ db: CipherDatabase, table: String, _ row: [String: CipherDatabase.Value]) throws {
        let keys = row.keys.sorted()
        let sql = "INSERT INTO \(table) (\(keys.map { "\"\($0)\"" }.joined(separator: ", "))) VALUES (\(keys.map { _ in "?" }.joined(separator: ", ")))"
        guard try db.run(sql, keys.map { row[$0]! }) == 1 else { throw DJCError.writeVerificationFailed("\(table) 행을 넣지 못했습니다") }
    }

    /// 넣은 행을 다시 읽어 칸마다(형식까지) 비교한다.
    static func verify(_ db: CipherDatabase, table: String, id: String, _ expected: [String: CipherDatabase.Value]) throws {
        let keys = expected.keys.sorted()
        var ok = false
        try db.query("SELECT \(keys.map { "\"\($0)\", typeof(\"\($0)\")" }.joined(separator: ", ")) FROM \(table) WHERE ID = ?", [.text(id)]) { r in
            ok = keys.enumerated().allSatisfy { i, key in
                let type = r.string(Int32(i * 2 + 1))
                switch expected[key]! {
                case .null: return type == "null"
                case let .text(value): return type == "text" && r.string(Int32(i * 2)) == value
                case let .int(value): return type == "integer" && r.int(Int32(i * 2)) == value
                case let .real(value): return type == "real" && r.double(Int32(i * 2)) == value
                }
            }
        }
        guard ok else { throw DJCError.writeVerificationFailed("\(table) \(id) 행이 넣은 값과 다릅니다") }
    }

    static func save(_ report: Report, in backup: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: backup.appending(path: "track-report.json"), options: .atomic)
    }
}
