import DJCDomain
import Foundation

/// DJCrate 큐 초안을 rekordbox `master.db`에 직접 쓴다.
///
/// rekordbox 7.2.18이 직접 큐를 고쳤을 때 DB가 바뀐 모양을 비교해 그대로 따른다(2026-09-26 확인):
/// - `djmdCue`: 지운 큐는 행을 지우고, 새 큐는 새 행(ID는 32비트 난수, UUID 새로)으로 넣는다.
/// - `contentCue.Cues`(JSON): 남은 큐는 원문 그대로 두고, 지운 큐를 빼고, 새 큐를 끝에 붙인다. `rb_cue_count`는 큐 수.
/// - `contentCue`·`djmdContent`: 동기화 상태 256 → 257, `rb_local_usn`은 전역 카운터(`agentRegistry.localUpdateCount`)를
///   하나씩 올려 받는다. `djmdContent.CueUpdated`는 고친 횟수만큼 늘린다.
/// 옮긴 큐는 지우고 새로 넣는다. FLAC은 rekordbox처럼 프레임 탐색 위치(SeekInfo)를 계산해 적는다.
/// VBR MP3(MPEG 탐색 위치 규칙 미확인)는 막는다.
///
/// 안전장치: rekordbox(에이전트 포함)가 켜져 있거나 확인하지 않은 버전·DB 구조면 쓰지 않는다(`RekordboxCompatibility`). 쓰기 전에 DB를 통째로 백업하고, 한
/// 트랜잭션 안에서 쓰고 다시 읽어 검증한 뒤에만 커밋한다. 커밋 뒤 무결성 검사·재검증이 실패하면 백업으로 되돌린다
/// (`writeRolledBack`). 되돌리지도 못하면 상태를 알 수 없으니 `restoreFailed`로 따로 알린다.
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
        /// 분석 전 곡에 분석 파일을 붙인 결과(added = 박 수). 옛 보고서에는 없다.
        public var analysisOutcomes: [Outcome]?
        /// 새로 만든 분석 파일(되돌릴 때 지운다). 옛 보고서에는 없다.
        public var createdFiles: [String]?

        public var written: [Outcome] { outcomes.filter { $0.status == .written } }
        public var blocked: [Outcome] { outcomes.filter { $0.status == .blocked } }
        public var gridWritten: [Outcome] { (gridOutcomes ?? []).filter { $0.status == .written } }
        public var gridBlocked: [Outcome] { (gridOutcomes ?? []).filter { $0.status == .blocked } }
        public var gainWritten: [Outcome] { (gainOutcomes ?? []).filter { $0.status == .written } }
        public var gainBlocked: [Outcome] { (gainOutcomes ?? []).filter { $0.status == .blocked } }
        public var analysisWritten: [Outcome] { (analysisOutcomes ?? []).filter { $0.status == .written } }
        public var analysisBlocked: [Outcome] { (analysisOutcomes ?? []).filter { $0.status == .blocked } }
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
    ///   - writeGuard: 라이브 DB 판단과 실행·버전 확인(시험에서 바꾼다). DB 구조는 사본이어도 늘 확인한다.
    ///   - analysisInputs: 분석 전 곡(분석 파일 없음)의 음원 길이·음량(곡 UUID별). 그 곡의 그리드 초안으로 분석 파일을 만들어 붙인다.
    public static func write(drafts: [CueDraft], grids: [GridDraft] = [], gains: [String: Double] = [:],
                             analysisInputs: [String: AnalysisInput] = [:],
                             to database: URL = liveDatabase, dryRun: Bool,
                             now: Date = .now, backups: URL, shareRoot: URL? = nil,
                             guard writeGuard: RekordboxWriteGuard = .system) throws -> Report {
        try write(drafts: drafts, grids: grids, gains: gains, analysisInputs: analysisInputs, to: database, dryRun: dryRun, now: now,
                  backups: backups, shareRoot: shareRoot, guard: writeGuard, attachesAnalysis: attachesAnalysis)
    }

    /// - Parameter attachesAnalysis: 분석 붙이기를 여는지. 앱은 `attachesAnalysis`를 따르고, 시험과 사본 실험(`djc lab analysis-attach-test`)만 바꾼다.
    package static func write(drafts: [CueDraft], grids: [GridDraft], gains: [String: Double], analysisInputs: [String: AnalysisInput],
                              to database: URL, dryRun: Bool, now: Date, backups: URL, shareRoot: URL?,
                              guard writeGuard: RekordboxWriteGuard = .system, attachesAnalysis: Bool) throws -> Report {
        let stamp = CueJSON.timestamps(now)
        let grids = grids.filter(\.hasChanges)
        guard drafts.contains(where: \.hasChanges) || !grids.isEmpty || !gains.isEmpty else {
            // 쓸 것이 없으면 DB를 열지도, 백업을 만들지도 않는다.
            return Report(outcomes: drafts.map { Outcome(trackUUID: $0.trackUUID, title: $0.trackUUID, status: .unchanged,
                                                          reason: nil, removed: 0, added: 0) },
                          backup: nil, dryRun: dryRun, createdAt: stamp.json, finalUpdateCount: nil)
        }
        let live = writeGuard.isLive(database)
        let gridRoot = shareRoot ?? (live ? RekordboxShare.directory : nil)
        if live { try writeGuard.checkLive(database, dryRun: dryRun) }
        do {
            let reader = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
            defer { reader.close() }
            try RekordboxCompatibility.checkSchema(reader)
            // 백업(약 150MB)을 뜨기 전에 막힐 조건을 먼저 본다.
            let counters = try RekordboxCompatibility.updateCounters(reader)
            if let local = counters.local { try RekordboxCompatibility.checkCounters(local: local, cloud: counters.cloud) }
        }
        // 그리드 계획(파일을 읽기만 한다)
        var gridPlans: [RekordboxGridWriter.Plan] = []
        var gridOutcomes: [Outcome] = []
        // 분석 전 곡(분석 파일 없음)의 그리드 초안은 분석 파일을 만들어 붙인다(파형·오토게인까지).
        var attachPlans: [AttachPlan] = []
        var analysisOutcomes: [Outcome] = []
        if !grids.isEmpty {
            let reader = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
            defer { reader.close() }
            for draft in grids {
                var info: (title: String, anlz: String?, bpm: Int, path: String, id: String, fileName: String)?
                try reader.query("""
                    SELECT Title, AnalysisDataPath, BPM, FolderPath, ID, FileNameL FROM djmdContent WHERE UUID = ? AND rb_local_deleted = 0
                    """, [.text(draft.trackUUID)]) { r in
                    info = (r.string(0) ?? "", r.string(1), r.int(2) ?? 0, r.string(3) ?? "", r.string(4) ?? "", r.string(5) ?? "")
                }
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
                if needsAnalysis(info.anlz) {
                    let fileName = info.fileName.isEmpty ? URL(filePath: info.path).lastPathComponent : info.fileName
                    do {
                        let plan = try attachPlan(draft: draft, content: (info.id, info.title, info.path, fileName),
                                                  input: analysisInputs[draft.trackUUID], share: gridRoot, reader: reader, enabled: attachesAnalysis)
                        attachPlans.append(plan)
                        analysisOutcomes.append(Outcome(trackUUID: draft.trackUUID, title: info.title, status: .written, reason: nil,
                                                        removed: 0, added: plan.ready.beats))
                    } catch let blocked as Blocked {
                        analysisOutcomes.append(Outcome(trackUUID: draft.trackUUID, title: blocked.title, status: .blocked,
                                                        reason: blocked.reason, removed: 0, added: 0))
                    }
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
        }

        let backup = dryRun ? nil : try makeBackup(of: database, in: backups, now: now, label: "write")
        // 분석 파일도 원본을 백업에 둔다(되돌리기용).
        if let backup, !gridPlans.isEmpty { try backupAnalysis(gridPlans, in: backup) }

        var outcomes: [Outcome] = []
        var gainOutcomes: [Outcome] = []
        var written: [(contentID: String, expectation: Expectation)] = []
        var attached: [AttachPlan] = []
        var finalUpdateCount: Int?
        var committed = false
        do {
            let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive(), writable: true)
            try db.execute("BEGIN IMMEDIATE")
            var finished = false
            defer { if !finished { try? db.execute("ROLLBACK") } }

            var usn = try localUpdateCount(db)
            let startUSN = usn
            // 분석 붙이기가 먼저: 같은 곡의 큐·게인은 분석한 곡에 쓰는 것과 같게 뒤에 쓴다.
            for var plan in attachPlans {
                try db.execute("SAVEPOINT djc_analysis")
                do {
                    try applyAttach(&plan, db: db, usn: &usn, stamp: stamp)
                    try db.execute("RELEASE djc_analysis")
                    attached.append(plan)
                } catch let blocked as Blocked {
                    try db.execute("ROLLBACK TO djc_analysis")
                    try db.execute("RELEASE djc_analysis")
                    if let i = analysisOutcomes.firstIndex(where: { $0.trackUUID == plan.trackUUID }) {
                        analysisOutcomes[i] = Outcome(trackUUID: plan.trackUUID, title: blocked.title, status: .blocked,
                                                      reason: blocked.reason, removed: 0, added: 0)
                    }
                }
            }
            for draft in drafts {
                try db.execute("SAVEPOINT djc_track")
                do {
                    let result = try apply(draft, db: db, usn: &usn, stamp: stamp)
                    outcomes.append(result.outcome)
                    if let expectation = result.expectation {
                        try verify(db: db, contentID: result.contentID, expectation)
                        written.append((result.contentID, expectation))
                    }
                    try db.execute("RELEASE djc_track")
                } catch let blocked as Blocked {
                    try db.execute("ROLLBACK TO djc_track")
                    try db.execute("RELEASE djc_track")
                    outcomes.append(Outcome(trackUUID: draft.trackUUID, title: blocked.title, status: .blocked,
                                            reason: blocked.reason, removed: 0, added: 0))
                }
            }
            // 오토게인: rekordbox가 직접 고쳤을 때처럼 djmdMixerParam 한 행(삭제 안 된 것)의 게인 두 칸·상태·변경 번호만 바꾼다.
            for (uuid, gainDB) in gains.sorted(by: { $0.key < $1.key }) {
                try db.execute("SAVEPOINT djc_gain")
                do {
                    gainOutcomes.append(try applyGain(uuid: uuid, gainDB: gainDB, db: db, usn: &usn, stamp: stamp))
                    try db.execute("RELEASE djc_gain")
                } catch let blocked as Blocked {
                    try db.execute("ROLLBACK TO djc_gain")
                    try db.execute("RELEASE djc_gain")
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
                guard changed == 1 else { throw DJCError.writeVerificationFailed("변경 카운터를 올리지 못했습니다") }
            }
            guard try localUpdateCount(db) == usn else { throw DJCError.writeVerificationFailed("변경 카운터가 맞지 않습니다") }
            finalUpdateCount = usn

            let databaseChanged = !written.isEmpty || gridPlans.contains { $0.newBPM100 != nil }
                || gainOutcomes.contains { $0.status == .written } || !attached.isEmpty
            if dryRun || !databaseChanged {
                try db.execute("ROLLBACK")
            } else {
                try db.execute("COMMIT")
                committed = true
                try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            }
            finished = true
            db.close()
        } catch {
            // 커밋 전 실패는 ROLLBACK으로 끝난다. 백업은 남겨 두지만 쓸 일은 없다.
            throw error
        }

        // 백업은 시험 실행이 아닐 때만 있다(= 커밋했을 수 있다).
        if let backup, !written.isEmpty || !attached.isEmpty {
            do {
                try checkIntegrity(of: database)
                let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
                defer { db.close() }
                for item in written { try verify(db: db, contentID: item.contentID, item.expectation) }
                for plan in attached { try verifyAttach(plan, db: db) }
            } catch {
                throw recover(from: error, database: database, backup: backup, live: live)
            }
        }

        // 분석 파일(붙이기는 새로 만들고, 그리드는 고친다): DB가 끝난 뒤 쓴다. 하나라도 검증에 실패하면 DB·파일 모두 쓰기 전으로
        // 되돌린다(만든 파일은 지운다). 큐 없이 BPM·게인만 커밋했어도 DB를 되돌린다.
        var created: [URL] = []
        if let backup, !gridPlans.isEmpty || !attached.isEmpty {
            do {
                for plan in attached { try writeAnalysisFiles(plan, created: &created) }
                for plan in gridPlans { try RekordboxGridWriter.apply(plan) }
            } catch {
                throw recover(from: error, database: database, backup: backup, live: live, restoreDatabase: committed) {
                    try removeAnalysisFiles(created)
                    try restoreGridFiles(gridPlans)
                }
            }
        }

        var report = Report(outcomes: outcomes, backup: backup?.path, dryRun: dryRun, createdAt: stamp.json,
                            finalUpdateCount: finalUpdateCount)
        report.gridOutcomes = gridOutcomes.isEmpty ? nil : gridOutcomes
        report.gainOutcomes = gainOutcomes.isEmpty ? nil : gainOutcomes
        report.analysisOutcomes = analysisOutcomes.isEmpty ? nil : analysisOutcomes
        report.createdFiles = created.isEmpty ? nil : created.map(\.path)
        if let backup {
            try? save(report, in: backup)
            // 되돌리면 DJCrate 초안도 살릴 수 있게 쓴 초안을 백업 옆에 둔다.
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
            // 분석을 붙인 곡도 그리드 초안으로 쓴 것이라 함께 둔다(되돌리면 그리드 초안을 살린다).
            let gridWritten = Set((report.gridWritten + report.analysisWritten).map(\.trackUUID))
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

    // MARK: - 커밋 뒤 실패

    /// 커밋 뒤 확인·분석 파일 쓰기가 실패했을 때 쓰기 전으로 되돌리고 던질 오류를 고른다.
    /// 모두 되돌렸으면 `writeRolledBack`, 하나라도 못 했거나 되돌린 DB가 무결성 검사를 통과하지 못하면 `restoreFailed`.
    /// - Parameters:
    ///   - restoreDatabase: DB를 커밋했으면 true(백업의 master.db로 바꾼다)
    ///   - files: 분석 파일 되돌리기(바꾼 파일은 원본으로, 만든 파일은 지우기)
    static func recover(from failure: any Error, database: URL, backup: URL, live: Bool, restoreDatabase: Bool = true,
                        files: () throws -> Void = {}) -> DJCError {
        var problems: [String] = []
        do { try files() } catch { problems.append("분석 파일: \(DJCError.reason(of: error))") }
        if restoreDatabase {
            do {
                try restoreFiles(from: backup, to: database)
                try checkIntegrity(of: database)
            } catch {
                problems.append("master.db: \(DJCError.reason(of: error))")
            }
        }
        let reason = DJCError.reason(of: failure)
        guard problems.isEmpty else {
            return .restoreFailed(reason: reason, restoreError: problems.joined(separator: " / "), backup: backup.path,
                                  database: live ? nil : database.path)
        }
        return .writeRolledBack(reason)
    }

    /// 그리드를 쓴 분석 파일을 원본 바이트로 되돌린다. 원본 그대로인 파일(쓰기 전에 실패한 곡)은 건드리지 않는다.
    static func restoreGridFiles(_ plans: [RekordboxGridWriter.Plan]) throws {
        var files: [(URL, Data)] = []
        for plan in plans {
            files.append((plan.datURL, plan.originalDat))
            if let extURL = plan.extURL, let originalExt = plan.originalExt { files.append((extURL, originalExt)) }
        }
        try each(files.filter { (try? Data(contentsOf: $0.0)) != $0.1 }) { url, original in
            try original.write(to: url, options: .atomic)
        }
    }

    /// 하나가 실패해도 나머지를 모두 해 보고, 처음 실패를 던진다(되돌리기를 중간에 멈추지 않게).
    static func each<S: Sequence>(_ items: S, _ body: (S.Element) throws -> Void) throws {
        var first: (any Error)?
        for item in items {
            do { try body(item) } catch { first = first ?? error }
        }
        if let first { throw first }
    }
}
