@testable import DJCrate
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Synchronization
import Testing

@MainActor
@Suite("iTunes 선택창 소스 캐시", .serialized)
struct ITunesSyncSourceCacheTests {
    private func store(_ fixture: RekordboxFixture) -> LibraryStore {
        LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.itunes-sync-source.\(UUID())")!, persist: false),
                     resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                     backupDirectory: fixture.backups, playlistDraftSaver: { _ in },
                     mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
    }

    private var syncA: Data {
        Data("""
            <SYNC_ITUNES_PLAYLIST Version="3.0.0"><PLAYLISTS>
            <NODE Id="0" ParentId="0" Attribute="1" Timestamp="0" Lib_Type="1" CheckType="2"/>
            <NODE Id="A" ParentId="0" Attribute="0" Timestamp="100" Lib_Type="1" CheckType="1"/>
            </PLAYLISTS></SYNC_ITUNES_PLAYLIST>
            """.utf8)
    }

    @Test func 현재_전체_카탈로그는_선택창에서_다시_캡처하지_않는다() async throws {
        let fixture = try RekordboxFixture()
        try syncA.write(to: fixture.root.appending(path: "playlists3.sync"))
        let cached = try ITunesLibrarySnapshot(sourcePlaylists: [
            .init(id: "A", name: "선택됨"), .init(id: "B", name: "아직 선택 안 됨")
        ]).applyingRekordboxSelection(syncA)
        try cached.save(for: fixture.database)
        let store = store(fixture)
        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        let calls = Mutex(0)
        let source = await store.iTunesSyncSource(arguments: ["test"], environment: [:], captureITunes: {
            calls.withLock { $0 += 1 }
            return .init(status: .unavailable)
        })
        #expect(calls.withLock { $0 } == 0)
        #expect(source.status == .ready)
        #expect(source.sourcePlaylists?.map(\.id) == ["A", "B"])
        #expect(source.selectedIDs == ["A"])
    }

    @Test func 명시적_새로고침과_동기화_원본_변경은_새_캡처를_시작한다() async throws {
        let fixture = try RekordboxFixture()
        try syncA.write(to: fixture.root.appending(path: "playlists3.sync"))
        let cached = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "이전")])
            .applyingRekordboxSelection(syncA)
        try cached.save(for: fixture.database)
        let store = store(fixture)
        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        let calls = Mutex(0)
        let newer = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "새 내용")])
        let refreshed = await store.iTunesSyncSource(forceRefresh: true, arguments: ["test"], environment: [:], captureITunes: {
            calls.withLock { $0 += 1 }
            return newer
        })
        #expect(refreshed.playlists == newer.playlists)
        #expect(calls.withLock { $0 } == 1)

        try (syncA + Data("\n".utf8)).write(to: fixture.root.appending(path: "playlists3.sync"))
        let changed = await store.iTunesSyncSource(arguments: ["test"], environment: [:], captureITunes: {
            calls.withLock { $0 += 1 }
            return newer
        })
        #expect(changed.playlists == newer.playlists)
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func 명시한_DB는_강제_새로고침에서도_Music을_조회하지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let cached = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "사본 목록")])
        try cached.save(for: fixture.database)
        let store = store(fixture)
        let arguments = ["test", "--db", fixture.database.path]
        await store.load(snapshot: fixture.database, arguments: arguments, environment: [:])
        let calls = Mutex(0)
        let source = await store.iTunesSyncSource(forceRefresh: true, arguments: arguments, environment: [:], captureITunes: {
            calls.withLock { $0 += 1 }
            return .init(status: .unavailable)
        })
        #expect(calls.withLock { $0 } == 0)
        #expect(source.playlists == cached.playlists)
    }

    @Test func 겹친_선택창은_진행중인_캡처_하나를_공유한다() async throws {
        let fixture = try RekordboxFixture()
        let store = store(fixture)
        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        let calls = Mutex(0)
        let started = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let captured = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "새 목록")])
        let first = Task {
            await store.iTunesSyncSource(arguments: ["test"], environment: [:], captureITunes: {
                calls.withLock { $0 += 1 }
                started.withLock { $0 = true }
                resume.wait()
                return captured
            })
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while !started.withLock({ $0 }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard started.withLock({ $0 }) else {
            resume.signal(); _ = await first.value
            Issue.record("첫 캡처가 시작되지 않았습니다")
            return
        }
        let second = Task {
            await store.iTunesSyncSource(arguments: ["test"], environment: [:], captureITunes: {
                calls.withLock { $0 += 1 }
                return .init(status: .unavailable)
            })
        }
        for _ in 0..<100 { await Task.yield() }
        resume.signal()
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(calls.withLock { $0 } == 1)
        #expect(firstResult == captured)
        #expect(secondResult == captured)
    }

    @Test func 강제_캡처가_진행중이어도_유효한_캐시는_즉시_연다() async throws {
        let fixture = try RekordboxFixture()
        try syncA.write(to: fixture.root.appending(path: "playlists3.sync"))
        let cached = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "기존 목록")])
            .applyingRekordboxSelection(syncA)
        try cached.save(for: fixture.database)
        let store = store(fixture)
        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        let started = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let refresh = Task {
            await store.iTunesSyncSource(forceRefresh: true, arguments: ["test"], environment: [:], captureITunes: {
                started.withLock { $0 = true }
                resume.wait()
                return cached
            })
        }
        let startDeadline = ContinuousClock.now + .seconds(15)
        while !started.withLock({ $0 }) && ContinuousClock.now < startDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard started.withLock({ $0 }) else {
            resume.signal(); _ = await refresh.value
            Issue.record("강제 캡처가 시작되지 않았습니다")
            return
        }
        let completed = Mutex(false)
        let reopen = Task {
            let value = await store.iTunesSyncSource(arguments: ["test"], environment: [:], captureITunes: {
                Issue.record("유효한 캐시 대신 Music을 읽었습니다")
                return .init(status: .unavailable)
            })
            completed.withLock { $0 = true }
            return value
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while !completed.withLock({ $0 }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let returnedBeforeRefresh = completed.withLock { $0 }
        resume.signal()
        _ = await refresh.value
        let value = await reopen.value
        #expect(returnedBeforeRefresh)
        #expect(value == cached)
    }

    @Test func 더_최근_store_카탈로그가_선택창_임시캐시보다_우선한다() async throws {
        let fixture = try RekordboxFixture()
        try syncA.write(to: fixture.root.appending(path: "playlists3.sync"))
        let store = store(fixture)
        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        let old = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "옛 목록")])
            .applyingRekordboxSelection(syncA)
        _ = await store.iTunesSyncSource(arguments: ["test"], environment: [:], captureITunes: { old })
        let newer = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "새 목록")])
            .applyingRekordboxSelection(syncA)
        store.iTunesSnapshot = newer
        let result = await store.iTunesSyncSource(arguments: ["test"], environment: [:], captureITunes: {
            Issue.record("새 store 카탈로그 대신 Music을 읽었습니다")
            return .init(status: .unavailable)
        })
        #expect(result.sourcePlaylists?.first?.name == "새 목록")
    }

    @Test func 오래_걸린_캡처는_그사이_도착한_store_카탈로그를_덮지_않는다() async throws {
        let fixture = try RekordboxFixture()
        try syncA.write(to: fixture.root.appending(path: "playlists3.sync"))
        let store = store(fixture)
        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        let old = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "옛 목록")])
            .applyingRekordboxSelection(syncA)
        let newer = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "최신 목록")])
            .applyingRekordboxSelection(syncA)
        let started = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let loading = Task {
            await store.iTunesSyncSource(arguments: ["test"], environment: [:], captureITunes: {
                started.withLock { $0 = true }
                resume.wait()
                return old
            })
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while !started.withLock({ $0 }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard started.withLock({ $0 }) else {
            resume.signal(); _ = await loading.value
            Issue.record("Music 캡처가 시작되지 않았습니다")
            return
        }
        store.iTunesSnapshot = newer
        resume.signal()
        let lateResult = await loading.value
        #expect(lateResult.sourcePlaylists?.first?.name == "최신 목록")
        let reopened = await store.iTunesSyncSource(arguments: ["test"], environment: [:], captureITunes: {
            Issue.record("최신 Store 캐시 대신 Music을 읽었습니다")
            return .init(status: .unavailable)
        })
        #expect(reopened.sourcePlaylists?.first?.name == "최신 목록")
    }

    @Test func 편집한_체크박스는_새로고침에_남고_편집하지_않은_선택은_원본을_따른다() async throws {
        let fixture = try RekordboxFixture()
        let sync = fixture.root.appending(path: "playlists3.sync")
        try syncA.write(to: sync)
        let catalog: [ITunesLibrarySnapshot.Playlist] = [
            .init(id: "A", name: "첫 목록"), .init(id: "B", name: "둘째 목록")
        ]
        let old = try ITunesLibrarySnapshot(sourcePlaylists: catalog).applyingRekordboxSelection(syncA)
        try old.save(for: fixture.database)
        let store = store(fixture)
        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        store.presentITunesSync()
        let model = store.iTunesSync
        await model.load(store: store, arguments: ["test"], environment: [:], captureITunes: {
            Issue.record("정상 캐시에서 Music을 다시 읽었습니다")
            return .init(status: .unavailable)
        })
        #expect(model.selection.selectedIDs == ["A"])
        model.selection = .init(selectedIDs: ["B"])
        let fresh = try ITunesLibrarySnapshot(sourcePlaylists: catalog + [.init(id: "C", name: "새 목록")])
            .applyingRekordboxSelection(syncA)
        await model.load(store: store, forceRefresh: true, arguments: ["test"], environment: [:],
                         captureITunes: { fresh })
        #expect(model.selection.selectedIDs == ["B"])
        #expect(model.source.sourcePlaylists?.map(\.id) == ["A", "B", "C"])

        store.presentITunesSync()
        let untouched = store.iTunesSync
        await untouched.load(store: store, arguments: ["test"], environment: [:], captureITunes: { fresh })
        #expect(untouched.selection.selectedIDs == ["A"])
        let syncB = Data(String(decoding: syncA, as: UTF8.self).replacingOccurrences(of: "Id=\"A\"", with: "Id=\"B\"").utf8)
        try syncB.write(to: sync)
        let externallyChanged = try ITunesLibrarySnapshot(sourcePlaylists: catalog).applyingRekordboxSelection(syncB)
        await untouched.load(store: store, forceRefresh: true, arguments: ["test"], environment: [:],
                             captureITunes: { externallyChanged })
        #expect(untouched.selection.selectedIDs == ["B"])
    }

    @Test func 새로고침_실패는_체크박스를_보존하고_다음_성공에서_되살린다() async throws {
        let fixture = try RekordboxFixture()
        try syncA.write(to: fixture.root.appending(path: "playlists3.sync"))
        let catalog: [ITunesLibrarySnapshot.Playlist] = [
            .init(id: "A", name: "첫 목록"), .init(id: "B", name: "둘째 목록")
        ]
        let cached = try ITunesLibrarySnapshot(sourcePlaylists: catalog).applyingRekordboxSelection(syncA)
        try cached.save(for: fixture.database)
        let store = store(fixture)
        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        store.presentITunesSync()
        let model = store.iTunesSync
        await model.load(store: store, arguments: ["test"], environment: [:], captureITunes: {
            Issue.record("기존 카탈로그를 다시 읽었습니다")
            return .init(status: .unavailable)
        })
        model.selection = .init(selectedIDs: ["B"])
        await model.load(store: store, forceRefresh: true, arguments: ["test"], environment: [:],
                         captureITunes: { .init(status: .unavailable) })
        #expect(model.source.status == .stale)
        #expect(model.source.sourcePlaylists?.map(\.id) == ["A", "B"])
        #expect(model.selection.selectedIDs == ["B"])
        #expect(!model.canSync)
        let recovered = try ITunesLibrarySnapshot(sourcePlaylists: catalog + [.init(id: "C", name: "셋째 목록")])
            .applyingRekordboxSelection(syncA)
        await model.load(store: store, forceRefresh: true, arguments: ["test"], environment: [:],
                         captureITunes: { recovered })
        #expect(model.source.status == .ready)
        #expect(model.selection.selectedIDs == ["B"])
    }

    @Test func 열린_선택창의_DB가_바뀌면_늦은_결과를_버리고_로딩을_끝낸다() async throws {
        let fixture = try RekordboxFixture()
        let store = store(fixture)
        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        store.presentITunesSync()
        let model = store.iTunesSync
        let started = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let loading = Task {
            await model.load(store: store, arguments: ["test"], environment: [:], captureITunes: {
                started.withLock { $0 = true }
                resume.wait()
                return ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "늦은 목록")])
            })
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while !started.withLock({ $0 }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard started.withLock({ $0 }) else {
            resume.signal(); await loading.value
            Issue.record("Music 캡처가 시작되지 않았습니다")
            return
        }
        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        resume.signal()
        await loading.value
        #expect(!model.isLoading)
        #expect(model.database == nil)
        #expect(model.error != nil)
        #expect(model.source.status == .notCaptured)
    }

    @Test func 닫은_선택창의_늦은_캡처는_새_선택창을_바꾸지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let store = store(fixture)
        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        store.presentITunesSync()
        let old = store.iTunesSync
        let started = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let loading = Task {
            await old.load(store: store, arguments: ["test"], environment: [:], captureITunes: {
                started.withLock { $0 = true }
                resume.wait()
                return ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "늦은 목록")])
            })
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while !started.withLock({ $0 }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard started.withLock({ $0 }) else {
            resume.signal(); await loading.value
            Issue.record("Music 캡처가 시작되지 않았습니다")
            return
        }
        store.showingITunesSync = false
        store.presentITunesSync()
        let reopened = store.iTunesSync
        resume.signal()
        await loading.value
        #expect(old.source.status == .notCaptured)
        #expect(reopened.source.status == .notCaptured)
        #expect(reopened.selection.selectedIDs.isEmpty)
    }
}
