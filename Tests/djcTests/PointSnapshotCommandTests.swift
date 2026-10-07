import DJCDomain
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing
@testable import djc

/// `djc snapshot-point`(#224): 합성 사본(`--db`) 옆 `point-snapshots/`에만 만든다.
@Suite("djc snapshot-point")
struct PointSnapshotCommandTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    static let copyGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })

    func run(_ fixture: RekordboxFixture, _ args: String...) throws -> String {
        try PointSnapshotCommand.run(["snapshot-point"] + args + ["--db", fixture.database.path], now: now, guard: Self.copyGuard)
    }

    @Test func 만들고_목록에서_보고_고정·풀기·지우기를_한다() throws {
        let fixture = try RekordboxFixture()
        let created = try run(fixture, "create", "--name", "정리 전")
        #expect(created.contains("2026-09-25T120000Z-manual"), "\(created)")
        let folder = fixture.root.appending(path: "point-snapshots")
        #expect(RekordboxPointSnapshot.list(in: folder).first?.metadata.name == "정리 전")

        let list = try run(fixture, "list")
        #expect(list.contains("시점 스냅샷 1개") && list.contains("‘정리 전’") && list.contains("수동"), "\(list)")
        #expect(list.contains("쓰기 전 백업 0개"))

        #expect(try run(fixture, "pin", "정리 전").contains("고정했습니다"))
        #expect(try run(fixture, "list").contains("고정"))
        #expect(throws: DJCError.self) { try run(fixture, "delete", "2026-09-25T120000Z-manual") }
        #expect(try run(fixture, "unpin", "2026-09-25T120000Z-manual").contains("고정을 풀었습니다"))
        #expect(try run(fixture, "delete", "2026-09-25T120000Z-manual").contains("지웠습니다"))
        #expect(RekordboxPointSnapshot.list(in: folder).isEmpty)
    }

    @Test func 대상이나_ID가_없으면_사용법이나_이유를_알린다() throws {
        let fixture = try RekordboxFixture()
        #expect(throws: UsageError.self) { try PointSnapshotCommand.run(["snapshot-point", "create"], guard: Self.copyGuard) }
        #expect(throws: UsageError.self) { try PointSnapshotCommand.run(["snapshot-point"], guard: Self.copyGuard) }
        #expect(throws: UsageError.self) { try run(fixture, "pin") }
        #expect(throws: UsageError.self) { try run(fixture, "rename") }
        #expect(throws: UsageError.self) {
            try PointSnapshotCommand.run(["snapshot-point", "list", "--live", "--db", fixture.database.path], guard: Self.copyGuard)
        }
        #expect(throws: DJCError.self) { try run(fixture, "pin", "없는-스냅샷") }
    }

    @Test func 명령_목록에_있고_읽기_사본_snapshot과_이름이_다르다() {
        let names = MainCommands.all.map(\.name)
        #expect(names.contains("snapshot-point") && names.contains("snapshot"))
    }
}
