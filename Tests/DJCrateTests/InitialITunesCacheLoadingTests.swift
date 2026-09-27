@testable import DJCrate
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Synchronization
import Testing

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
        let deadline = ContinuousClock.now + .seconds(90)
        while !started.withLock({ $0 }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard started.withLock({ $0 }) else {
            resume.signal(); await loading.value
            await store.initialITunesRefreshTask?.value
            Issue.record("Music 최신화가 시작되지 않았습니다")
            return
        }
        let completedDeadline = ContinuousClock.now + .seconds(30)
        while !completed.withLock({ $0 }) && ContinuousClock.now < completedDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let returnedBeforeMusic = completed.withLock { $0 }
        let loadedBeforeMusic = !store.isLoading && store.rows.map(\.id) == ["1"]
        let available = await store.iTunesSyncSource(arguments: ["test"], environment: [:], captureITunes: {
            Issue.record("선택창이 정상 캐시 대신 Music을 다시 읽었습니다")
            return .init(status: .unavailable)
        })
        resume.signal()
        await loading.value
        await store.initialITunesRefreshTask?.value
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
            await store.initialITunesRefreshTask?.value
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
            await store.initialITunesRefreshTask?.value
            Issue.record("Music 최신화를 기다리느라 초기 로드가 끝나지 않았습니다")
            return
        }
        await store.load(snapshot: database, arguments: ["test"], environment: [:])
        resume.signal()
        await loading.value
        await store.initialITunesRefreshTask?.value
        #expect(store.iTunesSnapshot.sourcePlaylists?.first?.name == "보존 목록")
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
            await store.initialITunesRefreshTask?.value
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
        await store.initialITunesRefreshTask?.value
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
