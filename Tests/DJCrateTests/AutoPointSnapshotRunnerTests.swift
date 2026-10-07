import DJCDomain
import DJCTestSupport
import Foundation
@testable import DJCrate
import RekordboxKit
import Testing

/// 앱이 뒤에서 남기는 자동 시점 스냅샷(#228). 합성 사본과 그 옆 폴더에만 뜨고, 시각·켜짐·쓰는 중은 주입한다.
@MainActor
@Suite("자동 시점 스냅샷 실행")
struct AutoPointSnapshotRunnerTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    static let copyGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })

    /// 쓰는 중 여부와 받은 알림
    final class Probe {
        var busy = false
        var toasts: [String] = []
        /// rekordbox 쓰기를 시작한 횟수. `writesDuringSnapshot`이면 물을 때마다 늘어 뜨는 동안 쓰기가 끼어든 것처럼 보인다
        var writes = 0
        var writesDuringSnapshot = false
        func writeCount() -> Int {
            if writesDuringSnapshot { writes += 1 }
            return writes
        }
    }

    func runner(_ fixture: RekordboxFixture, enabled: Bool = true, probe: Probe = Probe()) -> AutoPointSnapshotRunner {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = now
        return AutoPointSnapshotRunner(environment: .init(
            database: { fixture.database }, shareRoot: { nil }, snapshots: fixture.root.appending(path: "point-snapshots"),
            enabled: { enabled }, autoDays: { 7 }, busy: { probe.busy }, writeCount: { probe.writeCount() }, guardian: Self.copyGuard, now: { now },
            calendar: calendar, canClone: { _, _ in true }),
            onFailure: { toast in probe.toasts.append(toast.title) })
    }

    func snapshots(_ fixture: RekordboxFixture) -> [RekordboxPointSnapshot.Entry] {
        RekordboxPointSnapshot.list(in: fixture.root.appending(path: "point-snapshots"))
    }

    @Test func 켜져_있으면_뒤에서_뜨고_같은_날_다시_불러도_하나뿐이다() async throws {
        let fixture = try RekordboxFixture()
        let runner = runner(fixture)
        guard case .took = await runner.runIfDue() else { Issue.record("뜨지 않았다"); return }
        #expect(await runner.runIfDue() == .skipped(.alreadyToday))
        #expect(snapshots(fixture).map(\.metadata.kind) == [.auto])
    }

    @Test func 설정에서_끄면_뜨지_않는다() async throws {
        let fixture = try RekordboxFixture()
        #expect(await runner(fixture, enabled: false).runIfDue() == nil)
        #expect(snapshots(fixture).isEmpty)
    }

    @Test func rekordbox에_쓰는_중이면_미루고_끝나면_뜬다() async throws {
        let fixture = try RekordboxFixture()
        let probe = Probe()
        probe.busy = true
        let runner = runner(fixture, probe: probe)
        #expect(await runner.runIfDue() == nil)
        #expect(snapshots(fixture).isEmpty)
        probe.busy = false
        guard case .took = await runner.runIfDue() else { Issue.record("쓰기가 끝난 뒤에도 뜨지 않았다"); return }
    }

    @Test func 뜨는_동안_DJCrate가_rekordbox에_쓰기_시작하면_그_스냅샷을_버리고_알리지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let probe = Probe()
        probe.writesDuringSnapshot = true
        #expect(await runner(fixture, probe: probe).runIfDue() == nil)
        #expect(snapshots(fixture).isEmpty)
        #expect(probe.toasts.isEmpty)
    }

    @Test func 실패는_확인_창_없이_한_번만_작은_알림으로_알린다() async throws {
        let fixture = try RekordboxFixture()
        // 분석 폴더 안의 심볼릭 링크는 스냅샷이 거부한다(다시 해도 같은 실패)
        let folder = fixture.shareRoot.appending(path: "PIONEER/USBANLZ/abc")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link"), withDestinationURL: URL(filePath: "/etc/hosts"))
        let probe = Probe()
        let runner = runner(fixture, probe: probe)
        #expect(await runner.runIfDue() == nil)
        #expect(await runner.runIfDue() == nil)
        #expect(probe.toasts == ["자동 시점 스냅샷을 남기지 못했습니다"])
        #expect(snapshots(fixture).isEmpty)
    }

    @Test func 자동_스냅샷은_기본으로_켜져_있다() {
        #expect(SettingKeys.pointSnapshotAuto.defaultValue)
        #expect(SettingKeys.all.contains(SettingKeys.pointSnapshotAuto.name))
    }
}
