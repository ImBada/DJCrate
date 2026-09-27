@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

private final class ITunesSyncCaptureGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
}

@Suite("iTunes 동기화 일관성", .serialized)
struct ITunesSyncConsistencyTests {
    let base = Data("""
        <SYNC_ITUNES_PLAYLIST Version="3.0.0"><PLAYLISTS>
        <NODE Id="0" ParentId="0" Attribute="1" Timestamp="0" Lib_Type="1" CheckType="2"/>
        <NODE Id="A" ParentId="0" Attribute="0" Timestamp="100" Lib_Type="1" CheckType="1"/>
        </PLAYLISTS></SYNC_ITUNES_PLAYLIST>
        """.utf8)

    func original() throws -> ITunesLibrarySnapshot {
        try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "이전 선택"), .init(id: "B", name: "새 선택")])
            .applyingRekordboxSelection(base)
    }

    @MainActor func store(_ fixture: RekordboxFixture) -> LibraryStore {
        LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.itunes.consistency.\(UUID())")!, persist: false),
                     resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, backupDirectory: fixture.backups,
                     playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
    }

    @MainActor @Test func 늦은_읽기는_저장한_선택을_되돌리지_않는다() async throws {
        let fixture = try RekordboxFixture(), source = try original(), database = fixture.database
        try base.write(to: fixture.root.appending(path: "playlists3.sync"))
        try source.save(for: database)
        let store = store(fixture)
        await store.load(snapshot: database)
        let gate = ITunesSyncCaptureGate()
        let first = Task.detached {
            try LoadedLibrary.load(snapshot: database, refreshITunes: true, captureITunes: {
                gate.started.signal()
                _ = gate.resume.wait(timeout: .now() + 15)
                return source
            })
        }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: gate.started.wait(timeout: .now() + 15) == .success) }
        }
        #expect(started)
        defer { gate.resume.signal() }
        guard started else { _ = try? await first.value; return }
        try await store.syncITunesPlaylists(.init(selectedIDs: ["B"]), source: source, database: database,
                                           arguments: ["test", "--db", database.path], environment: [:])
        gate.resume.signal()
        let late = try await first.value
        #expect(late.iTunesSnapshot.selectedIDs == ["B"])
        #expect(ITunesLibrarySnapshot.load(for: database).selectedIDs == ["B"])
        #expect(store.iTunesSnapshot.selectedIDs == ["B"])
    }

    @MainActor @Test func 조용한_새로고침은_저장_뒤_오래된_UI를_채택하지_않는다() async throws {
        let fixture = try RekordboxFixture(), source = try original(), database = fixture.database
        try base.write(to: fixture.root.appending(path: "playlists3.sync"))
        try source.save(for: database)
        let store = store(fixture)
        await store.load(snapshot: database)
        let gate = ITunesSyncCaptureGate()
        let loading = Task {
            await store.load(snapshot: database, quiet: true, refreshITunes: true, captureITunes: {
                gate.started.signal()
                _ = gate.resume.wait(timeout: .now() + 15)
                return source
            })
        }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: gate.started.wait(timeout: .now() + 15) == .success) }
        }
        #expect(started)
        defer { gate.resume.signal() }
        guard started else { await loading.value; return }
        try await store.syncITunesPlaylists(.init(selectedIDs: ["B"]), source: source, database: database,
                                           arguments: ["test", "--db", database.path], environment: [:])
        gate.resume.signal()
        await loading.value
        #expect(store.iTunesSnapshot.selectedIDs == ["B"])
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
        #expect(ITunesLibrarySnapshot.load(for: database).selectedIDs == ["B"])
    }

    @MainActor @Test func 저장_실패는_기존_화면과_정상_사본을_보존한다() async throws {
        let fixture = try RekordboxFixture(), source = try original(), database = fixture.database
        let sync = fixture.root.appending(path: "playlists3.sync")
        try base.write(to: sync)
        try source.save(for: database)
        let store = store(fixture)
        await store.load(snapshot: database)
        try (base + Data("\n".utf8)).write(to: sync)
        await #expect(throws: (any Error).self) {
            try await store.syncITunesPlaylists(.init(selectedIDs: ["B"]), source: source, database: database,
                                               arguments: ["test", "--db", database.path], environment: [:])
        }
        #expect(store.iTunesSnapshot.selectedIDs == ["A"])
        #expect(store.iTunesLibrary.index["itunes:A"] != nil)
        #expect(ITunesLibrarySnapshot.load(for: database).selectedIDs == ["A"])
    }

    @MainActor @Test func 사본_루트의_현재_선택을_새_스냅샷에_적용한다() async throws {
        let fixture = try RekordboxFixture(), source = try original()
        let sync = fixture.root.appending(path: "playlists3.sync")
        try base.write(to: sync)
        try source.save(for: fixture.database)
        let snapshots = fixture.root.appending(path: "djc-snapshots")
        _ = try LibrarySnapshot.take(from: fixture.database, into: snapshots, force: true,
                                     now: Date(timeIntervalSince1970: 1_800_000_000))
        _ = try RekordboxWriter.write(drafts: [], iTunesSync: .init(base: base, source: source.selectionNodes,
                                                                   selection: .init(selectedIDs: ["B"])),
                                      to: fixture.database, dryRun: false, backups: fixture.backups)
        let fresh = try LibrarySnapshot.take(from: fixture.database, into: snapshots, force: true,
                                             now: Date(timeIntervalSince1970: 1_800_000_060))
        let environment = ["DJC_REKORDBOX_DIR": fixture.root.path]
        let explicit = self.store(fixture)
        await explicit.load(snapshot: fresh, arguments: ["test", "--db", fresh.path], environment: environment)
        #expect(explicit.iTunesSnapshot.selectedIDs == ["A"])
        #expect(explicit.iTunesLibrary.index["itunes:B"] == nil)
        let store = store(fixture)
        await store.load(snapshot: fresh, arguments: ["test"], environment: environment)
        #expect(store.iTunesSnapshot.selectedIDs == ["B"])
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
    }

    @Test func 다른_URL과_같은_초_교체에서도_늦은_캡처가_현재_선택을_덮지_못한다() async throws {
        let fixture = try RekordboxFixture(), source = try original(), rootDB = fixture.database
        let sync = fixture.root.appending(path: "playlists3.sync")
        try base.write(to: sync)
        try source.save(for: rootDB)
        let directory = fixture.root.appending(path: "djc-snapshots")
        let before = try LibrarySnapshot.take(from: rootDB, into: directory, force: true,
                                              now: Date(timeIntervalSince1970: 1_800_000_000))
        let gate = ITunesSyncCaptureGate()
        let pending = Task.detached {
            try LoadedLibrary.load(snapshot: before, refreshITunes: true, sourceDatabase: rootDB, captureITunes: {
                gate.started.signal()
                _ = gate.resume.wait(timeout: .now() + 15)
                return source
            })
        }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: gate.started.wait(timeout: .now() + 15) == .success) }
        }
        #expect(started)
        defer { gate.resume.signal() }
        guard started else { _ = try? await pending.value; return }
        _ = try RekordboxWriter.write(drafts: [], iTunesSync: .init(base: base, source: source.selectionNodes,
                                                                   selection: .init(selectedIDs: ["B"])),
                                      to: rootDB, dryRun: false, backups: fixture.backups)
        try source.applyingRekordboxSelection(Data(contentsOf: sync)).save(for: rootDB)
        let stamp = Date(timeIntervalSince1970: 1_800_000_060)
        let fresh = try LibrarySnapshot.take(from: rootDB, into: directory, force: true, now: stamp)
        let newest = try LoadedLibrary.load(snapshot: fresh, sourceDatabase: rootDB)
        ITunesRefreshCoordinator.shared.invalidateSnapshots([fresh])
        let replaced = try LibrarySnapshot.take(from: rootDB, into: directory, force: true, now: stamp)
        let sameSecond = try LoadedLibrary.load(snapshot: replaced, sourceDatabase: rootDB)
        gate.resume.signal()
        let late = try await pending.value
        #expect(newest.iTunesSnapshot.selectedIDs == ["B"])
        #expect(sameSecond.iTunesSnapshot.selectedIDs == ["B"])
        #expect(late.iTunesSnapshot.selectedIDs == ["B"])
        #expect(ITunesLibrarySnapshot.load(for: replaced).selectedIDs == ["B"])
    }

    @Test func 명시한_읽기_전용_사본의_정상_캐시는_재저장하지_않는다() throws {
        let fixture = try RekordboxFixture(), source = try original()
        let directory = fixture.root.appending(path: "readonly")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appending(path: "manual.db")
        try FileManager.default.copyItem(at: fixture.database, to: database)
        try source.save(for: database)
        try base.write(to: directory.appending(path: "playlists3.sync"))
        let originalData = try Data(contentsOf: ITunesLibrarySnapshot.url(for: database))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let loaded = try LoadedLibrary.load(snapshot: database)
        #expect(loaded.iTunesSnapshot.status == .ready)
        #expect(loaded.iTunesSnapshot.selectedIDs == ["A"])
        #expect(try Data(contentsOf: ITunesLibrarySnapshot.url(for: database)) == originalData)
    }

    @Test func 루트_사본에_없는_새_목록도_현재_스냅샷에서_유지한다() throws {
        let fixture = try RekordboxFixture(), source = try original()
        let directory = fixture.root.appending(path: "djc-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = directory.appending(path: "master-2026-01-01T000001.db")
        try FileManager.default.copyItem(at: fixture.database, to: snapshot)
        let oldCatalog = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "이전 선택")])
            .applyingRekordboxSelection(base)
        try oldCatalog.save(for: fixture.database)
        let updatedSync = try RekordboxITunesSyncChange(base: base, source: source.selectionNodes,
                                                        selection: .init(selectedIDs: ["B"])).render()
        try updatedSync.write(to: fixture.root.appending(path: "playlists3.sync"))
        try source.applyingRekordboxSelection(updatedSync).save(for: snapshot)
        let loaded = try LoadedLibrary.load(snapshot: snapshot, sourceDatabase: fixture.database)
        #expect(loaded.iTunesLibrary.index["itunes:B"] != nil)
    }

    @MainActor @Test func 같은_URL_사본이_저장_후_캐시를_지워도_현재_선택을_복구한다() async throws {
        let fixture = try RekordboxFixture(), source = try original(), database = fixture.database
        try base.write(to: fixture.root.appending(path: "playlists3.sync"))
        try source.save(for: database)
        let store = store(fixture)
        await store.load(snapshot: database)
        let previous = LoadedLibrary.ITunesFallback(source: database, contents: store.iTunesSnapshot)
        try await store.syncITunesPlaylists(.init(selectedIDs: ["B"]), source: source, database: database,
                                           arguments: ["test", "--db", database.path], environment: [:])
        // 같은 초의 스냅샷 교체는 같은 sidecar를 지울 수 있고, 라이브 루트에는 별도 캐시가 없다.
        try FileManager.default.removeItem(at: ITunesLibrarySnapshot.url(for: database))
        let newest = store.latestITunesFallback(previous)
        let loaded = try LoadedLibrary.load(snapshot: database, refreshITunes: true,
                                            previousITunesSnapshot: newest,
                                            captureITunes: { ITunesLibrarySnapshot(status: .unavailable) })
        #expect(newest?.contents.selectedIDs == ["B"])
        #expect(loaded.iTunesSnapshot.status == .stale)
        #expect(loaded.iTunesSnapshot.selectedIDs == ["B"])
        #expect(ITunesLibrarySnapshot.load(for: database).selectedIDs == ["B"])
    }

    @MainActor @Test func 조용한_스냅샷_복사가_저장_뒤_같은_URL을_교체해도_현재_선택을_유지한다() async throws {
        let fixture = try RekordboxFixture(), source = try original()
        try fixture.add(TrackSpec())
        let directory = fixture.root.appending(path: "djc-snapshots")
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let database = try LibrarySnapshot.take(from: fixture.database, into: directory, force: true, now: stamp)
        try base.write(to: directory.appending(path: "playlists3.sync"))
        try source.save(for: database)
        let store = store(fixture)
        await store.load(snapshot: database, arguments: ["test", "--db", database.path], environment: [:])
        #expect(store.rows.count == 1)
        let gate = ITunesSyncCaptureGate(), sourceDB = fixture.database
        let pending = Task {
            // CI의 사본 경로 설정과 무관하게 캡처 실패 뒤 메모리 복구를 검증한다.
            await store.takeSnapshot(force: true, quiet: true, snapshotDirectory: directory,
                                     snapshotCopy: { force in
                                         gate.started.signal()
                                         _ = gate.resume.wait(timeout: .now() + 15)
                                         return try LibrarySnapshot.take(from: sourceDB, into: directory, force: force, now: stamp)
                                     }, captureITunes: { ITunesLibrarySnapshot(status: .unavailable) },
                                     arguments: ["test"], environment: [:])
        }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: gate.started.wait(timeout: .now() + 15) == .success) }
        }
        #expect(started)
        defer { gate.resume.signal() }
        guard started else { await pending.value; return }
        #expect(!store.isLoading)
        try await store.syncITunesPlaylists(.init(selectedIDs: ["B"]), source: source, database: database,
                                           arguments: ["test", "--db", database.path], environment: [:])
        gate.resume.signal()
        await pending.value
        #expect(store.iTunesSnapshot.status == .stale)
        #expect(store.iTunesSnapshot.selectedIDs == ["B"])
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
        #expect(ITunesLibrarySnapshot.load(for: database).selectedIDs == ["B"])
    }

    @MainActor @Test func 사본_루트_캐시가_없어도_같은_초_스냅샷_교체는_현재_선택을_보존한다() async throws {
        let fixture = try RekordboxFixture(), source = try original()
        try fixture.add(TrackSpec())
        let environment = ["DJC_REKORDBOX_DIR": fixture.root.path]
        let arguments = ["test"]
        let directory = fixture.root.appending(path: "djc-snapshots")
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let database = try LibrarySnapshot.take(from: fixture.database, into: directory, force: true, now: stamp)
        try base.write(to: fixture.root.appending(path: "playlists3.sync"))
        try source.save(for: database)
        #expect(ITunesLibrarySnapshot.load(for: fixture.database).status == .notCaptured)
        let store = store(fixture)
        await store.load(snapshot: database, arguments: arguments, environment: environment)
        #expect(store.rows.count == 1)
        let gate = ITunesSyncCaptureGate(), sourceDB = fixture.database
        let pending = Task {
            await store.takeSnapshot(force: true, quiet: true, snapshotDirectory: directory,
                                     snapshotCopy: { force in
                                         gate.started.signal()
                                         _ = gate.resume.wait(timeout: .now() + 15)
                                         return try LibrarySnapshot.take(from: sourceDB, into: directory, force: force, now: stamp)
                                     }, captureITunes: { ITunesLibrarySnapshot(status: .unavailable) },
                                     arguments: arguments, environment: environment)
        }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: gate.started.wait(timeout: .now() + 15) == .success) }
        }
        #expect(started)
        defer { gate.resume.signal() }
        guard started else { await pending.value; return }
        #expect(!store.isLoading)
        try await store.syncITunesPlaylists(.init(selectedIDs: ["B"]), source: source, database: database,
                                           arguments: arguments, environment: environment)
        #expect(ITunesLibrarySnapshot.load(for: fixture.database).status == .notCaptured)
        gate.resume.signal()
        await pending.value
        #expect(store.iTunesSnapshot.status == .ready)
        #expect(store.iTunesSnapshot.selectedIDs == ["B"])
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
        #expect(ITunesLibrarySnapshot.load(for: database).selectedIDs == ["B"])
    }

    @Test func 같은_사본_폴더라도_다른_출처의_이전_목록은_섞지_않는다() throws {
        let fixture = try RekordboxFixture(), unrelated = try RekordboxFixture(), source = try original()
        let directory = fixture.root.appending(path: "djc-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousURL = directory.appending(path: "master-2026-01-01T000001.db")
        let fresh = directory.appending(path: "master-2026-01-01T000002.db")
        try FileManager.default.copyItem(at: fixture.database, to: fresh)
        let selected = try source.applying(ITunesSyncSelection(selectedIDs: ["B"]))
        let previous = LoadedLibrary.ITunesFallback(source: previousURL, contents: selected,
                                                    preferOverCurrent: true, sourceDatabase: unrelated.database)
        let loaded = try LoadedLibrary.load(snapshot: fresh, previousITunesSnapshot: previous,
                                            sourceDatabase: fixture.database)
        #expect(loaded.iTunesSnapshot.status == .notCaptured)
        #expect(loaded.iTunesLibrary.index["itunes:B"] == nil)
    }

    @MainActor @Test func 현재_sync와_맞는_활성_카탈로그를_옛_루트_사본보다_우선한다() async throws {
        let fixture = try RekordboxFixture(), source = try original()
        try fixture.add(TrackSpec())
        let root = fixture.database
        let oldCatalog = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "이전 선택")])
            .applyingRekordboxSelection(base)
        try oldCatalog.save(for: root)
        let currentSync = try RekordboxITunesSyncChange(base: base, source: source.selectionNodes,
                                                        selection: .init(selectedIDs: ["B"])).render()
        try currentSync.write(to: fixture.root.appending(path: "playlists3.sync"))
        let directory = fixture.root.appending(path: "djc-snapshots")
        let active = try LibrarySnapshot.take(from: root, into: directory, force: true,
                                              now: Date(timeIntervalSince1970: 1_800_000_000))
        try source.applyingRekordboxSelection(currentSync).save(for: active)
        let environment = ["DJC_REKORDBOX_DIR": fixture.root.path]
        let store = store(fixture)
        await store.load(snapshot: active, arguments: ["test"], environment: environment)
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
        let fresh = directory.appending(path: "master-2027-01-15T080100.db")
        await store.takeSnapshot(force: true, quiet: true, snapshotDirectory: directory,
                                 snapshotCopy: { force in
                                     try LibrarySnapshot.take(from: root, into: directory, force: force,
                                                              now: Date(timeIntervalSince1970: 1_800_000_060))
                                 }, captureITunes: { ITunesLibrarySnapshot(status: .unavailable) },
                                 arguments: ["test"], environment: environment)
        #expect(store.snapshotURL?.standardizedFileURL.path == fresh.standardizedFileURL.path)
        #expect(store.iTunesSnapshot.selectedIDs == ["B"])
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
        #expect(store.iTunesSnapshot.sourcePlaylists?.contains(where: { $0.id == "B" }) == true)
        #expect(ITunesLibrarySnapshot.load(for: root).sourcePlaylists?.map(\.id) == ["A"])
    }

    @Test func 새_캡처에서_실제로_사라진_목록은_이전_메모리에서_되살리지_않는다() throws {
        let fixture = try RekordboxFixture(), previous = try original()
        let directory = fixture.root.appending(path: "djc-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appending(path: "master-2027-01-15T080100.db")
        try FileManager.default.copyItem(at: fixture.database, to: database)
        let currentSync = try RekordboxITunesSyncChange(base: base, source: previous.selectionNodes,
                                                        selection: .init(selectedIDs: ["B"])).render()
        try currentSync.write(to: fixture.root.appending(path: "playlists3.sync"))
        let oldMemory = try previous.applyingRekordboxSelection(currentSync)
        let captured = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "남은 목록")])
            .applyingRekordboxSelection(currentSync)
        let fallback = LoadedLibrary.ITunesFallback(source: database, contents: oldMemory,
                                                    sourceDatabase: fixture.database)
        let loaded = try LoadedLibrary.load(snapshot: database, refreshITunes: true,
                                            previousITunesSnapshot: fallback, sourceDatabase: fixture.database,
                                            captureITunes: { captured })
        #expect(loaded.iTunesSnapshot.status == .ready)
        #expect(loaded.iTunesSnapshot.selectedIDs == ["B"])
        #expect(loaded.iTunesLibrary.index["itunes:B"] == nil)
        #expect(loaded.iTunesSnapshot.unavailablePlaylistCount == 1)
    }

    @Test func 다른_URL의_성공_캡처는_나중_요청_실패의_복구_사본이_된다() async throws {
        let fixture = try RekordboxFixture(), source = try original()
        let sourceDatabase = fixture.database
        let directory = fixture.root.appending(path: "djc-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstURL = directory.appending(path: "master-2026-01-01T000001.db")
        let secondURL = directory.appending(path: "master-2026-01-01T000002.db")
        for url in [firstURL, secondURL] { try FileManager.default.copyItem(at: fixture.database, to: url) }
        let firstGate = ITunesSyncCaptureGate(), secondGate = ITunesSyncCaptureGate()
        let first = Task.detached {
            try LoadedLibrary.load(snapshot: firstURL, refreshITunes: true, fallbackDirectory: directory,
                                   sourceDatabase: sourceDatabase, captureITunes: {
                                       firstGate.started.signal()
                                       _ = firstGate.resume.wait(timeout: .now() + 15)
                                       return source
                                   })
        }
        let firstStarted = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: firstGate.started.wait(timeout: .now() + 15) == .success) }
        }
        #expect(firstStarted)
        let second = Task.detached {
            try LoadedLibrary.load(snapshot: secondURL, refreshITunes: true, fallbackDirectory: directory,
                                   sourceDatabase: sourceDatabase, captureITunes: {
                                       secondGate.started.signal()
                                       _ = secondGate.resume.wait(timeout: .now() + 15)
                                       return ITunesLibrarySnapshot(status: .unavailable)
                                   })
        }
        let secondStarted = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: secondGate.started.wait(timeout: .now() + 15) == .success) }
        }
        #expect(secondStarted)
        firstGate.resume.signal()
        let good = try await first.value
        secondGate.resume.signal()
        let fallback = try await second.value
        #expect(good.iTunesSnapshot.status == .ready)
        #expect(ITunesLibrarySnapshot.load(for: firstURL).selectedIDs == ["A"])
        #expect(fallback.iTunesSnapshot.status == .stale)
        #expect(fallback.iTunesSnapshot.selectedIDs == ["A"])
    }

    @MainActor @Test func 명시_DB가_기본_사본_폴더에_있어도_활성화_새로고침은_출처를_바꾸지_않는다() async throws {
        let fixture = try RekordboxFixture(), source = try original()
        let directory = fixture.root.appending(path: "djc-snapshots")
        let database = try LibrarySnapshot.take(from: fixture.database, into: directory, force: true,
                                                now: Date(timeIntervalSince1970: 1_700_000_000))
        try source.save(for: database)
        let environment = ["DJC_REKORDBOX_DIR": fixture.root.path]
        let arguments = ["test", "--db", database.path]
        let store = store(fixture)
        await store.load(snapshot: database, arguments: arguments, environment: environment)
        await store.refreshIfRekordboxChanged(arguments: arguments, environment: environment)
        #expect(store.snapshotURL == database)
        #expect(store.iTunesSnapshot.selectedIDs == ["A"])
        #expect(store.lastError == nil)
        #expect(try LibrarySnapshot.latest(in: directory).standardizedFileURL.path == database.standardizedFileURL.path)
    }
}
