import DJCDomain
import Foundation
import RekordboxKit

/// 곡 추가·삭제 규칙을 맞출 때 쓰는 실험(읽기 전용).
enum TrackLab {
    static let all: [Command] = [
        Command("track-add-plan", "<음원 파일…>", "파일로 만든 곡 추가 계획을 JSON으로(규칙 맞추기용)", TrackLab.trackAddPlan),
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
