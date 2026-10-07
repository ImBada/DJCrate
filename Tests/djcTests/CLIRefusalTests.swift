import DJCTestSupport
import Foundation
import RekordboxKit
import Testing
@testable import djc

/// #231: 덮어쓰기·라이브 거부 규칙. 라이브 자리는 시험 프로세스의 임시 rekordbox 폴더(`RekordboxWriter.liveDatabase`)다.
@Suite("CLI 덮어쓰기·라이브 거부")
struct CLIRefusalTests {
    func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "djc-refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func 라이브_DB는_오류로_거부하고_사본은_통과한다() throws {
        let live = RekordboxWriter.liveDatabase
        #expect(throws: CLIGuards.Refusal.self) { try CLIGuards.refuseLiveDatabase(live) }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 링크는 실제로 있는 파일을 가리킬 때만 풀린다(가짜 라이브 자리를 임시 폴더에 둔다)
        let fakeLive = dir.appending(path: "master.db")
        try Data().write(to: fakeLive)
        let link = dir.appending(path: "link.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fakeLive)
        #expect(throws: CLIGuards.Refusal.self) { try CLIGuards.refuseLiveDatabase(link, live: fakeLive) }
        try CLIGuards.refuseLiveDatabase(dir.appending(path: "copy.db"))
    }

    @Test func 라이브_분석_폴더는_거부한다() throws {
        let live = LibrarySnapshot.rekordboxDirectory.appending(path: "share")
        #expect(throws: CLIGuards.Refusal.self) { try CLIGuards.refuseLiveShare(live) }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try CLIGuards.refuseLiveShare(dir)
    }

    @Test func 있는_출력은_overwrite_없이_거부한다() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appending(path: "o.xml")
        try CLIGuards.refuseExistingOutput(out, overwrite: false)
        try Data("x".utf8).write(to: out)
        #expect(throws: CLIGuards.Refusal.self) { try CLIGuards.refuseExistingOutput(out, overwrite: false) }
        try CLIGuards.refuseExistingOutput(out, overwrite: true)
    }

    @Test func schema_dump와_reflection_dry_run은_있는_파일을_덮지_않는다() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appending(path: "o.txt")
        try Data("원본".utf8).write(to: out)
        await #expect(throws: CLIGuards.Refusal.self) { try await MainCommands.schemaDump(["schema-dump", "/nonexistent.db", out.path]) }
        await #expect(throws: CLIGuards.Refusal.self) { try await MainCommands.reflectionDryRun(["reflection-dry-run", "--out", out.path]) }
        #expect(try String(contentsOf: out, encoding: .utf8) == "원본")
    }

    @Test func lab_쓰기_실험은_라이브_DB를_오류로_거부한다() async throws {
        let live = RekordboxWriter.liveDatabase.path
        await #expect(throws: CLIGuards.Refusal.self) { try await CueLab.gainWriteTest(["gain-write-test", live, "uuid", "1.0"]) }
        await #expect(throws: CLIGuards.Refusal.self) { try await CueLab.cueWriteSelftest(["cue-write-selftest", "--db", live]) }
        await #expect(throws: CLIGuards.Refusal.self) { try await TrackLab.tagWriteTest(["tag-write-test", "--db", live, "1:title=x"]) }
        await #expect(throws: CLIGuards.Refusal.self) { try await TrackLab.artworkWriteTest(["artwork-write-test", "--db", live, "--delete", "1"]) }
        let share = LibrarySnapshot.rekordboxDirectory.appending(path: "share").path
        await #expect(throws: CLIGuards.Refusal.self) {
            try await TrackLab.analysisAttachTest(["analysis-attach-test", "--db", "/tmp/not-live.db", "--share", share, "1"])
        }
        await #expect(throws: CLIGuards.Refusal.self) {
            try await TrackLab.analysisAttachTest(["analysis-attach-test", "--db", live, "--share", "/tmp/x", "1"])
        }
    }
}
