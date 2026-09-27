@testable import DJCrate
import DJCDomain
@testable import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

struct ITunesSyncTests {
    @MainActor private func store(backups: URL) -> LibraryStore {
        LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.itunes.sync.\(UUID())")!, persist: false),
                     resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, backupDirectory: backups,
                     playlistDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
    }
    let source: [ITunesLibrarySnapshot.Playlist] = [
        .init(id: "F", name: "폴더", isFolder: true),
        .init(id: "A", name: "동명", parentID: "F", paths: ["/b", "/a", "/b", nil]),
        .init(id: "B", name: "동명"),
    ]
    let base = Data("""
        <SYNC_ITUNES_PLAYLIST Version="3.0.0"><PLAYLISTS>
        <NODE Id="0" ParentId="0" Attribute="1" Timestamp="0" Lib_Type="1" CheckType="2"/>
        <NODE Id="B" ParentId="0" Attribute="0" Timestamp="100" Lib_Type="1" CheckType="1"/>
        </PLAYLISTS></SYNC_ITUNES_PLAYLIST>
        """.utf8)

    func snapshot() throws -> ITunesLibrarySnapshot {
        try ITunesLibrarySnapshot(playlists: [source[2]], sourcePlaylists: source).applyingRekordboxSelection(base)
    }

    @Test func 전체_원본을_보존하고_사용자_선택으로_교체한다() throws {
        let snapshot = try snapshot()
        let selected = try snapshot.applying(ITunesSyncSelection(selectedIDs: ["F"]))
        #expect(selected.playlists.map(\.id) == ["F", "A"])
        #expect(selected.playlists.last?.paths == ["/b", "/a", "/b", nil])
        #expect(selected.sourcePlaylists == source)
        #expect(try snapshot.applying(ITunesSyncSelection()).playlists.isEmpty)
    }

    @Test func 전체_선택을_다시_읽어도_루트_선택을_유지한다() throws {
        let snapshot = try snapshot()
        let data = try RekordboxITunesSyncChange(base: base, source: snapshot.selectionNodes,
                                                selection: .init(selectedIDs: ["0"])).render()
        let loaded = try snapshot.applyingRekordboxSelection(data)
        #expect(loaded.initialSelection.selectedIDs.contains("0"))
        #expect(loaded.initialSelection.expandedIDs(in: loaded.selectionNodes) == ["F", "A", "B"])
        #expect(loaded.unavailablePlaylistCount == 0)
    }

    @MainActor @Test func rekordbox에_적용한_선택만_표시하고_외부에서_바꾸면_다시_읽는다() async throws {
        let fixture = try RekordboxFixture(), snapshot = try snapshot()
        try snapshot.save(for: fixture.database)
        let syncURL = fixture.root.appending(path: "playlists3.sync")
        try base.write(to: syncURL)
        let store = store(backups: fixture.backups)
        await store.load(snapshot: fixture.database)
        store.sidebar = .itunesPlaylist("itunes:B")
        let before = try Data(contentsOf: fixture.database)
        try await store.syncITunesPlaylists(ITunesSyncSelection(selectedIDs: ["F"]), source: snapshot, database: fixture.database,
                                           arguments: ["DJCrate", "--db", fixture.database.path], environment: [:])
        #expect(store.iTunesLibrary.index["itunes:A"] != nil)
        #expect(store.iTunesLibrary.index["itunes:B"] == nil)
        #expect(store.sidebar == .filter(.all))
        #expect(try RekordboxITunesSelection.parse(Data(contentsOf: syncURL)).selectedIDs == ["F", "A"])
        await store.load(snapshot: fixture.database)
        #expect(store.iTunesLibrary.index["itunes:A"] != nil)
        #expect(store.iTunesLibrary.index["itunes:B"] == nil)
        #expect(try Data(contentsOf: fixture.database) == before)
        #expect(store.playlistDraft.isEmpty)
        // rekordbox에서 바꾼 선택이 DJCrate의 옛 로컬 선택에 가려지면 안 된다.
        try base.write(to: syncURL)
        await store.load(snapshot: fixture.database)
        #expect(store.iTunesLibrary.index["itunes:A"] == nil)
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
    }

    @MainActor @Test func 외부_변경과_출처_변경은_표시를_바꾸지_않는다() async throws {
        let fixture = try RekordboxFixture(), snapshot = try snapshot()
        try snapshot.save(for: fixture.database)
        let syncURL = fixture.root.appending(path: "playlists3.sync")
        try base.write(to: syncURL)
        let store = store(backups: fixture.backups)
        await store.load(snapshot: fixture.database)
        try (base + Data("\n".utf8)).write(to: syncURL)
        await #expect(throws: (any Error).self) {
            try await store.syncITunesPlaylists(ITunesSyncSelection(selectedIDs: ["F"]), source: snapshot, database: fixture.database,
                                               arguments: ["DJCrate", "--db", fixture.database.path], environment: [:])
        }
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
        #expect(!store.isWritingRekordbox)
        await #expect(throws: (any Error).self) {
            try await store.syncITunesPlaylists(ITunesSyncSelection(), source: snapshot, database: fixture.root.appending(path: "other.db"),
                                               arguments: ["DJCrate", "--db", fixture.database.path], environment: [:])
        }
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
        #expect(RekordboxWriter.backups(in: fixture.backups).isEmpty)
    }
}
