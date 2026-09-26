import RekordboxKit
import Foundation

/// 명령 하나. `run`은 명령 이름이 `args[0]`인 인자를 받는다.
struct Command: Sendable {
    let name: String
    let arguments: String?
    let summary: String
    let run: @Sendable ([String]) async throws -> Void

    init(_ name: String, _ arguments: String?, _ summary: String, _ run: @escaping @Sendable ([String]) async throws -> Void) {
        self.name = name
        self.arguments = arguments
        self.summary = summary
        self.run = run
    }

    func line(prefix: String = "anicue") -> String {
        let head = "  \(prefix) \(name)" + (arguments.map { " \($0)" } ?? "")
        // 한글·가나는 터미널에서 두 칸
        let width = head.unicodeScalars.reduce(0) { $0 + ((0x1100...0xFFDC).contains($1.value) ? 2 : 1) }
        return width < 46 ? head + String(repeating: " ", count: 46 - width) + summary
            : head + "\n" + String(repeating: " ", count: 46) + summary
    }
}

/// 명령에 인자가 모자라면 던진다. 그 명령의 사용법을 보여 준다.
struct UsageError: Error {}

enum CLI {
    static let lab = CueLab.all + GridLab.all + AudioLab.all

    static let usage = """
        anicue — rekordbox 애니송 라이브러리 관리 도구

        사용법:
        \(MainCommands.all.map { $0.line() }.joined(separator: "\n"))
        \(Command("compat", "[--db PATH]", "쓰기 전 확인: rekordbox 버전·DB 구조가 확인한 모양인지", { _ in }).line())
        \(Command("lab", "<명령>", "규칙을 알아낼 때 쓴 실험 명령(목록: anicue lab)", { _ in }).line())
        """

    static var labUsage: String {
        "anicue lab — 실험 명령(읽기 전용이거나 사본에만 쓴다)\n\n" + lab.map { $0.line(prefix: "anicue lab") }.joined(separator: "\n")
    }

    static func run(_ args: [String]) async throws {
        switch args.first {
        case "lab"?:
            try await dispatch(Array(args.dropFirst()), in: lab, usage: labUsage)
        case "compat"?:
            try compat(args)
        default:
            try await dispatch(args, in: MainCommands.all, usage: usage)
        }
    }

    static func dispatch(_ args: [String], in commands: [Command], usage: String) async throws {
        guard let name = args.first, let command = commands.first(where: { $0.name == name }) else {
            print(usage)
            return
        }
        do {
            try await command.run(args)
        } catch is UsageError {
            print("사용법:\n" + command.line(prefix: commands.first?.name == lab.first?.name ? "anicue lab" : "anicue"))
        }
    }

    /// 라이브 쓰기 전 확인(읽기 전용): 설치된 rekordbox 버전, DB 구조(스냅샷 사본)
    static func compat(_ args: [String]) throws {
        let version = RekordboxCompatibility.installedAppVersion()
        print("rekordbox 앱: \(version ?? "찾지 못함") · 확인한 버전 \(RekordboxCompatibility.verifiedAppVersions.sorted().map { "\($0).x" }.joined(separator: ", "))")
        try RekordboxCompatibility.checkApp(version: version)
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let db = try CipherDatabase(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        try RekordboxCompatibility.checkSchema(db)
        print("DB 구조: 확인한 모양과 같음(DBVersion \(RekordboxCompatibility.databaseVersion)) · \(snapshot.lastPathComponent)")
    }
}

do {
    try await CLI.run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("오류: \(error)\n".utf8))
    exit(1)
}
