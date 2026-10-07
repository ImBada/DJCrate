@testable import DJCrate
import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

/// 되돌릴 수 있는 rekordbox 쓰기는 묻지 않고 바로 쓴다(#210, #209 조사 1의 B칸).
/// 막힘·제외·손실(합치기)이 있거나 쓰기 전 백업을 만들 수 없을 때만 묻고, 창에는 그 이유만 보인다.
@MainActor
@Suite("쓰기 확인 판정")
struct WriteConfirmPolicyTests {
    typealias F = ReflectionCoordinatorTests
    let host = FakeReflectionHost()
    let prompter = ScriptedPrompter()

    func coordinator() -> ReflectionCoordinator {
        ReflectionCoordinator(host: host, prompter: prompter, isRekordboxRunning: { false })
    }

    // MARK: 판정(순수)

    @Test func 막힘_제외_손실이_없고_백업을_만들_수_있으면_묻지_않는다() {
        let report = F.preview(cues: [F.outcome("a", .written)], grids: [F.outcome("b", .written)]).report
        #expect(WriteConfirmPolicy.reasons(report, exclusions: [], canBackUp: true).isEmpty)
    }

    @Test func 막힘_제외_합치기_백업_불가는_각각_묻는다() {
        let blocked = F.preview(cues: [F.outcome("a", .written), F.outcome("b", .blocked, reason: "바뀜")]).report
        #expect(WriteConfirmPolicy.reasons(blocked, exclusions: [], canBackUp: true) == [.blocked])
        let clean = F.preview(cues: [F.outcome("a", .written)]).report
        #expect(WriteConfirmPolicy.reasons(clean, exclusions: ["• 곡 x: 큐 쓰지 않음: 초안을 불러오지 못했으니…"], canBackUp: true) == [.excluded])
        var merged = clean
        merged.mergeOutcomes = [.init(trackUUID: "m", title: "남길 곡", status: .written, reason: nil, removed: 1, added: 0)]
        #expect(WriteConfirmPolicy.reasons(merged, exclusions: [], canBackUp: true) == [.loss])
        #expect(WriteConfirmPolicy.reasons(clean, exclusions: [], canBackUp: false) == [.noBackup])
        var playlist = clean
        playlist.playlistOutcomes = [F.playlistOutcome(.rename(playlist: .id("9"), name: "x"), "목록", .blocked, reason: "rekordbox에서 바뀜")]
        #expect(WriteConfirmPolicy.reasons(playlist, exclusions: [], canBackUp: true) == [.blocked])
    }

    @Test func 넣기는_분석까지_다_들어가면_묻지_않고_빠지는_것이_있으면_묻는다() {
        #expect(WriteConfirmPolicy.addReasons(F.addPreview([F.track("a")]), writesArtwork: true, canBackUp: true).isEmpty)
        // 분석 없이 넣는 곡, 큐·키가 안 들어가는 곡, 넣지 못하는 곡
        #expect(WriteConfirmPolicy.addReasons(F.addPreview([F.track("a")], without: ["a": "ALAC"]), writesArtwork: true, canBackUp: true) == [.excluded])
        var cue = F.track("a")
        cue.cueReason = "메모리 큐가 11개가 됩니다"
        #expect(WriteConfirmPolicy.addReasons(F.addPreview([cue]), writesArtwork: true, canBackUp: true) == [.excluded])
        var key = F.track("a")
        key.keyReason = "확인하지 않은 키"
        #expect(WriteConfirmPolicy.addReasons(F.addPreview([key]), writesArtwork: true, canBackUp: true) == [.excluded])
        #expect(WriteConfirmPolicy.addReasons(F.addPreview([F.track("a"), F.track("b", written: false, reason: "이미 있음")]),
                                              writesArtwork: true, canBackUp: true) == [.blocked])
        #expect(WriteConfirmPolicy.addReasons(F.addPreview([F.track("a")]), writesArtwork: true, canBackUp: false) == [.noBackup])
    }

    // MARK: 흐름

    @Test func 막힘이_없으면_묻지_않고_쓰고_결과_토스트에서_복원한다() async throws {
        host.preview = .success(F.preview(cues: [F.outcome("a", .written)], tags: [F.tagOutcome("t", .written)]))
        var written = try host.preview.get().report
        written.backup = "/tmp/djc-test-backup"
        host.writtenReport = written
        await coordinator().write(rows: ["a", "t"].map(F.row))
        #expect(prompter.shown.isEmpty)
        #expect(host.wrote?.drafts == ["a"] && host.wrote?.tags == ["t"] && host.locks == [true, false])
        let toast = try #require(host.toast)
        #expect(toast.kind == .success && toast.title.contains("큐 1곡") && toast.title.contains("태그 1곡"))
        #expect(toast.undoBackup == URL(filePath: "/tmp/djc-test-backup"))
    }

    @Test func 막히면_쓰는_것은_빼고_막힌_이유만_보이는_창으로_묻는다() async throws {
        host.preview = .success(F.preview(cues: [F.outcome("a", .written), F.outcome("b", .blocked, reason: "rekordbox에서 바뀜")]))
        prompter.answer = false
        await coordinator().write(rows: ["a", "b"].map(F.row))
        let prompt = try #require(prompter.shown.first)
        #expect(prompt.title == "큐 1곡을 rekordbox에 쓸까요?" && prompt.confirm == "rekordbox에 쓰기")
        #expect(prompt.details == ["쓰지 않는 것 1:", "• 곡 b: rekordbox에서 바뀜"])
        #expect(host.wrote == nil)
    }

    @Test func 백업을_만들_수_없으면_묻는다() async throws {
        host.preview = .success(F.preview(cues: [F.outcome("a", .written)]))
        host.canBackUpBeforeWrite = false
        prompter.answer = false
        await coordinator().write(rows: [F.row("a")])
        let prompt = try #require(prompter.shown.first)
        #expect(prompt.details.contains { $0.contains("백업") })
        #expect(host.wrote == nil)
    }

    @Test func 분석까지_넣는_곡만이면_묻지_않고_넣는다() async {
        host.addPreview = .success(F.addPreview([F.track("a"), F.track("b")]))
        await coordinator().addTracks(rows: ["djc-a", "djc-b"].map(F.row))
        #expect(prompter.shown.isEmpty && host.added == ["a", "b"] && host.locks == [true, false])
    }

    @Test func 넣기_확인_창은_빠지는_곡만_보인다() async throws {
        var b = F.track("b")
        b.cueReason = "메모리 큐가 11개가 됩니다"
        host.addPreview = .success(F.addPreview([F.track("a"), b], without: ["b": "ALAC"]))
        prompter.answer = false
        await coordinator().addTracks(rows: ["djc-a", "djc-b"].map(F.row))
        let prompt = try #require(prompter.shown.first)
        #expect(prompt.title == "2곡을 rekordbox에 넣을까요?")
        #expect(prompt.details.contains("• 곡 b — 분석 없이(ALAC) · ⚠︎ 큐는 안 들어감(메모리 큐가 11개가 됩니다)"))
        #expect(!prompt.details.contains { $0.hasPrefix("• 곡 a") })
        #expect(host.added == nil)
    }

    @Test func 토스트에서_누른_복원은_그_뒤_변경과_초안_충돌이_없으면_묻지_않는다() async {
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: nil)
        host.changedSinceBackup = false
        await coordinator().restore(backup, confirmed: true)
        #expect(prompter.shown.isEmpty && host.restored == [backup.url] && host.keptCurrentDrafts == true)
        // 메뉴에서 고른 복원(어느 백업인지 아직 보지 않음)은 묻는다
        await coordinator().restore(backup)
        #expect(prompter.shown.count == 1)
    }

    @Test(arguments: [true, nil] as [Bool?])
    func 토스트에서_누른_복원도_그_뒤_rekordbox가_바뀌었거나_모르면_묻는다(changed: Bool?) async {
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: nil)
        host.changedSinceBackup = changed
        prompter.answer = false
        await coordinator().restore(backup, confirmed: true)
        #expect(prompter.shown.first?.critical == true && host.restored.isEmpty)
    }

    @Test func 토스트에서_누른_복원도_뒤_백업이_있으면_묻는다() async {
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: nil)
        host.changedSinceBackup = false
        host.laterBackups = 1
        prompter.answer = false
        await coordinator().restore(backup, confirmed: true)
        #expect(prompter.shown.count == 1 && host.restored.isEmpty)
    }

    @Test func 토스트에서_누른_복원도_초안_충돌이_있으면_고르게_한다() async {
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: nil)
        host.changedSinceBackup = false
        host.conflicts = ["• 곡 a: 큐"]
        prompter.choices = [.cancel]
        await coordinator().restore(backup, confirmed: true)
        #expect(prompter.shown.first?.alternate != nil && host.restored.isEmpty)
    }
}
