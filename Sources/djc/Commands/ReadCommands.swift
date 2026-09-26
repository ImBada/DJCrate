import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 인자와 출력만 맡고, 조회·JSON 계약은 DJCStorage에서 검증한다.
enum ReadCommands {
    static let names: Set<String> = ["search", "track", "playlists", "playlist", "histories", "history", "drafts"]
    static let jsonNames = names.union(["report", "path", "parse", "compat"])
    static let all: [Command] = [
        Command("search", "<검색어> [--bpm 최소-최대] [--key 키] [--playlist ID] [--filter 필터] [--db PATH] [--json]", "곡 찾기", run),
        Command("track", "<ContentID> [--db PATH] [--json]", "곡 정보·큐·그리드·게인·초안 보기", run),
        Command("playlists", "[--tree] [--db PATH] [--json]", "재생 목록·폴더 보기", run),
        Command("playlist", "<ID> [--db PATH] [--json]", "재생 목록의 곡을 순서대로 보기", run),
        Command("histories", "[--db PATH] [--json]", "재생 기록을 날짜순으로 보기", run),
        Command("history", "<ID> [--db PATH] [--json]", "기록의 곡을 재생 순서대로 보기", run),
        Command("drafts", "[--db PATH] [--json]", "반영 대기 초안 보기", run),
    ]

    static func handlesJSON(_ args: [String]) -> Bool {
        args.contains("--json") && jsonNames.contains(args.first ?? "")
    }

    static func run(_ args: [String]) async throws {
        let options = try Options(args)
        let name = args[0]
        if name == "parse" {
            try output(LibraryRead.parse(comment: options.operands[0]), name: name, json: true) { _ in "" }
            return
        }
        let explicit = options.values["--db"].map { URL(filePath: $0) }
        let snapshot = try LibraryRead.resolve(database: explicit)
        if name == "compat" {
            try output(LibraryRead.compatibility(snapshot: snapshot, version: RekordboxCompatibility.installedAppVersion()),
                       name: name, json: true) { _ in "" }
            return
        }
        let read = try LibraryRead(snapshot: snapshot, shareRoot: explicit == nil ? RekordboxShare.directory : nil)
        let json = options.flags.contains("--json")
        switch name {
        case "search":
            let result = try read.search(query: options.operands[0], bpm: options.bpm, key: options.values["--key"],
                                         playlistID: options.values["--playlist"], filter: options.filter)
            try output(result, name: name, json: json) { tracksText($0.tracks) }
        case "track":
            try output(read.track(id: options.operands[0]), name: name, json: json, text: trackText)
        case "playlists":
            try output(read.playlists(tree: options.flags.contains("--tree")), name: name, json: json) {
                playlistsText($0.playlists)
            }
        case "playlist":
            try output(read.playlist(id: options.operands[0]), name: name, json: json) {
                "\($0.playlist.name) · \($0.playlist.id)\n" + tracksText($0.tracks)
            }
        case "histories":
            try output(read.histories(), name: name, json: json) {
                $0.histories.isEmpty ? "재생 기록이 없습니다" : $0.histories.map {
                    "\($0.id) · \($0.dateCreated ?? "날짜 없음") · \($0.name) · \($0.trackCount)곡"
                }.joined(separator: "\n")
            }
        case "history":
            try output(read.history(id: options.operands[0]), name: name, json: json) {
                "\($0.history.dateCreated ?? "날짜 없음") · \($0.history.name)\n"
                    + ($0.entries.isEmpty ? "곡이 없습니다" : $0.entries.map {
                        "\($0.trackNumber). " + tracksText([$0.track])
                    }.joined(separator: "\n"))
            }
        case "drafts":
            try output(read.drafts(), name: name, json: json) { result in
                result.drafts.isEmpty ? "반영 대기 초안이 없습니다" : result.drafts.map {
                    "\($0.contentID ?? "컬렉션에 없음") · \($0.title ?? $0.trackUUID) · \(draftNames($0.kinds))"
                }.joined(separator: "\n")
            }
        case "report":
            try output(read.report(checkFiles: options.flags.contains("--files")), name: name, json: true) { _ in "" }
        case "path":
            try output(read.paths(query: options.operands[0]), name: name, json: true) { _ in "" }
        default: throw ReadFailure("invalid_arguments", "알 수 없는 명령입니다. djc로 명령 목록을 확인하세요")
        }
    }

    private static func output<T: Encodable>(_ result: T, name: String, json: Bool, text: (T) -> String) throws {
        if json { print(String(decoding: try ReadJSON.encode(command: name, data: result), as: UTF8.self)) }
        else { print(text(result)) }
    }

    private static func tracksText(_ tracks: [LibraryRead.TrackRecord]) -> String {
        tracks.isEmpty ? "곡이 없습니다" : tracks.map {
            "\($0.id) · \($0.title) · \($0.artist ?? "아티스트 없음") · \($0.bpm.map { String(format: "%.2f BPM", $0) } ?? "BPM 없음") · \($0.key ?? "키 없음")"
        }.joined(separator: "\n")
    }

    private static func playlistsText(_ playlists: [LibraryRead.PlaylistRecord], depth: Int = 0) -> String {
        playlists.map {
            String(repeating: "  ", count: depth) + "\($0.id) · \($0.name) · \($0.isFolder ? "폴더" : "재생 목록") · \($0.trackCount)곡"
                + ($0.children.map { $0.isEmpty ? "" : "\n" + playlistsText($0, depth: depth + 1) } ?? "")
        }.joined(separator: "\n")
    }

    private static func draftNames(_ kinds: [String]) -> String {
        kinds.map { ["cue": "큐", "grid": "그리드", "gain": "게인", "tag": "태그"][$0] ?? $0 }.joined(separator: ", ")
    }

    private static func trackText(_ result: LibraryRead.TrackInfo) -> String {
        let track = result.track
        var lines = [tracksText([track]), "UUID: \(track.uuid)", "파일: \(track.path)", "길이: \(track.lengthSeconds)초",
                     "앨범: \(track.album ?? "없음") · 앨범 아티스트: \(track.albumArtist ?? "없음")",
                     "장르: \(track.genre ?? "없음") · 작곡가: \(track.composer ?? "없음")",
                     "연도: \(track.releaseYear.map(String.init) ?? "없음") · 트랙 번호: \(track.trackNumber.map(String.init) ?? "없음")",
                     "코멘트: \(track.comment)"]
        lines += result.cues.map {
            "큐 \($0.kind == 0 ? "메모리" : ($0.hotCueSlot ?? "슬롯 \($0.kind)")) · \($0.inMsec)ms · \($0.name)"
                + ($0.isLoop ? " · 루프 끝 \($0.outMsec)ms\($0.activeLoop ? " (활성)" : "")" : "")
        }
        lines.append("그리드: \(result.grid.status == "available" ? "\(result.grid.beatCount)박 · \(result.grid.segments.count)구간" : "분석 파일 없음 또는 읽기 실패")")
        lines += result.grid.segments.map { String(format: "  %.3f초 · %.2f BPM · %d박", $0.start, $0.bpm, $0.firstBeatNumber) }
        lines.append("게인: " + (result.gain.map { String(format: "%.2f dB", $0.decibels) } ?? "없음"))
        lines.append("재생 목록: " + result.playlists.map { "\($0.name) (\($0.id))" }.joined(separator: ", "))
        lines.append("초안: " + (result.drafts.kinds.isEmpty ? "없음" : draftNames(result.drafts.kinds)))
        return lines.joined(separator: "\n")
    }

    private struct Options {
        var operands: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var bpm: ClosedRange<Double>?
        var filter: LibraryFilter = .all

        init(_ args: [String]) throws {
            let command = args.first ?? ""
            var valued: Set<String> = command == "parse" ? [] : ["--db"]
            var boolean: Set<String> = ["--json"]
            if command == "search" { valued.formUnion(["--bpm", "--key", "--playlist", "--filter"]) }
            if command == "playlists" { boolean.insert("--tree") }
            if command == "report" { boolean.insert("--files") }
            var index = 1, positionalOnly = false
            func invalid(_ message: String) -> ReadFailure {
                ReadFailure("invalid_arguments", message + ". djc로 사용법을 확인하세요")
            }
            while index < args.count {
                let arg = args[index]
                if arg == "--", !positionalOnly { positionalOnly = true; index += 1; continue }
                if !positionalOnly && arg.hasPrefix("--") {
                    if boolean.contains(arg) {
                        guard flags.insert(arg).inserted else { throw invalid("옵션이 중복되었습니다") }
                    } else if valued.contains(arg) {
                        guard values[arg] == nil, index + 1 < args.count, !args[index + 1].hasPrefix("--"), !args[index + 1].isEmpty else {
                            throw invalid("옵션 값이 없거나 중복되었습니다")
                        }
                        index += 1; values[arg] = args[index]
                    } else { throw invalid("알 수 없는 옵션입니다") }
                } else { operands.append(arg) }
                index += 1
            }
            let expected = ["search", "track", "playlist", "history", "path", "parse"].contains(command) ? 1 : 0
            guard operands.count == expected else { throw invalid("명령 인자 수가 맞지 않습니다") }
            if let raw = values["--bpm"] {
                let pieces = raw.split(separator: "-", omittingEmptySubsequences: false)
                guard pieces.count == 2, let lower = Double(pieces[0]), let upper = Double(pieces[1]),
                      lower.isFinite, upper.isFinite, lower > 0, lower <= upper else { throw invalid("BPM은 120-130처럼 양수 범위로 쓰세요") }
                bpm = lower...upper
            }
            if let raw = values["--filter"] {
                if raw == "backlog" {
                    throw invalid("backlog 필터는 삭제되었습니다. 빈 코멘트는 --filter empty-comment로 찾으세요")
                }
                guard let matched = LibraryFilter.allCases.first(where: { $0.cliName == raw }) else {
                    throw invalid("필터는 " + LibraryFilter.allCases.map(\.cliName).joined(separator: ", ") + " 중 하나로 쓰세요")
                }
                filter = matched
            }
        }
    }
}
