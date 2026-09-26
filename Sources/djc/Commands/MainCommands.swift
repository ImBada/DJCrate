import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AVFoundation
import Foundation

/// 늘 쓰는 명령: 스냅샷·현황·파싱·분석, rekordbox 쓰기·되돌리기, 테스트 픽스처.
enum MainCommands {
    static let all: [Command] = [
        Command("snapshot", "[--force]", "rekordbox master.db 스냅샷을 뜬다", snapshot),
        Command("report", "[--db PATH] [--files]", "라이브러리 현황(기본: 최신 스냅샷)", report),
        Command("analyze", "<파일|ContentID> [--db PATH]", "곡 파트 분석(ContentID면 기존 큐와 비교)", analyze),
        Command("reflection-dry-run", nil, "초안으로 반영 계획을 만들어 XML을 지정한 곳에만 쓴다(rekordbox는 그대로)", reflectionDryRun),
        Command("cue-write", "--db <사본.db> [--dry-run] [--uuid U] | --live", "큐 초안을 rekordbox DB에 직접 쓴다", cueWrite),
        Command("track-add", "--db <사본.db> [--share <분석 뿌리>] [--analyze] [--dry-run] <음원…> | --live …",
                "음원을 rekordbox 컬렉션에 넣는다(--analyze면 그리드·파형·오토게인까지, 기본은 사본)", trackAdd),
        Command("track-delete", "--db <사본.db> [--share <분석 뿌리>] [--dry-run] <ContentID…> | --live …", "곡을 rekordbox 컬렉션에서 뺀다(음원 파일은 그대로)", trackDelete),
        Command("rekordbox-restore", "[--backup <폴더> (--db <사본> | --live)]", "백업으로 되돌린다", rekordboxRestore),
        Command("schema-dump", "<사본.db> <출력.sql>", "사본 DB의 구조(CREATE 문)만 뽑는다", schemaDump),
        Command("path", "<제목>", "제목으로 파일 경로 찾기", path),
        Command("parse", "\"<코멘트>\"", "코멘트 문법 파싱 결과", parse),
    ]

    static func snapshot(_ args: [String]) async throws {
        let url = try LibrarySnapshot.take(force: args.contains("--force"))
        print(url.path)
    }

    static func report(_ args: [String]) async throws {
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        print("스냅샷: \(snapshot.path)\n")
        print(LibraryReport(library: library, checkFiles: args.contains("--files")).render())
    }

    static func analyze(_ args: [String]) async throws {
        guard args.count > 1 else { throw UsageError() }
        try await analyzeTrack(args[1], snapshotPath: value(after: "--db", in: args))
    }

    /// 실제 초안으로 반영 계획을 만들어 보고 XML을 지정한 곳에만 쓴다(rekordbox는 건드리지 않는다).
    static func reflectionDryRun(_ args: [String]) async throws {
        let library = try RekordboxLibrary.load(snapshot: LibrarySnapshot.latest())
        let uuids = CueDraftStore.uuids().union(GridDraftStore.uuids())
        var plans: [Reflection.Plan] = []
        for track in library.tracks where uuids.contains(track.uuid) {
            let plan = Reflection.plan(track: track, rawCues: library.cues(for: track),
                                       cueDraft: CueDraftStore.load(trackUUID: track.uuid),
                                       gridDraft: GridDraftStore.load(trackUUID: track.uuid))
            plans.append(plan)
            let draft = CueDraftStore.load(trackUUID: track.uuid)
            print("• \(track.title.prefix(30)) · 큐 변경 \(draft?.changes.count ?? 0) · 그리드 변경 \(plan.gridChanged) · 표시 \(plan.beforeMarks.count)→\(plan.marks.count) · " +
                  (plan.isEligible ? "반영 가능" : plan.blockers.isEmpty ? "변경 없음" : "막힘: \(plan.blockers.joined(separator: " / "))"))
        }
        if let out = value(after: "--out", in: args) {
            try Reflection.document(plans: plans.filter(\.isEligible), playlistName: "DJCrate 반영 시험").write(toFile: out, atomically: true, encoding: .utf8)
            print("XML: \(out)")
        }
    }

    /// 큐 초안을 rekordbox DB에 직접 쓴다. 기본은 --db 사본. 라이브 DB는 --live를 줘야 하고 rekordbox가 꺼져 있어야 한다.
    static func cueWrite(_ args: [String]) async throws {
        let live = args.contains("--live")
        guard live || value(after: "--db", in: args) != nil else { throw UsageError() }
        let database = live ? RekordboxWriter.liveDatabase : URL(filePath: value(after: "--db", in: args)!)
        let uuids = value(after: "--uuid", in: args).map { $0.components(separatedBy: ",") } ?? CueDraftStore.uuids().sorted()
        let drafts = uuids.compactMap(CueDraftStore.load(trackUUID:))
        let backups = live ? DJCPaths.rekordboxBackups : database.deletingLastPathComponent().appending(path: "backups")
        let report = try RekordboxWriter.write(drafts: drafts, to: database, dryRun: args.contains("--dry-run"), backups: backups)
        for outcome in report.outcomes {
            let mark = switch outcome.status { case .written: "✓"; case .blocked: "✗"; case .unchanged: "·" }
            print("\(mark) \(outcome.title.prefix(34)) — 지움 \(outcome.removed) · 넣음 \(outcome.added)\(outcome.reason.map { " · \($0)" } ?? "")")
        }
        print("\(report.dryRun ? "미리 보기(되돌림)" : "씀") · 쓴 곡 \(report.written.count) · 막힌 곡 \(report.blocked.count) · 백업 \(report.backup ?? "없음")")
    }

    /// 인자 가운데 옵션(과 그 값)을 뺀 나머지
    static func operands(_ args: [String], valued: Set<String>) -> [String] {
        var result: [String] = [], skip = false
        for arg in args.dropFirst() {
            if skip { skip = false; continue }
            if valued.contains(arg) { skip = true; continue }
            if arg.hasPrefix("--") { continue }
            result.append(arg)
        }
        return result
    }

    /// 음원을 컬렉션에 넣는다(분석 전). 기본은 --db 사본, 라이브 DB는 --live(rekordbox가 꺼져 있어야 한다).
    static func trackAdd(_ args: [String]) async throws {
        let live = args.contains("--live")
        guard live || value(after: "--db", in: args) != nil else { throw UsageError() }
        let database = live ? RekordboxWriter.liveDatabase : URL(filePath: value(after: "--db", in: args)!)
        let files = operands(args, valued: ["--db", "--share"])
        guard !files.isEmpty else { throw UsageError() }
        var plans: [TrackAddPlan] = []
        var analyses: [String: RekordboxTrackWriter.Analysis] = [:]
        for file in files {
            let url = URL(filePath: file)
            do {
                let plan = try TrackAddPlan.make(url: url, tags: try await AudioTags.read(url: url))
                plans.append(plan)
                guard args.contains("--analyze") else { continue }
                // 그리드: 음원 시간축 추정을 rekordbox 시간축으로 옮긴다. 음량: 오토게인(−10 LUFS 목표)
                guard var estimate = try await GridSuggestion.estimate(fileAt: url, cacheKey: "add-\(plan.fileID)") else {
                    print("· \(plan.fileName): 그리드를 추정하지 못해 분석 없이 넣습니다"); continue
                }
                let offset = RekordboxTimeline.predictedOffset(url: url)
                for i in estimate.segments.indices { estimate.segments[i].start += offset }
                let loudness = try Loudness.measure(fileAt: url)
                analyses[plan.path] = .init(segments: estimate.segments, loudness: loudness.integrated, peak: pow(10, loudness.peak / 20))
                print(String(format: "· %@: %.2f BPM · %.1f LUFS", plan.fileName, estimate.bpm, loudness.integrated ?? .nan))
            } catch { print("✗ \(url.lastPathComponent) — \(error)") }
        }
        let backups = live ? DJCPaths.rekordboxBackups : database.deletingLastPathComponent().appending(path: "backups")
        let report = try RekordboxTrackWriter.add(plans, analyses: analyses, to: database, shareRoot: value(after: "--share", in: args).map { URL(filePath: $0) },
                                                  dryRun: args.contains("--dry-run"), backups: backups)
        for o in report.added { print("\(o.written ? "✓" : "✗") \(o.title.prefix(40))\(o.contentID.map { " · ID \($0)" } ?? "")\(o.reason.map { " · \($0)" } ?? "")") }
        print("\(report.dryRun ? "미리 보기(되돌림)" : "넣음") · \(report.added.filter(\.written).count)곡 · 분석 파일 \(report.createdFiles.count)개 · 백업 \(report.backup ?? "없음")")
    }

    /// 곡을 컬렉션에서 뺀다. 분석 파일은 백업으로 옮긴다. 기본은 --db 사본(분석 파일은 --share를 줄 때만), 라이브는 --live.
    static func trackDelete(_ args: [String]) async throws {
        let live = args.contains("--live")
        guard live || value(after: "--db", in: args) != nil else { throw UsageError() }
        let database = live ? RekordboxWriter.liveDatabase : URL(filePath: value(after: "--db", in: args)!)
        let ids = operands(args, valued: ["--db", "--share"])
        guard !ids.isEmpty else { throw UsageError() }
        let backups = live ? DJCPaths.rekordboxBackups : database.deletingLastPathComponent().appending(path: "backups")
        let report = try RekordboxTrackWriter.delete(contentIDs: ids, from: database, shareRoot: value(after: "--share", in: args).map { URL(filePath: $0) },
                                                     dryRun: args.contains("--dry-run"), backups: backups)
        for o in report.deleted { print("\(o.written ? "✓" : "✗") \(o.title.prefix(40)) · ID \(o.contentID ?? "")\(o.reason.map { " · \($0)" } ?? "")") }
        print("\(report.dryRun ? "미리 보기(되돌림)" : "뺌") · \(report.deleted.filter(\.written).count)곡 · 분석 파일 \(report.removedFiles.count)개 · 백업 \(report.backup ?? "없음")")
    }

    /// 백업으로 되돌린다. 기본은 --db 사본. 라이브 DB는 --live(rekordbox가 꺼져 있어야 한다). 백업 목록은 인자 없이.
    static func rekordboxRestore(_ args: [String]) async throws {
        let live = args.contains("--live")
        guard let folder = value(after: "--backup", in: args), live || value(after: "--db", in: args) != nil else {
            for backup in RekordboxWriter.backups(in: DJCPaths.rekordboxBackups) {
                print(backup.url.lastPathComponent, "·", backup.titles.prefix(5).joined(separator: ", "), "· 카운터", backup.report?.finalUpdateCount ?? -1)
            }
            throw UsageError()
        }
        let database = live ? RekordboxWriter.liveDatabase : URL(filePath: value(after: "--db", in: args)!)
        let saved = try RekordboxWriter.restore(URL(filePath: folder), to: database,
                                                backups: live ? DJCPaths.rekordboxBackups : database.deletingLastPathComponent().appending(path: "backups"))
        print("되돌림 완료 · 되돌리기 전 상태 백업: \(saved.path)")
    }

    /// 사본 DB의 구조(CREATE 문)만 뽑는다. 데이터는 한 줄도 담지 않는다(테스트 픽스처용).
    static func schemaDump(_ args: [String]) async throws {
        guard args.count > 2 else { throw UsageError() }
        let db = try CipherDatabase(path: args[1], key: RekordboxKey.derive())
        var statements: [String] = []
        try db.query("""
            SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
            ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END, name
            """) { statements.append(($0.string(0) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) }
        var version = "?"
        try? db.query("SELECT DBVersion FROM djmdProperty LIMIT 1") { version = $0.string(0) ?? "?" }
        let text = "-- rekordbox master.db 구조(데이터 없음). DBVersion \(version)\n-- DJCrate schema-dump로 뽑음\n\n"
            + statements.map { $0 + ";" }.joined(separator: "\n\n") + "\n"
        try text.write(toFile: args[2], atomically: true, encoding: .utf8)
        print("구조 \(statements.count)개 → \(args[2]) · DBVersion \(version)")
    }

    /// 제목으로 파일 경로 찾기(개발용)
    static func path(_ args: [String]) async throws {
        let library = try RekordboxLibrary.load(snapshot: LibrarySnapshot.latest())
        guard args.count > 1 else { return }
        for track in library.tracks where track.title.contains(args[1]) && !track.isStreaming { print(track.folderPath) }
    }

    static func parse(_ args: [String]) async throws {
        guard args.count > 1 else { throw UsageError() }
        let comment = args[1]
        print("분류: \(CommentClassifier.classify(comment).rawValue)")
        if let parsed = ConventionParser.parse(comment) {
            dump(parsed)
        }
    }

    // MARK: - 도움

    static func analyzeTrack(_ target: String, snapshotPath: String?) async throws {
        var url = URL(filePath: target)
        var track: Track?
        var cues: [Cue] = []
        if !FileManager.default.fileExists(atPath: target) {
            let snapshot = try snapshotPath.map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
            let library = try RekordboxLibrary.load(snapshot: snapshot)
            guard let found = library.tracks.first(where: { $0.id == target }) else {
                print("트랙을 찾지 못했습니다: \(target)"); return
            }
            track = found
            cues = library.cues(for: found)
            url = URL(filePath: found.folderPath)
        }

        let started = Date()
        let analysis = try await PartAnalyzer.analyze(fileAt: url, cacheKey: track?.uuid)

        if let track { print("\(track.title) — \(track.artist ?? "")\n코멘트: \(track.comment)") }
        print(String(format: "길이 %@ · BPM %@ · 분석 %.1f초 · 통합 음량 %@ LUFS",
                     clock(analysis.duration),
                     analysis.bpm.map { String(format: "%.1f", $0) } ?? "-",
                     Date().timeIntervalSince(started),
                     analysis.integratedLoudness.map { String(format: "%.1f", $0) } ?? "-"))
        print("키: " + analysis.keys.map { "\(clock($0.span.start)) \($0.name)" }.joined(separator: " → "))
        print("마디 \(analysis.bars.count) · 섹션 \(analysis.sections.count) · 세그먼트 \(analysis.segments.count) · 프레이즈 \(analysis.phrases.count)\n")

        print("섹션별 에너지 (음량 LUFS / 보컬 / 드럼 / 점수)")
        for e in PartLabeler.energies(analysis) {
            print(String(format: "  %@–%@  %6.1f  %.2f  %.2f  %.2f",
                         clock(e.span.start), clock(e.span.end), e.loudness, e.vocal, e.drum, e.score))
        }

        print("\n파트 추정 v0")
        for m in PartLabeler.label(analysis) {
            print("  \(m.label.rawValue)\t\(clock(m.time))\t\(m.bar.map { "\($0)마디" } ?? "")\t신뢰도 \(m.confidence)")
        }

        if !cues.isEmpty {
            print("\nrekordbox 기존 큐 (직접 찍은 것)")
            for cue in cues.filter({ !$0.isAutoGenerated }).sorted(by: { $0.inMsec < $1.inMsec }) {
                let time = Double(cue.inMsec) / 1000
                let slot = cue.hotCueSlot.map { "핫큐 \($0)" } ?? "메모리"
                print("  \(slot)\t\(clock(time))\t\(analysis.barNumber(at: time).map { "\($0)마디" } ?? "")")
            }
        }
    }
}
