@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

@MainActor
@Suite("iTunes 사본 없는 쓰기 후 재로드")
struct ITunesMissingCacheReloadTests {
    @Test func 첫_Music_캡처_실패는_쓰기_후에도_실패로_남는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        let directory = fixture.root.appending(path: "snapshots")
        let sourceDB = fixture.database
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = try LibrarySnapshot.take(from: sourceDB, into: directory, force: true, now: stamp)
        let defaults = UserDefaults(suiteName: "djc.test.itunes-missing-cache.\(UUID())")!
        let store = LibraryStore(settings: SettingsStore(defaults: defaults, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                                 backupDirectory: fixture.backups, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })

        await store.load(snapshot: previous, refreshITunes: true, arguments: ["test"], environment: [:],
                         captureITunes: { ITunesLibrarySnapshot(status: .unavailable) })
        #expect(store.iTunesSnapshot.status == .unavailable)
        #expect(ITunesLibrarySnapshot.load(for: previous).status == .notCaptured)

        await store.takeSnapshot(force: true, quiet: true, refreshITunes: false, snapshotDirectory: directory,
                                 snapshotCopy: { force in
                                     try LibrarySnapshot.take(from: sourceDB, into: directory, force: force,
                                                              now: stamp.addingTimeInterval(60))
                                 }, captureITunes: {
                                     Issue.record("쓰기 후 Music을 다시 조회했습니다")
                                     return ITunesLibrarySnapshot()
                                 }, arguments: ["test"], environment: [:])

        #expect(!store.isLoading)
        #expect(store.iTunesSnapshot.status == .unavailable)
        #expect(store.iTunesSnapshot.status.message?.contains("Music 접근 권한") == true)
        #expect(ITunesLibrarySnapshot.load(for: try #require(store.snapshotURL)).status == .notCaptured)
    }

    @Test func 명시한_DB에_캐시가_없으면_미캡처_상태를_유지한다() throws {
        let fixture = try RekordboxFixture()
        let loaded = try LoadedLibrary.load(snapshot: fixture.database, refreshITunes: false,
                                            captureITunes: {
                                                Issue.record("명시한 DB를 읽을 때 Music을 조회했습니다")
                                                return ITunesLibrarySnapshot()
                                            })
        #expect(loaded.iTunesSnapshot.status == .notCaptured)
        #expect(loaded.iTunesLibrary.status.message == String(ui: "이 사본에는 캡처한 iTunes 목록이 없습니다"),
                "읽기가 끝난 명시적 사본을 스냅샷 생성 중으로 표시하지 않는다")
    }

    @Test func 이전도_미캡처인_완료된_재로드는_진행중으로_표시하지_않는다() throws {
        let fixture = try RekordboxFixture()
        let previous = fixture.root.appending(path: "previous.db")
        let loaded = try LoadedLibrary.load(snapshot: fixture.database,
                                            previousITunesSnapshot: .init(source: previous,
                                                contents: ITunesLibrarySnapshot(status: .notCaptured),
                                                preferOverCurrent: true),
                                            captureITunes: {
                                                Issue.record("쓰기 후 Music을 다시 조회했습니다")
                                                return ITunesLibrarySnapshot()
                                            })
        #expect(loaded.iTunesSnapshot.status == .unavailable)
        #expect(ITunesLibrarySnapshot.load(for: fixture.database).status == .notCaptured)
    }

    @Test(arguments: [ITunesLibrarySnapshot.Status.ready, .stale])
    func 현재_사용가능한_캐시는_이전_실패나_미캡처보다_우선한다(status: ITunesLibrarySnapshot.Status) throws {
        let fixture = try RekordboxFixture()
        let current = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "현재 목록")], status: status)
        try current.save(for: fixture.database)
        let previous = fixture.root.appending(path: "previous.db")
        for oldStatus in [ITunesLibrarySnapshot.Status.unavailable, .notCaptured] {
            let loaded = try LoadedLibrary.load(snapshot: fixture.database,
                                                previousITunesSnapshot: .init(source: previous,
                                                    contents: ITunesLibrarySnapshot(status: oldStatus),
                                                    preferOverCurrent: true))
            #expect(loaded.iTunesSnapshot.status == status)
            #expect(loaded.iTunesSnapshot.playlists == current.playlists)
        }
    }
}
