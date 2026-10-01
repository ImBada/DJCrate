import DJCDomain
import DJCStorage
import Foundation

/// rekordbox는 스냅샷으로 읽고, 앱이 읽는 초안 파일만 고친다.
enum DraftCommands {
    static let command = Command("draft", "cue|tag|rm … <ContentID> [--db PATH] [--dry-run] [--json]", String(ui: "큐·태그 초안 만들기·지우기(docs/cli.md)")) { args in try run(args) }

    struct Result: Encodable {
        let kind: String
        let action: String
        let contentID: String
        let trackUUID: String
        let dryRun: Bool
        var hasChanges = false
        var cue: CueDraft?
        var tag: TagDraft?
        /// 지우지 않고 damaged-drafts에 옮긴 읽지 못한 기존 초안 파일(데이터 폴더 기준, #174)
        var preserved: [String]?
    }

    static func run(_ args: [String]) throws {
        let options = try Options(args)
        let snapshot = try LibraryRead.resolve(database: options.values["--db"].map { URL(filePath: $0) })
        let read = try LibraryRead(snapshot: snapshot)
        let (track, cues) = try read.draftSource(id: options.id)
        let uuid = track.uuid
        guard !uuid.isEmpty, !uuid.contains("/"), !uuid.contains("\0"), uuid != ".", uuid != ".." else {
            throw invalid(String(ui: "곡 UUID를 초안 파일 이름으로 쓸 수 없습니다"))
        }
        // 기존 HOME과 아직 없는 초안 경로의 /private 표기가 달라지지 않게 먼저 정규화한다.
        let home = DJCPaths.userData.resolvingSymlinksInPath().standardizedFileURL
        let directory = home.appending(path: "\(options.kind)-drafts")
        let file = directory.appending(path: "\(uuid).json")
        // DB의 UUID나 외부 링크 때문에 초안 폴더 밖을 고치지 않는다.
        guard directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL,
              file.resolvingSymlinksInPath().standardizedFileURL == file.standardizedFileURL else {
            throw invalid(String(ui: "초안 폴더나 파일의 심볼릭 링크를 해제하세요"))
        }
        var result = Result(kind: options.kind, action: options.remove ? "remove" : "save", contentID: track.id,
                            trackUUID: uuid, dryRun: options.dryRun)
        do {
            if options.remove {
                if !options.dryRun {
                    if options.kind == "cue" { try CueDraftStore.remove(trackUUID: uuid, directory: directory) }
                    else { try TagDraftStore.remove(trackUUID: uuid, directory: directory) }
                }
            } else if options.kind == "cue" {
                // 자동 큐를 빼고 만든 옛 초안에는 곡의 자동 큐를 채운다(#145, 앱 덱과 같은 목록·한도).
                let saved: CueDraft? = try existing(file)
                var draft = saved?.includingAutoCues(from: cues) ?? CueDraft(trackUUID: uuid, rekordboxCues: cues)
                guard draft.trackUUID == uuid, Set(draft.base.map(\.id)).count == draft.base.count,
                      Set(draft.cues.map(\.id)).count == draft.cues.count,
                      (draft.base + draft.cues).allSatisfy({ cue in
                          switch cue.kind { case .memory: true; case let .hot(slot): (0..<8).contains(slot) }
                      }) else { throw corrupt() }
                let time = try options.number("--time")
                let end = try options.values["--loop-end"].map { _ in try options.number("--loop-end") }
                let beats = try options.values["--beats"].map { _ in try options.number("--beats") }
                guard time >= 0, time <= Double(track.lengthSeconds),
                      end.map({ $0 > time && $0 <= Double(track.lengthSeconds) }) ?? true,
                      beats.map({ $0 > 0 && EditableCue.Loop.beatLoopSize(beats: $0) != 0 }) ?? true else {
                    throw invalid(String(ui: "큐·루프 시각은 곡 길이 안에, 루프 끝은 시작 뒤에, 박 수는 정수 또는 1/n으로 쓰세요"))
                }
                let loop = end.map { EditableCue.Loop(end: $0, beats: beats) }
                let selected: UUID
                if let slot = options.slot {
                    let cue = EditableCue(kind: .hot(slot), time: time, name: options.values["--name"] ?? "", loop: loop)
                    draft.place(cue); selected = cue.id
                } else {
                    switch draft.addMemory(at: time, loop: loop) {
                    case .limitReached: throw ReadFailure("invalid_draft", String(ui: "메모리 큐는 rekordbox 자동 큐를 포함해 10개까지입니다. 기존 큐를 앱에서 정리하세요"))
                    case let .existing(id): selected = id
                    case let .added(id):
                        selected = id
                        if var cue = draft.cue(id) { cue.name = options.values["--name"] ?? ""; draft.place(cue) }
                    }
                }
                if options.flags.contains("--active"), draft.cue(selected)?.loop?.active != true { draft.toggleActiveLoop(selected) }
                let issues = draft.issues(duration: Double(track.lengthSeconds))
                guard issues.isEmpty else { throw invalid(issues.joined(separator: "; ")) }
                result.cue = draft; result.hasChanges = draft.hasChanges
                if !options.dryRun { try CueDraftStore.save(draft, directory: directory) }
            } else {
                var draft: TagDraft = try existing(file) ?? TagDraft(track: track)
                guard draft.trackUUID == uuid else { throw corrupt() }
                for key in TagFields.Key.allCases {
                    if let value = options.values[Options.flag(key)] { draft.fields[key] = value }
                }
                guard draft.issues.isEmpty else { throw invalid(draft.issues.joined(separator: "; ")) }
                result.tag = draft; result.hasChanges = draft.hasChanges
                if !options.dryRun { try TagDraftStore.save(draft, directory: directory) }
            }
        } catch let error as ReadFailure { throw error }
        catch { throw ReadFailure("draft_io_failed", String(ui: "초안을 읽거나 저장하지 못했습니다. DJC_HOME의 초안 파일과 접근 권한을 확인하세요")) }
        // 지우기는 읽지 못한 기존 파일을 지우지 않고 옮긴다. 조용히 사라지지 않게 알린다.
        let preserved = DamagedDrafts.take(home: home).map(\.name)
        if !preserved.isEmpty { result.preserved = preserved }
        if options.flags.contains("--json") {
            print(String(decoding: try ReadJSON.encode(command: "draft", data: result), as: UTF8.self))
        } else {
            print(String(ui: "\(options.dryRun ? String(ui: "미리 보기") : String(ui: "완료")) · \(options.kind == "cue" ? String(ui: "큐") : String(ui: "태그")) 초안 \(options.remove ? String(ui: "삭제") : String(ui: "저장")) · \(track.id)"))
            if let draft = result.cue {
                for cue in draft.cues {
                    let loop = cue.loop.map { String(ui: " · 루프 끝 ") + String(ui: "\($0.end, specifier: "%.3f")초") + ($0.active ? String(ui: " (활성)") : "") } ?? ""
                    print("  \(cue.kind.slotLetter ?? String(ui: "메모리")) · \(String(ui: "\(cue.time, specifier: "%.3f")초")) · \(cue.name)\(loop)")
                }
            }
            if let draft = result.tag {
                for key in draft.changedKeys { print("  \(key.label): \(draft.base[key]) → \(draft.fields[key])") }
            }
            if !preserved.isEmpty {
                print(String(ui: "  읽지 못한 기존 초안 파일은 지우지 않고 damaged-drafts에 옮겨 두었습니다: \(preserved.joined(separator: ", "))"))
            }
        }
    }

    private static func existing<T: Decodable>(_ file: URL) throws -> T? {
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: file)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        catch { throw corrupt() }
    }

    private static func corrupt() -> ReadFailure {
        ReadFailure("invalid_draft", String(ui: "기존 초안을 읽을 수 없습니다. 초안을 백업하고 앱에서 확인한 뒤 다시 시도하세요"))
    }

    private static func invalid(_ message: String) -> ReadFailure {
        ReadFailure("invalid_arguments", String(ui: "\(message). docs/cli.md의 draft 사용법을 확인하세요"))
    }

    private struct Options {
        let kind: String
        let remove: Bool
        let id: String
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var slot: Int?
        var dryRun: Bool { flags.contains("--dry-run") }

        static func flag(_ key: TagFields.Key) -> String {
            switch key {
            case .albumArtist: "--album-artist"
            case .trackNumber: "--track-number"
            default: "--" + key.rawValue
            }
        }

        init(_ args: [String]) throws {
            guard args.count >= 2 else { throw invalid(String(ui: "초안 종류를 지정하세요")) }
            remove = args[1] == "rm"
            let start = remove ? 3 : 2
            guard args.count >= start else { throw invalid(String(ui: "지울 초안 종류를 지정하세요")) }
            kind = args[remove ? 2 : 1]
            guard ["cue", "tag"].contains(kind) else { throw invalid(String(ui: "초안 종류는 cue 또는 tag입니다")) }
            var valued: Set<String> = ["--db"]
            var boolean: Set<String> = ["--json", "--dry-run"]
            if !remove {
                if kind == "cue" {
                    valued.formUnion(["--time", "--slot", "--name", "--loop-end", "--beats"]); boolean.insert("--active")
                } else { valued.formUnion(TagFields.Key.allCases.map(Self.flag)) }
            }
            var index = start, operands: [String] = [], positionalOnly = false
            while index < args.count {
                let arg = args[index]
                if arg == "--", !positionalOnly { positionalOnly = true; index += 1; continue }
                if arg.hasPrefix("--"), !positionalOnly {
                    if boolean.contains(arg) {
                        guard flags.insert(arg).inserted else { throw invalid(String(ui: "옵션이 중복되었습니다")) }
                    } else if valued.contains(arg) {
                        guard values[arg] == nil, index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                            throw invalid(String(ui: "옵션 값이 없거나 중복되었습니다"))
                        }
                        index += 1; values[arg] = args[index]
                    } else { throw invalid(String(ui: "알 수 없는 옵션입니다")) }
                } else { operands.append(arg) }
                index += 1
            }
            guard operands.count == 1, !operands[0].isEmpty else { throw invalid(String(ui: "ContentID 하나를 지정하세요")) }
            id = operands[0]
            if !remove, kind == "cue" {
                _ = try number("--time")
                if let raw = values["--slot"] {
                    guard raw.uppercased().utf8.count == 1, let ascii = raw.uppercased().utf8.first, (65...72).contains(ascii) else { throw invalid(String(ui: "핫큐 슬롯은 A~H입니다")) }
                    slot = Int(ascii - 65)
                }
                if values["--loop-end"] == nil, values["--beats"] != nil || flags.contains("--active") { throw invalid(String(ui: "루프 끝을 --loop-end로 지정하세요")) }
            }
            if !remove, kind == "tag", !TagFields.Key.allCases.contains(where: { values[Self.flag($0)] != nil }) { throw invalid(String(ui: "바꿀 태그를 하나 이상 지정하세요")) }
        }

        func number(_ flag: String) throws -> Double {
            guard let raw = values[flag], let number = Double(raw), number.isFinite else { throw invalid(String(ui: "\(flag)에 유한한 숫자를 지정하세요")) }
            return number
        }
    }
}
