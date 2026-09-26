@testable import DJCrate
import AppKit
import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

/// 반영 흐름(확인 → 미리 보기 → 묻기 → 쓰기 → 토스트)을 가짜 저장소·창으로 확인한다.
@MainActor
final class FakeReflectionHost: ReflectionHost {
    var isWritingRekordbox = false
    var writeStage: WriteStage?
    var toast: AppToast?
    var resultHistory = WriteResultHistory()
    var writtenReport: RekordboxWriter.Report?
    var trackReport: RekordboxTrackWriter.Report?
    let restoreSafetyBackup = URL(filePath: "/tmp/fixture-before-restore")
    var locks: [Bool] = []
    var targets: [TrackRow]?
    var preview: Result<LibraryStore.WritePreview, Error> = .failure(FixtureFailure())
    var wrote: (drafts: [String], grids: [String], gains: [String])?
    var changedSinceBackup: Bool?
    var restored: [URL] = []
    var beforePreview: (() async -> Void)?
    /// 쓰기·넣기·빼기가 던질 오류(확인 창 뒤 실제 쓰기 단계)
    var writeError: Error?

    func setWriteLock(_ locked: Bool) { isWritingRekordbox = locked; locks.append(locked) }
    func writeTargets(_ rows: [TrackRow]) -> [TrackRow] { targets ?? rows }
    func previewWrite(rows: [TrackRow]) async throws -> LibraryStore.WritePreview { await beforePreview?(); return try preview.get() }
    func writeToRekordbox(_ drafts: [CueDraft], grids: [GridDraft], gains: [String: Double]) async throws -> RekordboxWriter.Report {
        wrote = (drafts.map(\.trackUUID), grids.map(\.trackUUID), gains.keys.sorted())
        if let writeError { throw writeError }
        return try writtenReport ?? preview.get().report
    }
    func libraryChangedSince(_ backup: RekordboxWriter.Backup) async -> Bool? { changedSinceBackup }
    func restoreRekordbox(_ backup: RekordboxWriter.Backup) async throws -> URL {
        if let writeError { throw writeError }
        restored.append(backup.url)
        return restoreSafetyBackup
    }

    var addPreview: Result<LibraryStore.TrackAddPreview, Error> = .failure(FixtureFailure())
    var deletePreview: Result<LibraryStore.TrackDeletePreview, Error> = .failure(FixtureFailure())
    var added: [String]?
    var deleted: [String]?
    func trackAddTargets(_ rows: [TrackRow]) -> [TrackRow] { rows.filter(\.isStaged) }
    func previewTrackAdd(rows: [TrackRow]) async throws -> LibraryStore.TrackAddPreview { await beforePreview?(); return try addPreview.get() }
    func addTracksToRekordbox(_ preview: LibraryStore.TrackAddPreview) async throws -> RekordboxTrackWriter.Report {
        added = preview.report.added.filter(\.written).map(\.path)
        if let writeError { throw writeError }
        return trackReport ?? preview.report
    }
    func trackDeleteTargets(_ rows: [TrackRow]) -> [TrackRow] { rows.filter { !$0.isStaged } }
    func previewTrackDelete(rows: [TrackRow]) async throws -> LibraryStore.TrackDeletePreview { await beforePreview?(); return try deletePreview.get() }
    func deleteTracksFromRekordbox(_ preview: LibraryStore.TrackDeletePreview) async throws -> RekordboxTrackWriter.Report {
        deleted = preview.report.deleted.filter(\.written).compactMap(\.contentID)
        if let writeError { throw writeError }
        return trackReport ?? preview.report
    }
}

struct FixtureFailure: Error, CustomStringConvertible { var description = "미리 보기 실패" }

@MainActor
final class ScriptedPrompter: ReflectionPrompter {
    var answer = true
    var shown: [ReflectionPrompt] = []
    func show(_ prompt: ReflectionPrompt) -> Bool { shown.append(prompt); return answer }
}

@MainActor
@Suite("반영 흐름")
struct ReflectionCoordinatorTests {
    let host = FakeReflectionHost()
    let prompter = ScriptedPrompter()

    func coordinator(running: Bool = false) -> ReflectionCoordinator {
        ReflectionCoordinator(host: host, prompter: prompter, isRekordboxRunning: { running })
    }

    static func row(_ uuid: String) -> TrackRow {
        TrackRow(track: Track(id: uuid, uuid: uuid, title: "곡 \(uuid)", artist: nil, album: nil, albumArtist: nil, genre: nil,
                              composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180,
                              folderPath: "/x/\(uuid).mp3", comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil,
                              isDeleted: false),
                 cues: [], playCount: 0)
    }

    static func outcome(_ uuid: String, _ status: RekordboxWriter.Outcome.Status, reason: String? = nil, added: Int = 1) -> RekordboxWriter.Outcome {
        .init(trackUUID: uuid, title: "곡 \(uuid)", status: status, reason: reason, removed: 0, added: added)
    }

    static func preview(cues: [RekordboxWriter.Outcome], grids: [RekordboxWriter.Outcome] = [],
                        gains: [RekordboxWriter.Outcome] = [], analyses: [RekordboxWriter.Outcome] = []) -> LibraryStore.WritePreview {
        var report = RekordboxWriter.Report(outcomes: cues, backup: nil, dryRun: true, createdAt: "", finalUpdateCount: nil)
        report.gridOutcomes = grids.isEmpty ? nil : grids
        report.gainOutcomes = gains.isEmpty ? nil : gains
        report.analysisOutcomes = analyses.isEmpty ? nil : analyses
        return .init(report: report,
                     drafts: cues.map { CueDraft(trackUUID: $0.trackUUID, rekordboxCues: []) },
                     grids: (grids + analyses).map { GridDraft(trackUUID: $0.trackUUID, base: [], segments: []) },
                     gains: Dictionary(uniqueKeysWithValues: gains.map { ($0.trackUUID, -3.0) }))
    }

    @Test func rekordbox가_켜져_있으면_미리_보지도_않는다() async {
        await coordinator(running: true).write(rows: [Self.row("a")])
        #expect(prompter.shown.map(\.title) == ["rekordbox가 켜져 있어 쓰지 않았습니다"])
        #expect(host.locks.isEmpty && host.wrote == nil)
    }

    @Test func 쓸_초안이_없으면_알린다() async {
        host.targets = []
        await coordinator().write(rows: [Self.row("a")])
        #expect(prompter.shown.first?.title == "반영할 초안이 없습니다" && host.locks.isEmpty)
    }

    @Test func 모두_막히면_이유를_보여_주고_쓰지_않는다() async {
        host.preview = .success(Self.preview(cues: [Self.outcome("a", .blocked, reason: "VBR MP3")]))
        await coordinator().write(rows: [Self.row("a")])
        #expect(prompter.shown.first?.title == "rekordbox에 쓸 수 있는 초안이 없습니다")
        #expect(prompter.shown.first?.text.contains("VBR MP3") == true)
        #expect(host.wrote == nil && host.locks == [true, false] && host.writeStage == nil)
    }

    @Test func 취소하면_쓰지_않고_잠금을_푼다() async {
        host.preview = .success(Self.preview(cues: [Self.outcome("a", .written)]))
        prompter.answer = false
        await coordinator().write(rows: [Self.row("a")])
        #expect(prompter.shown.first?.confirm == "rekordbox에 쓰기")
        #expect(host.wrote == nil && !host.isWritingRekordbox)
    }

    @Test func 확인하면_쓸_수_있는_것만_쓴다() async {
        host.preview = .success(Self.preview(cues: [Self.outcome("a", .written), Self.outcome("b", .blocked, reason: "바뀜")],
                                             grids: [Self.outcome("a", .written), Self.outcome("c", .blocked, reason: "분석 전")],
                                             gains: [Self.outcome("d", .written, added: -300)]))
        await coordinator().write(rows: ["a", "b", "c", "d"].map(Self.row))
        #expect(host.wrote?.drafts == ["a"] && host.wrote?.grids == ["a"] && host.wrote?.gains == ["d"])
        #expect(host.locks == [true, false])
    }

    @Test func 분석_전_곡은_그리드_초안으로_분석을_붙여_쓴다() async {
        // 분석 붙이기만 쓸 수 있어도 확인 창을 띄우고, 그 곡의 그리드 초안을 넘긴다(막힌 곡은 넘기지 않는다)
        host.preview = .success(Self.preview(cues: [], analyses: [Self.outcome("n", .written, added: 96),
                                                                  Self.outcome("h", .blocked, reason: "rekordbox에서 트랙 분석을 먼저 한 뒤 쓰세요")]))
        await coordinator().write(rows: ["n", "h"].map(Self.row))
        #expect(prompter.shown.first?.title == "rekordbox에 분석 1곡을 씁니다")
        #expect(host.wrote?.drafts == [] && host.wrote?.grids == ["n"] && host.wrote?.gains == [])
    }

    @Test func 미리_보기가_실패하면_실패_토스트() async {
        await coordinator().write(rows: [Self.row("a")])
        #expect(host.toast?.kind == .failure && host.toast?.detail == "디스크 공간과 권한을 확인한 뒤 다시 시도하세요.")
        #expect(host.writeStage == nil && !host.isWritingRekordbox)
    }

    @Test func 쓰기_거부_토스트는_제목을_되풀이하지_않고_할_일을_안내한다() async {
        host.preview = .failure(DJCError.writeRefused("지원하지 않는 버전입니다"))
        await coordinator().write(rows: [Self.row("a")])
        #expect(host.toast?.title == "rekordbox에 쓰지 않았습니다")
        let detail = host.toast?.detail ?? ""
        #expect(detail.contains("지원하지 않는 버전입니다"))
        #expect(detail.contains("확인"))
        #expect(!detail.contains("rekordbox에 쓰지 않았습니다"))
        #expect(host.resultHistory.latest?.text == detail)
    }

    @Test func 파일_오류_토스트는_NSError_원문을_숨긴다() async {
        host.preview = .failure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
                                        userInfo: [NSLocalizedDescriptionKey: "Error Domain=NSCocoaErrorDomain SQL 원문"]))
        await coordinator().write(rows: [Self.row("a")])
        #expect(host.toast?.detail == "디스크 공간과 권한을 확인한 뒤 다시 시도하세요.")
    }

    /// 쓰기·넣기·빼기를 모두 확인 창까지 통과시켜 실제 쓰기 단계에서 `error`를 던지게 한다.
    func failEveryWrite(with error: Error) async {
        host.writeError = error
        host.preview = .success(Self.preview(cues: [Self.outcome("a", .written)]))
        host.addPreview = .success(Self.addPreview([Self.track("b")]))
        var report = RekordboxTrackWriter.Report(dryRun: true)
        report.deleted = [Self.track("c")]
        host.deletePreview = .success(.init(report: report, contentIDs: ["id-c"]))
        await coordinator().write(rows: [Self.row("a")])
        await coordinator().addTracks(rows: [Self.row("djc-b")])
        await coordinator().deleteTracks(rows: [Self.row("c")])
    }

    @Test func 자동_복원까지_실패하면_토스트가_아니라_닫아야_하는_심각_경고로_알린다() async {
        host.toast = AppToast(title: "이전 성공")
        let backup = "/tmp/rekordbox-backups/2026-09-26T120000-write"
        await failEveryWrite(with: DJCError.restoreFailed(reason: "무결성 검사 실패: x", restoreError: "master.db: 권한 없음",
                                                          backup: backup, database: nil))
        #expect(host.toast == nil, "사라지는 토스트로 알리지 않는다")
        // 확인 창 3개 뒤마다 경고 하나씩
        let alerts = prompter.shown.filter { $0.confirm == nil }
        #expect(alerts.count == 3 && alerts.allSatisfy(\.critical))
        let alert = try? #require(alerts.first)
        #expect(alert?.title == "쓰기 확인에 실패했고 자동 복원도 하지 못했습니다")
        let text = alert?.text ?? ""
        // 반영·넣기·빼기 모두 같은 버튼(가장 최근 쓰기 백업으로 되돌림). 사이드바 아래 '마지막 반영 되돌리기…'는 성공한 쓰기 뒤에만 보여 안내하지 않는다.
        #expect(text.contains("rekordbox를 켜지 말고, 사이드바에서 'rekordbox 반영 대기'를 고른 뒤 목록 위 '되돌리기…'로 쓰기 전 백업을 복원하세요."))
        #expect(!text.contains("마지막 반영 되돌리기"))
        #expect(text.contains("djc rekordbox-restore --backup '\(backup)' --live"))
        #expect(!text.contains("무결성 검사 실패: x") && !text.contains("master.db: 권한 없음"))
        #expect(host.writeStage == nil && host.locks == [true, false, true, false, true, false])
        #expect(host.resultHistory.latest?.kind == .failure)
        #expect(host.resultHistory.latest?.text == alerts.last?.text)
        #expect(host.resultHistory.latest?.backups == [URL(filePath: backup)])
    }

    @Test func 백업으로_되돌렸으면_실패_토스트로_알린다() async {
        await failEveryWrite(with: DJCError.writeRolledBack("무결성 검사 실패: x"))
        #expect(prompter.shown.allSatisfy { $0.confirm != nil }, "경고 창은 띄우지 않는다")
        #expect(host.toast?.kind == .failure && host.toast?.title == "rekordbox에서 빼지 않았습니다")
        #expect(host.toast?.detail?.contains("쓰기 전 백업으로 되돌렸습니다") == true)
        #expect(host.toast?.detail?.contains("초안을 확인") == true)
        #expect(host.toast?.detail?.contains("무결성 검사 실패: x") == false)
    }

    @Test func 확인_창은_종류별_곡_수와_막힌_이유를_보여_준다() {
        let preview = Self.preview(cues: [Self.outcome("a", .written, added: 2)],
                                   grids: [Self.outcome("a", .blocked, reason: "분석 전"), Self.outcome("g", .written, added: 64)],
                                   gains: [Self.outcome("d", .written, added: -250)])
        let prompt = ReflectionCoordinator.confirmation(preview.report)
        #expect(prompt.title == "rekordbox에 큐 1곡 · 그리드 1곡 · 게인 1곡을 씁니다")
        let lines = prompt.text.components(separatedBy: "\n")
        #expect(lines.contains("• 곡 a — 큐 추가 2 · 삭제 0 · ⚠︎ 그리드는 안 들어감"))
        #expect(lines.contains("• 곡 g — 그리드(박 64개)"))
        #expect(lines.contains("• 곡 d — 오토게인 -2.5 dB"))
        #expect(lines.contains("쓰지 않는 것 1:") && lines.contains("• 곡 a: 분석 전"))
    }

    @Test func 확인_창은_분석을_붙이는_곡과_막힌_이유를_보여_준다() {
        let preview = Self.preview(cues: [Self.outcome("a", .written, added: 1), Self.outcome("b", .written, added: 3)],
                                   analyses: [Self.outcome("a", .written, added: 128), Self.outcome("n", .written, added: 96),
                                              Self.outcome("b", .blocked, reason: "ALAC")])
        let prompt = ReflectionCoordinator.confirmation(preview.report)
        #expect(prompt.title == "rekordbox에 큐 2곡 · 분석 2곡을 씁니다")
        let lines = prompt.text.components(separatedBy: "\n")
        #expect(lines.contains("• 곡 a — 큐 추가 1 · 삭제 0 · 분석 파일 붙이기"))
        #expect(lines.contains("• 곡 b — 큐 추가 3 · 삭제 0 · ⚠︎ 그리드는 안 들어감"))
        #expect(lines.contains("• 곡 n — 분석 파일 붙이기(파형·그리드 박 96개·오토게인)"))
        #expect(lines.contains("• 곡 b: ALAC") && prompt.text.contains("키·프레이즈·보컬 분석은 없습니다"))
    }

    @Test func 실패와_경고_토스트는_시간이_지나도_닫히지_않는다() {
        #expect(AppToast(kind: .failure, title: "실패").duration == .infinity)
        #expect(AppToast(kind: .warning, title: "경고").duration == .infinity)
        #expect(AppToast(title: "성공").duration.isFinite)
    }

    @Test func 되돌리기_실패는_원문_대신_할_일을_심각_경고로_보여_준다() async {
        host.writeError = FixtureFailure()
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/test-backup"), createdAt: .now, isWrite: true, report: nil)
        await coordinator().restore(backup)
        #expect(prompter.shown.last?.critical == true)
        #expect(prompter.shown.last?.confirm == nil)
        #expect(prompter.shown.last?.text.contains("rekordbox를 켜지 말고") == true)
        #expect(prompter.shown.last?.text.contains("다시 되돌리세요") == true)
        #expect(prompter.shown.last?.text.contains("미리 보기 실패") == false)
        #expect(host.resultHistory.latest?.kind == .failure)
        #expect(host.resultHistory.latest?.backups == [backup.url])
    }

    // MARK: 곡 넣기·빼기

    static func track(_ path: String, written: Bool = true, reason: String? = nil) -> RekordboxTrackWriter.Outcome {
        .init(path: path, contentID: written ? "id-\(path)" : nil, title: "곡 \(path)", written: written, reason: reason)
    }

    static func addPreview(_ outcomes: [RekordboxTrackWriter.Outcome], without: [String: String] = [:]) -> LibraryStore.TrackAddPreview {
        var report = RekordboxTrackWriter.Report(dryRun: true)
        report.added = outcomes
        return .init(report: report, plans: [], stagedUUIDs: [:], withoutAnalysis: without, unreadable: [])
    }

    @Test func 추가한_곡만_넣고_rekordbox가_켜져_있으면_묻지도_않는다() async {
        await coordinator(running: true).addTracks(rows: [Self.row("djc-a")])
        #expect(prompter.shown.map(\.title) == ["rekordbox가 켜져 있어 넣지 않았습니다"] && host.added == nil)
        prompter.shown = []
        await coordinator().addTracks(rows: [Self.row("a")])
        #expect(prompter.shown.first?.title == "rekordbox에 넣을 곡이 없습니다" && host.locks.isEmpty)
    }

    @Test func 넣기_확인_창은_분석_여부와_넣지_않는_곡을_보여_주고_확인하면_넣는다() async {
        var a = Self.track("a"), b = Self.track("b")
        a.cuesWritten = 2
        b.cueReason = "메모리 큐가 11개가 됩니다"
        host.addPreview = .success(Self.addPreview([a, b, Self.track("c", written: false, reason: "이미 rekordbox 컬렉션에 있는 파일입니다")],
                                                   without: ["b": "ALAC"]))
        await coordinator().addTracks(rows: ["djc-a", "djc-b", "djc-c"].map(Self.row))
        let prompt = try? #require(prompter.shown.first)
        #expect(prompt?.title == "rekordbox 컬렉션에 2곡을 넣습니다" && prompt?.confirm == "rekordbox에 넣기" && prompt?.critical == false)
        let lines = prompt?.text.components(separatedBy: "\n") ?? []
        #expect(lines.contains("• 곡 a — 그리드·파형·오토게인까지 · 큐 2개") && lines.contains("• 곡 b — 분석 없이(ALAC) · ⚠︎ 큐는 안 들어감(메모리 큐가 11개가 됩니다)"))
        #expect(lines.contains("넣지 않는 곡 1:") && lines.contains("• 곡 c: 이미 rekordbox 컬렉션에 있는 파일입니다"))
        #expect(host.added == ["a", "b"] && host.locks == [true, false])
    }

    @Test func 빼기는_경고_창으로_묻고_취소하면_빼지_않는다() async {
        var report = RekordboxTrackWriter.Report(dryRun: true)
        report.deleted = [Self.track("a"), Self.track("b", written: false, reason: "확인하지 않은 표(djmdSongMyTag)에 걸린 곡")]
        host.deletePreview = .success(.init(report: report, contentIDs: ["id-a", "id-b"]))
        prompter.answer = false
        await coordinator().deleteTracks(rows: [Self.row("a"), Self.row("b")])
        let prompt = try? #require(prompter.shown.first)
        #expect(prompt?.critical == true && prompt?.title == "rekordbox 컬렉션에서 1곡을 뺍니다" && prompt?.confirm == "rekordbox에서 빼기")
        #expect(prompt?.text.contains("음원 파일은 지우지 않습니다") == true && prompt?.text.contains("djmdSongMyTag") == true)
        #expect(host.deleted == nil && !host.isWritingRekordbox)
        prompter.answer = true
        await coordinator().deleteTracks(rows: [Self.row("a"), Self.row("b")])
        #expect(host.deleted == ["id-a"])
    }

    @Test func 곡_넣기를_되돌리는_창은_추가_목록으로_돌아온다고_알린다() {
        var tracks = RekordboxTrackWriter.Report(dryRun: false)
        tracks.added = [Self.track("a")]
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: nil, trackReport: tracks)
        let prompt = ReflectionCoordinator.restoreConfirmation(backup, changedSince: false)
        #expect(prompt.text.contains("그때 넣은 1곡은 컬렉션에서 빠지고") && prompt.text.contains("추가 목록으로 돌아옵니다"))
        #expect(backup.titles == ["곡 a"])
    }

    @Test func 자동_복원이_실패한_백업도_되돌리기로_복원한다() async {
        // 복원 실패로 끝난 쓰기는 보고서를 남기지 않는다 → 그 뒤 바뀌었는지 모름(nil). 막지 않고 묻고 되돌린다.
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b-write"), createdAt: .now, isWrite: true, report: nil)
        #expect(backup.finalUpdateCount == nil)
        host.changedSinceBackup = nil
        await coordinator().restore(backup)
        #expect(prompter.shown.map(\.confirm) == ["되돌리기"] && prompter.shown.first?.text.contains("확인하지 못했습니다") == true)
        #expect(host.restored == [backup.url])
    }

    @Test func 되돌리기는_그_뒤_rekordbox가_바뀌었으면_경고한다() async {
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: nil)
        host.changedSinceBackup = true
        await coordinator().restore(backup)
        #expect(prompter.shown.first?.critical == true && prompter.shown.first?.confirm == "되돌리기")
        #expect(host.restored == [backup.url] && host.locks == [true, false])
        prompter.answer = false
        await coordinator().restore(backup)
        #expect(host.restored.count == 1)
    }

    @Test(arguments: [true, nil] as [Bool?])
    func 변경됐거나_확인하지_못한_되돌리기는_파괴적_경고이고_Return으로_실행하지_않는다(changed: Bool?) async throws {
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: nil)
        host.changedSinceBackup = changed
        prompter.answer = false
        await coordinator().restore(backup)
        let prompt = try #require(prompter.shown.first)
        #expect(prompt.critical && prompt.destructive)
        #expect(host.restored.isEmpty && host.locks == [true, false])

        _ = NSApplication.shared
        let alert = AlertPrompter().makeAlert(prompt)
        alert.layout()
        #expect(alert.alertStyle == .critical)
        #expect(alert.buttons.first?.hasDestructiveAction == true)
        #expect(alert.buttons.allSatisfy { $0.keyEquivalent != "\r" })
        #expect(alert.window.defaultButtonCell == nil)
        #expect(alert.buttons.last?.keyEquivalent == "\u{1b}")
    }

    @Test func 변경이_없는_되돌리기는_Return으로_확인할_수_있다() {
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: nil)
        let prompt = ReflectionCoordinator.restoreConfirmation(backup, changedSince: false)
        #expect(!prompt.critical && !prompt.destructive)
        _ = NSApplication.shared
        let alert = AlertPrompter().makeAlert(prompt)
        alert.layout()
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        #expect(alert.buttons.first?.hasDestructiveAction == false)
        #expect(alert.buttons.last?.keyEquivalent == "\u{1b}")
    }

    @Test func 쓰기_넣기_빼기_확인_창은_Return_기본_버튼을_유지하고_Esc로_취소할_수_있다() {
        var deleted = RekordboxTrackWriter.Report(dryRun: true)
        deleted.deleted = [Self.track("a")]
        let prompts = [
            ReflectionCoordinator.confirmation(Self.preview(cues: [Self.outcome("a", .written)]).report),
            ReflectionCoordinator.addConfirmation(Self.addPreview([Self.track("a")])),
            ReflectionCoordinator.deleteConfirmation(.init(report: deleted, contentIDs: ["id-a"])),
        ]
        _ = NSApplication.shared
        for prompt in prompts {
            #expect(!prompt.destructive)
            let alert = AlertPrompter().makeAlert(prompt)
            alert.layout()
            #expect(alert.buttons.map(\.title) == [prompt.confirm, "취소"])
            #expect(alert.buttons.first?.keyEquivalent == "\r")
            #expect(alert.buttons.first?.hasDestructiveAction == false)
            #expect(alert.buttons.last?.keyEquivalent == "\u{1b}")
        }
    }

    @Test func 정보_알림은_한국어_확인_버튼을_직접_만든다() {
        _ = NSApplication.shared
        let alert = AlertPrompter().makeAlert(ReflectionPrompt(title: "알림", text: "안내"))
        #expect(alert.buttons.map(\.title) == ["확인"])
    }

    @Test func 자동_복원_실패_경고는_심각_경고와_한국어_확인_버튼을_유지한다() throws {
        let prompt = try #require(ReflectionCoordinator.restoreFailureAlert(
            DJCError.restoreFailed(reason: "검증 실패", restoreError: "복원 실패", backup: "/tmp/b", database: nil)))
        _ = NSApplication.shared
        let alert = AlertPrompter().makeAlert(prompt)
        #expect(alert.alertStyle == .critical && !prompt.destructive)
        #expect(alert.buttons.map(\.title) == ["확인"])
        #expect(alert.buttons.first?.keyEquivalent == "\r")
    }
}
