import CryptoKit
import DJCDomain
import Foundation

/// rekordbox 컬렉션에 곡을 넣고 뺀다(rekordbox를 켜지 않고).
///
/// rekordbox 7.2.18 실험(2026-09-26, 묶음 1·2)에서 확인한 모양을 따른다:
/// - 추가(분석 전): `djmdContent` 행 하나 + 새 이름이면 `djmdArtist`·`djmdAlbum`·`djmdGenre` 행. 분석 파일·파일 행·오토게인 행은 없다.
///   곡 ID는 1~2^28 난수, 아티스트 등은 32비트 난수. 관련 행 번호(usn)를 먼저 받고 곡 행이 마지막 번호를 받는다.
/// - 음원에 아트워크가 있으면 아트워크 파일 셋(`TrackArtwork`)·`ImagePath`·`artwork.jpg` 파일 행도 넣는다(`writesArtwork`가 열렸을 때).
/// - 삭제: 행을 실제로 지운다(삭제 표시가 아님). 곡 행·큐(`djmdCue`·`contentCue`)·파일 행·오토게인 행·재생 목록·재생 이력 항목.
///   같은 목록·이력의 뒤 순번은 하나씩 당기고(한 번호로 몰아서), 그 곡만 쓰던 아티스트·앨범 행도 지운다. 분석 폴더·아트워크 파일도 지운다.
///   재생 목록 순번 당기기는 재생 이력에서 본 것을 따른 추정이다.
/// - 확인하지 않은 표(MyTag·핫큐 뱅크·샘플러·관련 곡·신청곡·검열 구간·클라우드 내보내기)에 걸린 곡은 지우지 않는다.
///
/// 안전장치는 큐 쓰기(`RekordboxWriter`)와 같다: 사전 확인 → 전체 백업 → 한 트랜잭션 → 다시 읽어 검증 → 무결성 검사 → 실패 시 복원.
/// 커밋 뒤 실패는 복원했으면 `writeRolledBack`, 복원도 못 했으면 `restoreFailed`로 알린다.
public enum RekordboxTrackWriter {
    public struct Outcome: Codable, Hashable, Sendable {
        public var path: String
        public var contentID: String?
        public var title: String
        public var written: Bool
        public var reason: String?
        /// 넣은 곡의 UUID(초안을 새 곡으로 옮길 때 쓴다)
        public var uuid: String?
        /// 곡과 함께 넣은 큐 수(큐를 주지 않았거나 막혔으면 nil)
        public var cuesWritten: Int?
        /// 큐를 넣지 못한 이유(곡은 넣었다)
        public var cueReason: String?
    }

    public struct Report: Codable, Sendable {
        public var added: [Outcome] = []
        public var deleted: [Outcome] = []
        public var backup: String?
        public var dryRun: Bool
        /// 지운 곡의 분석·아트워크 파일(백업 폴더 `anlz/`로 옮겨 두었다가 되돌릴 때 살린다)
        public var removedFiles: [String] = []
        /// 새로 만든 분석·아트워크 파일(되돌릴 때 지운다)
        public var createdFiles: [String] = []
        /// 쓴 직후 rekordbox 변경 카운터. 되돌리기 전에 그 뒤 rekordbox에서 바뀐 게 있는지 본다.
        public var finalUpdateCount: Int?

        /// 실제로 넣거나 뺀 곡 이름
        public var titles: [String] { (added + deleted).filter(\.written).map(\.title) }
    }

    /// 곡과 함께 붙일 분석(그리드·음량). 파형·음원 정보는 쓰기 모듈이 음원에서 직접 만든다.
    public struct Analysis: Sendable {
        /// rekordbox 시간축 그리드 구간
        public var segments: [GridSegment]
        /// 통합 음량(LUFS). nil이면 오토게인 0dB.
        public var loudness: Double?
        /// 샘플 피크(선형, 0~1)
        public var peak: Double

        public init(segments: [GridSegment], loudness: Double?, peak: Double) {
            self.segments = segments
            self.loudness = loudness
            self.peak = peak
        }
    }

    /// 분석까지 붙인 곡의 `ContentLink`(프레이즈·보컬 분석 없음, 라이브러리 426곡이 쓰는 값)
    static let analysedContentLink = 0x2C060E

    /// 곡을 넣을 때 음원 내장 아트워크도 넣는지(#4). 파일·칸 모양은 라이브러리로 확인했고,
    /// rekordbox가 아트워크 든 곡을 넣을 때의 변경 번호 순서를 실험으로 확인하기 전까지 닫아 둔다.
    public static let writesArtwork = false

    /// 지울 곡을 막는 표(아직 rekordbox 실험으로 확인하지 않음)
    static let unverifiedReferenceTables = ["contentActiveCensor", "djmdActiveCensor", "djmdCloudExportSongPlaylist", "djmdSongHotCueBanklist",
                                            "djmdSongMyTag", "djmdSongRelatedTracks", "djmdSongRequestList", "djmdSongSampler", "djmdSongTagList"]

    // MARK: - 추가

    /// - Parameters:
    ///   - analyses: 경로마다 붙일 분석. 있으면 분석 파일(.DAT·.EXT·.2EX)·파일 행·오토게인 행까지 넣는다(CBR MP3·AAC·WAV만).
    ///   - shareRoot: 분석 파일 뿌리. 라이브 DB면 rekordbox share 폴더, 사본이면 명시해야 분석을 붙인다.
    ///   - cues: 경로마다 함께 넣을 큐. 곡을 넣은 같은 트랜잭션에서 큐 쓰기(`RekordboxWriter`)와 같은 규칙으로 쓴다.
    ///     큐가 막히면 곡만 넣고 이유를 `cueReason`에 남긴다.
    ///   - writesArtwork: 음원 내장 아트워크로 아트워크 파일 셋·`ImagePath`·파일 행을 넣는지(share가 있을 때만). 앱은 `writesArtwork`를 따른다.
    public static func add(_ plans: [TrackAddPlan], analyses: [String: Analysis] = [:], cues: [String: [EditableCue]] = [:],
                           to database: URL = RekordboxWriter.liveDatabase,
                           shareRoot: URL? = nil, dryRun: Bool, now: Date = .now, backups: URL,
                           guard writeGuard: RekordboxWriteGuard = .system,
                           writesArtwork: Bool = RekordboxTrackWriter.writesArtwork) throws -> Report {
        var report = Report(dryRun: dryRun)
        guard !plans.isEmpty else { return report }
        try preflight(database, dryRun: dryRun, guard: writeGuard)
        let live = writeGuard.isLive(database)
        let share = shareRoot ?? (live ? RekordboxShare.directory : nil)
        // 곡 UUID를 먼저 정한다(분석·아트워크 폴더 이름이 된다)
        let uuids = Dictionary(plans.map { ($0.path, UUID().uuidString.lowercased()) }) { first, _ in first }
        // 분석·아트워크 파일은 DB 밖에서 미리 만든다(오래 걸리고 실패해도 DB를 건드리기 전에 알 수 있게)
        var prepared: [String: PreparedAnalysis] = [:]
        var artworks: [String: PreparedArtwork] = [:]
        for plan in plans {
            let uuid = uuids[plan.path]!
            if writesArtwork, let share, let image = plan.artwork, let files = TrackArtwork.make(image) {
                artworks[plan.path] = PreparedArtwork(uuid: uuid, files: files, share: share)
            }
            guard let analysis = analyses[plan.path] else { continue }
            do {
                prepared[plan.path] = try prepare(path: plan.path, fileName: plan.fileName, duration: plan.duration, uuid: uuid,
                                                  analysis: analysis, share: share)
            } catch {
                prepared[plan.path] = PreparedAnalysis(uuid: uuid, blocked: "분석 파일을 만들지 못했습니다: \(error)")
            }
        }
        let stamp = CueJSON.timestamps(now)
        let backup = dryRun ? nil : try RekordboxWriter.makeBackup(of: database, in: backups, now: now, label: "add")
        report.backup = backup?.path
        var inserted: [(id: String, expected: [String: CipherDatabase.Value])] = []
        /// 곡과 함께 넣은 파일 행·오토게인 행(커밋 뒤 다시 읽어 비교)
        var extraRows: [InsertedRow] = []
        var cueChecks: [(contentID: String, expectation: RekordboxWriter.Expectation)] = []
        report.finalUpdateCount = try transaction(database, dryRun: dryRun) { db, usn in
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
                    let ready = prepared[plan.path]
                    if let reason = ready?.blocked { throw Blocked(reason) }
                    let uuid = uuids[plan.path]!
                    let artwork = artworks[plan.path]
                    usn += 1
                    var row = contentRow(plan, id: id, uuid: uuid, artistID: artistID, albumID: albumID,
                                         genreID: genreID, composerID: composerID, library: library, usn: usn, stamp: stamp)
                    if let ready { row.merge(ready.columns) { _, new in new } }
                    if let artwork { row["ImagePath"] = .text(artwork.imagePath) }
                    try insert(db, table: "djmdContent", row)
                    try verify(db, table: "djmdContent", id: id, row)
                    var planRows: [InsertedRow] = []
                    if let artwork {
                        // 아트워크 파일 행은 artwork.jpg 하나(_m·_s는 행이 없다)
                        usn += 1
                        let file = fileRow(uuid: uuid, share: artwork.share, artwork.files[0], contentID: id, usn: usn, stamp: stamp)
                        try insert(db, table: file.table, file.values)
                        try verify(db, table: file.table, id: file.id, file.values)
                        planRows.append(file)
                    }
                    if let ready {
                        for row in try insertAnalysisRows(db, ready, contentID: id, usn: &usn, stamp: stamp) {
                            try verify(db, table: row.table, id: row.id, row.values)
                            planRows.append(row)
                        }
                    }
                    var outcome = Outcome(path: plan.path, contentID: id, title: plan.title, written: true, reason: nil, uuid: uuid)
                    if let list = cues[plan.path], !list.isEmpty {
                        var draft = CueDraft(trackUUID: uuid, rekordboxCues: [])
                        for cue in list { draft.place(cue) }
                        try db.execute("SAVEPOINT djc_add_cues")
                        do {
                            let result = try RekordboxWriter.apply(draft, db: db, usn: &usn, stamp: stamp)
                            if let expectation = result.expectation {
                                try RekordboxWriter.verify(db: db, contentID: id, expectation)
                                cueChecks.append((id, expectation))
                                // 큐를 쓰면 곡 행의 CueUpdated·변경 번호가 바뀐다
                                row["CueUpdated"] = .text(String(result.outcome.added))
                                row["rb_local_usn"] = .int(expectation.contentUSN)
                                outcome.cuesWritten = result.outcome.added
                            }
                            try db.execute("RELEASE djc_add_cues")
                        } catch let blocked as RekordboxWriter.Blocked {
                            try db.execute("ROLLBACK TO djc_add_cues")
                            try db.execute("RELEASE djc_add_cues")
                            outcome.cueReason = blocked.reason
                        }
                    }
                    try db.execute("RELEASE djc_add")
                    inserted.append((id, row))
                    extraRows += planRows
                    report.added.append(outcome)
                } catch let blocked as Blocked {
                    try db.execute("ROLLBACK TO djc_add")
                    try db.execute("RELEASE djc_add")
                    report.added.append(Outcome(path: plan.path, contentID: nil, title: plan.title, written: false, reason: blocked.reason))
                }
            }
            return !inserted.isEmpty
        }
        if let backup, !inserted.isEmpty {
            try afterCommit(database, backup: backup, live: live) { db in
                for item in inserted { try verify(db, table: "djmdContent", id: item.id, item.expected) }
                for row in extraRows { try verify(db, table: row.table, id: row.id, row.values) }
                for check in cueChecks { try RekordboxWriter.verify(db: db, contentID: check.contentID, check.expectation) }
            }
            // 분석·아트워크 파일: DB가 끝난 뒤 쓴다. 실패하면 쓴 파일과 만든 빈 폴더를 지우고 DB를 되돌린다.
            let written = report.added.filter(\.written).map(\.path)
            var created: [URL] = []
            do {
                for path in written {
                    let analysisFiles = prepared[path].flatMap { $0.blocked == nil ? $0.files : nil } ?? []
                    for (url, data) in analysisFiles + (artworks[path]?.files ?? []) {
                        guard !FileManager.default.fileExists(atPath: url.path) else { throw DJCError.writeVerificationFailed("파일이 이미 있습니다: \(url.path)") }
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: url, options: .atomic)
                        created.append(url)
                        guard try Data(contentsOf: url) == data else { throw DJCError.writeVerificationFailed("파일 확인 실패: \(url.lastPathComponent)") }
                    }
                }
            } catch {
                throw RekordboxWriter.recover(from: error, database: database, backup: backup, live: live) {
                    try RekordboxWriter.removeAnalysisFiles(created)
                }
            }
            report.createdFiles = created.map(\.path)
        }
        if let backup { try? save(report, in: backup) }
        return report
    }

    /// DB 밖에서 미리 만든 분석(파일 바이트·곡 행 분석 칸·파일 행·오토게인)
    struct PreparedAnalysis {
        var uuid: String
        var columns: [String: CipherDatabase.Value] = [:]
        var files: [(URL, Data)] = []
        var gain: (high: Int, low: Int) = (0, 0)
        var peak: (high: Int, low: Int) = (0, 0)
        var share: URL?
        /// 분석을 붙일 수 없는 이유(곡을 넣지 않는다)
        var blocked: String?
        /// PQTZ 박 수
        var beats = 0
    }

    /// DB 밖에서 미리 만든 아트워크 파일 셋(`artwork.jpg`·`_m`·`_s` 순서, 파일 행은 첫 파일만)
    struct PreparedArtwork {
        var imagePath: String
        var files: [(URL, Data)]
        var share: URL

        init(uuid: String, files: TrackArtwork.Files, share: URL) {
            imagePath = TrackArtwork.imagePath(uuid: uuid)
            let folder = share.appending(path: String(TrackArtwork.folder(uuid: uuid).dropFirst()))
            self.files = zip(TrackArtwork.fileNames, [files.full, files.medium, files.small]).map { (folder.appending(path: $0), $1) }
            self.share = share
        }
    }

    /// 곡 UUID로 정하는 분석 폴더(`/PIONEER/USBANLZ/<앞 3자>/<나머지>`)
    static func analysisFolder(uuid: String) -> String { "/PIONEER/USBANLZ/\(uuid.prefix(3))/\(uuid.dropFirst(3))" }

    /// 곡 넣기와 분석 붙이기(`RekordboxWriter+Analysis`)가 함께 쓰는 레시피. 분석 폴더는 곡 UUID로 정한다.
    /// - Parameter duration: AVFoundation 길이(초). `Length`에 버림해 적는다.
    static func prepare(path: String, fileName: String, duration: Double, uuid: String, analysis: Analysis,
                        share: URL?) throws -> PreparedAnalysis {
        var ready = PreparedAnalysis(uuid: uuid, share: share)
        guard let share else { ready.blocked = "사본 DB에는 분석 파일 뿌리(share)를 주어야 분석을 붙입니다"; return ready }
        let url = URL(filePath: path)
        let facts = AudioFacts.read(url: url)
        if let reason = facts.unsupported { ready.blocked = reason; return ready }
        guard let first = analysis.segments.first, first.bpm > 0 else { ready.blocked = "그리드가 없습니다"; return ready }
        let waveforms = try RekordboxWaveforms.analyze(url: url)
        let waveformDuration = Double(waveforms.columns) / RekordboxWaveforms.columnsPerSecond
        let beats = RekordboxGridWriter.beats(segments: analysis.segments, duration: waveformDuration)
        ready.beats = beats.count
        let files = try TrackAnalysisFiles.make(fileName: fileName, beats: beats, waveforms: waveforms, facts: facts)
        let folder = analysisFolder(uuid: uuid)
        let datPath = folder + "/ANLZ0000.DAT"
        ready.files = [("DAT", files.dat), ("EXT", files.ext), ("2EX", files.twoEx)].map { ext, data in
            (share.appending(path: String(folder.dropFirst()) + "/ANLZ0000.\(ext)"), data)
        }
        ready.columns = [
            "BPM": .int(Int((first.bpm * 100).rounded())), "Length": .int(Int(duration.rounded(.down))),
            "BitRate": .int(facts.bitRate), "BitDepth": .int(facts.bitDepth), "SampleRate": .int(facts.sampleRate),
            "AnalysisDataPath": .text(datPath), "Analysed": .int(105), "ContentLink": .int(analysedContentLink),
            "AnalysisUpdated": .text("3"), "TrackInfoUpdated": .text("2"),
        ]
        // 오토게인: rekordbox는 약 −10 LUFS에 맞춘다(라이브러리 비교 2026-09-26)
        let gainDB = analysis.loudness.map { RekordboxAutoGain.targetLoudness - $0 } ?? 0
        ready.gain = RekordboxAutoGain.halves(Float(pow(10, gainDB / 20)))
        ready.peak = RekordboxAutoGain.halves(Float(min(max(analysis.peak, 0), 1)))
        return ready
    }

    /// 파일 행(.DAT·.EXT·.2EX)과 오토게인 행. 넣은 행을 돌려준다(다시 읽어 비교할 때 쓴다).
    @discardableResult
    static func insertAnalysisRows(_ db: CipherDatabase, _ ready: PreparedAnalysis, contentID: String, usn: inout Int,
                                   stamp: (db: String, json: String)) throws -> [InsertedRow] {
        guard ready.share != nil else { return [] }
        var inserted: [InsertedRow] = []
        for file in ready.files {
            usn += 1
            inserted.append(fileRow(ready, file, contentID: contentID, usn: usn, stamp: stamp))
        }
        usn += 1
        inserted.append(mixerRow(ready, contentID: contentID, usn: usn, stamp: stamp))
        for row in inserted { try insert(db, table: row.table, row.values) }
        return inserted
    }

    /// 분석 파일 하나의 `contentFile` 행(ID = `<곡 UUID>_<경로, /는 %2F>`, MD5·크기·로컬 경로)
    static func fileRow(_ ready: PreparedAnalysis, _ file: (url: URL, data: Data), contentID: String, usn: Int,
                        stamp: (db: String, json: String)) -> InsertedRow {
        fileRow(uuid: ready.uuid, share: ready.share, file, contentID: contentID, usn: usn, stamp: stamp)
    }

    /// share 아래 파일 하나의 `contentFile` 행. 분석 파일과 아트워크(`artwork.jpg`) 행이 같은 칸 모양이다(라이브러리 조사 2026-09-26).
    static func fileRow(uuid: String, share root: URL?, _ file: (url: URL, data: Data), contentID: String, usn: Int,
                        stamp: (db: String, json: String)) -> InsertedRow {
        let share = root?.path ?? ""
        let path = "/" + file.url.path.dropFirst(share.count).drop(while: { $0 == "/" })
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? path
        let row: [String: CipherDatabase.Value] = [
            "ID": .text("\(uuid)_\(encoded)"), "ContentID": .text(contentID), "Path": .text(path),
            "Hash": .text(Insecure.MD5.hash(data: file.data).map { String(format: "%02x", $0) }.joined()), "Size": .int(file.data.count),
            "rb_local_path": .text(file.url.path), "rb_insync_hash": .null, "rb_insync_local_usn": .null, "rb_file_hash_dirty": .int(0),
            "rb_local_file_status": .int(0), "rb_in_progress": .int(0), "rb_process_type": .int(0), "rb_temp_path": .null,
            "rb_priority": .int(50), "rb_file_size_dirty": .int(0), "UUID": .text(UUID().uuidString.lowercased()),
        ]
        return InsertedRow(table: "contentFile", values: row.merging(syncColumns(usn: usn, stamp: stamp)) { a, _ in a })
    }

    /// 오토게인 `djmdMixerParam` 행
    static func mixerRow(_ ready: PreparedAnalysis, contentID: String, usn: Int, stamp: (db: String, json: String)) -> InsertedRow {
        let mixer: [String: CipherDatabase.Value] = [
            "ID": .text(UUID().uuidString.lowercased()), "ContentID": .text(contentID), "GainHigh": .int(ready.gain.high),
            "GainLow": .int(ready.gain.low), "PeakHigh": .int(ready.peak.high), "PeakLow": .int(ready.peak.low),
            "UUID": .text(UUID().uuidString.lowercased()),
        ]
        return InsertedRow(table: "djmdMixerParam", values: mixer.merging(syncColumns(usn: usn, stamp: stamp)) { a, _ in a })
    }

    /// 넣은 행 하나(표·칸 값)
    struct InsertedRow {
        var table: String
        var values: [String: CipherDatabase.Value]
        var id: String { if case let .text(id)? = values["ID"] { id } else { "" } }
    }

    /// 분석 전 곡 행(78칸). 칸 형식(글자·정수·NULL)까지 rekordbox 7.2.18과 같게.
    static func contentRow(_ plan: TrackAddPlan, id: String, uuid: String, artistID: String?, albumID: String?, genreID: String?,
                           composerID: String?, library: (masterDBID: String, deviceID: String), usn: Int,
                           stamp: (db: String, json: String)) -> [String: CipherDatabase.Value] {
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

    static func findOrCreate(_ db: CipherDatabase, table: String, name: String, usn: inout Int, stamp: (db: String, json: String)) throws -> String {
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
                                  stamp: (db: String, json: String)) throws -> String {
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

    static func syncColumns(usn: Int, stamp: (db: String, json: String)) -> [String: CipherDatabase.Value] {
        ["rb_data_status": .int(0), "rb_local_data_status": .int(0), "rb_local_deleted": .int(0), "rb_local_synced": .int(0),
         "usn": .null, "rb_local_usn": .int(usn), "created_at": .text(stamp.db), "updated_at": .text(stamp.db)]
    }

    // MARK: - 삭제

    public static func delete(contentIDs: [String], from database: URL = RekordboxWriter.liveDatabase, shareRoot: URL? = nil,
                              dryRun: Bool, now: Date = .now, backups: URL, guard writeGuard: RekordboxWriteGuard = .system) throws -> Report {
        var report = Report(dryRun: dryRun)
        guard !contentIDs.isEmpty else { return report }
        try preflight(database, dryRun: dryRun, guard: writeGuard)
        let live = writeGuard.isLive(database)
        let share = shareRoot ?? (live ? RekordboxShare.directory : nil)
        let stamp = CueJSON.timestamps(now)
        let backup = dryRun ? nil : try RekordboxWriter.makeBackup(of: database, in: backups, now: now, label: "delete")
        report.backup = backup?.path
        var gone: [String] = []
        var files: [URL] = []
        report.finalUpdateCount = try transaction(database, dryRun: dryRun) { db, usn in
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
        // 백업은 시험 실행이 아닐 때만 있다
        guard let backup, !gone.isEmpty else { return report }
        try afterCommit(database, backup: backup, live: live) { db in
            for id in gone where try RekordboxWriter.scalar(db, "SELECT count(*) FROM djmdContent WHERE ID = ?", [.text(id)]) != 0 {
                throw DJCError.writeVerificationFailed("지운 곡이 다시 읽혔습니다")
            }
        }
        // 분석 폴더·아트워크 파일: 백업 폴더로 옮겨 두고(되돌리기 때 살림) 원래 자리에서 지운다. 아트워크 폴더는 rekordbox처럼 남긴다.
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
    /// 커밋했으면 마지막 변경 카운터를 돌려준다.
    @discardableResult
    static func transaction(_ database: URL, dryRun: Bool, _ body: (CipherDatabase, inout Int) throws -> Bool) throws -> Int? {
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
            finished = true
            return nil
        }
        try db.execute("COMMIT")
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        finished = true
        return usn
    }

    /// 커밋 뒤 무결성 검사와 다시 읽기. 실패하면 백업으로 되돌린다(되돌리지 못하면 `restoreFailed`).
    static func afterCommit(_ database: URL, backup: URL, live: Bool, _ check: (CipherDatabase) throws -> Void) throws {
        do {
            try RekordboxWriter.checkIntegrity(of: database)
            let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
            defer { db.close() }
            try check(db)
        } catch {
            throw RekordboxWriter.recover(from: error, database: database, backup: backup, live: live)
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

    /// 백업 폴더의 곡 추가·삭제 보고서
    public static func report(in backup: URL) -> Report? {
        (try? Data(contentsOf: backup.appending(path: "track-report.json"))).flatMap { try? JSONDecoder().decode(Report.self, from: $0) }
    }

    static func save(_ report: Report, in backup: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: backup.appending(path: "track-report.json"), options: .atomic)
    }
}
