@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Synchronization
import Testing

@MainActor
@Suite("초안을 보존하는 라이브러리 동기화")
struct LibrarySyncTests {
    func store(_ fixture: RekordboxFixture) -> LibraryStore {
        LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.sync.\(UUID())")!, persist: false),
                     resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                     backupDirectory: fixture.backups, playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in },
                     playlistImportURL: nil, stagingSaver: { _ in })
    }

    @Test(arguments: [false, true])
    func 명시적_동기화만_안_고친_태그를_갱신한다(explicit: Bool) async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(spec.id)])
        let store = store(fixture), args = ["test", "--db", fixture.database.path]
        await store.load(snapshot: fixture.database, arguments: args, environment: [:])
        let row = try #require(store.rowsByUUID[spec.uuid])
        store.setTag(.comment, "내 코멘트", rows: [row])
        DraftWriter.flush()
        defer { try? TagDraftStore.remove(trackUUID: spec.uuid, directory: TagDraftStore.directory) }
        let before = try #require(TagDraftStore.load(trackUUID: spec.uuid))
        try fixture.execute("UPDATE djmdContent SET Title = '최신 제목' WHERE ID = ?", [.text(spec.id)])
        await store.load(snapshot: fixture.database, synchronizingDrafts: explicit, arguments: args, environment: [:])
        DraftWriter.flush()
        let actual = try #require(TagDraftStore.load(trackUUID: spec.uuid))
        #expect(store.rowsByUUID[spec.uuid]?.track.title == "최신 제목")
        #expect(actual == store.tagDrafts[spec.uuid])
        #expect(actual.fields.comment == "내 코멘트")
        if explicit {
            #expect(actual.base.title == "최신 제목" && actual.fields.title == "최신 제목")
            let report = try RekordboxWriter.write(drafts: [], tags: [actual], to: fixture.database, dryRun: false,
                                                   backups: fixture.backups, shareRoot: fixture.shareRoot)
            #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
        } else { #expect(actual == before) }
    }

    @Test func 같은_칸_충돌과_그리드_초안은_파일까지_그대로_보존한다() async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(spec.id)])
        let store = store(fixture), args = ["test", "--db", fixture.database.path]
        await store.load(snapshot: fixture.database, arguments: args, environment: [:])
        let row = try #require(store.rowsByUUID[spec.uuid])
        store.setTag(.comment, "내 코멘트", rows: [row])
        DraftWriter.flush()
        var grid = GridDraft(trackUUID: spec.uuid, base: [.init(start: 0.2, bpm: 120, firstBeatNumber: 1)],
                             segments: [.init(start: 0.3, bpm: 120, firstBeatNumber: 1)])
        grid.shift(by: 0.01)
        try GridDraftStore.save(grid)
        let tagURL = TagDraftStore.directory.appending(path: "\(spec.uuid).json")
        let gridURL = GridDraftStore.directory.appending(path: "\(spec.uuid).json")
        let tagBefore = try Data(contentsOf: tagURL), gridBefore = try Data(contentsOf: gridURL)
        defer {
            try? TagDraftStore.remove(trackUUID: spec.uuid, directory: TagDraftStore.directory)
            GridDraftStore.remove(trackUUID: spec.uuid)
        }
        try fixture.execute("UPDATE djmdContent SET Commnt = '현재 코멘트' WHERE ID = ?", [.text(spec.id)])
        await store.load(snapshot: fixture.database, synchronizingDrafts: true, arguments: args, environment: [:])
        DraftWriter.flush()
        #expect(try Data(contentsOf: tagURL) == tagBefore && Data(contentsOf: gridURL) == gridBefore)
        #expect(store.tagDrafts[spec.uuid]?.fields.comment == "내 코멘트")
        #expect(store.toast?.kind == .warning)
        let report = try RekordboxWriter.write(drafts: [], tags: [try #require(store.tagDrafts[spec.uuid])],
                                               to: fixture.database, dryRun: false, backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.tagWritten.isEmpty && report.tagBlocked.count == 1)
        #expect(try RekordboxLibrary.load(snapshot: fixture.database).tracks.first?.comment == "현재 코멘트")
    }

    @Test func 실패한_동기화는_기존_초안을_바꾸지_않는다() async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(spec.id)])
        let store = store(fixture), args = ["test", "--db", fixture.database.path]
        await store.load(snapshot: fixture.database, arguments: args, environment: [:])
        store.setTag(.comment, "내 코멘트", rows: [try #require(store.rowsByUUID[spec.uuid])])
        DraftWriter.flush()
        defer { try? TagDraftStore.remove(trackUUID: spec.uuid, directory: TagDraftStore.directory) }
        let before = try #require(TagDraftStore.load(trackUUID: spec.uuid))
        await store.load(snapshot: fixture.root.appending(path: "없는.db"), quiet: true, synchronizingDrafts: true,
                         arguments: args, environment: [:])
        #expect(store.lastError != nil && store.tagDrafts[spec.uuid] == before)
        #expect(TagDraftStore.load(trackUUID: spec.uuid) == before)
    }
    @Test(arguments: [false, true])
    func 같은_칸_충돌은_그_칸만_명시적으로_선택한다(keepingDraft: Bool) async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(spec.id)])
        let store = store(fixture), args = ["test", "--db", fixture.database.path]
        await store.load(snapshot: fixture.database, arguments: args, environment: [:])
        store.setTag(.comment, "내 코멘트", rows: [try #require(store.rowsByUUID[spec.uuid])])
        DraftWriter.flush()
        defer { try? TagDraftStore.remove(trackUUID: spec.uuid, directory: TagDraftStore.directory) }
        try fixture.execute("UPDATE djmdContent SET Commnt = '현재 코멘트', Title = '최신 제목' WHERE ID = ?", [.text(spec.id)])
        await store.load(snapshot: fixture.database, synchronizingDrafts: true, arguments: args, environment: [:])
        let stale = try #require(store.tagDrafts[spec.uuid])
        let undo = UndoManager()
        store.undoManager = undo
        store.resolveTagConflict(.comment, keepingDraft: keepingDraft, rows: [try #require(store.rowsByUUID[spec.uuid])])
        DraftWriter.flush()
        if keepingDraft {
            let resolved = try #require(TagDraftStore.load(trackUUID: spec.uuid))
            #expect(resolved.base.comment == "현재 코멘트" && resolved.fields.comment == "내 코멘트")
            #expect(resolved.base.title == "최신 제목" && resolved.fields.title == "최신 제목")
            let report = try RekordboxWriter.write(drafts: [], tags: [resolved], to: fixture.database, dryRun: true,
                                                   backups: fixture.backups, shareRoot: fixture.shareRoot)
            #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
        } else {
            #expect(store.tagDrafts[spec.uuid] == nil && TagDraftStore.load(trackUUID: spec.uuid) == nil)
        }
        undo.undo()
        #expect(store.tagDrafts[spec.uuid] == stale)
    }

    @Test func 태그_저장_실패_후_새로_읽어도_입력을_잃지_않는다() throws {
        let fixture = try RekordboxFixture()
        let home = fixture.root.appending(path: "bad-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let directory = home.appending(path: "tag-drafts")
        // 권한을 바꾸는 대신 디렉터리 자리에 파일을 둬 저장 실패를 재현한다.
        try Data([0]).write(to: directory)
        let store = LibraryStore(saveTagDrafts: { DraftWriter.save($0, directory: directory) }, backupDirectory: fixture.backups)
        store.phase = .loaded
        let row = ReflectionCoordinatorTests.row(UUID().uuidString)
        store.rowsByUUID[row.track.uuid] = row
        store.setTag(.comment, "저장할 코멘트", rows: [row])
        DraftWriter.flush()
        let before = try #require(store.tagDrafts[row.track.uuid])
        defer {
            var cleared = before
            cleared.fields = cleared.base
            DraftWriter.save([cleared], directory: directory)
            DraftWriter.flush()
        }
        #expect(TagDraftStore.load(trackUUID: row.track.uuid, directory: directory) == nil)
        store.refreshExternalDrafts(home: home)
        #expect(store.tagDrafts[row.track.uuid] == before)
        #expect(store.lastError?.contains("태그 초안을 저장하지 못") == true)
        let otherHome = fixture.root.appending(path: "other-home")
        let otherDirectory = otherHome.appending(path: "tag-drafts")
        let other = LibraryStore(saveTagDrafts: { DraftWriter.save($0, directory: otherDirectory) }, backupDirectory: fixture.backups)
        other.phase = .loaded
        other.rowsByUUID[row.track.uuid] = row
        other.setTag(.comment, "다른 홈 코멘트", rows: [row])
        DraftWriter.flush()
        other.refreshExternalDrafts(home: otherHome)
        #expect(other.lastError == nil && other.tagDrafts[row.track.uuid]?.fields.comment == "다른 홈 코멘트")
        #expect(DraftWriter.failedTagSaveUUIDs(in: directory) == [row.track.uuid])
        try FileManager.default.removeItem(at: directory)
        // 값은 그대로여도 명시적 동기화/쓰기 재시도는 실패한 저장만 다시 실행한다.
        store.retryFailedTagSaves(in: directory)
        store.refreshExternalDrafts(home: home)
        #expect(store.lastError == nil && DraftWriter.failedTagSaveUUIDs(in: directory).isEmpty)
        #expect(TagDraftStore.load(trackUUID: row.track.uuid, directory: directory)?.fields.comment == "저장할 코멘트")
        try FileManager.default.removeItem(at: directory)
        try Data([0]).write(to: directory)
        store.setTag(.comment, "또 실패한 코멘트", rows: [row])
        // 실패한 버리기도 메모리의 삭제 의도를 되살리지 않는다.
        store.revertTags(rows: [row])
        DraftWriter.flush()
        store.refreshExternalDrafts(home: home)
        #expect(store.tagDrafts[row.track.uuid] == nil)
        try FileManager.default.removeItem(at: directory)
        store.setTag(.comment, "재시도 코멘트", rows: [row])
        DraftWriter.flush()
        store.refreshExternalDrafts(home: home)
        #expect(store.lastError == nil && DraftWriter.failedTagSaveUUIDs(in: directory).isEmpty)
        #expect(TagDraftStore.load(trackUUID: row.track.uuid, directory: directory)?.fields.comment == "재시도 코멘트")
    }

    @Test(arguments: [false, true], [false, true])
    func 명시한_DB_모드는_그_사본만_동기화한다(environmentOverride: Bool, launchOverride: Bool) async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        let store = store(fixture)
        let args = environmentOverride ? ["test"] : ["test", "--db", fixture.database.path]
        let env = environmentOverride ? ["DJC_DB": fixture.database.path] : [:]
        await store.load(snapshot: fixture.database, arguments: args, environment: env)
        try fixture.execute("UPDATE djmdContent SET Title = '지정 사본 새 제목' WHERE ID = ?", [.text(spec.id)])
        let taken = ThreadRecorder(), source = fixture.database
        store.takeLiveSnapshot = { _ in taken.record("take", main: false); return source }
        if launchOverride {
            store.launchArguments = args
            store.launchEnvironment = env
            await store.synchronizeLibrary()
        } else {
            await store.synchronizeLibrary(arguments: args, environment: env)
        }
        #expect(store.snapshotURL == fixture.database && store.rowsByUUID[spec.uuid]?.track.title == "지정 사본 새 제목")
        #expect(taken.calls.isEmpty)
        // 실행 환경이 이미 사본 모드여도 반대쪽 주입으로 기본 인자의 우선순위를 확인한다(뜨기는 합성 DB만 돌려준다).
        if launchOverride, LibraryStore.explicitDatabaseRequested(arguments: ProcessInfo.processInfo.arguments,
                                                                 environment: ProcessInfo.processInfo.environment) {
            store.launchArguments = ["test"]
            store.launchEnvironment = ["DJC_REKORDBOX_DIR": fixture.root.path]
            await store.synchronizeLibrary()
            #expect(taken.calls.count == 1)
        }
    }

    @Test(arguments: [false, true])
    func 쓰기나_미저장_드래그_중에는_동기화하지_않는다(writing: Bool) async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        let store = store(fixture), args = ["test", "--db", fixture.database.path]
        await store.load(snapshot: fixture.database, arguments: args, environment: [:])
        try fixture.execute("UPDATE djmdContent SET Title = '다른 제목' WHERE ID = ?", [.text(spec.id)])
        store.isWritingRekordbox = writing
        store.allowsLibrarySync = { writing }
        await store.synchronizeLibrary(arguments: args, environment: [:])
        #expect(!store.canSynchronizeLibrary && store.rowsByUUID[spec.uuid]?.track.title == spec.title)
    }

    @Test func 동기화_도중_드래그가_시작하면_덱의_메모리를_덮지_않는다() async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        let store = store(fixture), args = ["test", "--db", fixture.database.path]
        await store.load(snapshot: fixture.database, arguments: args, environment: [:])
        var loads: [TrackRow?] = []
        store.onLoadToDeck = { loads.append($0) }
        let row: TrackRow = try #require(store.rowsByUUID[spec.uuid])
        store.loadToDeck(row)
        var calls = 0
        store.allowsLibrarySync = { calls += 1; return calls == 1 }
        store.onRekordboxWritten = { _ in Issue.record("미저장 드래그를 다시 읽었습니다") }
        try fixture.execute("UPDATE djmdContent SET Title = '동기화한 제목' WHERE ID = ?", [.text(spec.id)])
        await store.synchronizeLibrary(arguments: args, environment: [:])
        #expect(store.rowsByUUID[spec.uuid]?.track.title == "동기화한 제목" && loads.count == 1)
    }

    @Test func 읽는_도중_쓰기가_시작하면_동기화_결과를_버린다() async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        let store = store(fixture), args = ["test", "--db", fixture.database.path]
        await store.load(snapshot: fixture.database, arguments: args, environment: [:])
        store.setTag(.comment, "보존할 코멘트", rows: [try #require(store.rowsByUUID[spec.uuid])])
        DraftWriter.flush()
        defer { try? TagDraftStore.remove(trackUUID: spec.uuid, directory: TagDraftStore.directory) }
        let before = try #require(TagDraftStore.load(trackUUID: spec.uuid))
        try fixture.execute("UPDATE djmdContent SET Title = '쓰는 중 최신 제목' WHERE ID = ?", [.text(spec.id)])
        let resume = DispatchSemaphore(value: 0), started = Mutex(false)
        let loading = Task {
            await store.load(snapshot: fixture.database, quiet: true, refreshITunes: true, synchronizingDrafts: true,
                             arguments: args, environment: [:], captureITunes: {
                                 started.withLock { $0 = true }
                                 resume.wait()
                                 return ITunesLibrarySnapshot()
                             })
        }
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        store.isWritingRekordbox = true
        resume.signal()
        await loading.value
        DraftWriter.flush()
        #expect(store.rowsByUUID[spec.uuid]?.track.title == spec.title)
        #expect(store.tagDrafts[spec.uuid] == before && TagDraftStore.load(trackUUID: spec.uuid) == before)
    }

}
