import DJCDomain
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// 하루 한 번 자동 시점 스냅샷(#228). 시각·달력·클론 가능 여부·rekordbox 켜짐은 주입하고, 합성 사본(`RekordboxFixture`)으로만 뜬다.
@Suite("자동 시점 스냅샷")
struct RekordboxAutoPointSnapshotTests {
    /// 2026-09-25 12:00 UTC
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    let day = 86_400.0
    static let copyGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func folder(_ fixture: RekordboxFixture) -> URL { fixture.root.appending(path: "point-snapshots") }

    func auto(_ fixture: RekordboxFixture, at time: Date, days: Int = 7, canClone: Bool = true,
              guard writeGuard: RekordboxWriteGuard = copyGuard) throws -> RekordboxPointSnapshot.AutoOutcome {
        try RekordboxPointSnapshot.takeAutoIfDue(database: fixture.database, shareRoot: nil, in: folder(fixture), autoDays: days,
                                                 now: time, calendar: utc, canClone: { _, _ in canClone }, guard: writeGuard)
    }

    /// 라이브러리를 바꾼다(수정 시각이 확실히 달라지게 시각도 밀어 둔다)
    func change(_ fixture: RekordboxFixture, at time: Date) throws {
        var track = TrackSpec(id: String(Int.random(in: 1000...9999)))
        track.title = "새 곡"
        try fixture.add(track)
        try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: fixture.database.path)
    }

    @Test func 처음이면_뜨고_원본_DB의_크기·수정_시각을_적는다() throws {
        let fixture = try RekordboxFixture()
        let outcome = try auto(fixture, at: now)
        guard case let .took(entry) = outcome else { Issue.record("\(outcome)"); return }
        #expect(entry.metadata.kind == .auto && entry.metadata.name.isEmpty && !entry.metadata.pinned)
        #expect(entry.id == "2026-09-25T120000Z-auto")
        #expect(entry.metadata.source == RekordboxPointSnapshot.sourceStamp(of: fixture.database))
        #expect(RekordboxPointSnapshot.list(in: folder(fixture)).first?.metadata.source == entry.metadata.source, "다시 읽어도 같다")
    }

    @Test func 같은_날에는_라이브러리가_바뀌어도_한_번만_뜬다() throws {
        let fixture = try RekordboxFixture()
        _ = try auto(fixture, at: now)
        try change(fixture, at: now.addingTimeInterval(60))
        #expect(try auto(fixture, at: now.addingTimeInterval(3_600)) == .skipped(.alreadyToday))
        #expect(RekordboxPointSnapshot.list(in: folder(fixture)).count == 1)
    }

    @Test func 마지막_스냅샷_뒤_바뀌지_않았으면_다음_날에도_뜨지_않고_바뀌면_뜬다() throws {
        let fixture = try RekordboxFixture()
        _ = try auto(fixture, at: now)
        #expect(try auto(fixture, at: now.addingTimeInterval(day)) == .skipped(.unchanged))
        try change(fixture, at: now.addingTimeInterval(day + 60))
        let next = try auto(fixture, at: now.addingTimeInterval(day + 120))
        guard case let .took(entry) = next else { Issue.record("\(next)"); return }
        #expect(entry.id == "2026-09-26T120200Z-auto")
    }

    @Test func 수동_스냅샷_뒤_바뀌지_않았어도_뜨지_않는다() throws {
        let fixture = try RekordboxFixture()
        try RekordboxPointSnapshot.create(name: "정리 전", database: fixture.database, shareRoot: nil, in: folder(fixture), autoDays: 7,
                                          now: now, guard: Self.copyGuard)
        #expect(try auto(fixture, at: now.addingTimeInterval(day)) == .skipped(.unchanged))
        #expect(RekordboxPointSnapshot.list(in: folder(fixture)).map(\.metadata.kind) == [.manual])
    }

    @Test func 원본_도장이_없는_옛_스냅샷_뒤에는_바뀐_것으로_보고_뜬다() throws {
        let fixture = try RekordboxFixture()
        let old = try RekordboxPointSnapshot.take(name: "", kind: .manual, database: fixture.database, shareRoot: nil, in: folder(fixture),
                                                  now: now.addingTimeInterval(-day), guard: Self.copyGuard)
        var metadata = old.metadata
        metadata.source = nil
        try RekordboxPointSnapshot.save(metadata, in: old.url)
        guard case .took = try auto(fixture, at: now) else { Issue.record("옛 스냅샷 뒤에 뜨지 않았다"); return }
    }

    @Test func rekordbox가_켜져_있으면_건너뛰고_아무것도_남기지_않는다() throws {
        let fixture = try RekordboxFixture()
        // 사본이라도 rekordbox가 켜져 있으면 뜨지 않는다(자동은 rekordbox가 꺼졌을 때만)
        let running = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { true }, appVersion: { "7.2.18" })
        #expect(try auto(fixture, at: now, guard: running) == .skipped(.rekordboxRunning))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder(fixture).path)) ?? []).isEmpty)
    }

    @Test func 뜨는_동안_rekordbox가_켜지면_버리고_오류를_낸다() throws {
        let fixture = try RekordboxFixture()
        let calls = PointSnapshotCallCounter()
        let flipping = RekordboxWriteGuard(isLive: { _ in true }, isRekordboxRunning: { calls.next() > 1 }, appVersion: { "7.2.18" })
        #expect(throws: DJCError.self) { try auto(fixture, at: now, guard: flipping) }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder(fixture).path)) ?? []).isEmpty)
    }

    @Test func 클론이_안_되면_큰_복사를_하지_않고_건너뛴다() throws {
        let fixture = try RekordboxFixture()
        #expect(try auto(fixture, at: now, canClone: false) == .skipped(.noClone))
        #expect(RekordboxPointSnapshot.list(in: folder(fixture)).isEmpty)
    }

    @Test func WAL이_남아_있으면_오류_없이_건너뛴다() throws {
        let fixture = try RekordboxFixture()
        try Data(repeating: 1, count: 32).write(to: URL(filePath: fixture.database.path + "-wal"))
        #expect(try auto(fixture, at: now) == .skipped(.walPending))
        #expect(RekordboxPointSnapshot.list(in: folder(fixture)).isEmpty)
    }

    @Test func 보관_일수가_지난_자동만_정리하고_수동·고정·복원_직전은_남긴다() throws {
        let fixture = try RekordboxFixture()
        let manual = try RekordboxPointSnapshot.take(name: "옛 수동", kind: .manual, database: fixture.database, shareRoot: nil,
                                                     in: folder(fixture), now: now.addingTimeInterval(-30 * day), guard: Self.copyGuard)
        let restore = try RekordboxPointSnapshot.take(name: "", kind: .beforeRestore, database: fixture.database, shareRoot: nil,
                                                      in: folder(fixture), now: now.addingTimeInterval(-29 * day), guard: Self.copyGuard)
        var autos: [RekordboxPointSnapshot.Entry] = []
        for offset in [-20.0, -10, -5] {
            try change(fixture, at: now.addingTimeInterval(offset * day - 60))
            guard case let .took(entry) = try auto(fixture, at: now.addingTimeInterval(offset * day), days: 90) else {
                Issue.record("자동 스냅샷을 뜨지 않았다"); return
            }
            autos.append(entry)
        }
        try RekordboxPointSnapshot.setPinned(true, autos[0].url, in: folder(fixture))

        // 바뀐 것이 없어 건너뛰어도 정리는 한다
        #expect(try auto(fixture, at: now, days: 7) == .skipped(.unchanged))
        let kept = Set(RekordboxPointSnapshot.list(in: folder(fixture)).map(\.id))
        #expect(kept == [manual.id, restore.id, autos[0].id, autos[2].id])
    }

    @Test func 시험_프로세스는_실제_rekordbox_라이브러리에서_뜨지_않는다() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-auto-point-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = LibrarySnapshot.realRekordboxDirectory.appending(path: "master.db")
        #expect(throws: DJCError.self) {
            try RekordboxPointSnapshot.takeAutoIfDue(database: real, shareRoot: nil, in: folder, autoDays: 7, now: now, calendar: utc,
                                                     canClone: { _, _ in true }, guard: Self.copyGuard)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
