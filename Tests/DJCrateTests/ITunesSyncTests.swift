@testable import DJCrate
import DJCDomain
@testable import DJCStorage
import DJCTestSupport
import Foundation
import Testing

struct ITunesSyncTests {
    @MainActor private func store(selectionURL: URL) -> LibraryStore {
        LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.itunes.sync.\(UUID())")!, persist: false),
                     resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in },
                     playlistImportURL: nil, iTunesSelectionURL: selectionURL, stagingSaver: { _ in })
    }
    let source: [ITunesLibrarySnapshot.Playlist] = [
        .init(id: "F", name: "폴더", isFolder: true),
        .init(id: "A", name: "동명", parentID: "F", paths: ["/b", "/a", "/b", nil]),
        .init(id: "B", name: "동명"),
    ]

    @Test func 전체_원본을_보존하고_사용자_선택으로_교체한다() throws {
        let snapshot = ITunesLibrarySnapshot(playlists: [source[2]], sourcePlaylists: source)
        let selected = try snapshot.applying(ITunesSyncSelection(selectedIDs: ["F"]))
        #expect(selected.playlists.map(\.id) == ["F", "A"])
        #expect(selected.playlists.last?.paths == ["/b", "/a", "/b", nil])
        #expect(selected.sourcePlaylists == source)
        #expect(try snapshot.applying(ITunesSyncSelection()).playlists.isEmpty)
    }

    @Test func 저장한_빈_선택은_설정_없음과_다르다() throws {
        let fixture = try RekordboxFixture()
        let url = fixture.root.appending(path: "selection.json")
        #expect(try ITunesSyncSelectionStore.load(url: url) == nil)
        try ITunesSyncSelectionStore.save(ITunesSyncSelection(), url: url)
        #expect(try ITunesSyncSelectionStore.load(url: url)?.selectedIDs == [])
        try Data("broken".utf8).write(to: url)
        #expect(throws: (any Error).self) { try ITunesSyncSelectionStore.load(url: url) }
    }

    @MainActor @Test func 적용하면_즉시_목록을_바꾸고_다시_열어도_유지하며_DB는_불변이다() async throws {
        let fixture = try RekordboxFixture()
        let snapshot = ITunesLibrarySnapshot(playlists: [source[2]], sourcePlaylists: source)
        try snapshot.save(for: fixture.database)
        let selectionURL = fixture.root.appending(path: "selection.json")
        let store = store(selectionURL: selectionURL)
        await store.load(snapshot: fixture.database)
        store.sidebar = .itunesPlaylist("itunes:B")
        let before = try Data(contentsOf: fixture.database)
        try store.syncITunesPlaylists(ITunesSyncSelection(selectedIDs: ["F"]), source: snapshot, database: fixture.database)
        #expect(store.iTunesLibrary.index["itunes:A"] != nil)
        #expect(store.iTunesLibrary.index["itunes:B"] == nil)
        #expect(store.sidebar == .filter(.all))
        await store.load(snapshot: fixture.database)
        #expect(store.iTunesLibrary.index["itunes:A"] != nil)
        #expect(store.iTunesLibrary.index["itunes:B"] == nil)
        #expect(try Data(contentsOf: fixture.database) == before)
        #expect(store.playlistDraft.isEmpty)
        var refreshed = snapshot
        refreshed.sourcePlaylists?.append(.init(id: "D", name: "나중에 추가", parentID: "F"))
        try refreshed.save(for: fixture.database)
        await store.load(snapshot: fixture.database)
        #expect(store.iTunesLibrary.index["itunes:D"] != nil)
        #expect(store.iTunesLibrary.index["itunes:B"] == nil)
        try store.syncITunesPlaylists(ITunesSyncSelection(), source: snapshot, database: fixture.database)
        await store.load(snapshot: fixture.database)
        #expect(store.iTunesLibrary.tree.isEmpty)
    }

    @MainActor @Test func 저장_실패와_출처_변경은_표시와_선택을_바꾸지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let snapshot = ITunesLibrarySnapshot(playlists: [source[2]], sourcePlaylists: source)
        try snapshot.save(for: fixture.database)
        let store = store(selectionURL: fixture.root)
        await store.load(snapshot: fixture.database)
        #expect(throws: (any Error).self) {
            try store.syncITunesPlaylists(ITunesSyncSelection(selectedIDs: ["F"]), source: snapshot, database: fixture.database)
        }
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
        #expect(throws: (any Error).self) {
            try store.syncITunesPlaylists(ITunesSyncSelection(), source: snapshot, database: fixture.root.appending(path: "other.db"))
        }
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
    }
}
