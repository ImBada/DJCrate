import DJCAnalysis
import DJCDomain
import Foundation
import RekordboxKit

/// 곡 추가·삭제 규칙을 맞출 때 쓰는 실험(읽기 전용).
enum TrackLab {
    static let all: [Command] = [
        Command("track-add-plan", "<음원 파일…>", "파일로 만든 곡 추가 계획을 JSON으로(규칙 맞추기용)", TrackLab.trackAddPlan),
        Command("analysis-repro", "<ContentID…> [--db 스냅샷]", "rekordbox 분석 파일을 같은 그리드로 다시 만들어 태그마다 비교(파형은 수치로)", TrackLab.analysisRepro),
        Command("facts-check", "[--limit N] [--db 스냅샷]", "음원 정보(비트레이트·샘플레이트·비트)를 rekordbox 곡 행과 형식별로 비교", TrackLab.factsCheck),
        Command("pvbr-check", "[--db 스냅샷]", "라이브러리 MP3마다 만든 PVBR·비트레이트를 rekordbox .DAT와 바이트로 비교", TrackLab.pvbrCheck),
        Command("pvb2-check", "[--db 스냅샷]", "라이브러리 FLAC마다 만든 PVB2(.EXT 탐색표)·음원 칸을 rekordbox와 바이트로 비교", TrackLab.pvb2Check),
        Command("track-add-repro", "--db <스냅샷> <음원 파일…>", "파일로 곡 추가 계획을 만들어 rekordbox가 넣은 행과 칸마다 비교", TrackLab.trackAddRepro),
        Command("analysis-attach-test", "--db <사본.db> --share <사본 share> [--grid-from <.DAT>] <ContentID…>",
                "분석 전 곡에 분석 파일을 붙여 본다(사본만, 막아 둔 쓰기 경로를 열어서). 그리드는 .DAT에서 읽거나 추정", TrackLab.analysisAttachTest),
    ]

    static func trackAddPlan(_ args: [String]) async throws {
        guard args.count > 1 else { throw UsageError() }
        var plans: [TrackAddPlan] = []
        for file in args.dropFirst() {
            let url = URL(filePath: file)
            plans.append(try TrackAddPlan.make(url: url, tags: try await AudioTags.read(url: url)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(plans), as: UTF8.self))
    }

    static func analysisRepro(_ args: [String]) async throws {
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let ids = MainCommands.operands(args, valued: ["--db"])
        guard !ids.isEmpty else { throw UsageError() }
        let db = try CipherDatabase(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        for id in ids {
            var row: (path: String, dat: String, bitRate: Int, sampleRate: Int, bitDepth: Int, length: Int)?
            try db.query("SELECT FolderPath, AnalysisDataPath, BitRate, SampleRate, BitDepth, Length FROM djmdContent WHERE ID = ?", [.text(id)]) { r in
                row = (r.string(0) ?? "", r.string(1) ?? "", r.int(2) ?? 0, r.int(3) ?? 0, r.int(4) ?? 0, r.int(5) ?? 0)
            }
            guard let row, let datURL = RekordboxShare.analysisURL(row.dat) else { print("✘ \(id): 곡 없음"); continue }
            let url = URL(filePath: row.path)
            let facts = AudioFacts.read(url: url)
            let rbDat = try AnlzFile(url: datURL)
            let rbExt = try AnlzFile(url: datURL.deletingPathExtension().appendingPathExtension("EXT"))
            let beats = BeatGridTags.decode(pqtz: rbDat.tag("PQTZ")!.bytes, pqt2: nil).beats
            let waves = try RekordboxWaveforms.analyze(url: url)
            let tags = try await AudioTags.read(url: url)
            let files = try TrackAnalysisFiles.make(fileName: url.lastPathComponent.precomposedStringWithCanonicalMapping, beats: beats,
                                                    waveforms: waves, facts: facts)
            let ours = try AnlzFile(data: files.dat), oursExt = try AnlzFile(data: files.ext)
            print("== \(url.lastPathComponent.prefix(40)) · \(facts.unsupported ?? "분석 붙이기 가능")")
            print("   칸: 비트레이트 rb \(row.bitRate)/djc \(facts.bitRate) · 샘플레이트 \(row.sampleRate)/\(facts.sampleRate) · 비트 \(row.bitDepth)/\(facts.bitDepth) · 길이 \(row.length)/\(Int(tags.duration))")
            print("   .DAT 태그 순서 rb \(rbDat.tags.map(\.fourcc).joined(separator: " ")) / djc \(ours.tags.map(\.fourcc).joined(separator: " "))")
            print("   .DAT 머리 같음 \(rbDat.header == ours.header) · " + ["PPTH", "PVBR", "PQTZ", "PCOB"].map { name in
                "\(name) \(rbDat.tags.filter { $0.fourcc == name }.map(\.bytes) == ours.tags.filter { $0.fourcc == name }.map(\.bytes) ? "같음" : "다름")"
            }.joined(separator: " · "))
            print("   .EXT 태그 순서 rb \(rbExt.tags.map(\.fourcc).joined(separator: " ")) / djc \(oursExt.tags.map(\.fourcc).joined(separator: " "))")
            if let a = rbDat.tag("PVBR"), let b = ours.tag("PVBR"), a.bytes != b.bytes {
                print("   PVBR 끝값 rb \(a.bytes.suffix(4).map { String(format: "%02x", $0) }.joined()) / djc \(b.bytes.suffix(4).map { String(format: "%02x", $0) }.joined())")
            }
            if let a = rbDat.tag("PPTH"), let b = ours.tag("PPTH"), a.bytes != b.bytes { print("   PPTH rb \(a.bytes.count)바이트 / djc \(b.bytes.count)바이트") }
        }
    }

    static func factsCheck(_ args: [String]) async throws {
        let limit = Int(value(after: "--limit", in: args) ?? "") ?? 60
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let db = try CipherDatabase(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        var rows: [(type: Int, path: String, bitRate: Int, sampleRate: Int, bitDepth: Int)] = []
        try db.query("""
            SELECT FileType, FolderPath, BitRate, SampleRate, BitDepth FROM djmdContent
            WHERE rb_local_deleted = 0 AND Analysed = 105 AND FolderPath LIKE '/%' ORDER BY random() LIMIT ?
            """, [.int(limit)]) { rows.append(($0.int(0) ?? 0, $0.string(1) ?? "", $0.int(2) ?? 0, $0.int(3) ?? 0, $0.int(4) ?? 0)) }
        var tally: [String: (all: Int, same: Int)] = [:]
        for row in rows where FileManager.default.fileExists(atPath: row.path) {
            let facts = AudioFacts.read(url: URL(filePath: row.path))
            let key = "형식 \(row.type)\(facts.unsupported == nil ? "" : " (분석 안 붙임)")"
            let same = facts.bitRate == row.bitRate && facts.sampleRate == row.sampleRate && facts.bitDepth == row.bitDepth
            tally[key, default: (0, 0)].all += 1
            if same { tally[key]!.same += 1 } else if facts.unsupported == nil {
                print("✘ \((row.path as NSString).lastPathComponent.prefix(36)) · 비트레이트 \(row.bitRate)/\(facts.bitRate) · 샘플레이트 \(row.sampleRate)/\(facts.sampleRate) · 비트 \(row.bitDepth)/\(facts.bitDepth)")
            }
        }
        for (key, t) in tally.sorted(by: { $0.key < $1.key }) { print("\(key): \(t.same)/\(t.all) 같음") }
    }

    static func pvbrCheck(_ args: [String]) async throws {
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let db = try CipherDatabase(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        var rows: [(path: String, dat: String, bitRate: Int)] = []
        try db.query("SELECT FolderPath, AnalysisDataPath, BitRate FROM djmdContent WHERE rb_local_deleted = 0 AND FileType = 1 AND Analysed = 105 AND FolderPath LIKE '/%'") {
            rows.append(($0.string(0) ?? "", $0.string(1) ?? "", $0.int(2) ?? 0))
        }
        var tally: [String: (all: Int, pvbr: Int, bitRate: Int)] = [:]
        var shown = 0
        for row in rows where FileManager.default.fileExists(atPath: row.path) {
            guard let datURL = RekordboxShare.analysisURL(row.dat), let dat = try? AnlzFile(url: datURL), let rb = dat.tag("PVBR") else { continue }
            let facts = AudioFacts.read(url: URL(filePath: row.path))
            let kind = facts.unsupported != nil ? "막음" : (facts.pvbrEntries.isEmpty ? "CBR" : "VBR")
            let same = TrackAnalysisFiles.pvbr(facts) == rb.bytes
            tally[kind, default: (0, 0, 0)].all += 1
            if same { tally[kind]!.pvbr += 1 }
            if facts.bitRate == row.bitRate { tally[kind]!.bitRate += 1 }
            if kind != "막음", !same || facts.bitRate != row.bitRate, shown < 10 {
                shown += 1
                print("✘ \((row.path as NSString).lastPathComponent.prefix(36)) · \(kind) · PVBR \(same ? "같음" : "다름") · 비트레이트 \(row.bitRate)/\(facts.bitRate)")
            }
        }
        for (kind, t) in tally.sorted(by: { $0.key < $1.key }) { print("\(kind): \(t.all)곡 · PVBR 같음 \(t.pvbr) · 비트레이트 같음 \(t.bitRate)") }
    }

    static func pvb2Check(_ args: [String]) async throws {
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let db = try CipherDatabase(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        var rows: [(path: String, dat: String, sampleRate: Int, bitDepth: Int, bitRate: Int)] = []
        try db.query("SELECT FolderPath, AnalysisDataPath, SampleRate, BitDepth, BitRate FROM djmdContent WHERE rb_local_deleted = 0 AND FileType = 5 AND Analysed = 105 AND FolderPath LIKE '/%'") {
            rows.append(($0.string(0) ?? "", $0.string(1) ?? "", $0.int(2) ?? 0, $0.int(3) ?? 0, $0.int(4) ?? 0))
        }
        var all = 0, same = 0, sameSamples = 0, cells = 0, blocked = 0, shown = 0
        for row in rows where FileManager.default.fileExists(atPath: row.path) {
            guard let datURL = RekordboxShare.analysisURL(row.dat),
                  let ext = try? AnlzFile(url: datURL.deletingPathExtension().appendingPathExtension("EXT")), let rb = ext.tag("PVB2") else { continue }
            all += 1
            let facts = AudioFacts.read(url: URL(filePath: row.path))
            guard facts.unsupported == nil, let ours = TrackAnalysisFiles.pvb2(facts) else { blocked += 1; continue }
            if (facts.sampleRate, facts.bitDepth, facts.bitRate) == (row.sampleRate, row.bitDepth, row.bitRate) { cells += 1 }
            if ours == rb.bytes { same += 1; sameSamples += 1; continue }
            // 칸마다 시작 샘플만 같은지(바이트 위치만 다르면 분석 뒤 파일이 바뀐 것)
            let samples = { (d: Data) in stride(from: 32, to: d.count, by: 20).map { d.subdata(in: $0..<$0 + 8) } }
            if samples(ours) == samples(rb.bytes) { sameSamples += 1 }
            if shown < 10 {
                shown += 1
                print("✘ \((row.path as NSString).lastPathComponent.prefix(36)) · 샘플 \(samples(ours) == samples(rb.bytes) ? "같음(바이트 위치만 다름)" : "다름")")
            }
        }
        print("FLAC \(all)곡 · PVB2 같음 \(same) · 시작 샘플까지 같음 \(sameSamples) · 샘플레이트·비트·비트레이트 같음 \(cells) · 막음 \(blocked)")
    }

    /// 파일마다 DJCrate 계획과 rekordbox가 넣은 행(같은 경로)을 칸마다 비교한다.
    /// 분석 붙이기를 사본에 써 본다. rekordbox 실험(기존 분석 전 곡을 rekordbox가 분석) 전 사본에 같은 곡을 써서
    /// `djc lab db-diff`로 rekordbox 결과와 칸마다 비교할 때 쓴다. 라이브 DB·실제 분석 폴더는 거부한다.
    static func analysisAttachTest(_ args: [String]) async throws {
        guard let dbPath = value(after: "--db", in: args), let sharePath = value(after: "--share", in: args) else { throw UsageError() }
        let database = URL(filePath: dbPath), share = URL(filePath: sharePath)
        func same(_ a: URL, _ b: URL) -> Bool { a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path }
        guard !same(database, RekordboxWriter.liveDatabase), !same(share, LibrarySnapshot.rekordboxDirectory.appending(path: "share")),
              !share.appending(path: "PIONEER/USBANLZ").resolvingSymlinksInPath().path.hasPrefix(
                  FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer").resolvingSymlinksInPath().path) else {
            print("라이브 rekordbox DB·분석 폴더에는 쓰지 않습니다. 사본을 주세요"); return
        }
        let ids = MainCommands.operands(args, valued: ["--db", "--share", "--grid-from"])
        guard !ids.isEmpty else { throw UsageError() }
        let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
        var tracks: [(id: String, uuid: String, path: String)] = []
        for id in ids {
            try db.query("SELECT ID, UUID, FolderPath FROM djmdContent WHERE ID = ? AND rb_local_deleted = 0", [.text(id)]) {
                tracks.append(($0.string(0) ?? "", $0.string(1) ?? "", $0.string(2) ?? ""))
            }
        }
        db.close()
        var grids: [GridDraft] = [], inputs: [String: RekordboxWriter.AnalysisInput] = [:]
        for track in tracks {
            let url = URL(filePath: track.path)
            var segments: [GridSegment]
            if let dat = value(after: "--grid-from", in: args) {
                segments = GridDraft.segments(from: try BeatGrid.load(anlz: URL(filePath: dat)))
            } else {
                // 음원 시간축 추정을 rekordbox 시간축으로 옮긴다(곡 넣기 --analyze와 같다)
                guard let estimate = try await GridSuggestion.estimate(fileAt: url, cacheKey: "attach-\(track.uuid)") else {
                    print("✗ \(track.id): 그리드를 추정하지 못했습니다"); continue
                }
                let offset = RekordboxTimeline.predictedOffset(url: url)
                segments = estimate.segments.map { var s = $0; s.start += offset; return s }
            }
            let loudness = try Loudness.measure(fileAt: url)
            inputs[track.uuid] = .init(duration: try await AudioTags.read(url: url).duration, loudness: loudness.integrated,
                                       peak: pow(10, loudness.peak / 20))
            grids.append(GridDraft(trackUUID: track.uuid, base: [], segments: segments))
            print(String(format: "· %@: %.2f BPM · 첫 박 %.4f초 · %.1f LUFS", track.id, segments.first?.bpm ?? 0, segments.first?.start ?? 0,
                         loudness.integrated ?? .nan))
        }
        let report = try RekordboxWriter.write(drafts: [], grids: grids, gains: [:], analysisInputs: inputs, to: database,
                                               dryRun: args.contains("--dry-run"), now: .now,
                                               backups: database.deletingLastPathComponent().appending(path: "backups"), shareRoot: share,
                                               attachesAnalysis: true)
        for o in (report.analysisOutcomes ?? []) + (report.gridOutcomes ?? []) {
            print("\(o.status == .written ? "✓" : "✗") \(o.title.prefix(40)) · 박 \(o.added)\(o.reason.map { " · \($0)" } ?? "")")
        }
        print("\(report.dryRun ? "미리 보기(되돌림)" : "씀") · 분석 파일 \(report.createdFiles?.count ?? 0)개 · 변경 카운터 \(report.finalUpdateCount.map(String.init) ?? "-") · 백업 \(report.backup ?? "없음")")
    }

    static func trackAddRepro(_ args: [String]) async throws {
        guard let dbPath = value(after: "--db", in: args) else { throw UsageError() }
        let files = args.dropFirst().filter { $0 != "--db" && $0 != dbPath }
        guard !files.isEmpty else { throw UsageError() }
        let db = try CipherDatabase(path: dbPath, key: RekordboxKey.derive())
        defer { db.close() }
        func name(_ table: String, _ id: String?) throws -> String? {
            guard let id, !id.isEmpty else { return nil }
            var result: String?
            try db.query("SELECT Name FROM \(table) WHERE ID = ?", [.text(id)]) { result = $0.string(0) }
            return result
        }
        var total = 0, matched = 0
        for file in files {
            let url = URL(filePath: file)
            let plan = try TrackAddPlan.make(url: url, tags: try await AudioTags.read(url: url))
            var row: [String: String?] = [:]
            let columns = ["Title", "FileNameL", "ArtistID", "AlbumID", "GenreID", "ComposerID", "Commnt", "ReleaseYear", "TrackNo", "DiscNo",
                           "ISRC", "Lyricist", "FileType", "FileSize", "rb_file_id", "DateCreated", "StockDate", "Length", "Analysed"]
            try db.query("SELECT \(columns.joined(separator: ", ")) FROM djmdContent WHERE FolderPath = ? AND rb_local_deleted = 0",
                         [.text(plan.path)]) { r in
                for (i, c) in columns.enumerated() { row[c] = r.string(Int32(i)) }
            }
            guard !row.isEmpty else { print("✘ \(plan.fileName): rekordbox 행 없음"); continue }
            var albumArtist: String?
            if let albumID = row["AlbumID"] ?? nil {
                try db.query("SELECT AlbumArtistID FROM djmdAlbum WHERE ID = ?", [.text(albumID)]) { albumArtist = $0.string(0) }
            }
            let rekordbox: [(String, String?)] = [
                ("제목", row["Title"] ?? nil), ("파일 이름", row["FileNameL"] ?? nil), ("아티스트", try name("djmdArtist", row["ArtistID"] ?? nil)),
                ("앨범", try name("djmdAlbum", row["AlbumID"] ?? nil)), ("앨범 아티스트", try name("djmdArtist", albumArtist)),
                ("장르", try name("djmdGenre", row["GenreID"] ?? nil)), ("작곡가", try name("djmdArtist", row["ComposerID"] ?? nil)),
                ("코멘트", row["Commnt"] ?? nil), ("연도", row["ReleaseYear"] ?? nil), ("트랙", row["TrackNo"] ?? nil), ("디스크", row["DiscNo"] ?? nil),
                ("ISRC", row["ISRC"] ?? nil), ("작사", row["Lyricist"] ?? nil), ("형식", row["FileType"] ?? nil), ("크기", row["FileSize"] ?? nil),
                ("파일 ID", row["rb_file_id"] ?? nil), ("만든 날", row["DateCreated"] ?? nil), ("넣은 날", row["StockDate"] ?? nil),
                ("길이", row["Length"] ?? nil),
            ]
            let ours: [String?] = [plan.title, plan.fileName, plan.artist, plan.album, plan.albumArtist, plan.genre, plan.composer, plan.comment,
                                   String(plan.year), String(plan.trackNumber), String(plan.discNumber), plan.isrc, plan.lyricist,
                                   String(plan.fileType), String(plan.fileSize), plan.fileID, plan.dateCreated, plan.stockDate, String(plan.length)]
            var diffs: [String] = []
            for ((label, theirs), mine) in zip(rekordbox, ours) {
                total += 1
                if (theirs ?? "") == (mine ?? "") { matched += 1 } else { diffs.append("\(label): rekordbox「\(theirs ?? "nil")」 · DJC「\(mine ?? "nil")」") }
            }
            let analysed = (row["Analysed"] ?? nil) ?? "0"
            print("\(diffs.isEmpty ? "✔" : "✘") \(plan.fileName.prefix(40)) (분석 \(analysed))" + (diffs.isEmpty ? "" : "\n    " + diffs.joined(separator: "\n    ")))
        }
        print("칸 \(total)개 중 \(matched)개 같음")
    }
}
