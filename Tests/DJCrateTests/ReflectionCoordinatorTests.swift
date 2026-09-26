@testable import DJCrate
import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

/// 반영 흐름(확인 → 미리 보기 → 묻기 → 쓰기 → 토스트)을 가짜 저장소·창으로 확인한다.
@MainActor
final class FakeReflectionHost: ReflectionHost {
    var isWritingRekordbox = false
    var writeStage: String?
    var toast: AppToast?
    var locks: [Bool] = []
    var targets: [TrackRow]?
    var preview: Result<LibraryStore.WritePreview, Error> = .failure(FixtureFailure())
    var wrote: (drafts: [String], grids: [String], gains: [String])?
    var changedSinceBackup: Bool?
    var restored: [URL] = []
    /// 쓰기·넣기·빼기가 던질 오류(확인 창 뒤 실제 쓰기 단계)
    var writeError: Error?

    func setWriteLock(_ locked: Bool) { isWritingRekordbox = locked; locks.append(locked) }
    func writeTargets(_ rows: [TrackRow]) -> [TrackRow] { targets ?? rows }
    func previewWrite(rows: [TrackRow]) async throws -> LibraryStore.WritePreview { try preview.get() }
    func writeToRekordbox(_ drafts: [CueDraft], grids: [GridDraft], gains: [String: Double]) async throws -> RekordboxWriter.Report {
        wrote = (drafts.map(\.trackUUID), grids.map(\.trackUUID), gains.keys.sorted())
        if let writeError { throw writeError }
        return try preview.get().report
    }
    func libraryChangedSince(_ backup: RekordboxWriter.Backup) async -> Bool? { changedSinceBackup }
    func restoreRekordbox(_ backup: RekordboxWriter.Backup) async throws { restored.append(backup.url) }

    var addPreview: Result<LibraryStore.TrackAddPreview, Error> = .failure(FixtureFailure())
    var deletePreview: Result<LibraryStore.TrackDeletePreview, Error> = .failure(FixtureFailure())
    var added: [String]?
    var deleted: [String]?
    func trackAddTargets(_ rows: [TrackRow]) -> [TrackRow] { rows.filter(\.isStaged) }
    func previewTrackAdd(rows: [TrackRow]) async throws -> LibraryStore.TrackAddPreview { try addPreview.get() }
    func addTracksToRekordbox(_ preview: LibraryStore.TrackAddPreview) async throws -> RekordboxTrackWriter.Report {
        added = preview.report.added.filter(\.written).map(\.path)
        if let writeError { throw writeError }
        return preview.report
    }
    func trackDeleteTargets(_ rows: [TrackRow]) -> [TrackRow] { rows.filter { !$0.isStaged } }
    func previewTrackDelete(rows: [TrackRow]) async throws -> LibraryStore.TrackDeletePreview { try deletePreview.get() }
    func deleteTracksFromRekordbox(_ preview: LibraryStore.TrackDeletePreview) async throws -> RekordboxTrackWriter.Report {
        deleted = preview.report.deleted.filter(\.written).compactMap(\.contentID)
        if let writeError { throw writeError }
        return preview.report
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
                        gains: [RekordboxWriter.Outcome] = []) -> LibraryStore.WritePreview {
        var report = RekordboxWriter.Report(outcomes: cues, backup: nil, dryRun: true, createdAt: "", finalUpdateCount: nil)
        report.gridOutcomes = grids.isEmpty ? nil : grids
        report.gainOutcomes = gains.isEmpty ? nil : gains
        return .init(report: report,
                     drafts: cues.map { CueDraft(trackUUID: $0.trackUUID, rekordboxCues: []) },
                     grids: grids.map { GridDraft(trackUUID: $0.trackUUID, base: [], segments: []) },
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

    @Test func 미리_보기가_실패하면_실패_토스트() async {
        await coordinator().write(rows: [Self.row("a")])
        #expect(host.toast?.kind == .failure && host.toast?.detail == "미리 보기 실패")
        #expect(host.writeStage == nil && !host.isWritingRekordbox)
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
        #expect(text.contains("rekordbox를 켜지 말고") && text.contains("'rekordbox 반영 대기'의 '되돌리기…'"))
        #expect(text.contains("djc rekordbox-restore --backup '\(backup)' --live"))
        #expect(text.contains("무결성 검사 실패: x") && text.contains("master.db: 권한 없음"))
        #expect(host.writeStage == nil && host.locks == [true, false, true, false, true, false])
    }

    @Test func 백업으로_되돌렸으면_실패_토스트로_알린다() async {
        await failEveryWrite(with: DJCError.writeRolledBack("무결성 검사 실패: x"))
        #expect(prompter.shown.allSatisfy { $0.confirm != nil }, "경고 창은 띄우지 않는다")
        #expect(host.toast?.kind == .failure && host.toast?.title == "rekordbox에서 빼지 않았습니다")
        #expect(host.toast?.detail == "쓴 결과를 확인하지 못해 쓰기 전 백업으로 되돌렸습니다: 무결성 검사 실패: x")
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
}
