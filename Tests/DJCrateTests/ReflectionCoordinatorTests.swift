@testable import DJCrate
import AppKit
import DJCDomain
import DJCTestSupport
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
    var wrote: (drafts: [String], grids: [String], gains: [String], tags: [String])?
    var wroteArtworks: [String]?
    var hasPlaylistDrafts = false
    /// 미리 보기에 재생 목록 초안을 넣으라고 했는지, 쓰기에 넘긴 재생 목록 초안
    var previewedPlaylists: Bool?
    var wroteMerges: [DuplicateMergeDraft]?
    var wrotePlaylists: PlaylistDraft??
    var changedSinceBackup: Bool?
    var restored: [URL] = []
    var beforePreview: (() async -> Void)?
    /// 쓰기·넣기·빼기가 던질 오류(확인 창 뒤 실제 쓰기 단계)
    var writeError: Error?

    func setWriteLock(_ locked: Bool) { isWritingRekordbox = locked; locks.append(locked) }
    func writeTargets(_ rows: [TrackRow]) -> [TrackRow] { targets ?? rows }
    func previewWrite(rows: [TrackRow], playlists: Bool) async throws -> LibraryStore.WritePreview {
        previewedPlaylists = playlists
        await beforePreview?()
        return try preview.get()
    }
    func writeToRekordbox(_ drafts: [CueDraft], grids: [GridDraft], gains: [String: Double], tags: [TagDraft], artworks: [ArtworkEdit],
                          playlists: PlaylistDraft?, merges: [DuplicateMergeDraft]) async throws -> RekordboxWriter.Report {
        wrote = (drafts.map(\.trackUUID), grids.map(\.trackUUID), gains.keys.sorted(), tags.map(\.trackUUID))
        wroteArtworks = artworks.map(\.trackUUID)
        wrotePlaylists = .some(playlists)
        wroteMerges = merges
        if let writeError { throw writeError }
        return try writtenReport ?? preview.get().report
    }
    func libraryChangedSince(_ backup: RekordboxWriter.Backup) async -> Bool? { changedSinceBackup }
    func restoreRekordbox(_ backup: RekordboxWriter.Backup) async throws -> URL {
        if let writeError { throw writeError }
        restored.append(backup.url)
        return restoreSafetyBackup
    }
    /// 쓰기·복원 뒤따른 경고, 복원 충돌, 복원에 넘긴 선택(#175)
    var followUp: [String] = []
    var conflicts: [String] = []
    var keptCurrentDrafts: Bool?
    var writeFollowUp: [String] { followUp }
    func restoreDraftConflictDetails(_ backup: RekordboxWriter.Backup) -> [String] { conflicts }
    func restoreRekordbox(_ backup: RekordboxWriter.Backup, keepingCurrentDrafts: Bool) async throws -> URL {
        keptCurrentDrafts = keepingCurrentDrafts
        return try await restoreRekordbox(backup)
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
    /// 차례로 쓸 확인 답(비면 `answer`)
    var answers: [Bool] = []
    /// 세 갈래 창의 답(비면 `answer`에 따라 확인·취소)
    var choices: [ReflectionChoice] = []
    var shown: [ReflectionPrompt] = []
    func show(_ prompt: ReflectionPrompt) -> Bool {
        shown.append(prompt)
        return answers.isEmpty ? answer : answers.removeFirst()
    }
    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice {
        shown.append(prompt)
        if !choices.isEmpty { return choices.removeFirst() }
        return answer ? .confirm : .cancel
    }
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
                        gains: [RekordboxWriter.Outcome] = [], analyses: [RekordboxWriter.Outcome] = [],
                        tags: [RekordboxWriter.Outcome] = []) -> LibraryStore.WritePreview {
        var report = RekordboxWriter.Report(outcomes: cues, backup: nil, dryRun: true, createdAt: "", finalUpdateCount: nil)
        report.gridOutcomes = grids.isEmpty ? nil : grids
        report.gainOutcomes = gains.isEmpty ? nil : gains
        report.analysisOutcomes = analyses.isEmpty ? nil : analyses
        report.tagOutcomes = tags.isEmpty ? nil : tags
        return .init(report: report,
                     drafts: cues.map { CueDraft(trackUUID: $0.trackUUID, rekordboxCues: []) },
                     grids: (grids + analyses).map { GridDraft(trackUUID: $0.trackUUID, base: [], segments: []) },
                     gains: Dictionary(uniqueKeysWithValues: gains.map { ($0.trackUUID, -3.0) }),
                     tags: tags.map { TagDraft(trackUUID: $0.trackUUID, base: TagFields()) })
    }

    static func tagOutcome(_ uuid: String, _ status: RekordboxWriter.Outcome.Status, fields: [String] = ["title", "artist"],
                           reason: String? = nil) -> RekordboxWriter.Outcome {
        var outcome = outcome(uuid, status, reason: reason, added: fields.count)
        outcome.fields = status == .written ? fields : nil
        return outcome
    }

    @Test func rekordbox가_켜져_있으면_미리_보지도_않는다() async {
        await coordinator(running: true).write(rows: [Self.row("a")])
        #expect(prompter.shown.map(\.title) == ["rekordbox가 켜져 있어 쓰지 않았습니다"])
        #expect(host.locks.isEmpty && host.wrote == nil)
    }

    @Test func 쓸_초안이_없으면_알린다() async {
        host.targets = []
        await coordinator().write(rows: [Self.row("a")])
        #expect(prompter.shown.first?.title == "쓸 초안이 없습니다" && host.locks.isEmpty)
    }

    @Test func 모두_막히면_이유를_보여_주고_쓰지_않는다() async {
        host.preview = .success(Self.preview(cues: [Self.outcome("a", .blocked, reason: "VBR MP3")]))
        await coordinator().write(rows: [Self.row("a")])
        #expect(prompter.shown.first?.title == "rekordbox에 쓸 수 있는 초안이 없습니다")
        #expect(prompter.shown.first?.details.contains("• 곡 a: VBR MP3") == true)
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

    // MARK: 재생 목록 초안(#39·#40)

    static func playlistOutcome(_ edit: PlaylistEdit, _ name: String, _ status: RekordboxWriter.Outcome.Status,
                                reason: String? = nil) -> PlaylistOutcome {
        PlaylistOutcome(edit: edit, playlistID: status == .written ? "1" : nil, name: name, status: status, reason: reason)
    }

    static func playlistPreview(_ outcomes: [PlaylistOutcome]) -> LibraryStore.WritePreview {
        var preview = Self.preview(cues: [])
        preview.report.playlistOutcomes = outcomes
        var draft = PlaylistDraft()
        _ = try? draft.append(.create(key: "k", name: "세트", isFolder: false, parent: .root), rekordbox: PlaylistLayout())
        preview.playlists = draft
        return preview
    }

    @Test func 곡_초안이_없어도_재생_목록_초안만_쓴다() async throws {
        host.targets = []
        host.hasPlaylistDrafts = true
        let preview = Self.playlistPreview([
            Self.playlistOutcome(.create(key: "k", name: "세트", isFolder: false, parent: .root), "세트", .written),
            Self.playlistOutcome(.addTracks(playlist: .id("9"), contentIDs: ["1", "2"]), "옛 목록", .blocked,
                                 reason: "초안을 만든 뒤 rekordbox에서 이 목록이 바뀌었으니 현재 목록을 비교해 다시 적용하거나 초안을 버리세요."),
        ])
        host.preview = .success(preview)
        await coordinator().write(rows: [])
        #expect(host.previewedPlaylists == true)
        let prompt = try #require(prompter.shown.first)
        #expect(prompt.title == "재생 목록 1건을 rekordbox에 쓸까요?")
        #expect(prompt.details.contains("• 세트 — 새 재생 목록 만들기"))
        #expect(prompt.details.contains { $0.hasPrefix("• 옛 목록: 2곡 넣기 — 초안을 만든 뒤 rekordbox에서") })
        // 쓰기에는 초안 전체를 넘긴다(결과가 편집 순서와 같아야 쓴 편집만 뺄 수 있다)
        #expect(host.wrotePlaylists == .some(preview.playlists))
        #expect(host.wrote?.drafts == [] && host.locks == [true, false])
        #expect(host.toast?.title == "rekordbox에 썼습니다 · 재생 목록 1건")
    }

    @Test func 곡을_골라_쓸_때는_재생_목록_초안을_넣지_않는다() async {
        host.targets = []
        host.hasPlaylistDrafts = true
        await coordinator().write(rows: [Self.row("a")], playlists: false)
        #expect(prompter.shown.first?.title == "쓸 초안이 없습니다" && host.previewedPlaylists == nil)
        // 곡 초안이 있으면 곡만 미리 본다
        host.targets = nil
        host.preview = .success(Self.preview(cues: [Self.outcome("a", .written)]))
        await coordinator().write(rows: [Self.row("a")], playlists: false)
        #expect(host.previewedPlaylists == false && host.wrotePlaylists == .some(nil))
    }

    @Test func 재생_목록_편집이_모두_막히면_이유만_보여_준다() async {
        host.targets = []
        host.hasPlaylistDrafts = true
        host.preview = .success(Self.playlistPreview([
            Self.playlistOutcome(.rename(playlist: .id("9"), name: "x"), "스마트", .blocked, reason: "인텔리전트 재생 목록은 아직 쓰지 않습니다(rekordbox에서 고치세요)"),
        ]))
        await coordinator().write(rows: [])
        #expect(prompter.shown.first?.title == "rekordbox에 쓸 수 있는 초안이 없습니다")
        #expect(prompter.shown.first?.details == ["• 스마트: 이름 바꾸기 — 인텔리전트 재생 목록은 아직 쓰지 않습니다(rekordbox에서 고치세요)"])
        #expect(host.wrote == nil)
    }

    @Test func 쓰기_결과에_재생_목록_편집마다_한_줄을_남긴다() {
        var report = RekordboxWriter.Report(outcomes: [], backup: "/tmp/b", dryRun: false, createdAt: "", finalUpdateCount: 1)
        report.playlistOutcomes = [
            Self.playlistOutcome(.removeTracks(playlist: .id("1"), entries: [.init(trackNo: 1, contentID: "a")]), "목록", .written),
            Self.playlistOutcome(.delete(playlist: .id("2")), "폴더", .blocked, reason: "rekordbox에서 지운 목록입니다"),
            Self.playlistOutcome(.rename(playlist: .id("3"), name: "같음"), "같음", .unchanged),
        ]
        let result = WriteResult.written(report, preview: report)
        #expect(result.kind == .warning && result.title == "rekordbox에 썼습니다 · 재생 목록 1건")
        #expect(result.text.components(separatedBy: "\n") == [
            "• 목록 — 재생 목록 쓰기 완료: 1곡 빼기",
            "• 폴더 — 재생 목록 쓰지 않음(지우기): rekordbox에서 지운 목록입니다",
            "• 같음 — 재생 목록 변경 없음(이름 바꾸기)",
        ])
    }

    @Test func 태그만_쓸_수_있어도_묻고_막힌_곡의_태그는_넘기지_않는다() async {
        host.preview = .success(Self.preview(cues: [], tags: [Self.tagOutcome("t", .written),
                                                              Self.tagOutcome("x", .blocked, reason: "rekordbox에서 곡 정보가 바뀌었습니다")]))
        await coordinator().write(rows: ["t", "x"].map(Self.row))
        #expect(prompter.shown.first?.title == "태그 1곡을 rekordbox에 쓸까요?")
        #expect(host.wrote?.tags == ["t"] && host.wrote?.drafts == [] && host.wrote?.grids == [] && host.wrote?.gains == [])
    }

    @Test func 확인_창은_바뀌는_태그_칸과_음원_파일은_그대로라는_것을_알린다() {
        let preview = Self.preview(cues: [Self.outcome("a", .written, added: 1)],
                                   tags: [Self.tagOutcome("a", .written, fields: ["comment"]), Self.tagOutcome("t", .written),
                                          Self.tagOutcome("x", .blocked, reason: "규칙을 확인하지 않은 칸")])
        let prompt = ReflectionCoordinator.confirmation(preview.report)
        #expect(prompt.title == "큐 1곡 · 태그 2곡을 rekordbox에 쓸까요?")
        let lines = prompt.details
        #expect(lines.contains("• 곡 a — 큐 +1 · 태그(코멘트)"))
        #expect(lines.contains("• 곡 t — 태그(제목·아티스트)"))
        #expect(lines.contains("• 곡 x: 규칙을 확인하지 않은 칸"))
        #expect(lines.contains { $0.contains("음원 파일의 태그는 그대로") })
        // 태그를 쓰지 않으면 안내도 없다
        let cuesOnly = ReflectionCoordinator.confirmation(Self.preview(cues: [Self.outcome("a", .written)]).report)
        #expect(!cuesOnly.details.contains { $0.contains("음원 파일의 태그") })
    }

    @Test func 분석_전_곡은_그리드_초안으로_분석을_붙여_쓴다() async {
        // 분석 붙이기만 쓸 수 있어도 확인 창을 띄우고, 그 곡의 그리드 초안을 넘긴다(막힌 곡은 넘기지 않는다)
        host.preview = .success(Self.preview(cues: [], analyses: [Self.outcome("n", .written, added: 96),
                                                                  Self.outcome("h", .blocked, reason: "rekordbox에서 트랙 분석을 먼저 한 뒤 쓰세요")]))
        await coordinator().write(rows: ["n", "h"].map(Self.row))
        #expect(prompter.shown.first?.title == "분석 1곡을 rekordbox에 쓸까요?")
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
        let alert: ReflectionPrompt? = alerts.first
        #expect(alert != nil)
        #expect(alert?.title == "쓰기 확인에 실패했고 자동 복원도 하지 못했습니다")
        let text = alert?.text ?? ""
        // 반영·넣기·빼기 모두 같은 버튼(가장 최근 쓰기 백업으로 되돌림). 사이드바 아래 '마지막 반영 되돌리기…'는 성공한 쓰기 뒤에만 보여 안내하지 않는다.
        #expect(text.contains("rekordbox를 켜지 말고, 사이드바에서 'rekordbox 쓰기 대기'를 고른 뒤 목록 위 '쓰기 전으로 복원…'으로 백업을 복원하세요."))
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
        #expect(host.toast?.detail?.contains("쓰기 전 백업으로 복원했습니다") == true)
        #expect(host.toast?.detail?.contains("초안을 확인") == true)
        #expect(host.toast?.detail?.contains("무결성 검사 실패: x") == false)
    }

    @Test func 확인_창은_종류별_곡_수와_막힌_이유를_보여_준다() {
        let preview = Self.preview(cues: [Self.outcome("a", .written, added: 2)],
                                   grids: [Self.outcome("a", .blocked, reason: "분석 전"), Self.outcome("g", .written, added: 64)],
                                   gains: [Self.outcome("d", .written, added: -250)])
        let prompt = ReflectionCoordinator.confirmation(preview.report)
        #expect(prompt.title == "큐 1곡 · 그리드 1곡 · 게인 1곡을 rekordbox에 쓸까요?")
        let lines = prompt.details
        #expect(lines.contains("• 곡 a — 큐 +2 · ⚠︎ 그리드는 안 들어감"))
        #expect(lines.contains("• 곡 g — 그리드(박 64개)"))
        #expect(lines.contains("• 곡 d — 오토게인 -2.5 dB"))
        #expect(lines.contains("쓰지 않는 것 1:") && lines.contains("• 곡 a: 분석 전"))
    }

    @Test(arguments: [(1, 0, "큐 +1"), (0, 2, "큐 −2"), (1, 1, "큐 +1 · −1")])
    func 큐_변경_줄에는_0을_빼고_바뀐_수만_쓴다(_ added: Int, _ removed: Int, _ expected: String) {
        var outcome = Self.outcome("a", .written, added: added)
        outcome.removed = removed
        let prompt = ReflectionCoordinator.confirmation(Self.preview(cues: [outcome]).report)
        #expect(prompt.title == "큐 1곡을 rekordbox에 쓸까요?")
        #expect(prompt.details.first == "• 곡 a — " + expected)
        #expect(prompt.text.hasSuffix("백업한 뒤 쓰고 다시 확인합니다. 끝날 때까지 rekordbox를 켜지 마세요."))
    }

    @Test func 넣기와_빼기와_되돌리기도_짧게_묻고_백업을_안내한다() {
        var track = Self.track("a")
        track.cuesWritten = 0
        let add = ReflectionCoordinator.addConfirmation(Self.addPreview([track]))
        #expect(add.title == "1곡을 rekordbox에 넣을까요?")
        #expect(!add.details.contains { $0.contains("큐 0개") })
        var report = RekordboxTrackWriter.Report(dryRun: true)
        report.deleted = [track]
        let delete = ReflectionCoordinator.deleteConfirmation(.init(report: report, contentIDs: ["id-a"]))
        #expect(delete.title == "1곡을 rekordbox에서 뺄까요?")
        for prompt in [add, delete] {
            #expect(prompt.text.hasSuffix("백업한 뒤 쓰고 다시 확인합니다. 끝날 때까지 rekordbox를 켜지 마세요."))
        }
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: nil)
        let restore = ReflectionCoordinator.restoreConfirmation(backup, changedSince: true)
        #expect(restore.title == "rekordbox를 쓰기 전으로 복원할까요?")
        #expect(restore.text.contains("백업: "))
        #expect(restore.text.contains("그 변경도 함께 사라집니다"))
        #expect(restore.text.hasSuffix("백업한 뒤 복원하고 다시 확인합니다. 끝날 때까지 rekordbox를 켜지 마세요."))
        #expect(restore.critical && restore.destructive)
    }

    @Test func 확인_창은_분석을_붙이는_곡과_막힌_이유를_보여_준다() {
        let preview = Self.preview(cues: [Self.outcome("a", .written, added: 1), Self.outcome("b", .written, added: 3)],
                                   analyses: [Self.outcome("a", .written, added: 128), Self.outcome("n", .written, added: 96),
                                              Self.outcome("b", .blocked, reason: "ALAC")])
        let prompt = ReflectionCoordinator.confirmation(preview.report)
        #expect(prompt.title == "큐 2곡 · 분석 2곡을 rekordbox에 쓸까요?")
        let lines = prompt.details
        #expect(lines.contains("• 곡 a — 큐 +1 · 분석 파일 붙이기"))
        #expect(lines.contains("• 곡 b — 큐 +3 · ⚠︎ 그리드는 안 들어감"))
        #expect(lines.contains("• 곡 n — 분석 파일 붙이기(파형·그리드 박 96개·오토게인)"))
        #expect(lines.contains("• 곡 b: ALAC") && lines.contains { $0.contains("키·프레이즈·보컬 분석은 없습니다") })
    }

    @Test func 확인_창은_분석과_함께_아트워크도_넣는_곡을_알린다() {
        // rekordbox는 분석 전 곡을 분석할 때 음원 그림으로 아트워크를 만든다(#87, 2026-09-26 실험)
        var preview = Self.preview(cues: [Self.outcome("a", .written, added: 1)],
                                   analyses: [Self.outcome("a", .written, added: 128), Self.outcome("n", .written, added: 96),
                                              Self.outcome("p", .written, added: 64)])
        preview.report.artworkAdded = ["a", "n"]
        let lines = ReflectionCoordinator.confirmation(preview.report).details
        #expect(lines.contains("• 곡 a — 큐 +1 · 분석 파일 붙이기 · 앨범아트"))
        #expect(lines.contains("• 곡 n — 분석 파일 붙이기(파형·그리드 박 96개·오토게인·앨범아트)"))
        #expect(lines.contains("• 곡 p — 분석 파일 붙이기(파형·그리드 박 64개·오토게인)"), "그림이 없는 곡")
        #expect(lines.contains("파형·그리드·오토게인과 음원의 앨범아트를 붙입니다. 키·프레이즈·보컬 분석은 없습니다."))
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
        #expect(prompter.shown.last?.text.contains("다시 복원하세요") == true)
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
        let prompt: ReflectionPrompt? = prompter.shown.first
        #expect(prompt != nil)
        #expect(prompt?.title == "2곡을 rekordbox에 넣을까요?" && prompt?.confirm == "rekordbox에 넣기" && prompt?.critical == false)
        let lines = prompt?.details ?? []
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
        let prompt: ReflectionPrompt? = prompter.shown.first
        #expect(prompt != nil)
        #expect(prompt?.critical == true && prompt?.title == "1곡을 rekordbox에서 뺄까요?" && prompt?.confirm == "rekordbox에서 빼기")
        #expect(prompt?.text.contains("음원 파일은 지우지 않습니다") == true && prompt?.details.contains { $0.contains("djmdSongMyTag") } == true)
        #expect(host.deleted == nil && !host.isWritingRekordbox)
        prompter.answer = true
        await coordinator().deleteTracks(rows: [Self.row("a"), Self.row("b")])
        #expect(host.deleted == ["id-a"])
    }

    /// 동기화 상태 곡은 쓰기 쪽이 곡마다 막고 이유를 돌려준다(#196). 확인 창은 빼지 않는 곡과 그 이유를 보여 주고, 뺄 곡만 뺀다.
    @Test func 빼기_확인_창은_동기화_곡을_이유와_함께_빼지_않는_곡으로_보여_준다() async {
        var report = RekordboxTrackWriter.Report(dryRun: true)
        report.deleted = [Self.track("a"), Self.track("b", written: false, reason: RekordboxTrackWriter.syncedTrackReason),
                          Self.track("c", written: false, reason: RekordboxTrackWriter.syncedOrphanReason)]
        host.deletePreview = .success(.init(report: report, contentIDs: ["id-a", "id-b", "id-c"]))
        await coordinator().deleteTracks(rows: ["a", "b", "c"].map(Self.row))
        let prompt: ReflectionPrompt? = prompter.shown.first
        #expect(prompt?.title == "1곡을 rekordbox에서 뺄까요?")
        let lines = prompt?.details ?? []
        #expect(lines.contains("빼지 않는 곡 2:"))
        #expect(lines.contains("• 곡 b: rekordbox 클라우드와 동기화된 곡이라 빼는 규칙을 아직 확인하지 못했으니 rekordbox에서 직접 빼세요"))
        #expect(lines.contains { $0.hasPrefix("• 곡 c: 이 곡만 쓰던 앨범·아티스트 행이 클라우드와 동기화된 행") })
        #expect(host.deleted == ["id-a"])
    }

    @Test func 빼기는_모두_동기화_곡이라_막히면_이유를_알리고_쓰지_않는다() async {
        var report = RekordboxTrackWriter.Report(dryRun: true)
        report.deleted = [Self.track("a", written: false, reason: RekordboxTrackWriter.syncedTrackReason)]
        host.deletePreview = .success(.init(report: report, contentIDs: ["id-a"]))
        await coordinator().deleteTracks(rows: [Self.row("a")])
        let prompt: ReflectionPrompt? = prompter.shown.first
        #expect(prompt?.title == "rekordbox에서 뺄 수 있는 곡이 없습니다" && prompt?.confirm == nil)
        #expect(prompt?.details == ["• 곡 a: " + RekordboxTrackWriter.syncedTrackReason])
        #expect(host.deleted == nil && host.locks == [true, false])
    }

    @Test func 곡_넣기를_되돌리는_창은_추가_목록으로_돌아온다고_알린다() {
        var tracks = RekordboxTrackWriter.Report(dryRun: false)
        tracks.added = [Self.track("a")]
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: nil, trackReport: tracks)
        let prompt = ReflectionCoordinator.restoreConfirmation(backup, changedSince: false)
        #expect(prompt.text.contains("넣었던 1곡은 컬렉션에서 빠지고") && prompt.text.contains("추가 목록으로 돌아옵니다"))
        #expect(backup.titles == ["곡 a"])
    }

    @Test func 뒤에_뜬_백업이_있으면_함께_되돌린다고_알린다() {
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: nil)
        #expect(!ReflectionCoordinator.restoreConfirmation(backup, changedSince: false).text.contains("함께 되돌립니다"))
        let prompt = ReflectionCoordinator.restoreConfirmation(backup, changedSince: false, later: 2)
        #expect(prompt.text.contains("쓰거나 복원한 2번도 분석 파일까지 함께 되돌립니다"))
    }

    @Test func 자동_복원이_실패한_백업도_되돌리기로_복원한다() async {
        // 복원 실패로 끝난 쓰기는 보고서를 남기지 않는다 → 그 뒤 바뀌었는지 모름(nil). 막지 않고 묻고 되돌린다.
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b-write"), createdAt: .now, isWrite: true, report: nil)
        #expect(backup.finalUpdateCount == nil)
        host.changedSinceBackup = nil
        await coordinator().restore(backup)
        #expect(prompter.shown.map(\.confirm) == ["쓰기 전으로 복원"] && prompter.shown.first?.text.contains("확인하지 못했습니다") == true)
        #expect(host.restored == [backup.url])
    }

    @Test func 되돌리기는_그_뒤_rekordbox가_바뀌었으면_경고한다() async {
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: nil)
        host.changedSinceBackup = true
        await coordinator().restore(backup)
        #expect(prompter.shown.first?.critical == true && prompter.shown.first?.confirm == "쓰기 전으로 복원")
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

    @Test func 넣기_확인_창은_아트워크를_함께_넣는_곡을_표시한다() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-art-prompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let withArt = try TrackAddPlan.make(url: try AudioFixture.wav(seconds: 1, in: folder, name: "art.wav"), tags: AudioTags(duration: 1, artwork: Data([1])))
        let bare = try TrackAddPlan.make(url: try AudioFixture.wav(seconds: 1, in: folder, name: "bare.wav"), tags: AudioTags(duration: 1))
        let later = try TrackAddPlan.make(url: try AudioFixture.wav(seconds: 1, in: folder, name: "later.wav"), tags: AudioTags(duration: 1, artwork: Data([1])))
        var preview = Self.addPreview([Self.track(withArt.path), Self.track(bare.path), Self.track(later.path)], without: [later.path: "그리드 없음"])
        preview.plans = [withArt, bare, later]
        let open = ReflectionCoordinator.addConfirmation(preview, writesArtwork: true).details
        #expect(open.contains("• 곡 \(withArt.path) — 그리드·파형·오토게인까지 · 앨범아트"))
        #expect(open.contains("• 곡 \(bare.path) — 그리드·파형·오토게인까지"))
        // 분석 없이 넣는 곡은 rekordbox처럼 아트워크를 넣지 않는다. rekordbox가 분석할 때 뽑는다(2026-09-26 실험).
        #expect(open.contains("• 곡 \(later.path) — 분석 없이(그리드 없음)"))
        #expect(open.last == "분석 없이 넣는 곡은 rekordbox에서 분석해야 파형·그리드·앨범아트가 생깁니다.")
        #expect(!open.contains(ReflectionCoordinator.artworkClosedNote))
        // 닫혀 있으면 곡 줄에는 붙이지 않고, 분석까지 붙이는 곡에 아트워크가 있을 때만 무엇을 하면 되는지 한 번 알린다
        let closed = ReflectionCoordinator.addConfirmation(preview, writesArtwork: false).details
        #expect(!closed.contains { $0.hasSuffix("· 앨범아트") } && closed.last == ReflectionCoordinator.artworkClosedNote)
        preview.plans = [bare, later]
        let bareOnly = ReflectionCoordinator.addConfirmation(preview, writesArtwork: false).details
        #expect(!bareOnly.contains(ReflectionCoordinator.artworkClosedNote))
        #expect(bareOnly.last == "분석 없이 넣는 곡은 rekordbox에서 분석해야 파형·그리드·앨범아트가 생깁니다.")
        preview.plans = [bare]
        #expect(ReflectionCoordinator.addConfirmation(preview, writesArtwork: true).details.last
                == "분석 없이 넣는 곡은 rekordbox에서 분석해야 파형·그리드가 생깁니다.")
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
