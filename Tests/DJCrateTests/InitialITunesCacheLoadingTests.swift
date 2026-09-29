@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Synchronization
import Testing

/// 멈춰 둔 Music 조회(#130 환경의 수 분짜리 조회). 조회 횟수를 세고, 풀어 줄 때까지 기다린다.
private final class StalledMusic: Sendable {
    let calls = Mutex(0)
    let result: ITunesLibrarySnapshot
    private let gate = DispatchSemaphore(value: 0)

    init(_ result: ITunesLibrarySnapshot) { self.result = result }
    var started: Bool { calls.withLock { $0 > 0 } }
    func capture() -> ITunesLibrarySnapshot {
        calls.withLock { $0 += 1 }
        gate.wait()
        return result
    }
    /// 잘못 다시 조회해도 시험이 멈추지 않게 넉넉히 푼다.
    func release() { for _ in 0..<4 { gate.signal() } }
}

@MainActor
@Suite("초기 iTunes 캐시 로드", .serialized)
struct InitialITunesCacheLoadingTests {
    private var sync: Data {
        Data("""
            <SYNC_ITUNES_PLAYLIST Version="3.0.0"><PLAYLISTS>
            <NODE Id="0" ParentId="0" Attribute="1" Timestamp="0" Lib_Type="1" CheckType="2"/>
            <NODE Id="A" ParentId="0" Attribute="0" Timestamp="100" Lib_Type="1" CheckType="1"/>
            </PLAYLISTS></SYNC_ITUNES_PLAYLIST>
            """.utf8)
    }

    private func store(_ fixture: RekordboxFixture) -> LibraryStore {
        LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.initial-itunes-cache.\(UUID())")!, persist: false),
                     resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                     backupDirectory: fixture.backups, playlistDraftSaver: { _ in },
                     mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
    }

    private func snapshot(_ fixture: RekordboxFixture, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try sync.write(to: directory.appending(path: "playlists3.sync"))
        return try LibrarySnapshot.take(from: fixture.database, into: directory, force: true,
                                        now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func 정상_전체캐시는_Music을_기다리지_않고_DB와_선택창을_연다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        let directory = fixture.root.appending(path: "snapshots")
        let database = try snapshot(fixture, directory: directory)
        let cached = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "캐시 목록")])
            .applyingRekordboxSelection(sync)
        try cached.save(for: database)
        let newer = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "새 목록")])
            .applyingRekordboxSelection(sync)
        let store = store(fixture)
        let started = Mutex(false)
        let completed = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let loading = Task {
            await store.loadInitial(snapshotDirectory: directory, arguments: ["test"], environment: [:], captureITunes: {
                started.withLock { $0 = true }
                resume.wait()
                return newer
            })
            completed.withLock { $0 = true }
        }
        // Music 최신화가 시작될 때까지 기다린다. 시간 제한은 없다(부하가 걸리면 오래 걸릴 뿐 판정은 같다).
        // 시작하지 않는 구현이면 loadInitial이 돌아온 뒤에 남은 최신화 작업이 없으므로 그때 끝낸다.
        while !started.withLock({ $0 }) && !(completed.withLock({ $0 }) && store.iTunesRefresh == nil) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard started.withLock({ $0 }) else {
            resume.signal(); await loading.value
            await store.iTunesRefresh?.task.value
            Issue.record("Music 최신화가 시작되지 않았습니다")
            return
        }
        // Music 조회는 막혀 있다. 이 시점에 DB와 행이 이미 열려 있어야 Music을 기다리지 않은 것이다(상태로 본다).
        let loadedBeforeMusic = !store.isLoading && store.rows.map(\.id) == ["1"]
        // loadInitial도 막힌 Music을 기다리지 않고 돌아와야 한다. Music이 막혀 있는 채로 돌아온 것만 센다(풀기 전에 확인).
        while loadedBeforeMusic && !completed.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let returnedBeforeMusic = completed.withLock { $0 }
        // 이미 Music을 기다린 것으로 드러났다면, 아래 선택창 확인이 막힌 Music에 걸려 멈추지 않게 먼저 풀어 준다(실패로 끝낸다).
        if !(loadedBeforeMusic && returnedBeforeMusic) { resume.signal() }
        let available = await store.iTunesSyncSource(arguments: ["test"], environment: [:], captureITunes: {
            Issue.record("선택창이 정상 캐시 대신 Music을 다시 읽었습니다")
            return .init(status: .unavailable)
        })
        resume.signal()
        await loading.value
        await store.iTunesRefresh?.task.value
        #expect(returnedBeforeMusic)
        #expect(loadedBeforeMusic)
        #expect(available.sourcePlaylists?.first?.name == "캐시 목록")
    }

    @Test func 늦은_초기_Music은_그뒤_시작한_DB_로드를_덮지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let directory = fixture.root.appending(path: "snapshots")
        let database = try snapshot(fixture, directory: directory)
        let cached = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "보존 목록")])
            .applyingRekordboxSelection(sync)
        try cached.save(for: database)
        let store = store(fixture)
        let started = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let completed = Mutex(false)
        let loading = Task {
            await store.loadInitial(snapshotDirectory: directory, arguments: ["test"], environment: [:], captureITunes: {
                started.withLock { $0 = true }
                resume.wait()
                return ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "늦은 목록")])
            })
            completed.withLock { $0 = true }
        }
        let deadline = ContinuousClock.now + .seconds(90)
        while !started.withLock({ $0 }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard started.withLock({ $0 }) else {
            resume.signal()
            await loading.value
            await store.iTunesRefresh?.task.value
            Issue.record("Music 최신화가 시작되지 않았습니다")
            return
        }
        let completedDeadline = ContinuousClock.now + .seconds(30)
        while !completed.withLock({ $0 }) && ContinuousClock.now < completedDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard completed.withLock({ $0 }) else {
            resume.signal()
            await loading.value
            await store.iTunesRefresh?.task.value
            Issue.record("Music 최신화를 기다리느라 초기 로드가 끝나지 않았습니다")
            return
        }
        await store.load(snapshot: database, arguments: ["test"], environment: [:])
        resume.signal()
        await loading.value
        await store.iTunesRefresh?.task.value
        #expect(store.iTunesSnapshot.sourcePlaylists?.first?.name == "보존 목록")
    }

    /// 캐시로 연 뒤 뒤에서 도는 Music 최신화를 멈춰 둔다.
    private func openWithStalledMusic(_ store: LibraryStore, directory: URL, music: StalledMusic) async -> Bool {
        let opened = Mutex(false)
        let loading = Task {
            await store.loadInitial(snapshotDirectory: directory, arguments: ["test"], environment: [:],
                                    captureITunes: { music.capture() })
            opened.withLock { $0 = true }
        }
        let deadline = ContinuousClock.now + .seconds(90)
        while !(music.started && opened.withLock { $0 }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard music.started, opened.withLock({ $0 }) else {
            music.release()
            await loading.value
            await store.iTunesRefresh?.task.value
            Issue.record("캐시로 열고 Music 최신화를 시작하지 못했습니다")
            return false
        }
        return true
    }

    @Test func 쓰기_뒤_다시_읽기가_버린_Music_최신화를_새_사본에서_이어받는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        let directory = fixture.root.appending(path: "snapshots")
        let database = try snapshot(fixture, directory: directory)
        try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "캐시 목록")])
            .applyingRekordboxSelection(sync).save(for: database)
        let music = StalledMusic(try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "최신 목록")])
            .applyingRekordboxSelection(sync))
        let store = store(fixture)
        guard await openWithStalledMusic(store, directory: directory, music: music) else { return }

        // 쓰기 뒤 다시 읽기는 Music을 기다리지 않고 캐시로 새 사본을 연다.
        try fixture.add(TrackSpec(id: "2"))
        let sourceDB = fixture.database
        let reloaded = Mutex(false)
        let reload = Task {
            await store.takeSnapshot(force: true, quiet: true, refreshITunes: false, snapshotDirectory: directory,
                                     snapshotCopy: { force in
                                         try LibrarySnapshot.take(from: sourceDB, into: directory, force: force,
                                                                  now: Date(timeIntervalSince1970: 1_800_000_060))
                                     }, captureITunes: { music.capture() }, arguments: ["test"], environment: [:])
            reloaded.withLock { $0 = true }
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while !reloaded.withLock({ $0 }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let reloadedBeforeMusic = reloaded.withLock { $0 } && store.rows.count == 2
        let cachedName = store.iTunesSnapshot.sourcePlaylists?.first?.name
        music.release()
        await reload.value
        // 멈춤이 풀리면 버려진 최신화의 결과가 새 사본에 들어와야 한다(지난 세션 목록이 남지 않게).
        let appliedDeadline = ContinuousClock.now + .seconds(10)
        while store.iTunesSnapshot.sourcePlaylists?.first?.name != "최신 목록" && ContinuousClock.now < appliedDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await store.iTunesRefresh?.task.value
        #expect(reloadedBeforeMusic)
        #expect(cachedName == "캐시 목록")
        #expect(store.iTunesSnapshot.sourcePlaylists?.first?.name == "최신 목록")
        let reloadedDatabase = try #require(store.snapshotURL)
        #expect(reloadedDatabase != database)
        #expect(ITunesLibrarySnapshot.load(for: reloadedDatabase).sourcePlaylists?.first?.name == "최신 목록")
        #expect(music.calls.withLock { $0 } == 1)
    }

    @Test func Music_최신화_중에는_동기화_쓰기를_막고_끝나면_최신_목록으로_연다() async throws {
        let fixture = try RekordboxFixture()
        let directory = fixture.root.appending(path: "snapshots")
        let database = try snapshot(fixture, directory: directory)
        try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "캐시 목록")])
            .applyingRekordboxSelection(sync).save(for: database)
        let music = StalledMusic(try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "최신 목록")])
            .applyingRekordboxSelection(sync))
        let store = store(fixture)
        guard await openWithStalledMusic(store, directory: directory, music: music) else { return }

        store.presentITunesSync()
        let model = store.iTunesSync
        let opening = Task {
            await model.load(store: store, arguments: ["test"], environment: [:], captureITunes: {
                Issue.record("선택창이 진행 중인 최신화 대신 Music을 다시 읽었습니다")
                return .init(status: .unavailable)
            })
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isLoading && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let shownName = model.source.sourcePlaylists?.first?.name
        let blockedWhileRefreshing = !model.canSync
        // 창을 거치지 않은 쓰기도 막는다. 막지 못하면 명시한 임시 사본에만 쓴다.
        var refused: String?
        let opened = try #require(store.snapshotURL)
        do {
            try await store.syncITunesPlaylists(model.selection, source: model.source, database: opened,
                                                arguments: ["test", "--db", opened.path], environment: [:])
        } catch DJCError.writeRefused(let reason) {
            refused = reason
        } catch {
            refused = "\(error)"
        }
        music.release()
        await store.iTunesRefresh?.task.value
        let refreshedDeadline = ContinuousClock.now + .seconds(10)
        while !(model.source.sourcePlaylists?.first?.name == "최신 목록" && model.canSync)
                && ContinuousClock.now < refreshedDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(shownName == "캐시 목록")
        #expect(blockedWhileRefreshing)
        #expect(refused == String(ui: "Music 보관함을 새로 읽는 중이니 목록이 최신으로 바뀐 뒤 동기화하세요."))
        #expect(model.source.sourcePlaylists?.first?.name == "최신 목록")
        #expect(model.canSync)
        store.showingITunesSync = false
        await opening.value
    }

    @Test func 초기_Music_최신화와_선택창_강제_새로고침은_캡처_하나를_공유한다() async throws {
        let fixture = try RekordboxFixture()
        let directory = fixture.root.appending(path: "snapshots")
        let database = try snapshot(fixture, directory: directory)
        let cached = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "이전 목록")])
            .applyingRekordboxSelection(sync)
        try cached.save(for: database)
        let fresh = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "최신 목록")])
            .applyingRekordboxSelection(sync)
        let store = store(fixture)
        let calls = Mutex(0)
        let started = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let initial = Task {
            await store.loadInitial(snapshotDirectory: directory, arguments: ["test"], environment: [:], captureITunes: {
                calls.withLock { $0 += 1 }
                started.withLock { $0 = true }
                resume.wait()
                return fresh
            })
        }
        let deadline = ContinuousClock.now + .seconds(90)
        while !started.withLock({ $0 }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard started.withLock({ $0 }) else {
            resume.signal(); await initial.value
            await store.iTunesRefresh?.task.value
            Issue.record("초기 Music 최신화가 시작되지 않았습니다")
            return
        }
        let forced = Task {
            await store.iTunesSyncSource(forceRefresh: true, arguments: ["test"], environment: [:], captureITunes: {
                calls.withLock { $0 += 1 }
                return ITunesLibrarySnapshot(status: .unavailable)
            })
        }
        for _ in 0..<100 { await Task.yield() }
        resume.signal()
        await initial.value
        await store.iTunesRefresh?.task.value
        let result = await forced.value
        #expect(calls.withLock { $0 } == 1)
        #expect(result.sourcePlaylists?.first?.name == "최신 목록")
    }

    @Test func 전체캐시가_없으면_기존_Music_로딩을_유지한다() async throws {
        let fixture = try RekordboxFixture()
        let directory = fixture.root.appending(path: "snapshots")
        _ = try snapshot(fixture, directory: directory)
        let store = store(fixture)
        let started = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let loading = Task {
            await store.loadInitial(snapshotDirectory: directory, arguments: ["test"], environment: [:], captureITunes: {
                started.withLock { $0 = true }
                resume.wait()
                return ITunesLibrarySnapshot()
            })
        }
        let deadline = ContinuousClock.now + .seconds(90)
        while !started.withLock({ $0 }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let remainedLoading = store.isLoading && store.rows.isEmpty
        resume.signal()
        await loading.value
        #expect(started.withLock { $0 })
        #expect(remainedLoading)
    }

    @Test func 명시_DB와_사본_모드에서는_Music을_조회하지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let directory = fixture.root.appending(path: "djc-snapshots")
        _ = try snapshot(fixture, directory: directory)
        let explicit = store(fixture)
        await explicit.loadInitial(snapshotDirectory: directory, arguments: ["test", "--db", fixture.database.path],
                                   environment: [:], captureITunes: {
            Issue.record("명시 DB에서 Music을 읽었습니다")
            return .init(status: .unavailable)
        })
        #expect(explicit.snapshotURL == fixture.database)
        let copy = store(fixture)
        await copy.loadInitial(snapshotDirectory: directory, arguments: ["test"],
                               environment: ["DJC_REKORDBOX_DIR": fixture.root.path], captureITunes: {
            Issue.record("사본 모드에서 Music을 읽었습니다")
            return .init(status: .unavailable)
        })
        #expect(copy.snapshotURL.map { LibrarySnapshot.sameDirectory($0.deletingLastPathComponent(), directory) } == true)
    }
}
