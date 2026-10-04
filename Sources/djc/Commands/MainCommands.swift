import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AVFoundation
import Foundation

/// 늘 쓰는 명령: 스냅샷·현황·파싱·분석, rekordbox 쓰기·되돌리기, 테스트 픽스처.
enum MainCommands {
    static let all: [Command] = [
        Command("snapshot", "[--force]", String(ui: "rekordbox master.db 스냅샷을 뜬다"), snapshot),
        Command("report", "[--db PATH] [--files] [--comment-preset none|anisong] [--json]", String(ui: "라이브러리 현황(기본: 최신 스냅샷)"), report),
        Command("analyze", String(ui: "<파일|ContentID> [--db PATH]"), String(ui: "곡 파트 분석(ContentID면 기존 큐와 비교)"), analyze),
        Command("reflection-dry-run", nil, String(ui: "초안으로 반영 계획을 만들어 XML을 지정한 곳에만 쓴다(rekordbox는 그대로)"), reflectionDryRun),
        Command("cue-write", String(ui: "--db <사본.db> [--dry-run] [--uuid U] | --live"), String(ui: "큐 초안을 rekordbox DB에 직접 쓴다"), cueWrite),
        Command("track-add", String(ui: "--db <사본.db> [--share <분석 뿌리>] [--analyze] [--dry-run] <음원…> | --live …"),
                String(ui: "음원을 rekordbox 컬렉션에 넣는다(--analyze면 그리드·파형·오토게인까지, 기본은 사본)"), trackAdd),
        Command("track-delete", String(ui: "--db <사본.db> [--share <분석 뿌리>] [--dry-run] <ContentID…> | --live …"), String(ui: "곡을 rekordbox 컬렉션에서 뺀다(음원 파일은 그대로)"), trackDelete),
        Command("playlist-write", String(ui: "--db <사본.db> [--dry-run] <편집.json>"),
                String(ui: "재생 목록 편집(JSON 배열)을 사본 DB와 그 옆 masterPlaylists6.xml에 쓴다(라이브 라이브러리는 거부)"), playlistWrite),
        Command("rekordbox-restore", String(ui: "[--backup <폴더> (--db <사본> | --live) [--share <폴더>]]"), String(ui: "백업으로 되돌린다"), rekordboxRestore),
        Command("schema-dump", String(ui: "<사본.db> <출력.sql>"), String(ui: "사본 DB의 구조(CREATE 문)만 뽑는다"), schemaDump),
        Command("path", String(ui: "<제목> [--db PATH] [--json]"), String(ui: "제목으로 파일 경로 찾기"), path),
        Command("parse", String(ui: "\"<코멘트>\" [--json]"), String(ui: "애니송 프리셋으로 코멘트 파싱"), parse),
    ] + ReadCommands.all + UsbCommands.all

    static func snapshot(_ args: [String]) async throws {
        let url = try LibrarySnapshot.take(force: args.contains("--force"))
        print(url.path)
    }

    static func report(_ args: [String]) async throws {
        let preset: CommentPreset
        if args.contains("--comment-preset") {
            guard let raw = value(after: "--comment-preset", in: args), let selected = CommentPreset(rawValue: raw) else {
                throw ReadFailure("invalid_arguments", String(ui: "코멘트 프리셋은 --comment-preset none 또는 anisong으로 쓰세요"))
            }
            preset = selected
        } else { preset = .none }
        let snapshot = try LibraryRead.resolve(database: value(after: "--db", in: args).map { URL(filePath: $0) })
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        print(String(ui: "스냅샷: \(snapshot.path)\n"))
        print(LibraryReport(library: library, checkFiles: args.contains("--files"), commentRule: preset.rule).render())
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
            print(String(ui: "• \(track.title.prefix(30)) · 큐 변경 \(draft?.changes.count ?? 0) · 그리드 변경 \(String(plan.gridChanged)) · 표시 \(plan.beforeMarks.count)→\(plan.marks.count) · ") +
                  (plan.isEligible ? String(ui: "반영 가능") : plan.blockers.isEmpty ? String(ui: "변경 없음") : String(ui: "막힘: \(plan.blockers.joined(separator: " / "))")))
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
            print(String(ui: "\(mark) \(outcome.title.prefix(34)) — 지움 \(outcome.removed) · 넣음 \(outcome.added)\(outcome.reason.map { " · \($0)" } ?? "")"))
        }
        print(String(ui: "\(report.dryRun ? String(ui: "미리 보기(되돌림)") : String(ui: "씀")) · 쓴 곡 \(report.written.count) · 막힌 곡 \(report.blocked.count) · 백업 \(report.backup ?? String(ui: "없음"))"))
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
                    print(String(ui: "· \(plan.fileName): 그리드를 추정하지 못해 분석 없이 넣습니다")); continue
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
        print(String(ui: "\(report.dryRun ? String(ui: "미리 보기(되돌림)") : String(ui: "넣음")) · \(report.added.filter(\.written).count)곡 · 만든 파일(분석·앨범아트) \(report.createdFiles.count)개 · 백업 \(report.backup ?? String(ui: "없음"))"))
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
        print(String(ui: "\(report.dryRun ? String(ui: "미리 보기(되돌림)") : String(ui: "뺌")) · \(report.deleted.filter(\.written).count)곡 · 지운 파일(분석·앨범아트) \(report.removedFiles.count)개 · 백업 \(report.backup ?? String(ui: "없음"))"))
    }

    /// 재생 목록 편집을 사본에 쓴다. 편집 JSON 예: `[{"create":{"key":"f","name":"새 폴더","isFolder":true,"parent":"root"}},
    /// {"addTracks":{"playlist":"new:f","contentIDs":["123"]}}]`. 라이브 라이브러리는 앱의 반영으로만 쓴다.
    static func playlistWrite(_ args: [String]) async throws {
        guard let path = value(after: "--db", in: args), let file = operands(args, valued: ["--db"]).first else { throw UsageError() }
        let database = URL(filePath: path)
        let real = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer/rekordbox/master.db")
        guard database.resolvingSymlinksInPath().standardizedFileURL.path != real.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw DJCError.writeRefused(String(ui: "playlist-write는 사본에만 씁니다. rekordbox 라이브러리는 앱의 반영으로 쓰세요"))
        }
        let edits = try JSONDecoder().decode([PlaylistEdit].self, from: Data(contentsOf: URL(filePath: file)))
        let report = try RekordboxWriter.write(drafts: [], playlists: edits, to: database, dryRun: args.contains("--dry-run"),
                                               backups: database.deletingLastPathComponent().appending(path: "backups"))
        for o in report.playlistOutcomes ?? [] {
            let mark = switch o.status { case .written: "✓"; case .blocked: "✗"; case .unchanged: "·" }
            print("\(mark) \(o.name.prefix(34))\(o.playlistID.map { " · ID \($0)" } ?? "")\(o.reason.map { " · \($0)" } ?? "")")
        }
        print(String(ui: "\(report.dryRun ? String(ui: "미리 보기(되돌림)") : String(ui: "씀")) · 쓴 편집 \(report.playlistWritten.count) · 막힌 편집 \(report.playlistBlocked.count) · 카운터 \(report.finalUpdateCount.map(String.init) ?? "-") · 백업 \(report.backup ?? String(ui: "없음"))"))
    }

    /// 백업으로 되돌린다. 기본은 --db 사본. 라이브 DB는 --live(rekordbox가 꺼져 있어야 한다). 백업 목록은 인자 없이.
    static func rekordboxRestore(_ args: [String]) async throws {
        let live = args.contains("--live")
        guard let folder = value(after: "--backup", in: args), live || value(after: "--db", in: args) != nil else {
            for backup in RekordboxWriter.backups(in: DJCPaths.rekordboxBackups) {
                print(backup.url.lastPathComponent, "·", backup.titles.prefix(5).joined(separator: ", "), String(ui: "· 카운터"), backup.report?.finalUpdateCount ?? -1)
            }
            throw UsageError()
        }
        let database = live ? RekordboxWriter.liveDatabase : URL(filePath: value(after: "--db", in: args)!)
        let saved = try RekordboxWriter.restore(URL(filePath: folder), to: database,
                                                backups: live ? DJCPaths.rekordboxBackups : database.deletingLastPathComponent().appending(path: "backups"),
                                                shareRoot: value(after: "--share", in: args).map { URL(filePath: $0) })
        print(String(ui: "되돌림 완료 · 되돌리기 전 상태 백업: \(saved.path)"))
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
        print(String(ui: "구조 \(statements.count)개 → \(args[2]) · DBVersion \(version)"))
    }

    /// 제목으로 파일 경로 찾기(개발용)
    static func path(_ args: [String]) async throws {
        let library = try RekordboxLibrary.load(snapshot: LibraryRead.resolve(database: value(after: "--db", in: args).map { URL(filePath: $0) }))
        guard args.count > 1 else { return }
        for track in library.tracks where track.title.contains(args[1]) && !track.isStreaming { print(track.folderPath) }
    }

    static func parse(_ args: [String]) async throws {
        guard args.count > 1 else { throw UsageError() }
        let comment = args[1]
        let rule = AnisongCommentRule()
        print(String(ui: "분류: \(rule.evaluate(comment).classification)"))
        if let parsed = rule.parse(comment) {
            dump(parsed)
        }
    }

    private static func partName(_ label: PartLabeler.Label) -> String {
        switch label {
        case .firstChorus: String(ui: "1사비")
        case .secondChorus: String(ui: "2사비")
        case .lastChorus: String(ui: "라사비")
        case .interlude: String(ui: "간주")
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
                print(String(ui: "트랙을 찾지 못했습니다: \(target)")); return
            }
            track = found
            cues = library.cues(for: found)
            url = URL(filePath: found.folderPath)
        }

        let started = Date()
        let analysis = try await PartAnalyzer.analyze(fileAt: url, cacheKey: track?.uuid)

        if let track { print(String(ui: "\(track.title) — \(track.artist ?? "")\n코멘트: \(track.comment)")) }
        print(String(ui: "길이 \(clock(analysis.duration)) · BPM \(analysis.bpm.map { String(format: "%.1f", $0) } ?? "-") · 분석 \(Date().timeIntervalSince(started), specifier: "%.1f")초 · 통합 음량 \(analysis.integratedLoudness.map { String(format: "%.1f", $0) } ?? "-") LUFS"))
        print(String(ui: "키: \(analysis.keys.map { "\(clock($0.span.start)) \($0.name)" }.joined(separator: " → "))"))
        print(String(ui: "마디 \(analysis.bars.count) · 섹션 \(analysis.sections.count) · 세그먼트 \(analysis.segments.count) · 프레이즈 \(analysis.phrases.count)\n"))

        print(String(ui: "섹션별 에너지 (음량 LUFS / 보컬 / 드럼 / 점수)"))
        for e in PartLabeler.energies(analysis) {
            print(String(format: "  %@–%@  %6.1f  %.2f  %.2f  %.2f",
                         clock(e.span.start), clock(e.span.end), e.loudness, e.vocal, e.drum, e.score))
        }

        print(String(ui: "\n파트 추정 v0"))
        for m in PartLabeler.label(analysis) {
            print(String(ui: "  \(partName(m.label))\t\(clock(m.time))\t\(m.bar.map { String(ui: "\($0)마디") } ?? "")\t신뢰도 \(String(m.confidence))"))
        }

        if !cues.isEmpty {
            print(String(ui: "\nrekordbox 기존 큐 (직접 찍은 것)"))
            for cue in cues.filter({ !$0.isAutoGenerated }).sorted(by: { $0.inMsec < $1.inMsec }) {
                let time = Double(cue.inMsec) / 1000
                let slot = cue.hotCueSlot.map { String(ui: "핫큐 \(String($0))") } ?? String(ui: "메모리")
                print("  \(slot)\t\(clock(time))\t\(analysis.barNumber(at: time).map { String(ui: "\($0)마디") } ?? "")")
            }
        }
    }
}
