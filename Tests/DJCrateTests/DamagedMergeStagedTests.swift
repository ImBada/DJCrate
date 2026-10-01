@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// #178: 합치기 초안(`merge-drafts.json`)과 추가 목록(`staged.json`)이 손상되면 지우거나 빈 값으로 덮지 않고
/// `damaged-drafts`에 옮겨 보관한 뒤 알린다(#174와 같은 방식).
@Suite("합치기 초안·추가 목록 손상 파일", .serialized)
struct DamagedMergeStagedTests {
    func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-damaged-merge-staged-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    let broken = Data("{\"깨진".utf8)

    func preserved(in home: URL) -> [URL] {
        let root = home.appending(path: DamagedDrafts.folderName)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "json" }
    }

    func merge(_ id: String = "a") -> DuplicateMergeDraft {
        .init(keeping: .init(contentID: id, trackUUID: id, title: "남길 곡", duration: 30, offset: 0, cues: []),
              removing: [.init(contentID: "\(id)-뺄", trackUUID: "\(id)-뺄", title: "뺄 곡", duration: 30, offset: 0, cues: [])], base: "base")
    }

    func track(_ name: String = "a") -> StagedTrack {
        StagedTrack(path: "/fixtures/\(name).wav", title: "합성 곡 \(name)", duration: 30, addedOn: "2026-10-02")
    }

    // MARK: - 합치기 초안 저장소

    @Test func 손상된_합치기_초안은_저장_전에_옮겨_보관하고_새_초안을_쓴다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: DuplicateMergeDraftStore.fileName)
        try broken.write(to: url)
        try DuplicateMergeDraftStore.save([merge()], url: url)
        #expect(DuplicateMergeDraftStore.load(url: url) == [merge()])
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
        #expect(DamagedDrafts.take(home: home).map(\.name) == ["merge-drafts.json"])
    }

    @Test func 손상된_합치기_초안을_비우기로_지우지_않는다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: DuplicateMergeDraftStore.fileName)
        try broken.write(to: url)
        try DuplicateMergeDraftStore.save([], url: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
        _ = DamagedDrafts.take(home: home)
    }

    @Test func 읽지_못하는_합치기_초안은_덮지_않는다() throws {
        let home = try home()
        let url = home.appending(path: DuplicateMergeDraftStore.fileName)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: home)
        }
        try DuplicateMergeDraftStore.save([merge("기존")], url: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try DuplicateMergeDraftStore.save([merge("기존"), merge("새")], url: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(DuplicateMergeDraftStore.load(url: url) == [merge("기존")])
        #expect(preserved(in: home).isEmpty)
    }

    @Test func 정상_합치기_초안은_저장해도_옮기지_않는다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: DuplicateMergeDraftStore.fileName)
        try DuplicateMergeDraftStore.save([merge("a")], url: url)
        try DuplicateMergeDraftStore.save([merge("a"), merge("b")], url: url)
        #expect(DuplicateMergeDraftStore.load(url: url).count == 2)
        #expect(preserved(in: home).isEmpty && DamagedDrafts.take(home: home).isEmpty)
    }

    // MARK: - 추가 목록 저장소

    @Test func 손상된_추가_목록은_저장_전에_옮겨_보관하고_새_목록을_쓴다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: StagingStore.fileName)
        try broken.write(to: url)
        try StagingStore.save([track()], url: url)
        #expect(StagingStore.load(url: url).map(\.path) == [track().path])
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
        #expect(DamagedDrafts.take(home: home).map(\.name) == ["staged.json"])
    }

    @Test func 읽지_못하는_추가_목록은_덮지_않는다() throws {
        let home = try home()
        let url = home.appending(path: StagingStore.fileName)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: home)
        }
        try StagingStore.save([track("기존")], url: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try StagingStore.save([track("기존"), track("새")], url: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(StagingStore.load(url: url).map(\.path) == [track("기존").path])
        #expect(preserved(in: home).isEmpty)
    }

    @Test func 편집본_넣기가_손상된_추가_목록을_새_목록으로_덮지_않는다() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try broken.write(to: home.appending(path: StagingStore.fileName))
        let output = try AudioFixture.wav(seconds: 4, in: home, name: "원곡 (Edit).wav")
        let edit = try TrackEdit(grid: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], sourceDuration: 4, bars: BarRange.list("1-1"))
        let staged = try await EditStaging.stage(fileAt: output, edit: edit, cues: [], source: nil, home: home)
        #expect(StagingStore.load(url: home.appending(path: StagingStore.fileName)).map(\.uuid) == [staged.uuid])
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
        #expect(DamagedDrafts.take(home: home).map(\.name) == ["staged.json"])
    }

    // MARK: - 데이터 폴더 훑기

    @Test func 데이터_폴더를_훑으면_손상된_두_파일을_옮기고_정상_파일은_둔다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try broken.write(to: home.appending(path: DuplicateMergeDraftStore.fileName))
        try broken.write(to: home.appending(path: StagingStore.fileName))
        DamagedDrafts.preserveAll(home: home)
        #expect(Set(DamagedDrafts.take(home: home).map(\.name)) == ["merge-drafts.json", "staged.json"])
        #expect(preserved(in: home).count == 2 && preserved(in: home).allSatisfy { (try? Data(contentsOf: $0)) == broken })
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: StagingStore.fileName).path))

        try DuplicateMergeDraftStore.save([merge()], url: home.appending(path: DuplicateMergeDraftStore.fileName))
        try StagingStore.save([track()], url: home.appending(path: StagingStore.fileName))
        DamagedDrafts.preserveAll(home: home)
        #expect(DamagedDrafts.take(home: home).isEmpty)
        #expect(DuplicateMergeDraftStore.load(url: home.appending(path: DuplicateMergeDraftStore.fileName)) == [merge()])
        #expect(StagingStore.load(url: home.appending(path: StagingStore.fileName)).count == 1)
    }

    // MARK: - 앱: 읽기·저장·알림

    @MainActor func store(home: URL, fixture: RekordboxFixture? = nil) -> LibraryStore {
        let mergeURL = home.appending(path: DuplicateMergeDraftStore.fileName), stagedURL = home.appending(path: StagingStore.fileName)
        let store = LibraryStore(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture?.backups ?? home.appending(path: "backups"), playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { try DuplicateMergeDraftStore.save($0, url: mergeURL) },
                                 playlistImportURL: nil, stagingSaver: { try StagingStore.save($0, url: stagedURL) })
        store.draftHome = home
        return store
    }

    @Test @MainActor func 읽을_때_손상된_합치기_초안과_추가_목록을_옮기고_할_일까지_알린다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try broken.write(to: home.appending(path: DuplicateMergeDraftStore.fileName))
        try broken.write(to: home.appending(path: StagingStore.fileName))
        let store = store(home: home, fixture: fixture)
        await store.load(snapshot: fixture.database, arguments: ["test", "--db", fixture.database.path], environment: [:])
        #expect(preserved(in: home).count == 2 && preserved(in: home).allSatisfy { (try? Data(contentsOf: $0)) == broken })
        #expect(store.mergeDrafts.isEmpty && store.staged.isEmpty)
        let message = try #require(store.draftFileMessage)
        #expect(message.kind == .warning)
        // 합치기 초안은 초안 파일로 세고, 추가 목록은 다시 추가할 일을 따로 안내한다.
        #expect(message.text == LibraryStore.damagedDraftText(1, stagedList: true))
        #expect(message.text.contains("damaged-drafts") && message.text.contains("추가했던 곡 파일을 다시 추가하세요"))
        // 새 합치기 초안을 만들어도 보관한 파일은 그대로다.
        try store.setMergeDrafts([merge()])
        #expect(DuplicateMergeDraftStore.load(url: home.appending(path: DuplicateMergeDraftStore.fileName)) == [merge()])
        #expect(preserved(in: home).count == 2 && preserved(in: home).allSatisfy { (try? Data(contentsOf: $0)) == broken })
    }

    @Test @MainActor func 추가_목록만_손상됐으면_초안_파일_수에_세지_않고_추가_안내만_한다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try broken.write(to: home.appending(path: StagingStore.fileName))
        let store = store(home: home, fixture: fixture)
        await store.load(snapshot: fixture.database, arguments: ["test", "--db", fixture.database.path], environment: [:])
        #expect(store.draftFileMessage?.text == LibraryStore.damagedDraftText(0, stagedList: true))
        #expect(store.draftFileMessage?.text.contains("초안 파일") == false)
    }

    @Test @MainActor func 편집본을_넣다가_옮긴_추가_목록은_새_목록이_차_있어도_알린다() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try broken.write(to: home.appending(path: StagingStore.fileName))
        let output = try AudioFixture.wav(seconds: 4, in: home, name: "원곡 (Edit).wav")
        let edit = try TrackEdit(grid: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], sourceDuration: 4, bars: BarRange.list("1-1"))
        let staged = try await EditStaging.stage(fileAt: output, edit: edit, cues: [], source: nil, home: home)
        let store = store(home: home)
        store.showStagedEdit(staged)
        // 옛 추가 목록은 보관만 됐고 새로 읽은 목록에는 편집본뿐이므로 다시 추가할 일을 알려야 한다.
        #expect(store.staged.map(\.uuid) == [staged.uuid])
        #expect(store.draftFileMessage?.text == LibraryStore.damagedDraftText(0, stagedList: true))
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
    }

    @Test @MainActor func 합치기_초안_저장이_손상된_파일을_옮기면_메모리_초안이_비었을_때만_알린다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: DuplicateMergeDraftStore.fileName)
        let store = store(home: home)
        // 읽은 뒤 바깥에서 깨졌다. 메모리 초안을 새로 썼으니 잃은 것이 없어 알리지 않는다.
        try store.setMergeDrafts([merge("a")])
        try broken.write(to: url)
        try store.setMergeDrafts([merge("a"), merge("b")])
        #expect(DuplicateMergeDraftStore.load(url: url).count == 2)
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
        #expect(store.draftFileMessage == nil)
        // 메모리 초안이 비었는데 파일이 깨져 있었다: 옛 내용은 보관만 되므로 알린다.
        try store.setMergeDrafts([])
        try broken.write(to: url)
        try store.setMergeDrafts([])
        #expect(preserved(in: home).count == 2)
        #expect(store.draftFileMessage?.text == LibraryStore.damagedDraftText(1))
    }

    @Test @MainActor func 추가_목록_저장이_손상된_파일을_옮기면_메모리_목록이_비었을_때만_알린다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: StagingStore.fileName)
        let store = store(home: home)
        // 읽은 뒤 바깥에서 깨졌다. 메모리 목록을 새로 썼으니 잃은 것이 없어 알리지 않는다.
        store.staged = [track("a")]
        try broken.write(to: url)
        #expect(store.restage([track("b")]) == 1)
        #expect(StagingStore.load(url: url).map(\.path) == [track("a").path, track("b").path])
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
        #expect(store.draftFileMessage == nil)
        // 메모리 목록이 비었는데 파일이 깨져 있었다: 옛 목록은 보관만 되므로 다시 추가할 일을 알린다.
        try broken.write(to: url)
        #expect(store.unstage(uuids: Set(store.staged.map(\.uuid))).count == 2 && store.staged.isEmpty)
        #expect(preserved(in: home).count == 2)
        #expect(store.draftFileMessage?.text == LibraryStore.damagedDraftText(0, stagedList: true))
    }
}
