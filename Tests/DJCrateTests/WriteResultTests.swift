@testable import DJCrate
import Foundation
@testable import RekordboxKit
import Testing

@MainActor
@Suite("쓰기 결과 보관")
struct WriteResultTests {
    typealias Fixture = ReflectionCoordinatorTests

    @Test(arguments: ["쓰기", "넣기", "빼기", "되돌리기"])
    func 결과는_토스트를_닫고_재시작해도_열린다(operation: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "last-write-result.json")
        let host = FakeReflectionHost()
        host.resultHistory = WriteResultHistory(url: url)
        let coordinator = ReflectionCoordinator(host: host, prompter: ScriptedPrompter(), isRekordboxRunning: { false })
        let backupURL = URL(filePath: "/tmp/fixture-write-backup")
        var expected: [String]
        switch operation {
        case "쓰기":
            var preview = Fixture.preview(cues: [Fixture.outcome("written", .written), Fixture.outcome("blocked", .blocked, reason: "큐가 바뀜")],
                                          grids: [Fixture.outcome("grid", .blocked, reason: "분석 전")],
                                          analyses: [Fixture.outcome("analysis", .written), Fixture.outcome("analysis-blocked", .blocked, reason: "ALAC")])
            host.preview = .success(preview)
            preview.report.outcomes.removeAll { $0.status != .written }
            preview.report.gridOutcomes = nil
            preview.report.analysisOutcomes?.removeAll { $0.status != .written }
            preview.report.backup = backupURL.path
            host.writtenReport = preview.report
            await coordinator.write(rows: [Fixture.row("written"), Fixture.row("blocked")])
            expected = ["곡 written", "곡 blocked", "큐가 바뀜", "분석 전", "곡 analysis", "ALAC"]
        case "넣기":
            var add = Fixture.addPreview([Fixture.track("added"), Fixture.track("blocked", written: false, reason: "이미 있음")], without: ["added": "ALAC"])
            add.unreadable = ["읽지 못한 곡: 파일 없음"]
            host.addPreview = .success(add)
            var tracks = RekordboxTrackWriter.Report(dryRun: false)
            tracks.added = [Fixture.track("added")]
            tracks.backup = backupURL.path
            host.trackReport = tracks
            await coordinator.addTracks(rows: [Fixture.row("djc-added")])
            expected = ["곡 added", "이미 있음", "ALAC", "파일 없음"]
        case "빼기":
            var tracks = RekordboxTrackWriter.Report(dryRun: false)
            tracks.deleted = [Fixture.track("deleted"), Fixture.track("blocked", written: false, reason: "연결된 표")]
            host.deletePreview = .success(.init(report: tracks, contentIDs: ["id-deleted", "id-blocked"]))
            tracks.deleted.removeAll { !$0.written }
            tracks.backup = backupURL.path
            host.trackReport = tracks
            await coordinator.deleteTracks(rows: [Fixture.row("deleted")])
            expected = ["곡 deleted", "연결된 표"]
        default:
            var tracks = RekordboxTrackWriter.Report(dryRun: false)
            tracks.deleted = [Fixture.track("deleted")]
            let backup = RekordboxWriter.Backup(url: backupURL, createdAt: .now, isWrite: true, report: nil, trackReport: tracks)
            await coordinator.restore(backup)
            expected = ["쓰기 전 상태로 복원했습니다", "곡 deleted"]
        }
        host.toast = nil
        let result = try #require(WriteResultHistory(url: url).latest)
        for text in expected { #expect(result.text.contains(text)) }
        #expect(result.backups.contains(backupURL))
        #expect(result.kind == (operation == "되돌리기" ? .success : .warning))
        if operation == "되돌리기" { #expect(result.backups.contains(host.restoreSafetyBackup)) }
        // 경고 알림의 둘째 줄(무엇을 쓰지 않았는지)도 다시 열 때 그대로다(#147).
        let shortfall = ["쓰기": "큐 1곡 · 그리드 1곡 · 분석 1곡은 쓰지 않았습니다", "넣기": "2곡은 넣지 않았습니다", "빼기": "1곡은 빼지 않았습니다"]
        if let shortfall = shortfall[operation] { #expect(result.toast.detail?.hasPrefix(shortfall) == true) }
    }

    /// #147: 막힌 항목이 있으면 알림 둘째 줄에 무엇을 쓰지 않았는지와 할 일을 보인다.
    /// 막힘 이유는 할 일까지 적은 문장이라 이유가 하나면 그대로 보이고, 여럿이면 결과 보기로 안내한다.
    @Test func 막힌_항목이_있으면_무엇을_쓰지_않았는지와_할_일을_보인다() {
        let reason = "rekordbox 분석 파일이 없습니다. rekordbox에서 트랙 분석을 먼저 하세요"
        let set = Fixture.playlistOutcome(.create(key: "k", name: "세트", isFolder: false, parent: .root), "세트", .written)
        var predicted = Fixture.preview(cues: [Fixture.outcome("1", .written), Fixture.outcome("2", .written)],
                                        grids: [Fixture.outcome("3", .written), Fixture.outcome("4", .blocked, reason: reason)]).report
        predicted.playlistOutcomes = [set]
        var actual = predicted
        actual.gridOutcomes?.removeAll { $0.status != .written }
        let one = WriteResult.written(actual, preview: predicted)
        #expect(one.kind == .warning)
        #expect(one.title == "rekordbox에 썼습니다 · 큐 2곡 · 그리드 1곡 · 재생 목록 1건")
        #expect(one.toast.detail == "그리드 1곡은 쓰지 않았습니다 — " + reason)

        predicted.outcomes.append(Fixture.outcome("5", .blocked, reason: "초안을 만든 뒤 rekordbox에서 큐가 바뀌었습니다"))
        actual.playlistOutcomes = [set, Fixture.playlistOutcome(.create(key: "e", name: " ", isFolder: false, parent: .root), " ", .blocked,
                                                                reason: "이름을 적어 주세요")]
        let many = WriteResult.written(actual, preview: predicted)
        #expect(many.kind == .warning)
        #expect(many.toast.detail == "큐 1곡 · 그리드 1곡 · 재생 목록 1건은 쓰지 않았습니다 — 이유와 할 일은 ‘결과 보기’에서 확인하세요")
    }

    /// #147: 쓴 항목에 붙은 참고 사유(경로가 예상과 달라 분석 파일을 남김)만 있으면 성공으로 보이고, 사유는 결과에 남긴다.
    /// 곡 빼기·쓰기 전으로 복원도 같은 기준이다.
    @Test func 참고_사유만_붙으면_성공으로_보인다() throws {
        let note = RekordboxWriter.fileOwnershipWarning
        var merge = Fixture.preview(cues: []).report
        merge.mergeOutcomes = [Fixture.outcome("m", .written, reason: note)]
        let merged = WriteResult.written(merge, preview: merge)
        #expect(merged.kind == .success && merged.text.contains(note))
        #expect(merged.toast.detail == "전체 내용과 백업 위치는 ‘마지막 쓰기 결과…’에서 다시 볼 수 있습니다.")

        var tracks = RekordboxTrackWriter.Report(dryRun: false)
        tracks.deleted = [Fixture.track("d", reason: note)]
        let deleted = WriteResult.tracks(tracks, preview: tracks, adding: false)
        #expect(deleted.kind == .success && deleted.text.contains(note))

        let saved = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: saved) }
        try Data().write(to: saved.appending(path: "file-ownership-warning"))
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: merge)
        let restored = WriteResult.restored(backup, saved: saved)
        #expect(restored.kind == .success && restored.text.contains(note))
    }

    /// #147: 곡 넣기에서 넣지 않은 곡·분석 없이 넣은 곡·쓰지 않은 큐는 할 일이 남아 경고로 보이고 둘째 줄에 적는다.
    @Test func 곡_넣기_경고는_넣지_않은_것과_할_일을_보인다() {
        var report = RekordboxTrackWriter.Report(dryRun: false)
        report.added = [Fixture.track("a")]
        let unanalyzed = WriteResult.tracks(report, preview: report, adding: true, withoutAnalysis: ["a": "ALAC"])
        #expect(unanalyzed.kind == .warning && unanalyzed.title == "rekordbox에 1곡을 넣었습니다")
        #expect(unanalyzed.toast.detail == "1곡은 분석 없이 넣었습니다 — rekordbox에서 분석하세요")

        var preview = report
        preview.added.append(Fixture.track("b", written: false, reason: "이미 rekordbox 컬렉션에 있는 파일입니다"))
        let skipped = WriteResult.tracks(report, preview: preview, adding: true)
        #expect(skipped.kind == .warning)
        #expect(skipped.toast.detail == "1곡은 넣지 않았습니다 — 이미 rekordbox 컬렉션에 있는 파일입니다")

        report.added[0].cueReason = "큐가 바뀜"
        let all = WriteResult.tracks(report, preview: preview, adding: true, withoutAnalysis: ["a": "ALAC"])
        #expect(all.toast.detail == "1곡은 넣지 않았습니다 · 1곡은 분석 없이 넣었습니다 · 1곡의 큐는 쓰지 않았습니다 — 이유와 할 일은 ‘결과 보기’에서 확인하세요")
    }

    @Test func 태그_결과도_곡마다_남긴다() {
        var preview = Fixture.preview(cues: [], tags: [Fixture.tagOutcome("t", .written), Fixture.tagOutcome("x", .blocked, reason: "바뀜")])
        let predicted = preview.report
        preview.report.tagOutcomes = [Fixture.tagOutcome("t", .written)]
        let result = WriteResult.written(preview.report, preview: predicted)
        #expect(result.title == "rekordbox에 썼습니다 · 태그 1곡" && result.kind == .warning)
        #expect(result.text.contains("• 곡 t — 태그 쓰기 완료") && result.text.contains("• 곡 x — 태그 쓰지 않음: 바뀜"))
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: preview.report)
        #expect(WriteResult.restored(backup, saved: URL(filePath: "/tmp/s")).text.contains("• 곡 t"))
    }

    @Test func 모두_막힌_결과도_전체_이유를_남긴다() async throws {
        let host = FakeReflectionHost()
        host.preview = .success(Fixture.preview(cues: (1...15).map { Fixture.outcome("\($0)", .blocked, reason: "이유 \($0)") }))
        await ReflectionCoordinator(host: host, prompter: ScriptedPrompter(), isRekordboxRunning: { false }).write(rows: [Fixture.row("1")])
        #expect(host.resultHistory.latest?.text.contains("이유 15") == true)
        #expect(host.resultHistory.latest?.kind == .warning)
    }

    @Test func 기록_저장이_실패해도_결과를_메모리에_보존하고_실패를_알린다() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = WriteResultHistory(url: folder)
        let result = WriteResult(kind: .success, title: "쓴 결과", text: "전체 내용")
        history.record(result)
        #expect(history.latest == result)
        #expect(history.storageError != nil)
    }

    @Test func 미리보기_취소는_확인창이나_쓰기까지_가지_않는다() async {
        let host = FakeReflectionHost()
        host.preview = .success(Fixture.preview(cues: [Fixture.outcome("a", .written)]))
        let prompter = ScriptedPrompter()
        let task = Task { await ReflectionCoordinator(host: host, prompter: prompter, isRekordboxRunning: { false }).write(rows: [Fixture.row("a")]) }
        task.cancel()
        await task.value
        #expect(host.wrote == nil && prompter.shown.isEmpty)
        #expect(host.toast?.title.contains("취소") == true && host.toast?.detail?.contains("아무것도 쓰지 않았습니다") == true)
        #expect(!host.isWritingRekordbox && host.writeStage == nil)
    }

    @Test(arguments: ["쓰기", "넣기", "빼기"])
    func 미리보기_도중_취소하면_확인창과_실제_쓰기를_건너뛴다(operation: String) async {
        let host = FakeReflectionHost()
        host.preview = .success(Fixture.preview(cues: [Fixture.outcome("a", .written)]))
        host.addPreview = .success(Fixture.addPreview([Fixture.track("added")]))
        var tracks = RekordboxTrackWriter.Report(dryRun: true)
        tracks.deleted = [Fixture.track("deleted")]
        host.deletePreview = .success(.init(report: tracks, contentIDs: ["id-deleted"]))
        let prompter = ScriptedPrompter()
        var suspended: CheckedContinuation<Void, Never>?
        host.beforePreview = { await withCheckedContinuation { suspended = $0 } }
        let coordinator = ReflectionCoordinator(host: host, prompter: prompter, isRekordboxRunning: { false })
        let task = Task {
            switch operation {
            case "쓰기": await coordinator.write(rows: [Fixture.row("a")])
            case "넣기": await coordinator.addTracks(rows: [Fixture.row("djc-added")])
            default: await coordinator.deleteTracks(rows: [Fixture.row("deleted")])
            }
        }
        while suspended == nil { await Task.yield() }
        #expect(host.writeStage?.cancellable == true)
        #expect(host.writeStage?.completed == 0 && host.writeStage?.total == 1)
        task.cancel()
        suspended?.resume()
        await task.value
        #expect(prompter.shown.isEmpty && host.wrote == nil && host.added == nil && host.deleted == nil)
        #expect(host.resultHistory.latest?.text == "rekordbox에 아무것도 쓰지 않았습니다.")
        #expect(host.writeStage == nil && !host.isWritingRekordbox)
    }

    @Test func 실제_쓰기_단계에는_취소를_전달하지_않는다() async {
        let store = LibraryStore(resultHistory: WriteResultHistory(), feedback: AppFeedback(announce: { _ in }))
        var suspended: CheckedContinuation<Void, Never>?
        var cancelled = false
        store.writeTask = Task {
            await withCheckedContinuation { suspended = $0 }
            cancelled = Task.isCancelled
        }
        while suspended == nil { await Task.yield() }
        store.writeStage = WriteStage("rekordbox에 쓰는 중…")
        store.cancelWritePreparation()
        suspended?.resume()
        await store.writeTask?.value
        #expect(!cancelled)
    }

    @Test func 실패_결과도_토스트를_닫은_뒤_남는다() async throws {
        let host = FakeReflectionHost()
        host.preview = .failure(FixtureFailure())
        let coordinator = ReflectionCoordinator(host: host, prompter: ScriptedPrompter(), isRekordboxRunning: { false })
        await coordinator.write(rows: [Fixture.row("a")])
        host.toast = nil
        #expect(host.resultHistory.latest?.kind == .failure)
        #expect(host.resultHistory.latest?.text == "디스크 공간과 권한을 확인한 뒤 다시 시도하세요.")
    }

    @Test func 알림은_주입한_한_함수로_제목과_설명을_보낸다() {
        var messages: [AppMessage] = []
        let feedback = AppFeedback(announce: { messages.append($0) }, isVoiceOverEnabled: { true })
        let store = LibraryStore(resultHistory: WriteResultHistory(), feedback: feedback)
        store.toast = AppToast(kind: .failure, title: "실패", detail: "이유 전체")
        store.stagingMessage = AppMessage(kind: .failure, text: "목록 저장 실패")
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        deck.feedback = feedback
        deck.showToast("덱 안내")
        #expect(messages.map(\.text) == ["실패\n이유 전체", "목록 저장 실패", "덱 안내"])
        #expect(messages.first?.kind == .failure)
        #expect(!AppToast(title: "성공").automaticallyDismisses(voiceOverEnabled: true))
        #expect(deck.toastTask == nil)
    }
}
