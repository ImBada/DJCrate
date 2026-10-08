import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// `djc xml-diff`: 다른 도구·rekordbox가 만든 rekordbox XML을 스냅샷 사본과 비교한다(#72 가져오기). 읽기만 한다.
/// 곡은 파일 경로로 맞추고, 큐·그리드·태그·재생 목록의 차이를 종류별로 센다(규칙은 `XMLLibraryDiff`).
enum XMLDiffCommand {
    static let command = Command("xml-diff", "--db <사본.db> --xml <파일.xml> [--share <폴더> | --no-analysis] [--limit N] [--json]",
                                 String(ui: "rekordbox XML과 라이브러리의 차이를 본다(읽기만)")) { args in
        let request = try request(args)
        let report = try report(request)
        if request.json {
            FileHandle.standardOutput.write(try json(report) + Data("\n".utf8))
        } else {
            for line in lines(report, limit: request.limit) { print(line) }
        }
    }

    struct Request: Equatable {
        var database: URL
        var xml: URL
        /// 분석 파일 뿌리. 없으면 사본 DB 옆 `share`(라이브 분석 파일로 대신하지 않는다)
        var share: URL?
        /// 그리드를 읽지 않고 비교하지도 않는다
        var noAnalysis = false
        var json = false
        /// 글 출력에서 곡·재생 목록을 몇 개까지 적을지
        var limit = 50
    }

    struct Report {
        var xml: XMLLibrary
        var library: XMLLibrary
        var diff: XMLLibraryDiff.Result
    }

    static func request(_ args: [String]) throws -> Request {
        var values: [String: String] = [:], flags: Set<String> = []
        var index = 1
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--db", "--xml", "--share", "--limit":
                guard values[arg] == nil, index + 1 < args.count, !args[index + 1].hasPrefix("--"), !args[index + 1].isEmpty else { throw UsageError() }
                values[arg] = args[index + 1]
                index += 1
            case "--json", "--no-analysis":
                guard flags.insert(arg).inserted else { throw UsageError() }
            default:
                throw UsageError()
            }
            index += 1
        }
        guard let db = values["--db"], let xml = values["--xml"], !(flags.contains("--no-analysis") && values["--share"] != nil) else {
            throw UsageError()
        }
        var limit = 50
        if let text = values["--limit"] {
            guard let value = Int(text), value >= 0 else { throw UsageError() }
            limit = value
        }
        return Request(database: URL(filePath: db), xml: URL(filePath: xml), share: values["--share"].map { URL(filePath: $0) },
                       noAnalysis: flags.contains("--no-analysis"), json: flags.contains("--json"), limit: limit)
    }

    /// 라이브 DB를 먼저 거부하고(DB·XML을 열기 전), XML과 사본을 읽어 비교한다.
    static func report(_ request: Request) throws -> Report {
        let snapshot = try LibraryRead.resolve(database: request.database)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.xml.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ReadFailure("missing_xml", String(ui: "XML 파일이 없습니다: \(request.xml.path). 파일 위치를 확인하세요"))
        }
        let share = try XMLExportCommand.shareRoot(share: request.share, noAnalysis: request.noAnalysis, snapshot: snapshot)
        let xml = try RekordboxXMLReader.read(url: request.xml)
        let library = try RekordboxXMLImport.library(snapshot: snapshot, shareRoot: share)
        return Report(xml: xml, library: library, diff: XMLLibraryDiff.compute(xml: xml, library: library))
    }

    // MARK: - 글

    static func lines(_ report: Report, limit: Int) -> [String] {
        let diff = report.diff, matching = diff.matching, counts = diff.counts
        var lines = [
            String(ui: "XML 곡 \(matching.xmlTracks) · 맞춘 곡 \(matching.matched) · 라이브러리에 없는 곡 \(matching.unmatched) · 여러 곡에 맞는 곡 \(matching.ambiguous)"),
            String(ui: "큐가 다른 곡 \(counts.cueTracks) · 그리드가 다른 곡 \(counts.gridTracks) · 태그가 다른 곡 \(counts.tagTracks)"),
            String(ui: "없는 재생 목록 \(counts.missingPlaylists) · 곡이 다른 재생 목록 \(counts.changedPlaylists) · 이름이 겹쳐 비교하지 않은 목록 \(counts.ambiguousPlaylists)"),
        ]
        if !report.library.hasGrids { lines.append(String(ui: "그리드는 비교하지 않았습니다(분석 파일을 읽지 않음)")) }
        if counts.xmlWithoutGrid > 0 { lines.append(String(ui: "XML에 그리드가 없어 비교하지 않은 곡 \(counts.xmlWithoutGrid)")) }
        let skipped = report.xml.skipped.sorted { $0.key < $1.key }.map { "\($0.key.label) \($0.value)" }
        if !skipped.isEmpty { lines.append(String(ui: "읽지 않고 건너뛴 것: \(skipped.joined(separator: " · "))")) }
        if diff.isEmpty {
            lines.append(String(ui: "차이가 없습니다"))
            return lines
        }
        for track in diff.tracks.prefix(limit) { lines.append("• " + summary(track)) }
        if diff.tracks.count > limit {
            lines.append(String(ui: "곡 \(diff.tracks.count - limit)개는 줄였습니다. --limit으로 늘리거나 --json으로 모두 보세요"))
        }
        for change in diff.playlists.prefix(limit) {
            let path = change.path.joined(separator: " / ")
            switch change.kind {
            case .missing: lines.append("• " + String(ui: "없는 재생 목록: \(path) (곡 \(change.xmlEntries.count))"))
            case .changed:
                lines.append("• " + String(ui: "곡이 다른 재생 목록: \(path) (XML \(change.xmlEntries.count)곡 · 라이브러리 \(change.libraryEntries.count)곡)"))
            }
        }
        if diff.playlists.count > limit {
            lines.append(String(ui: "재생 목록 \(diff.playlists.count - limit)개는 줄였습니다. --limit으로 늘리거나 --json으로 모두 보세요"))
        }
        return lines
    }

    /// 곡 한 줄: 경로 — 제목: 큐 +더할 것 −뺄 것 · 그리드 · 태그 칸
    static func summary(_ track: XMLLibraryDiff.TrackDiff) -> String {
        var parts: [String] = []
        if let cues = track.cues { parts.append(String(ui: "큐 +\(cues.added.count) −\(cues.removed.count)")) }
        if track.grid != nil { parts.append(String(ui: "그리드")) }
        if !track.tags.isEmpty {
            parts.append(String(ui: "태그 \(track.tags.map(\.key.label).joined(separator: "·"))"))
        }
        return "\(track.path) — \(track.title): \(parts.joined(separator: " · "))"
    }

    // MARK: - JSON

    struct JSONMark: Encodable {
        var kind: String
        var slot: String?
        var start: Double
        var end: Double?
        var name: String

        init(_ mark: XMLLibrary.Mark) {
            kind = mark.kind == .memory ? "memory" : "hot"
            slot = mark.kind.slotLetter
            start = mark.start; end = mark.end; name = mark.name
        }
    }

    struct JSONTag: Encodable {
        var key: String
        var library: String
        var xml: String
    }

    struct JSONCues: Encodable {
        var added: [JSONMark]
        var removed: [JSONMark]
    }

    struct JSONTrack: Encodable {
        var xmlID: String
        var libraryID: String
        var path: String
        var title: String
        var cues: JSONCues?
        var grid: XMLLibraryDiff.GridChange?
        var tags: [JSONTag]
    }

    struct JSONUnmatched: Encodable {
        var xmlID: String
        var path: String?
        var title: String
    }

    struct JSONPlaylist: Encodable {
        var kind: String
        var path: [String]
        var libraryID: String?
        var xmlEntries: [String]
        var libraryEntries: [String]
        var unmatchedEntries: Int
    }

    struct JSONReport: Encodable {
        var gridsCompared: Bool
        var matching: XMLLibraryDiff.Matching
        var counts: XMLLibraryDiff.Counts
        var skipped: [String: Int]
        var tracks: [JSONTrack]
        var unmatched: [JSONUnmatched]
        var ambiguous: [JSONUnmatched]
        var playlists: [JSONPlaylist]
    }

    static func json(_ report: Report) throws -> Data {
        let diff = report.diff
        let byKey = Dictionary(report.xml.tracks.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        func records(_ keys: [String]) -> [JSONUnmatched] {
            keys.map { JSONUnmatched(xmlID: $0, path: byKey[$0]?.path, title: byKey[$0]?.title ?? "") }
        }
        let body = JSONReport(
            gridsCompared: report.library.hasGrids, matching: diff.matching, counts: diff.counts,
            skipped: Dictionary(uniqueKeysWithValues: report.xml.skipped.map { ($0.key.rawValue, $0.value) }),
            tracks: diff.tracks.map { track in
                JSONTrack(xmlID: track.xmlKey, libraryID: track.libraryKey, path: track.path, title: track.title,
                          cues: track.cues.map { JSONCues(added: $0.added.map(JSONMark.init), removed: $0.removed.map(JSONMark.init)) },
                          grid: track.grid, tags: track.tags.map { JSONTag(key: $0.key.rawValue, library: $0.library, xml: $0.xml) })
            },
            unmatched: records(diff.matches.unmatched), ambiguous: records(diff.matches.ambiguous),
            playlists: diff.playlists.map {
                JSONPlaylist(kind: $0.kind.rawValue, path: $0.path, libraryID: $0.libraryID, xmlEntries: $0.xmlEntries,
                             libraryEntries: $0.libraryEntries, unmatchedEntries: $0.unmatchedEntries)
            })
        return try ReadJSON.encode(command: "xml-diff", data: body)
    }
}
