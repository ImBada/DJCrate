import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 하루 한 번 자동 시점 스냅샷(#228)을 앱이 돌아가는 동안 뒤에서 남긴다. 확인 창·알림 없이 조용히 하고,
/// 미룬 이유(rekordbox 켜짐·오늘 이미 있음·바뀐 것 없음 등)는 남기지 않는다. 실패는 로그로 남기고, 다시 해 볼 일이 아닌 실패만
/// 앱을 켠 동안 한 번 작은 토스트로 알린다. 뜨기는 메인 액터 밖에서 한다.
@MainActor
final class AutoPointSnapshotRunner {
    struct Environment {
        var database: () -> URL
        var shareRoot: () -> URL?
        var snapshots: URL
        var enabled: () -> Bool
        var autoDays: () -> Int
        /// rekordbox에 쓰는 중이면 미룬다(쓰기를 막지 않는다)
        var busy: () -> Bool
        /// rekordbox 쓰기를 시작한 횟수. 뜨는 동안 늘면 분석 파일과 DB가 다른 시점일 수 있어 그 스냅샷을 버린다
        var writeCount: () -> Int = { 0 }
        var guardian: RekordboxWriteGuard = .system
        var now: () -> Date = { .now }
        var calendar: Calendar = .current
        var canClone: @Sendable (URL, URL) -> Bool = { RekordboxPointSnapshot.canClone(from: $0, to: $1) }
    }

    /// 처음 볼 때까지(앱이 막 켜져 라이브러리를 읽는 동안은 비켜 준다)
    static let firstDelay: Duration = .seconds(90)
    /// 다시 볼 간격(rekordbox를 끈 뒤 오래 기다리지 않게 짧게, 보는 일은 폴더 목록·파일 정보뿐이다)
    static let interval: Duration = .seconds(600)

    let environment: Environment
    /// 실패 알림(앱은 토스트)
    var onFailure: (AppToast) -> Void
    private(set) var isRunning = false
    private var warned = false

    init(environment: Environment, onFailure: @escaping (AppToast) -> Void = { _ in }) {
        self.environment = environment
        self.onFailure = onFailure
    }

    /// 이 실행에서 자동 스냅샷을 볼지. 명시한 사본(`--db`·`DJC_DB`)으로 연 창은 사용자의 라이브러리를 고른 실행이 아니라서
    /// 사본 rekordbox 폴더(`DJC_REKORDBOX_DIR`)가 있어도 보지 않고, 자가 테스트·측정·캡처 실행(`DiagnosticRun`)은
    /// 90초 뒤 디스크 일이 끼지 않게 보지 않는다.
    static func isAllowed(arguments: [String], environment: [String: String]) -> Bool {
        !LibraryStore.explicitDatabaseRequested(arguments: arguments, environment: environment) && !DiagnosticRun.isActive(arguments: arguments)
    }

    /// 앱이 쓰는 것: 대상은 쓰기·복원과 같은 `LibraryStore.rekordboxDatabase`(#182). 볼지는 `isAllowed`가 가르고,
    /// 설정을 저장하지 않는 저장소(`settings.persist` 꺼짐)는 사용자가 끈 설정을 지킬 수 없어 뜨지 않는다.
    convenience init(store: LibraryStore, arguments: [String] = ProcessInfo.processInfo.arguments,
                     environment: [String: String] = ProcessInfo.processInfo.environment) {
        let settings = store.settings
        let allowed = Self.isAllowed(arguments: arguments, environment: environment)
        self.init(environment: Environment(
            database: { [weak store] in store?.rekordboxDatabase ?? RekordboxWriter.liveDatabase },
            shareRoot: { [weak store] in store?.rekordboxShareRoot },
            snapshots: DJCPaths.pointSnapshots,
            enabled: { allowed && settings.persist && settings.value(SettingKeys.pointSnapshotAuto) },
            autoDays: { Int(settings.value(SettingKeys.pointSnapshotAutoDays)) },
            busy: { [weak store] in store?.isWritingRekordbox ?? true },
            writeCount: { [weak store] in store?.rekordboxWriteCount ?? 0 }))
        onFailure = { [weak store] toast in store?.toast = toast }
    }

    /// 앱이 켜져 있는 동안 되풀이한다(취소되면 끝).
    func loop() async {
        do { try await Task.sleep(for: Self.firstDelay) } catch { return }
        while !Task.isCancelled {
            await runIfDue()
            do { try await Task.sleep(for: Self.interval) } catch { return }
        }
    }

    /// 때가 됐으면 한 번 뜬다. 끄거나 쓰는 중이면 nil.
    @discardableResult
    func runIfDue() async -> RekordboxPointSnapshot.AutoOutcome? {
        guard !isRunning, environment.enabled(), !environment.busy() else { return nil }
        isRunning = true
        defer { isRunning = false }
        let env = environment, database = env.database(), share = env.shareRoot(), days = env.autoDays(), now = env.now()
        let snapshots = env.snapshots, calendar = env.calendar, canClone = env.canClone, guardian = env.guardian
        let writesBefore = env.writeCount()
        let result = await Task.detached(priority: .utility) {
            Result {
                try RekordboxPointSnapshot.takeAutoIfDue(database: database, shareRoot: share, in: snapshots, autoDays: days, now: now,
                                                         calendar: calendar, canClone: canClone, guard: guardian)
            }
        }.value
        switch result {
        case let .success(outcome):
            // 뜨는 동안 DJCrate가 rekordbox에 쓰기 시작했으면 DB와 분석 파일이 어긋났을 수 있다(다음에 다시 뜬다)
            if case let .took(entry) = outcome, env.busy() || env.writeCount() != writesBefore {
                try? FileManager.default.removeItem(at: entry.url)
                FileHandle.standardError.write(Data("[자동 시점 스냅샷] 뜨는 동안 rekordbox 쓰기가 끼어들어 버렸습니다\n".utf8))
                return nil
            }
            return outcome
        case let .failure(error):
            FileHandle.standardError.write(Data("[자동 시점 스냅샷] \(error)\n".utf8))
            // 뜨는 도중 rekordbox가 켜지거나 쓰기가 끼어든 것은 다음에 다시 본다(알리지 않는다)
            if env.guardian.isRekordboxRunning() || env.busy() || warned { return nil }
            warned = true
            onFailure(.notice(String(ui: "자동 시점 스냅샷을 남기지 못했습니다"), AppErrorMessage.message(for: error)))
            return nil
        }
    }
}
