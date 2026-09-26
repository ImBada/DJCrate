import DJCDomain
import Foundation
import RekordboxKit

/// 곡 추가·삭제 규칙을 맞출 때 쓰는 실험(읽기 전용).
enum TrackLab {
    static let all: [Command] = [
        Command("track-add-plan", "<음원 파일…>", "파일로 만든 곡 추가 계획을 JSON으로(규칙 맞추기용)", TrackLab.trackAddPlan),
        Command("analysis-repro", "<ContentID…> [--db 스냅샷]", "rekordbox 분석 파일을 같은 그리드로 다시 만들어 태그마다 비교(파형은 수치로)", TrackLab.analysisRepro),
        Command("facts-check", "[--limit N] [--db 스냅샷]", "음원 정보(비트레이트·샘플레이트·비트)를 rekordbox 곡 행과 형식별로 비교", TrackLab.factsCheck),
        Command("track-add-repro", "--db <스냅샷> <음원 파일…>", "파일로 곡 추가 계획을 만들어 rekordbox가 넣은 행과 칸마다 비교", TrackLab.trackAddRepro),
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

    /// 파일마다 DJCrate 계획과 rekordbox가 넣은 행(같은 경로)을 칸마다 비교한다.
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
