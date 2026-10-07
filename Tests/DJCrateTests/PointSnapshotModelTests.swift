import DJCDomain
import DJCTestSupport
import Foundation
@testable import DJCrate
import RekordboxKit
import Testing

/// 시점 스냅샷 창(#224): 합성 사본으로 만들기·목록(쓰기 전 백업과 함께)·고정·지우기. 사용자 데이터 폴더는 쓰지 않는다.
@MainActor
@Suite("시점 스냅샷 창")
struct PointSnapshotModelTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    static let copyGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })

    func model(_ fixture: RekordboxFixture, prompter: ScriptedPrompter = ScriptedPrompter(), busy: String? = nil,
               guard writeGuard: RekordboxWriteGuard = copyGuard, clock: Date? = nil) -> PointSnapshotModel {
        PointSnapshotModel(database: fixture.database, shareRoot: fixture.shareRoot, snapshots: fixture.root.appending(path: "point-snapshots"),
                           backups: fixture.backups, guard: writeGuard, busyReason: { busy }, prompter: prompter, now: { clock ?? now })
    }

    @Test func 이름을_붙여_남기면_목록_맨_위에_고른_채로_보이고_이름_칸을_비운다() async throws {
        let fixture = try RekordboxFixture()
        let model = model(fixture)
        model.newName = "큰 정리 전"
        await model.create()
        #expect(model.isError == false, "\(model.message ?? "")")
        let first = try #require(model.rows.first)
        #expect(first.name == "큰 정리 전" && first.kind == "수동")
        #expect(model.selection == first.id)
        #expect(model.newName.isEmpty)
        #expect((first.bytes ?? 0) > 0)
    }

    @Test func 쓰기_전_백업도_같은_목록에_보이지만_고정할_수_없다() async throws {
        let fixture = try RekordboxFixture()
        try makeBackup(fixture, "2026-09-01T000000-write")
        try makeBackup(fixture, "2026-09-02T000000-before-restore")
        // 백업 목록의 시각은 폴더를 만든 때라 스냅샷은 그 뒤 시각으로 뜬다(소수 초는 ms까지만 적는다)
        let model = model(fixture, clock: Date().addingTimeInterval(1))
        await model.create()
        await model.refresh()
        #expect(model.rows.map(\.kind) == ["수동", "복원 직전 백업", "쓰기 전 백업"], "\(model.rows.map { ($0.kind, $0.date.timeIntervalSince1970) })")
        let backupRow = try #require(model.rows.first { $0.entry == nil })
        await model.setPinned(true, backupRow)
        #expect(!model.rows.contains { $0.pinned && $0.entry == nil })
    }

    /// 쓰기 전 백업 하나(합성: 사본 DB를 백업 폴더에 둔다)
    @discardableResult
    func makeBackup(_ fixture: RekordboxFixture, _ name: String) throws -> URL {
        let folder = fixture.backups.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.database, to: folder.appending(path: "master.db"))
        return folder
    }

    @Test func 고정하고_풀_수_있고_고정한_것은_지우지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let prompter = ScriptedPrompter()
        let model = model(fixture, prompter: prompter)
        await model.create()
        let row = try #require(model.rows.first)
        await model.setPinned(true, row)
        #expect(model.rows.first?.pinned == true)
        await model.delete(try #require(model.rows.first))
        #expect(prompter.shown.isEmpty, "고정한 것은 묻지도 않는다")
        #expect(model.rows.count == 1)
        await model.setPinned(false, try #require(model.rows.first))
        #expect(model.rows.first?.pinned == false)
    }

    @Test func 지우기는_한_번_묻고_취소하면_그대로_둔다() async throws {
        let fixture = try RekordboxFixture()
        let prompter = ScriptedPrompter()
        let model = model(fixture, prompter: prompter)
        await model.create()
        prompter.answer = false
        await model.delete(try #require(model.rows.first))
        #expect(model.rows.count == 1 && prompter.shown.count == 1)
        prompter.answer = true
        await model.delete(try #require(model.rows.first))
        #expect(model.rows.isEmpty && prompter.shown.count == 2)
        #expect(prompter.shown.last?.destructive == true)
    }

    @Test func rekordbox가_켜져_있으면_이유를_알리고_남기지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let running = RekordboxWriteGuard(isLive: { _ in true }, isRekordboxRunning: { true }, appVersion: { "7.2.18" })
        let model = model(fixture, guard: running)
        await model.create()
        #expect(model.isError)
        #expect(model.message?.contains("rekordbox를 완전히 종료") == true, "\(model.message ?? "")")
        #expect(model.rows.isEmpty)
    }

    @Test func 쓰는_중에는_막는다() async throws {
        let fixture = try RekordboxFixture()
        let model = model(fixture, busy: "rekordbox에 쓰는 중입니다")
        await model.create()
        #expect(model.isError && model.rows.isEmpty)
    }

    // MARK: - 비교·복원(#225)

    func title(_ fixture: RekordboxFixture, _ id: String) throws -> String? {
        try fixture.rows("SELECT Title FROM djmdContent WHERE ID = ?", [.text(id)]).first?["Title"]
    }

    @Test func 복원은_비교한_뒤_한_번만_묻고_취소하면_그대로_두고_확인하면_되돌린다() async throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec(id: "501")
        track.title = "원래 제목"
        try fixture.add(track)
        let prompter = ScriptedPrompter()
        let model = model(fixture, prompter: prompter, clock: Date())
        model.newName = "정리 전"
        await model.create()
        try fixture.execute("UPDATE djmdContent SET Title = '바꾼 제목' WHERE ID = '501'")
        let row = try #require(model.rows.first { $0.entry != nil })

        prompter.answer = false
        await model.restore(row)
        #expect(prompter.shown.count == 1)
        #expect(try title(fixture, "501") == "바꾼 제목")
        let prompt = try #require(prompter.shown.first)
        #expect(prompt.title.contains("정리 전") && prompt.destructive && prompt.confirm == "이 시점으로 복원")
        #expect(prompt.details.contains { $0.contains("곡 정보가 바뀌는 곡 1") })
        #expect(prompt.text.contains("초안은 그대로"))
        #expect(model.comparison?.tagsChanged == ["바꾼 제목"], "비교 결과도 창에 남는다")

        prompter.answer = true
        await model.restore(row)
        #expect(prompter.shown.count == 2)
        #expect(try title(fixture, "501") == "원래 제목")
        #expect(model.isError == false, "\(model.message ?? "")")
        #expect(model.rows.contains { $0.entry?.metadata.kind == .beforeRestore && $0.name == "‘정리 전’ 복원 전" })
    }

    @Test func rekordbox가_켜져_있으면_묻지_않고_이유를_알린다() async throws {
        let fixture = try RekordboxFixture()
        let prompter = ScriptedPrompter()
        _ = try RekordboxPointSnapshot.create(name: "전", database: fixture.database, shareRoot: nil, in: fixture.root.appending(path: "point-snapshots"),
                                             autoDays: 7, now: now, guard: Self.copyGuard)
        let running = RekordboxWriteGuard(isLive: { _ in true }, isRekordboxRunning: { true }, appVersion: { "7.2.18" })
        let model = model(fixture, prompter: prompter, guard: running)
        await model.refresh()
        await model.restore(try #require(model.rows.first))
        #expect(prompter.shown.isEmpty && model.isError)
        #expect(model.message?.contains("rekordbox를 완전히 종료") == true)
    }

    @Test func 스냅샷_뒤_클라우드_동기화가_있었으면_확인_창에_한_줄_알린다() throws {
        let entry = RekordboxPointSnapshot.Entry(url: URL(filePath: "/tmp/x"),
                                                 metadata: .init(name: "전", kind: .manual, createdAt: now, cloudUpdateCount: 100))
        var diff = RekordboxPointSnapshotDiff()
        diff.currentCloudUpdateCount = 100
        #expect(!PointSnapshotModel.restoreConfirmation(entry, diff: diff).text.contains("클라우드"))
        diff.currentCloudUpdateCount = 120
        let prompt = PointSnapshotModel.restoreConfirmation(entry, diff: diff)
        #expect(prompt.text.contains("클라우드 동기화"))
        #expect(prompt.text.contains("다른 곳이 없습니다"))
    }
}
