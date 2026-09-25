import Foundation

/// anicue 큐 초안을 rekordbox `master.db`에 직접 쓴다.
///
/// rekordbox 7.2.18이 직접 큐를 고쳤을 때 DB가 바뀐 모양을 비교해 그대로 따른다(2026-09-26 확인):
/// - `djmdCue`: 지운 큐는 행을 지우고, 새 큐는 새 행(ID는 32비트 난수, UUID 새로)으로 넣는다.
/// - `contentCue.Cues`(JSON): 남은 큐는 원문 그대로 두고, 지운 큐를 빼고, 새 큐를 끝에 붙인다. `rb_cue_count`는 큐 수.
/// - `contentCue`·`djmdContent`: 동기화 상태 256 → 257, `rb_local_usn`은 전역 카운터(`agentRegistry.localUpdateCount`)를
///   하나씩 올려 받는다. `djmdContent.CueUpdated`는 고친 횟수만큼 늘린다.
/// 옮긴 큐는 지우고 새로 넣는다. FLAC은 rekordbox처럼 프레임 탐색 위치(SeekInfo)를 계산해 적는다.
/// 루프를 옮기는 것과 VBR MP3(MPEG 탐색 위치 규칙 미확인)는 막는다.
///
/// 안전장치: rekordbox(에이전트 포함)가 켜져 있으면 라이브 DB에 쓰지 않는다. 쓰기 전에 DB를 통째로 백업하고, 한
/// 트랜잭션 안에서 쓰고 다시 읽어 검증한 뒤에만 커밋한다. 커밋 뒤 무결성 검사·재검증이 실패하면 백업으로 되돌린다.
/// 초안을 시작한 뒤 rekordbox에서 그 곡의 큐가 바뀌었으면 그 곡은 쓰지 않는다.
public enum RekordboxWriter {
    public struct Outcome: Codable, Hashable, Sendable {
        public enum Status: String, Codable, Sendable {
            case written
            case blocked
            case unchanged
        }

        public var trackUUID: String
        public var title: String
        public var status: Status
        public var reason: String?
        public var removed: Int
        public var added: Int
    }

    public struct Report: Codable, Sendable {
        public var outcomes: [Outcome]
        /// 쓰기 전 백업 폴더(시험 실행이면 nil)
        public var backup: String?
        public var dryRun: Bool
        public var createdAt: String
        /// 쓴 직후 rekordbox 변경 카운터. 되돌리기 전에 지금 값과 비교해 그 뒤 rekordbox에서 바뀐 게 있는지 본다.
        public var finalUpdateCount: Int?
        /// 그리드(분석 파일) 쓰기 결과. 옛 보고서에는 없다.
        public var gridOutcomes: [Outcome]?
        /// 오토게인 쓰기 결과(added = 새 게인 ×100 dB). 옛 보고서에는 없다.
        public var gainOutcomes: [Outcome]?

        public var written: [Outcome] { outcomes.filter { $0.status == .written } }
        public var blocked: [Outcome] { outcomes.filter { $0.status == .blocked } }
        public var gridWritten: [Outcome] { (gridOutcomes ?? []).filter { $0.status == .written } }
        public var gridBlocked: [Outcome] { (gridOutcomes ?? []).filter { $0.status == .blocked } }
        public var gainWritten: [Outcome] { (gainOutcomes ?? []).filter { $0.status == .written } }
        public var gainBlocked: [Outcome] { (gainOutcomes ?? []).filter { $0.status == .blocked } }
    }

    public static var liveDatabase: URL { LibrarySnapshot.rekordboxDirectory.appending(path: "master.db") }

    public static var backupDirectory: URL { AnicuePaths.userData.appending(path: "rekordbox-backups") }

    /// 백업은 한 개에 150MB 안팎이다. 최근 이만큼만 남긴다.
    static let backupsToKeep = 5

    static func isLive(_ database: URL) -> Bool {
        database.resolvingSymlinksInPath().standardizedFileURL.path
            == liveDatabase.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - 쓰기

    /// 초안들을 쓴다. `dryRun`이면 같은 과정을 모두 거친 뒤 되돌린다(스냅샷 사본으로 미리 보기).
    /// - Parameters:
    ///   - grids: 그리드 초안. 분석 파일(`shareRoot` 아래)을 고친다.
    ///   - shareRoot: 분석 파일 뿌리. 라이브 DB면 rekordbox share 폴더, 사본 DB면 명시해야 그리드를 쓴다(실제 파일을 건드리지 않게).
    public static func write(drafts: [CueDraft], grids: [GridDraft] = [], gains: [String: Double] = [:],
                             to database: URL = liveDatabase, dryRun: Bool,
                             now: Date = .now, backups: URL = backupDirectory, shareRoot: URL? = nil) throws -> Report {
        let stamp = CueJSON.timestamps(now)
        let grids = grids.filter(\.hasChanges)
        guard drafts.contains(where: \.hasChanges) || !grids.isEmpty || !gains.isEmpty else {
            // 쓸 것이 없으면 DB를 열지도, 백업을 만들지도 않는다.
            return Report(outcomes: drafts.map { Outcome(trackUUID: $0.trackUUID, title: $0.trackUUID, status: .unchanged,
                                                          reason: nil, removed: 0, added: 0) },
                          backup: nil, dryRun: dryRun, createdAt: stamp.json, finalUpdateCount: nil)
        }
        let live = isLive(database)
        let gridRoot = shareRoot ?? (live ? RekordboxShare.directory : nil)
        if live {
            guard !dryRun else { throw AnicueError.writeRefused("미리 보기는 스냅샷 사본으로만 합니다") }
            guard !LibrarySnapshot.isRekordboxRunning() else {
                throw AnicueError.writeRefused("rekordbox가 켜져 있습니다. rekordbox를 완전히 종료한 뒤 다시 시도하세요")
            }
            let wal = URL(filePath: database.path + "-wal")
            if let size = (try? FileManager.default.attributesOfItem(atPath: wal.path))?[.size] as? Int, size > 0 {
                throw AnicueError.writeRefused("rekordbox가 정상적으로 종료되지 않은 것 같습니다(WAL 파일이 남아 있음). rekordbox를 한 번 켰다가 종료한 뒤 다시 시도하세요")
            }
        }
        // 그리드 계획(파일을 읽기만 한다)
        var gridPlans: [RekordboxGridWriter.Plan] = []
        var gridOutcomes: [Outcome] = []
        if !grids.isEmpty {
            let reader = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
            for draft in grids {
                var info: (title: String, anlz: String?, bpm: Int, path: String)?
                try reader.query("SELECT Title, AnalysisDataPath, BPM, FolderPath FROM djmdContent WHERE UUID = ? AND rb_local_deleted = 0",
                                 [.text(draft.trackUUID)]) { r in info = (r.string(0) ?? "", r.string(1), r.int(2) ?? 0, r.string(3) ?? "") }
                guard let info else {
                    gridOutcomes.append(Outcome(trackUUID: draft.trackUUID, title: draft.trackUUID, status: .blocked,
                                                reason: "rekordbox 컬렉션에서 곡을 찾지 못했습니다", removed: 0, added: 0))
                    continue
                }
                guard let gridRoot else {
                    gridOutcomes.append(Outcome(trackUUID: draft.trackUUID, title: info.title, status: .blocked,
                                                reason: "사본 DB에는 분석 파일 경로를 따로 주어야 그리드를 씁니다", removed: 0, added: 0))
                    continue
                }
                do {
                    let plan = try RekordboxGridWriter.plan(draft: draft, title: info.title, analysisDataPath: info.anlz,
                                                            rekordboxBPM100: info.bpm, audioPath: info.path, shareRoot: gridRoot)
                    gridPlans.append(plan)
                    gridOutcomes.append(Outcome(trackUUID: draft.trackUUID, title: info.title, status: .written, reason: nil,
                                                removed: 0, added: plan.beats.count))
                } catch let blocked as RekordboxGridWriter.Blocked {
                    gridOutcomes.append(Outcome(trackUUID: draft.trackUUID, title: blocked.title, status: .blocked,
                                                reason: blocked.reason, removed: 0, added: 0))
                }
            }
            reader.close()
        }

        let backup = dryRun ? nil : try makeBackup(of: database, in: backups, now: now, label: "write")
        // 분석 파일도 원본을 백업에 둔다(되돌리기용).
        if let backup, !gridPlans.isEmpty { try backupAnalysis(gridPlans, in: backup) }

        var outcomes: [Outcome] = []
        var gainOutcomes: [Outcome] = []
        var written: [(contentID: String, expectation: Expectation)] = []
        var finalUpdateCount: Int?
        do {
            let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive(), writable: true)
            try db.execute("BEGIN IMMEDIATE")
            var finished = false
            defer { if !finished { try? db.execute("ROLLBACK") } }

            var usn = try localUpdateCount(db)
            let startUSN = usn
            for draft in drafts {
                try db.execute("SAVEPOINT anicue_track")
                do {
                    let result = try apply(draft, db: db, usn: &usn, stamp: stamp)
                    outcomes.append(result.outcome)
                    if let expectation = result.expectation {
                        try verify(db: db, contentID: result.contentID, expectation)
                        written.append((result.contentID, expectation))
                    }
                    try db.execute("RELEASE anicue_track")
                } catch let blocked as Blocked {
                    try db.execute("ROLLBACK TO anicue_track")
                    try db.execute("RELEASE anicue_track")
                    outcomes.append(Outcome(trackUUID: draft.trackUUID, title: blocked.title, status: .blocked,
                                            reason: blocked.reason, removed: 0, added: 0))
                }
            }
            // 오토게인: rekordbox가 직접 고쳤을 때처럼 djmdMixerParam 한 행(삭제 안 된 것)의 게인 두 칸·상태·변경 번호만 바꾼다.
            for (uuid, gainDB) in gains.sorted(by: { $0.key < $1.key }) {
                try db.execute("SAVEPOINT anicue_gain")
                do {
                    gainOutcomes.append(try applyGain(uuid: uuid, gainDB: gainDB, db: db, usn: &usn, stamp: stamp))
                    try db.execute("RELEASE anicue_gain")
                } catch let blocked as Blocked {
                    try db.execute("ROLLBACK TO anicue_gain")
                    try db.execute("RELEASE anicue_gain")
                    gainOutcomes.append(Outcome(trackUUID: uuid, title: blocked.title, status: .blocked, reason: blocked.reason, removed: 0, added: 0))
                }
            }

            // BPM이 바뀌는 그리드: .DAT 파일 기록과 곡 BPM을 rekordbox처럼 고친다(파일은 커밋 뒤에 쓴다).
            for plan in gridPlans where plan.newBPM100 != nil {
                try applyGridDatabase(plan, db: db, usn: &usn, stamp: stamp)
                // 같은 곡에 큐도 썼으면 곡의 변경 번호는 이제 그리드 쪽 번호다.
                for i in written.indices where written[i].expectation.contentUUID == plan.trackUUID {
                    written[i].expectation.contentUSN = usn
                }
            }
            if usn != startUSN {
                let changed = try db.run("UPDATE agentRegistry SET int_1 = ? WHERE registry_id = 'localUpdateCount'", [.int(usn)])
                guard changed == 1 else { throw AnicueError.writeVerificationFailed("변경 카운터를 올리지 못했습니다") }
            }
            guard try localUpdateCount(db) == usn else { throw AnicueError.writeVerificationFailed("변경 카운터가 맞지 않습니다") }
            finalUpdateCount = usn

            let databaseChanged = !written.isEmpty || gridPlans.contains { $0.newBPM100 != nil }
                || gainOutcomes.contains { $0.status == .written }
            if dryRun || !databaseChanged {
                try db.execute("ROLLBACK")
            } else {
                try db.execute("COMMIT")
                try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            }
            finished = true
            db.close()
        } catch {
            // 커밋 전 실패는 ROLLBACK으로 끝난다. 백업은 남겨 두지만 쓸 일은 없다.
            throw error
        }

        if !dryRun, !written.isEmpty {
            do {
                try checkIntegrity(of: database)
                let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
                for item in written { try verify(db: db, contentID: item.contentID, item.expectation) }
            } catch {
                if let backup { try? restoreFiles(from: backup, to: database) }
                throw AnicueError.writeVerificationFailed("\(error)")
            }
        }

        // 그리드: DB가 끝난 뒤 분석 파일을 쓴다. 하나라도 검증에 실패하면 DB·파일 모두 쓰기 전으로 되돌린다.
        if !dryRun, !gridPlans.isEmpty {
            var applied: [RekordboxGridWriter.Plan] = []
            do {
                for plan in gridPlans {
                    try RekordboxGridWriter.apply(plan)
                    applied.append(plan)
                }
            } catch {
                for plan in applied { try? RekordboxGridWriter.restore(plan) }
                if let backup, !written.isEmpty { try? restoreFiles(from: backup, to: database) }
                throw AnicueError.writeVerificationFailed("\(error)")
            }
        }

        var report = Report(outcomes: outcomes, backup: backup?.path, dryRun: dryRun, createdAt: stamp.json,
                            finalUpdateCount: finalUpdateCount)
        report.gridOutcomes = gridOutcomes.isEmpty ? nil : gridOutcomes
        report.gainOutcomes = gainOutcomes.isEmpty ? nil : gainOutcomes
        if let backup {
            try? save(report, in: backup)
            // 되돌리면 anicue 초안도 살릴 수 있게 쓴 초안을 백업 옆에 둔다.
            let written = Set(report.written.map(\.trackUUID))
            let folder = backup.appending(path: "cue-drafts")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for draft in drafts where written.contains(draft.trackUUID) {
                try? JSONEncoder().encode(draft).write(to: folder.appending(path: "\(draft.trackUUID).json"), options: .atomic)
            }
            let gainWritten = Set(report.gainWritten.map(\.trackUUID))
            if !gainWritten.isEmpty {
                let written = gains.filter { gainWritten.contains($0.key) }
                try? JSONEncoder().encode(written).write(to: backup.appending(path: "gain-drafts.json"), options: .atomic)
            }
            let gridWritten = Set(report.gridWritten.map(\.trackUUID))
            if !gridWritten.isEmpty {
                let gridFolder = backup.appending(path: "grid-drafts")
                try? FileManager.default.createDirectory(at: gridFolder, withIntermediateDirectories: true)
                for draft in grids where gridWritten.contains(draft.trackUUID) {
                    try? JSONEncoder().encode(draft).write(to: gridFolder.appending(path: "\(draft.trackUUID).json"), options: .atomic)
                }
            }
            prune(backups)
        }
        return report
    }

    /// 백업에 들어 있는 게인 초안
    public static func gainDrafts(in backup: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: backup.appending(path: "gain-drafts.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
    }

    /// 오토게인 한 곡(流れ行く命 −3.3→+0.65dB 실험과 같은 칸): GainHigh·GainLow·상태 256→257·rb_local_usn·updated_at
    static func applyGain(uuid: String, gainDB: Double, db: CipherDatabase, usn: inout Int,
                          stamp: (db: String, json: String)) throws -> Outcome {
        var content: (id: String, title: String)?
        try db.query("SELECT ID, Title FROM djmdContent WHERE UUID = ? AND rb_local_deleted = 0", [.text(uuid)]) { content = ($0.string(0) ?? "", $0.string(1) ?? "") }
        guard let content else { throw Blocked(title: uuid, reason: "rekordbox 컬렉션에서 곡을 찾지 못했습니다") }
        guard gainDB.isFinite, (-24...24).contains(gainDB) else { throw Blocked(title: content.title, reason: "게인이 범위를 벗어납니다") }
        var rows: [String] = []
        try db.query("SELECT ID FROM djmdMixerParam WHERE ContentID = ? AND rb_local_deleted = 0", [.text(content.id)]) { rows.append($0.string(0) ?? "") }
        guard rows.count == 1, let rowID = rows.first else {
            throw Blocked(title: content.title, reason: rows.isEmpty ? "rekordbox 오토게인 값이 없는 곡입니다(분석 전)" : "오토게인 행이 여럿입니다")
        }
        let value = Float(pow(10, gainDB / 20))
        let (high, low) = RekordboxAutoGain.halves(value)
        usn += 1
        try db.run("""
            UPDATE djmdMixerParam SET GainHigh = ?, GainLow = ?,
                rb_data_status = CASE rb_data_status WHEN 256 THEN 257 ELSE rb_data_status END,
                rb_local_usn = ?, updated_at = ? WHERE ID = ?
            """, [.int(high), .int(low), .int(usn), .text(stamp.db), .text(rowID)])
        var check: (Int, Int)?
        try db.query("SELECT GainHigh, GainLow FROM djmdMixerParam WHERE ID = ?", [.text(rowID)]) { check = ($0.int(0) ?? -1, $0.int(1) ?? -1) }
        guard check?.0 == high, check?.1 == low else { throw AnicueError.writeVerificationFailed("오토게인 확인 실패 (\(content.title))") }
        return Outcome(trackUUID: uuid, title: content.title, status: .written, reason: nil, removed: 0, added: Int((gainDB * 100).rounded()))
    }

    /// BPM이 바뀌는 그리드의 DB 쪽(BPM 244→245 실험과 같은 칸):
    /// `contentFile`(.DAT): Hash·Size·상태 256→257·rb_local_usn·updated_at /
    /// `djmdContent`: BPM·AnalysisUpdated+1·TrackInfoUpdated+1·상태 256→257·rb_local_usn·updated_at.
    static func applyGridDatabase(_ plan: RekordboxGridWriter.Plan, db: CipherDatabase, usn: inout Int,
                                  stamp: (db: String, json: String)) throws {
        guard let bpm100 = plan.newBPM100 else { return }
        func fail(_ reason: String) -> AnicueError { .writeVerificationFailed("\(reason) (\(plan.title))") }
        var contentID: String?
        try db.query("SELECT ID FROM djmdContent WHERE UUID = ? AND rb_local_deleted = 0", [.text(plan.trackUUID)]) { contentID = $0.string(0) }
        guard let contentID else { throw fail("곡을 찾지 못했습니다") }
        usn += 1
        let fileUSN = usn
        let files = try db.run("""
            UPDATE contentFile SET Hash = ?, Size = ?,
                rb_data_status = CASE rb_data_status WHEN 256 THEN 257 ELSE rb_data_status END,
                rb_local_usn = ?, updated_at = ? WHERE ContentID = ? AND Path = ?
            """, [.text(plan.newDatMD5), .int(plan.newDat.count), .int(fileUSN), .text(stamp.db), .text(contentID), .text(plan.analysisDataPath)])
        guard files <= 1 else { throw fail("분석 파일 기록이 여럿입니다") }
        usn += 1
        let contentUSN = usn
        let changed = try db.run("""
            UPDATE djmdContent SET BPM = ?,
                AnalysisUpdated = CAST(ifnull(AnalysisUpdated, '0') AS INTEGER) + 1,
                TrackInfoUpdated = CAST(ifnull(TrackInfoUpdated, '0') AS INTEGER) + 1,
                rb_data_status = CASE rb_data_status WHEN 256 THEN 257 ELSE rb_data_status END,
                rb_local_usn = ?, updated_at = ? WHERE ID = ?
            """, [.int(bpm100), .int(contentUSN), .text(stamp.db), .text(contentID)])
        guard changed == 1 else { throw fail("곡 BPM을 고치지 못했습니다") }
        // rekordbox는 두 칸을 글자로 둔다.
        try db.run("UPDATE djmdContent SET AnalysisUpdated = CAST(AnalysisUpdated AS TEXT), TrackInfoUpdated = CAST(TrackInfoUpdated AS TEXT) WHERE ID = ?",
                   [.text(contentID)])
        var check: (Int, String?)?
        try db.query("SELECT BPM, typeof(AnalysisUpdated) FROM djmdContent WHERE ID = ?", [.text(contentID)]) { check = ($0.int(0) ?? 0, $0.string(1)) }
        guard check?.0 == bpm100, check?.1 == "text" else { throw fail("곡 BPM 확인 실패") }
    }

    /// DB 사본의 rekordbox 변경 카운터(읽기 전용).
    public static func updateCount(of database: URL) throws -> Int {
        let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
        return try localUpdateCount(db)
    }

    /// 백업에 들어 있는 쓰기 보고서와 초안.
    /// 백업에 들어 있는 그리드 초안
    public static func gridDrafts(in backup: URL) -> [GridDraft] {
        let folder = backup.appending(path: "grid-drafts")
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(GridDraft.self, from: $0) }
    }

    public static func contents(of backup: URL) -> (report: Report?, drafts: [CueDraft]) {
        let report = (try? Data(contentsOf: backup.appending(path: "report.json")))
            .flatMap { try? JSONDecoder().decode(Report.self, from: $0) }
        let folder = backup.appending(path: "cue-drafts")
        let drafts = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(CueDraft.self, from: $0) }
        return (report, drafts)
    }

    struct Blocked: Error {
        var title: String
        var reason: String
    }

    /// 쓴 뒤 곡이 가져야 할 상태
    struct Expectation {
        var contentUUID: String
        /// 편집 가능한 큐(자동 큐 제외): 종류·ms·이름
        var editable: [String]
        /// 건드리지 않은 큐 ID(자동 큐 포함)
        var untouchedIDs: Set<String>
        /// 새로 넣은 큐 ID
        var insertedIDs: Set<String>
        /// 건드리지 않은 JSON 객체 원문
        var untouchedJSON: [String: String]
        var cueUSN: Int
        var contentUSN: Int
    }

    struct CueRow {
        var id: String
        var kind: Int
        var inMsec: Int
        var outMsec: Int
        var comment: String
        var color: Int?
        var colorTableIndex: Int?
        var activeLoop: Int
        var inMpegFrame: Int
        var hasSeekInfo: Bool
        var deleted: Bool

        var cue: Cue {
            Cue(id: id, contentID: "", kind: kind, inMsec: inMsec, name: comment, colorTableIndex: colorTableIndex,
                outMsec: outMsec, color: color, activeLoop: activeLoop)
        }
    }

    static func apply(_ draft: CueDraft, db: CipherDatabase, usn: inout Int,
                      stamp: (db: String, json: String)) throws -> (outcome: Outcome, contentID: String, expectation: Expectation?) {
        // 곡
        var contents: [(id: String, title: String, fileType: Int, bitRate: Int, cueUpdated: String?, length: Int, deleted: Bool, path: String)] = []
        try db.query("""
            SELECT ID, Title, FileType, BitRate, CueUpdated, Length, rb_local_deleted, FolderPath FROM djmdContent WHERE UUID = ?
            """, [.text(draft.trackUUID)]) { r in
            contents.append((r.string(0) ?? "", r.string(1) ?? "", r.int(2) ?? -1, r.int(3) ?? 0, r.string(4),
                             r.int(5) ?? 0, (r.int(6) ?? 0) != 0, r.string(7) ?? ""))
        }
        guard contents.count == 1, let content = contents.first else {
            throw Blocked(title: draft.trackUUID, reason: contents.isEmpty ? "rekordbox 컬렉션에서 곡을 찾지 못했습니다" : "같은 UUID의 곡이 여럿입니다")
        }
        func block(_ reason: String) -> Blocked { Blocked(title: content.title, reason: reason) }
        guard !content.deleted else { throw block("rekordbox 컬렉션에서 지운 곡입니다") }

        // 큐 행
        var rows: [CueRow] = []
        try db.query("""
            SELECT ID, Kind, InMsec, OutMsec, Comment, Color, ColorTableIndex, ActiveLoop, InMpegFrame, InPointSeekInfo, rb_local_deleted
            FROM djmdCue WHERE ContentID = ?
            """, [.text(content.id)]) { r in
            rows.append(CueRow(id: r.string(0) ?? "", kind: r.int(1) ?? -1, inMsec: r.int(2) ?? 0, outMsec: r.int(3) ?? 0,
                               comment: r.string(4) ?? "", color: r.int(5), colorTableIndex: r.int(6), activeLoop: r.int(7) ?? 0,
                               inMpegFrame: r.int(8) ?? 0, hasSeekInfo: r.string(9) != nil, deleted: (r.int(10) ?? 0) != 0))
        }
        guard !rows.contains(where: \.deleted) else { throw block("삭제 표시된 큐 행이 있습니다") }

        // 형식: FLAC은 rekordbox처럼 큐가 든 프레임의 탐색 위치(SeekInfo)를 계산해 적는다(기존 큐 1,818개와 전수 일치 확인).
        // VBR MP3의 MPEG 탐색 위치는 규칙을 아직 다 찾지 못해 막는다.
        var flac: (sampleRate: Int, frames: [SeekInfo.FlacFrame])?
        switch content.fileType {
        case 1:
            guard content.bitRate > 0, !rows.contains(where: { $0.inMpegFrame != 0 }) else {
                throw block("VBR MP3는 rekordbox가 큐마다 적는 MPEG 탐색 위치의 규칙을 아직 다 찾지 못해 막아 두었습니다")
            }
        case 4, 11:
            break
        case 5:
            guard let table = SeekInfo.flacFrames(url: URL(filePath: content.path)) else {
                throw block("FLAC 파일을 읽지 못했습니다(탐색 위치를 계산할 수 없음)")
            }
            flac = table
        default:
            throw block("이 파일 형식(FileType \(content.fileType))은 아직 직접 쓰지 않습니다")
        }
        guard flac != nil || !rows.contains(where: \.hasSeekInfo) else { throw block("탐색 위치가 적힌 큐가 있어 아직 직접 쓰지 않습니다") }

        // contentCue(JSON)
        var cueRecords: [(id: String, cues: String?, deleted: Bool)] = []
        try db.query("SELECT ID, Cues, rb_local_deleted FROM contentCue WHERE ContentID = ?", [.text(content.id)]) { r in
            cueRecords.append((r.string(0) ?? "", r.string(1), (r.int(2) ?? 0) != 0))
        }
        guard cueRecords.count <= 1 else { throw block("큐 기록(contentCue)이 여럿입니다") }
        if let record = cueRecords.first, record.deleted { throw block("큐 기록(contentCue)이 삭제 표시돼 있습니다") }
        if cueRecords.isEmpty, !rows.isEmpty { throw block("큐 행은 있는데 큐 기록(contentCue)이 없습니다") }
        let objects: [CueJSON.Object]
        if let record = cueRecords.first {
            guard let text = record.cues, let parsed = try? CueJSON.parse(text) else { throw block("큐 기록(JSON)을 읽지 못했습니다") }
            objects = parsed
        } else {
            objects = []
        }
        let objectIDs = objects.map { object -> String in if case let .string(id)? = object["ID"] { id } else { "" } }
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let consistent = objectIDs.count == rows.count && Set(objectIDs).count == objectIDs.count
            && zip(objectIDs, objects).allSatisfy { id, object in
                guard let row = rowsByID[id] else { return false }
                return object["InMsec"] == .int(row.inMsec) && object["Kind"] == .int(row.kind)
            }
        guard consistent else { throw block("rekordbox 큐 기록(JSON)과 큐 행이 서로 다릅니다") }

        // 초안을 시작할 때와 rekordbox 큐가 같아야 한다.
        let current = rows.map(\.cue).filter { !$0.isAutoGenerated }.compactMap(EditableCue.init)
        guard key(current, withSource: true) == key(draft.base, withSource: true) else {
            throw block("초안을 만든 뒤 rekordbox에서 이 곡의 큐가 바뀌었습니다. anicue에서 다시 불러와 확인하세요")
        }

        // 바꿀 것
        var removals: [CueRow] = []
        var inserts: [(cue: EditableCue, replacing: CueRow?)] = []
        for change in draft.changes {
            switch change {
            case let .removed(old):
                guard let id = old.sourceID, let row = rowsByID[id] else { throw block("지울 큐를 찾지 못했습니다") }
                removals.append(row)
            case let .modified(old, new):
                guard let id = old.sourceID, let row = rowsByID[id] else { throw block("옮길 큐를 찾지 못했습니다") }
                guard !row.cue.isLoop, row.activeLoop == 0, new.loop == nil else {
                    throw block("루프(끝 지점·활성 루프) 쓰기는 rekordbox 실험으로 확인한 뒤 엽니다")
                }
                removals.append(row)
                inserts.append((new, row))
            case let .added(new):
                guard new.loop == nil else { throw block("루프(끝 지점·활성 루프) 쓰기는 rekordbox 실험으로 확인한 뒤 엽니다") }
                inserts.append((new, nil))
            }
        }
        guard !removals.isEmpty || !inserts.isEmpty else {
            return (Outcome(trackUUID: draft.trackUUID, title: content.title, status: .unchanged, reason: nil, removed: 0, added: 0), content.id, nil)
        }
        let removedIDs = Set(removals.map(\.id))
        let hotKinds = rows.filter { !removedIDs.contains($0.id) && $0.kind > 0 && $0.kind != 4 }.map(\.kind)
            + inserts.map { kind(for: $0.cue.kind) }.filter { $0 > 0 }
        guard Set(hotKinds).count == hotKinds.count else { throw block("같은 핫큐 자리에 큐가 둘 생깁니다") }
        // rekordbox는 곡당 메모리 큐를 10개까지 둔다(자동 큐 포함).
        let memoryAfter = rows.filter { !removedIDs.contains($0.id) && $0.kind == 0 }.count
            + inserts.filter { $0.cue.kind == .memory }.count
        guard memoryAfter <= 10 else { throw block("메모리 큐가 \(memoryAfter)개가 됩니다(rekordbox는 곡당 10개까지, 자동 큐 포함)") }
        let limit = (content.length + 1) * 1000
        guard inserts.allSatisfy({ (0...limit).contains(msec($0.cue.time)) }) else { throw block("곡 길이를 벗어난 큐가 있습니다") }
        // FLAC 탐색 위치(쓰기 전에 모두 계산해 둔다)
        var seekInfo: [EditableCue.ID: String] = [:]
        if let flac {
            for (cue, _) in inserts {
                guard let info = SeekInfo.flacSeekInfo(frames: flac.frames, sample: msec(cue.time) * flac.sampleRate / 1000) else {
                    throw block("FLAC 탐색 위치를 계산하지 못한 큐가 있습니다")
                }
                seekInfo[cue.id] = info
            }
        }

        // 곡 UUID(= contentCue.ID = 큐의 ContentUUID)
        let contentUUID = draft.trackUUID

        if cueRecords.isEmpty, try scalar(db, "SELECT count(*) FROM contentCue WHERE ID = ?", [.text(contentUUID)]) != 0 {
            throw block("같은 ID의 큐 기록(contentCue)이 이미 있습니다")
        }

        // 쓰기
        for row in removals {
            guard try db.run("DELETE FROM djmdCue WHERE ID = ? AND ContentID = ?", [.text(row.id), .text(content.id)]) == 1 else {
                throw AnicueError.writeVerificationFailed("큐 행을 지우지 못했습니다(\(content.title))")
            }
        }
        var newObjects: [CueJSON.Object] = []
        var insertedIDs: Set<String> = []
        for (cue, replacing) in inserts.sorted(by: { $0.cue.time < $1.cue.time }) {
            let id = try newCueID(db)
            let uuid = UUID().uuidString.lowercased()
            let inMsec = msec(cue.time)
            let kind = kind(for: cue.kind)
            // 옮긴 큐는 지정해 둔 색을 이어받는다.
            var color = -1
            var colorTableIndex: Int?
            if let old = replacing, (old.kind == 0) == (kind == 0),
               (old.color.map { $0 != -1 && $0 != 255 } ?? false) || (old.colorTableIndex ?? 0) > 0 {
                color = old.color ?? -1
                colorTableIndex = old.colorTableIndex
            }
            let comment: String? = cue.name.isEmpty ? nil : cue.name
            let inSeek = seekInfo[cue.id]
            try db.run("""
                INSERT INTO djmdCue (ID, ContentID, InMsec, InFrame, InMpegFrame, InMpegAbs, OutMsec, OutFrame, OutMpegFrame,
                    OutMpegAbs, Kind, Color, ColorTableIndex, ActiveLoop, Comment, BeatLoopSize, CueMicrosec, InPointSeekInfo,
                    OutPointSeekInfo, ContentUUID, UUID, rb_data_status, rb_local_data_status, rb_local_deleted, rb_local_synced,
                    usn, rb_local_usn, created_at, updated_at)
                VALUES (?, ?, ?, ?, 0, 0, -1, 0, 0, 0, ?, ?, ?, NULL, ?, NULL, NULL, ?, ?, ?, ?, 0, 0, 0, 0, NULL, NULL, ?, ?)
                """, [.text(id), .text(content.id), .int(inMsec), .int(inMsec * 150 / 1000), .int(kind), .int(color),
                      colorTableIndex.map { .int($0) } ?? .null, comment.map { .text($0) } ?? .null,
                      inSeek.map { .text($0) } ?? .null, inSeek == nil ? .null : .text("0,0,0"),
                      .text(contentUUID), .text(uuid), .text(stamp.db), .text(stamp.db)])
            newObjects.append(CueJSON.newObject([
                ("ID", .string(id)), ("ContentID", .string(content.id)), ("ContentUUID", .string(contentUUID)),
                ("InMsec", .int(inMsec)), ("InFrame", .int(inMsec * 150 / 1000)), ("InMpegFrame", .int(0)), ("InMpegAbs", .int(0)),
                ("InPointSeekInfo", inSeek.map { .string($0) }),
                ("OutMsec", .int(-1)), ("OutFrame", .int(0)), ("OutMpegFrame", .int(0)), ("OutMpegAbs", .int(0)),
                ("OutPointSeekInfo", inSeek == nil ? nil : .string("0,0,0")),
                ("Kind", .int(kind)), ("Color", .int(color)), ("ColorTableIndex", colorTableIndex.map { .int($0) }),
                ("Comment", comment.map { .string($0) }), ("UUID", .string(uuid)),
                ("created_at", .string(stamp.json)), ("updated_at", .string(stamp.json)),
            ]))
            insertedIDs.insert(id)
        }
        let kept = zip(objectIDs, objects).filter { !removedIDs.contains($0.0) }
        let json = CueJSON.serialize(kept.map(\.1) + newObjects)
        let count = kept.count + newObjects.count

        usn += 1
        let cueUSN = usn
        usn += 1
        let contentUSN = usn
        if let record = cueRecords.first {
            try db.run("""
                UPDATE contentCue SET Cues = ?, rb_cue_count = ?,
                    rb_data_status = CASE rb_data_status WHEN 256 THEN 257 ELSE rb_data_status END,
                    rb_local_usn = ?, updated_at = ? WHERE ID = ?
                """, [.text(json), .int(count), .int(cueUSN), .text(stamp.db), .text(record.id)])
        } else {
            try db.run("""
                INSERT INTO contentCue (ID, ContentID, Cues, rb_cue_count, UUID, rb_data_status, rb_local_data_status,
                    rb_local_deleted, rb_local_synced, usn, rb_local_usn, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 0, 0, 0, 0, NULL, ?, ?, ?)
                """, [.text(contentUUID), .text(content.id), .text(json), .int(count), .text(UUID().uuidString.lowercased()),
                      .int(cueUSN), .text(stamp.db), .text(stamp.db)])
        }
        let cueUpdated = (Int(content.cueUpdated ?? "") ?? 0) + removals.count + inserts.count
        try db.run("""
            UPDATE djmdContent SET CueUpdated = ?,
                rb_data_status = CASE rb_data_status WHEN 256 THEN 257 ELSE rb_data_status END,
                rb_local_usn = ?, updated_at = ? WHERE ID = ?
            """, [.text(String(cueUpdated)), .int(contentUSN), .text(stamp.db), .text(content.id)])

        let untouched = Set(rows.map(\.id)).subtracting(removedIDs)
        let expectation = Expectation(
            contentUUID: contentUUID,
            editable: key(draft.cues, withSource: false),
            untouchedIDs: untouched,
            insertedIDs: insertedIDs,
            untouchedJSON: Dictionary(uniqueKeysWithValues: kept.map { ($0.0, CueJSON.serialize([$0.1])) }),
            cueUSN: cueUSN, contentUSN: contentUSN)
        return (Outcome(trackUUID: draft.trackUUID, title: content.title, status: .written, reason: nil,
                        removed: removals.count, added: inserts.count), content.id, expectation)
    }

    // MARK: - 검증

    /// 곡 하나가 의도한 상태인지 다시 읽어 확인한다(쓰기 트랜잭션 안과 커밋 뒤 두 번).
    static func verify(db: CipherDatabase, contentID: String, _ expected: Expectation) throws {
        func fail(_ reason: String) -> AnicueError { .writeVerificationFailed("\(reason) (ContentID \(contentID))") }
        var rows: [CueRow] = []
        try db.query("SELECT ID, Kind, InMsec, OutMsec, Comment, ColorTableIndex FROM djmdCue WHERE ContentID = ?", [.text(contentID)]) { r in
            rows.append(CueRow(id: r.string(0) ?? "", kind: r.int(1) ?? -1, inMsec: r.int(2) ?? 0, outMsec: r.int(3) ?? 0,
                               comment: r.string(4) ?? "", color: nil, colorTableIndex: r.int(5), activeLoop: 0,
                               inMpegFrame: 0, hasSeekInfo: false, deleted: false))
        }
        guard Set(rows.map(\.id)) == expected.untouchedIDs.union(expected.insertedIDs), rows.count == Set(rows.map(\.id)).count else {
            throw fail("큐 행 구성이 다릅니다")
        }
        let editable = rows.map(\.cue).filter { !$0.isAutoGenerated }.compactMap(EditableCue.init)
        guard key(editable, withSource: false) == expected.editable else { throw fail("큐 위치·종류가 초안과 다릅니다") }

        var records: [(cues: String?, count: Int?, usn: Int?)] = []
        try db.query("SELECT Cues, rb_cue_count, rb_local_usn FROM contentCue WHERE ContentID = ?", [.text(contentID)]) { r in
            records.append((r.string(0), r.int(1), r.int(2)))
        }
        guard records.count == 1, let record = records.first, let text = record.cues,
              let objects = try? CueJSON.parse(text) else { throw fail("큐 기록(JSON)을 읽지 못했습니다") }
        guard CueJSON.serialize(objects) == text else { throw fail("큐 기록(JSON) 모양이 rekordbox와 다릅니다") }
        guard record.count == objects.count, record.usn == expected.cueUSN else { throw fail("큐 기록의 개수·변경 번호가 다릅니다") }
        var seen: Set<String> = []
        for object in objects {
            guard case let .string(id)? = object["ID"], seen.insert(id).inserted else { throw fail("큐 기록에 ID가 없거나 겹칩니다") }
            if let original = expected.untouchedJSON[id] {
                guard CueJSON.serialize([object]) == original else { throw fail("건드리지 않은 큐 기록이 바뀌었습니다") }
            } else {
                guard expected.insertedIDs.contains(id) else { throw fail("모르는 큐 기록이 있습니다") }
                // 새 큐는 JSON이 행의 모든 칸과 같아야 하고 칸 순서도 rekordbox와 같아야 한다.
                let columns = try rowValues(db: db, cueID: id)
                guard object.fields.map(\.key) == CueJSON.keyOrder.filter({ columns[$0] != nil }),
                      object.fields.allSatisfy({ columns[$0.key] == $0.value }) else { throw fail("새 큐의 기록(JSON)이 행과 다릅니다") }
            }
        }
        guard seen == Set(rows.map(\.id)) else { throw fail("큐 기록(JSON)과 큐 행이 다릅니다") }

        let contentUSN = try scalar(db, "SELECT rb_local_usn FROM djmdContent WHERE ID = ?", [.text(contentID)])
        guard contentUSN == expected.contentUSN else { throw fail("곡의 변경 번호가 다릅니다") }
    }

    /// 큐 행의 값(NULL 칸은 뺀다). 시각은 JSON 형식으로 바꾼다.
    static func rowValues(db: CipherDatabase, cueID: String) throws -> [String: CueJSON.Value] {
        var values: [String: CueJSON.Value] = [:]
        let columns = CueJSON.keyOrder
        try db.query("SELECT " + columns.map { "\"\($0)\"" }.joined(separator: ", ") + " FROM djmdCue WHERE ID = ?", [.text(cueID)]) { r in
            for (index, column) in columns.enumerated() {
                if CueJSON.stringKeys.contains(column) {
                    guard var text = r.string(Int32(index)) else { continue }
                    if column == "created_at" || column == "updated_at" {
                        text = text.replacingOccurrences(of: " +", with: "+").replacingOccurrences(of: " ", with: "T")
                    }
                    values[column] = .string(text)
                } else if let number = r.int(Int32(index)) {
                    values[column] = .int(number)
                }
            }
        }
        return values
    }

    /// 파일 전체 무결성(SQLite 구조 + SQLCipher 페이지 인증).
    static func checkIntegrity(of database: URL) throws {
        let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
        var quick: [String] = []
        try db.query("PRAGMA quick_check") { quick.append($0.string(0) ?? "") }
        guard quick == ["ok"] else { throw AnicueError.writeVerificationFailed("무결성 검사 실패: \(quick.prefix(3).joined(separator: " / "))") }
        var cipher: [String] = []
        try db.query("PRAGMA cipher_integrity_check") { cipher.append($0.string(0) ?? "") }
        guard cipher.isEmpty else { throw AnicueError.writeVerificationFailed("암호 페이지 검사 실패: \(cipher.prefix(3).joined(separator: " / "))") }
    }

    // MARK: - 백업·되돌리기

    public struct Backup: Sendable, Identifiable {
        public var id: String { url.path }
        public var url: URL
        public var createdAt: Date
        /// anicue가 쓰기 직전에 뜬 백업이면 true(되돌리기 직전 상태를 떠 둔 백업은 false)
        public var isWrite: Bool
        public var report: Report?

        public var titles: [String] { report?.written.map(\.title) ?? [] }
    }

    /// DB 파일(+WAL·SHM)을 통째로 복사한다. 복사하는 동안 원본이 바뀌면 실패한다.
    static func makeBackup(of database: URL, in directory: URL, now: Date, label: String) throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let name = formatter.string(from: now) + "-" + label
        let folder = directory.appending(path: name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(filePath: database.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let before = try fm.attributesOfItem(atPath: source.path)
            let destination = folder.appending(path: "master.db" + suffix)
            try fm.copyItem(at: source, to: destination)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let after = try fm.attributesOfItem(atPath: source.path)
            let copied = try fm.attributesOfItem(atPath: destination.path)
            guard before[.size] as? Int == after[.size] as? Int,
                  before[.modificationDate] as? Date == after[.modificationDate] as? Date,
                  copied[.size] as? Int == after[.size] as? Int
            else {
                try? fm.removeItem(at: folder)
                throw AnicueError.sourceChangedDuringCopy(path: source.path)
            }
        }
        return folder
    }

    static func save(_ report: Report, in backup: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: backup.appending(path: "report.json"), options: .atomic)
    }

    static func prune(_ directory: URL) {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { fm.fileExists(atPath: $0.appending(path: "master.db").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in folders.dropFirst(backupsToKeep) { try? fm.removeItem(at: old) }
    }

    /// 백업 목록(최근 것부터)
    public static func backups(in directory: URL = backupDirectory) -> [Backup] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { fm.fileExists(atPath: $0.appending(path: "master.db").path) }
            .map { folder in
                let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return Backup(url: folder, createdAt: created, isWrite: folder.lastPathComponent.hasSuffix("-write"),
                              report: contents(of: folder).report)
            }
            .sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }
    }

    /// 백업으로 되돌린다. 되돌리기 직전 상태도 따로 백업해 둔다.
    @discardableResult
    public static func restore(_ backup: URL, to database: URL = liveDatabase, now: Date = .now,
                               backups: URL = backupDirectory) throws -> URL {
        if isLive(database) {
            guard !LibrarySnapshot.isRekordboxRunning() else {
                throw AnicueError.writeRefused("rekordbox가 켜져 있습니다. rekordbox를 완전히 종료한 뒤 되돌리세요")
            }
        }
        // 백업이 멀쩡한지 먼저 본다.
        try checkIntegrity(of: backup.appending(path: "master.db"))
        let saved = try makeBackup(of: database, in: backups, now: now, label: "before-restore")
        try restoreFiles(from: backup, to: database)
        try restoreAnalysis(from: backup, saveCurrentTo: saved)
        try checkIntegrity(of: database)
        return saved
    }

    /// 분석 파일 원본을 백업 폴더 `anlz/`에 둔다(원래 경로는 manifest.json).
    static func backupAnalysis(_ plans: [RekordboxGridWriter.Plan], in backup: URL) throws {
        let folder = backup.appending(path: "anlz")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest: [String: String] = [:]
        for (i, plan) in plans.enumerated() {
            let dat = folder.appending(path: "\(i).DAT")
            try plan.originalDat.write(to: dat)
            manifest[dat.lastPathComponent] = plan.datURL.path
            if let extURL = plan.extURL, let originalExt = plan.originalExt {
                let ext = folder.appending(path: "\(i).EXT")
                try originalExt.write(to: ext)
                manifest[ext.lastPathComponent] = extURL.path
            }
        }
        try JSONEncoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
    }

    /// 백업의 분석 파일을 원래 자리로 되돌린다. 되돌리기 전 현재 파일은 `saveCurrentTo`에 둔다.
    static func restoreAnalysis(from backup: URL, saveCurrentTo: URL?) throws {
        let folder = backup.appending(path: "anlz")
        guard let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
              let manifest = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        if let saveCurrentTo {
            let current = saveCurrentTo.appending(path: "anlz")
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
            for (name, path) in manifest { try? FileManager.default.copyItem(at: URL(filePath: path), to: current.appending(path: name)) }
            try JSONEncoder().encode(manifest).write(to: current.appending(path: "manifest.json"))
        }
        for (name, path) in manifest {
            try Data(contentsOf: folder.appending(path: name)).write(to: URL(filePath: path), options: .atomic)
        }
    }

    static func restoreFiles(from backup: URL, to database: URL) throws {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let target = URL(filePath: database.path + suffix)
            let source = backup.appending(path: "master.db" + suffix)
            if fm.fileExists(atPath: source.path) {
                let partial = URL(filePath: database.path + suffix + ".anicue-restore")
                try? fm.removeItem(at: partial)
                try fm.copyItem(at: source, to: partial)
                _ = try fm.replaceItemAt(target, withItemAt: partial)
            } else if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
        }
    }

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
            return (withSource ? (cue.sourceID ?? "-") + "|" : "") + "\(kind)|\(msec(cue.time))|\(cue.name)"
        }.sorted()
    }
}
