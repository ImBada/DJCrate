@testable import DJCrate
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Synchronization
import Testing

private actor WriteReloadQueueGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@MainActor
@Suite("쓰기 뒤 스냅샷 대기열", .serialized)
struct WriteReloadQueueRegressionTests {
    @Test func Music_결과만_적용할_때_검색으로_숨긴_곡_선택을_보존한다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        let directory = fixture.root.appending(path: "snapshots")
        let sourceDB = fixture.database
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = try LibrarySnapshot.take(from: sourceDB, into: directory, force: true, now: stamp)
        let store = LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.music-selection.\(UUID())")!, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                                 backupDirectory: fixture.backups, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
        await store.load(snapshot: previous, arguments: ["test"], environment: [:])
        store.selection = ["1"]
        store.search = "존재하지 않는 검색어"
        #expect(store.displayRows.isEmpty)
        await store.takeSnapshot(force: true, snapshotDirectory: directory, snapshotCopy: { force in
            try LibrarySnapshot.take(from: sourceDB, into: directory, force: force, now: stamp.addingTimeInterval(60))
        }, captureITunes: { ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "합성 목록")]) },
                                 arguments: ["test"], environment: [:])
        #expect(store.selection == ["1"])
    }

    @Test func 병합한_요청도_Music을_기다리고_다른_정책은_따로_실행한다() async {
        let queue = SnapshotRequestQueue()
        let copyGate = WriteReloadQueueGate()
        let musicGate = WriteReloadQueueGate()
        var operations: [String] = []
        var returned: [String] = []
        let first = Task {
            await queue.run(force: true, quiet: true) { _, _ in
                await copyGate.pause()
                operations.append("첫 복사")
            }
        }
        await copyGate.waitUntilStarted()
        let second = Task {
            await queue.runWithFollowUp(force: false, quiet: true, refreshITunes: true) { _, _ in
                operations.append("병합 전 Music")
                return Task { await musicGate.pause() }
            }
            returned.append("두 번째")
        }
        for _ in 0..<1_000 where queue.waitingCount < 1 { await Task.yield() }
        let third = Task {
            await queue.runWithFollowUp(force: true, quiet: false, refreshITunes: true) { force, quiet in
                #expect(force && !quiet)
                operations.append("병합된 Music")
                return Task { await musicGate.pause() }
            }
            returned.append("세 번째")
        }
        for _ in 0..<1_000 where queue.waitingCount < 2 { await Task.yield() }
        let fourth = Task {
            await queue.runWithFollowUp(force: true, quiet: true, refreshITunes: false) { _, _ in
                operations.append("쓰기 뒤 복사")
                return nil
            }
            returned.append("네 번째")
        }
        for _ in 0..<1_000 where queue.waitingCount < 3 { await Task.yield() }
        #expect(queue.waitingCount == 3)
        await copyGate.release()
        await musicGate.waitUntilStarted()
        await first.value
        await fourth.value
        #expect(operations == ["첫 복사", "병합된 Music", "쓰기 뒤 복사"])
        #expect(returned == ["네 번째"])
        await musicGate.release()
        await second.value
        await third.value
        #expect(Set(returned) == ["두 번째", "세 번째", "네 번째"])
    }

    @Test(arguments: [false, true])
    func 느린_Music_캡처가_쓰기_뒤_DB_복사를_막지_않는다(sameSecond: Bool) async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        let directory = fixture.root.appending(path: "snapshots")
        let sourceDB = fixture.database
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = try LibrarySnapshot.take(from: sourceDB, into: directory, force: true, now: stamp)
        let cached = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "합성 목록")])
        let late = ITunesLibrarySnapshot(playlists: [.init(id: "B", name: "늦게 도착한 목록")])
        try cached.save(for: previous)
        let store = LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.write-reload-queue.\(UUID())")!, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                                 backupDirectory: fixture.backups, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
        await store.load(snapshot: previous, arguments: ["test"], environment: [:])

        let musicStarted = Mutex(false)
        let writeCopyStarted = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let background = Task {
            await store.takeSnapshot(force: true, quiet: sameSecond, snapshotDirectory: directory, snapshotCopy: { force in
                try LibrarySnapshot.take(from: sourceDB, into: directory, force: force, now: stamp.addingTimeInterval(60))
            }, captureITunes: {
                musicStarted.withLock { $0 = true }
                resume.wait()
                return late
            }, arguments: ["test"], environment: [:])
        }
        let startedDeadline = ContinuousClock.now + .seconds(10)
        while !musicStarted.withLock({ $0 }) && ContinuousClock.now < startedDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard musicStarted.withLock({ $0 }) else {
            resume.signal()
            await background.value
            Issue.record("Music 캡처가 시작되지 않았습니다")
            return
        }
        #expect(store.isLoading == !sameSecond)

        do { try fixture.add(TrackSpec(id: "2")) }
        catch {
            resume.signal()
            await background.value
            throw error
        }
        store.isWritingRekordbox = true
        let postWriteCompleted = Mutex(false)
        let copiedURL = Mutex<URL?>(nil)
        let postWrite = Task {
            await store.takeSnapshot(force: true, quiet: true, refreshITunes: false, snapshotDirectory: directory,
                                     snapshotCopy: { force in
                                         writeCopyStarted.withLock { $0 = true }
                                         let url = try LibrarySnapshot.take(from: sourceDB, into: directory, force: force,
                                                                            now: stamp.addingTimeInterval(sameSecond ? 60 : 120))
                                         copiedURL.withLock { $0 = url }
                                         return url
                                     }, captureITunes: { Issue.record("쓰기 뒤 Music을 조회했습니다"); return cached },
                                     arguments: ["test"], environment: [:])
            postWriteCompleted.withLock { $0 = true }
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while !postWriteCompleted.withLock({ $0 }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let copiedBeforeMusicReturned = writeCopyStarted.withLock { $0 }
        let loadedBeforeMusicReturned = postWriteCompleted.withLock { $0 } && store.rows.count == 2
        resume.signal()
        await postWrite.value
        await background.value
        store.isWritingRekordbox = false
        #expect(copiedBeforeMusicReturned)
        #expect(loadedBeforeMusicReturned)
        #expect(store.snapshotURL == copiedURL.withLock { $0 })
        #expect(store.iTunesSnapshot.playlists == cached.playlists)
        #expect(ITunesLibrarySnapshot.load(for: try #require(copiedURL.withLock { $0 })).playlists == cached.playlists)
    }
}
