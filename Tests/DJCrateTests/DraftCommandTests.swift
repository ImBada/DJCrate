import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

@Suite("CLI 초안")
struct DraftCommandTests {
    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
        func document(error: Bool = false) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: error ? stderr : stdout) as? [String: Any])
        }
    }

    func run(_ args: [String], fixture: RekordboxFixture, database: URL? = nil, json: Bool = true) throws -> Output {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [".build/debug/djc", ".build/out/Products/Debug/djc"]
        let executable = try #require(candidates.map { root.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = executable
        process.arguments = ["draft"] + args + ["--db", (database ?? fixture.database).path] + (json ? ["--json"] : [])
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DJC_HOME": fixture.root.appending(path: "home").path,
            "DJC_REKORDBOX_DIR": fixture.root.path,
        ]) { _, new in new }
        process.standardOutput = out; process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    func fixture() throws -> RekordboxFixture {
        let fixture = try RekordboxFixture()
        var track = TrackSpec(id: "101", uuid: "track-101")
        track.cues = [CueSpec(id: "original", inMsec: 1000)]
        try fixture.add(track)
        return fixture
    }

    func directory(_ fixture: RekordboxFixture, _ kind: String) -> URL {
        fixture.root.appending(path: "home/\(kind)-drafts")
    }

    @Test func 큐_생성은_base와_앱_형식을_보존하고_DB를_바꾸지_않는다() throws {
        let fixture = try fixture(), before = try Data(contentsOf: fixture.database)
        let output = try run(["cue", "101", "--time", "12.5", "--slot", "B", "--name", "합성 큐"], fixture: fixture)
        #expect(output.status == 0 && output.stderr.isEmpty)
        let json = try output.document()
        #expect(json["schemaVersion"] as? Int == 1 && json["command"] as? String == "draft")
        let data = try #require(json["data"] as? [String: Any])
        #expect(data["kind"] as? String == "cue" && data["dryRun"] as? Bool == false)
        let draft = try #require(CueDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "cue")))
        #expect(draft.base.count == 1 && draft.base.first?.sourceID == "original")
        #expect(draft.hotCue(slot: 1)?.time == 12.5 && draft.hotCue(slot: 1)?.name == "합성 큐")
        #expect(try Data(contentsOf: fixture.database) == before)
        let second = try run(["cue", "101", "--time", "20", "--slot", "C"], fixture: fixture)
        #expect(second.status == 0)
        let next = try #require(CueDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "cue")))
        #expect(next.base == draft.base && next.cues.count == 3)
    }

    @Test func 태그_편집과_삭제_dry_run() throws {
        let fixture = try fixture(), home = fixture.root.appending(path: "home")
        let preview = try run(["tag", "101", "--title", "새 제목", "--dry-run"], fixture: fixture)
        #expect(preview.status == 0)
        #expect(!FileManager.default.fileExists(atPath: home.path))
        #expect((try preview.document()["data"] as? [String: Any])?["dryRun"] as? Bool == true)
        #expect(try run(["tag", "101", "--title", "새 제목", "--comment", ""], fixture: fixture).status == 0)
        let first = try #require(TagDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "tag")))
        #expect(first.fields.title == "새 제목" && first.base.title != "새 제목")
        #expect(try run(["tag", "101", "--artist", "합성 가수"], fixture: fixture).status == 0)
        let next = try #require(TagDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "tag")))
        #expect(next.base == first.base && next.fields.title == "새 제목" && next.fields.artist == "합성 가수")
        #expect(try run(["rm", "tag", "101", "--dry-run"], fixture: fixture).status == 0)
        #expect(TagDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "tag")) != nil)
        #expect(try run(["rm", "tag", "101"], fixture: fixture).status == 0)
        #expect(TagDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "tag")) == nil)
        #expect(try run(["cue", "101", "--time", "10", "--dry-run"], fixture: fixture).status == 0)
        #expect(CueDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "cue")) == nil)
        #expect(try run(["cue", "101", "--time", "10"], fixture: fixture).status == 0)
        #expect(try run(["rm", "cue", "101"], fixture: fixture).status == 0)
        #expect(CueDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "cue")) == nil)
    }

    @Test func 잘못된_인자와_손상된_초안은_오류이고_보존한다() throws {
        let fixture = try fixture()
        for args in [["cue", "101", "--time", "nan"], ["cue", "101", "--time", "201"],
                     ["cue", "101", "--time", "2", "--slot", "I"], ["cue", "101", "--time", "2", "--slot", "ﬀ"], ["cue", "101", "--time", "2", "--active"],
                     ["cue", "101", "--time", "2", "--loop-end", "1"], ["tag", "101", "--year", "abc"],
                     ["tag", "101"], ["rm", "all", "101"], ["tag", "missing", "--title", "제목"]] {
            let output = try run(args, fixture: fixture)
            #expect(output.status == 1 && output.stdout.isEmpty)
            #expect(try output.document(error: true)["error"] != nil)
        }
        let folder = directory(fixture, "cue")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "track-101.json"), corrupt = Data("broken".utf8)
        try corrupt.write(to: file)
        let output = try run(["cue", "101", "--time", "2"], fixture: fixture)
        #expect(output.status == 1 && output.stdout.isEmpty)
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test func 일반_미리보기는_예정된_편집을_보여준다() throws {
        let fixture = try fixture()
        let cue = try run(["cue", "101", "--time", "12.5", "--name", "진입", "--dry-run"], fixture: fixture, json: false)
        let text = String(decoding: cue.stdout, as: UTF8.self)
        #expect(cue.status == 0 && text.contains("12.500") && text.contains("진입"))
        let tag = try run(["tag", "101", "--title", "새 제목", "--dry-run"], fixture: fixture, json: false)
        #expect(tag.status == 0 && String(decoding: tag.stdout, as: UTF8.self).contains("새 제목"))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "home").path))
    }

    @Test func 라이브_DB는_초안도_만들지_않는다() throws {
        let fixture = try fixture()
        let live = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer/rekordbox/master.db")
        let output = try run(["cue", "101", "--time", "2"], fixture: fixture, database: live)
        #expect(output.status == 1 && output.stdout.isEmpty)
        #expect((try output.document(error: true)["error"] as? [String: Any])?["code"] as? String == "live_database")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "home").path))
    }

    @Test func 큐_한도_중복_활성루프는_도메인_규칙을_따른다() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec(id: "101", uuid: "track-101")
        track.cues = (0..<10).map { CueSpec(id: "m\($0)", inMsec: $0 * 1000) }
        track.cues[0].comment = "1.1Bars"
        try fixture.add(track)
        #expect(try run(["cue", "101", "--time", "15"], fixture: fixture).status == 1)
        #expect(try run(["cue", "101", "--time", "1.01"], fixture: fixture).status == 0)
        #expect(CueDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "cue")) == nil)
        for slot in ["A", "B"] {
            #expect(try run(["cue", "101", "--time", "20", "--slot", slot, "--loop-end", "24", "--active"], fixture: fixture).status == 0)
        }
        let draft = try #require(CueDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "cue")))
        #expect(draft.cues.filter { $0.loop?.active == true }.count == 1)
        #expect(draft.hotCue(slot: 1)?.loop?.active == true)
    }
}
