@testable import AnicueApp
import AnicueDomain
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

    func setWriteLock(_ locked: Bool) { isWritingRekordbox = locked; locks.append(locked) }
    func writeTargets(_ rows: [TrackRow]) -> [TrackRow] { targets ?? rows }
    func previewWrite(rows: [TrackRow]) async throws -> LibraryStore.WritePreview { try preview.get() }
    func writeToRekordbox(_ drafts: [CueDraft], grids: [GridDraft], gains: [String: Double]) async throws -> RekordboxWriter.Report {
        wrote = (drafts.map(\.trackUUID), grids.map(\.trackUUID), gains.keys.sorted())
        return try preview.get().report
    }
    func libraryChangedSince(_ backup: RekordboxWriter.Backup) async -> Bool? { changedSinceBackup }
    func restoreRekordbox(_ backup: RekordboxWriter.Backup) async throws { restored.append(backup.url) }
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
