import AnicueDomain
import Foundation

/// anicue 큐 초안을 rekordbox `master.db`에 직접 쓴다.
///
/// rekordbox 7.2.18이 직접 큐를 고쳤을 때 DB가 바뀐 모양을 비교해 그대로 따른다(2026-09-26 확인):
/// - `djmdCue`: 지운 큐는 행을 지우고, 새 큐는 새 행(ID는 32비트 난수, UUID 새로)으로 넣는다.
/// - `contentCue.Cues`(JSON): 남은 큐는 원문 그대로 두고, 지운 큐를 빼고, 새 큐를 끝에 붙인다. `rb_cue_count`는 큐 수.
/// - `contentCue`·`djmdContent`: 동기화 상태 256 → 257, `rb_local_usn`은 전역 카운터(`agentRegistry.localUpdateCount`)를
///   하나씩 올려 받는다. `djmdContent.CueUpdated`는 고친 횟수만큼 늘린다.
/// 옮긴 큐는 지우고 새로 넣는다. FLAC은 rekordbox처럼 프레임 탐색 위치(SeekInfo)를 계산해 적는다.
/// VBR MP3(MPEG 탐색 위치 규칙 미확인)는 막는다.
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
                             now: Date = .now, backups: URL, shareRoot: URL? = nil) throws -> Report {
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

}
