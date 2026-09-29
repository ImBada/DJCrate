import DJCDomain
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// USB 수정 엔진의 재생 목록 편집(두 형식 목록 규칙). 합성 USB만 쓴다
extension UsbEditEngineTests {
    @Test("재생 목록 편집 8종: 만들기·이름·옮기기·순서·지우기·곡 넣기·곡 빼기·곡 옮기기")
    func playlistEditsEightKinds() throws {
        let env = try Self.exported()
        let (result, report) = try env.edit([
            .playlist(edit: .create(key: "f", name: "합성 폴더", isFolder: true, parent: .root)),
            .playlist(edit: .create(key: "l", name: "합성 새 목록", isFolder: false, parent: .new("f"))),
            .playlist(edit: .rename(playlist: .id("1"), name: "합성 바뀐 이름")),
            .playlist(edit: .move(playlist: .id("1"), into: .new("f"))),
            .playlist(edit: .reorder(playlist: .id("1"), index: 0)),
            .playlist(edit: .addTracks(playlist: .new("l"), contentIDs: ["3", "1"])),
            .playlist(edit: .moveTracks(playlist: .new("l"), entries: [PlaylistEntry(trackNo: 2, contentID: "1")], to: 1)),
            .playlist(edit: .removeTracks(playlist: .id("1"), entries: [PlaylistEntry(trackNo: 2, contentID: "2")])),
            .playlist(edit: .create(key: "d", name: "합성 지울 목록", isFolder: false, parent: .root)),
            .playlist(edit: .delete(playlist: .new("d"))),
        ])
        #expect(result.outcomes.allSatisfy { $0.outcome == .written })
        #expect(report.outcome == .written)
        #expect(result.changes?.requiredRules.isSuperset(of: [.editPlaylists, .playlistSiblingBase, .playlistFolderRow]) == true)
        let after = try env.read()
        let byID = Dictionary(uniqueKeysWithValues: after.playlists.map { ($0.id, $0) })
        #expect(Set(byID.keys) == [1, 2, 3])
        let folder = try #require(byID[2]), list = try #require(byID[3]), moved = try #require(byID[1])
        #expect(folder.attribute == 1 && folder.parentID == 0 && folder.sortOrder == [.oneLibrary: 1, .deviceLibrary: 1])
        #expect(moved.name == "합성 바뀐 이름" && moved.parentID == 2 && moved.sortOrder == [.oneLibrary: 0, .deviceLibrary: 0])
        #expect(list.parentID == 2 && list.sortOrder == [.oneLibrary: 1, .deviceLibrary: 1])
        #expect(list.entries[.oneLibrary] == [1, 3] && list.entries[.deviceLibrary] == [1, 3])
        #expect(moved.entries[.oneLibrary] == [1, 3] && moved.entries[.deviceLibrary] == [1, 3])
        #expect(after.playlists.allSatisfy { $0.presentIn == UsbFormat.defaultSet })
    }

    @Test("항목을 고친 목록은 OneLibrary 항목 번호를 1..N으로 다시 매긴다")
    func entriesRenumbered1toN() throws {
        let env = try Self.exported()
        try env.edit([.playlist(edit: .removeTracks(playlist: .id("1"), entries: [PlaylistEntry(trackNo: 1, contentID: "1")]))])
        let rows = try env.oneLibraryRows("SELECT content_id, sequenceNo FROM playlist_content WHERE playlist_id = 1 ORDER BY rowid")
        #expect(rows.map { $0["content_id"] } == ["2", "3"])
        #expect(rows.map { $0["sequenceNo"] } == ["1", "2"])
        #expect(try env.read(.deviceLibrary)?.playlists.first?.entries[.deviceLibrary] == [2, 3])
    }

    @Test("두 형식의 항목이 다른 목록은 곡 편집을 막고 이름 바꾸기는 한다")
    func entriesDifferBlocksEntryEdits_renameAllowed() throws {
        let env = try Self.rekordboxStyle {
            $0.playlists = [UsbLibraryFixture.Playlist(id: 10, name: "합성 목록", oneLibraryEntries: [1, 2], deviceLibraryEntries: [2, 1, 2])]
        }
        let result = try env.plan([
            .playlist(edit: .addTracks(playlist: .id("10"), contentIDs: ["3"])),
            .playlist(edit: .removeTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 1, contentID: "1")])),
            .playlist(edit: .moveTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 1, contentID: "1")], to: 2)),
            .playlist(edit: .rename(playlist: .id("10"), name: "합성 바뀐 이름")),
        ], withLocal: false)
        for index in 1...3 {
            guard case let .blocked(block) = result.outcome(index) else { Issue.record("막지 않음 \(index)"); continue }
            #expect(block.code == "playlistEntriesDiffer" && block.message.contains("이름·위치만"))
        }
        #expect(result.outcome(4) == .written)
        #expect(result.notes.contains("형식 사이 목록 불일치 1"))
        #expect(try env.write(result).outcome == .written)
        let after = try env.read()
        #expect(after.playlists.first?.entries[.oneLibrary] == [1, 2] && after.playlists.first?.entries[.deviceLibrary] == [2, 1, 2])
    }

    @Test("새 목록은 USB에 있고 이번에 막히지 않은 형식에만 만든다")
    func createPresentInWritableFormats() throws {
        let env = try Self.exported()
        env.setPdbFlag(4)
        let (result, _) = try env.edit([.playlist(edit: .create(key: "n", name: "합성 새 목록", isFolder: false, parent: .root))])
        #expect(result.applied?.playlists.first { $0.id == 2 }?.presentIn == [.oneLibrary])
        #expect(try env.read(.oneLibrary)?.playlists.map(\.id) == [1, 2])
        #expect(try env.read(.deviceLibrary)?.playlists.map(\.id) == [1])
    }

    @Test("Device Library가 막힌 USB에서는 두 형식에 있는 목록의 이름·부모를 바꾸지 않아 다음 편집이 USB 전체 막힘이 되지 않는다")
    func renameMoveBlockedWhileFormatBlocked() throws {
        let env = try Self.exported()
        // 두 형식에 폴더를 만들고 목록을 넣어 둔 뒤 Device Library를 막는다
        let (setup, _) = try env.edit([.playlist(edit: .create(key: "f", name: "합성 폴더", isFolder: true, parent: .root)),
                                       .playlist(edit: .move(playlist: .id("1"), into: .new("f")))], withLocal: false)
        #expect(setup.outcomes.allSatisfy { $0.outcome == .written })
        env.setPdbFlag(4)
        let (result, report) = try env.edit([
            .playlist(edit: .rename(playlist: .id("1"), name: "합성 바뀐 이름")),
            .playlist(edit: .move(playlist: .id("1"), into: .root)),
            .playlist(edit: .reorder(playlist: .id("1"), index: 0)),
            .playlist(edit: .create(key: "n", name: "합성 새 목록", isFolder: false, parent: .root)),
        ], withLocal: false)
        for index in 1...2 {
            guard case let .blocked(block) = result.outcome(index) else { Issue.record("막지 않음 \(index)"); continue }
            #expect(block.code == "playlistInBlockedFormat" && block.message.contains("Device Library"))
        }
        #expect(result.outcome(3) == .unchanged && result.outcome(4) == .written)
        #expect(report.outcome == .written)
        let source = try env.source()
        #expect(source.blocks.isEmpty)
        #expect(!source.mismatches.contains { if case .playlistConflict = $0 { true } else { false } })
        // 다음 편집도 USB 전체 막힘이 아니다
        let next = try env.plan([.removeTracks(usbContentIDs: [3])], withLocal: false)
        #expect(next.blocks.isEmpty && next.changes != nil)
        // 한 형식에만 있는 목록은 이름을 바꾼다
        let created = try #require(try env.read(.oneLibrary)?.playlists.first { $0.name == "합성 새 목록" })
        let renamed = try env.plan([.playlist(edit: .rename(playlist: .id(String(created.id)), name: "합성 바뀐 새 목록"))], withLocal: false)
        #expect(renamed.outcome(1) == .written)
    }

    @Test("형제 순번은 그 부모의 기존 형제를 따라 가장 큰 값 + 1, 형제가 없으면 0")
    func siblingBaseFollowsExisting() throws {
        let env = try Self.rekordboxStyle {
            var first = UsbLibraryFixture.Playlist(id: 10, name: "합성 목록 하나", entries: [1])
            first.sortOrder = 1
            var second = UsbLibraryFixture.Playlist(id: 11, name: "합성 목록 둘", entries: [2])
            second.sortOrder = 2
            $0.playlists = [first, second]
        }
        let result = try env.plan([
            .playlist(edit: .create(key: "a", name: "합성 새 목록", isFolder: false, parent: .root)),
            .playlist(edit: .create(key: "f", name: "합성 폴더", isFolder: true, parent: .root)),
            .playlist(edit: .create(key: "b", name: "합성 폴더 안", isFolder: false, parent: .new("f"))),
            .playlist(edit: .reorder(playlist: .id("11"), index: 0)),
        ], withLocal: false)
        let playlists = Dictionary(uniqueKeysWithValues: try #require(result.applied).playlists.map { ($0.name, $0) })
        #expect(playlists["합성 새 목록"]?.sortOrder == [.oneLibrary: 3, .deviceLibrary: 3])
        #expect(playlists["합성 폴더"]?.sortOrder == [.oneLibrary: 4, .deviceLibrary: 4])
        #expect(playlists["합성 폴더 안"]?.sortOrder == [.oneLibrary: 0, .deviceLibrary: 0])
        // 순서 바꾸기도 시작값(1)을 지킨다
        #expect(playlists["합성 목록 둘"]?.sortOrder == [.oneLibrary: 1, .deviceLibrary: 1])
        #expect(playlists["합성 목록 하나"]?.sortOrder == [.oneLibrary: 2, .deviceLibrary: 2])
        #expect(try env.write(result).outcome == .written)
    }

    @Test("한 형식에만 있는 목록은 다른 형식에 만들지 않는다")
    func oneFormatOnlyPlaylistNotCreatedInOther() throws {
        let env = try Self.rekordboxStyle {
            var only = UsbLibraryFixture.Playlist(id: 11, name: "합성 한 형식 목록", entries: [3])
            only.formats = [.oneLibrary]
            $0.playlists = [UsbLibraryFixture.Playlist(id: 10, name: "합성 목록", entries: [1, 2]), only]
        }
        let (result, _) = try env.edit([
            .playlist(edit: .rename(playlist: .id("11"), name: "합성 바뀐 이름")),
            .playlist(edit: .addTracks(playlist: .id("11"), contentIDs: ["1"])),
        ], withLocal: false)
        #expect(result.outcome(1) == .written && result.outcome(2) == .written)
        #expect(try env.read(.deviceLibrary)?.playlists.map(\.id) == [10])
        let one = try #require(try env.read(.oneLibrary)?.playlists.first { $0.id == 11 })
        #expect(one.name == "합성 바뀐 이름" && one.entries[.oneLibrary] == [3, 1])
    }

    @Test("폴더가 아닌 곳에 넣기·자기 안으로 옮기기·항목 자리가 다른 편집은 막는다")
    func playlistEditBlocks() throws {
        let env = try Self.exported()
        let result = try env.plan([
            .playlist(edit: .create(key: "f", name: "합성 폴더", isFolder: true, parent: .root)),
            .playlist(edit: .create(key: "x", name: "합성", isFolder: false, parent: .id("1"))),
            .playlist(edit: .move(playlist: .new("f"), into: .new("f"))),
            .playlist(edit: .removeTracks(playlist: .id("1"), entries: [PlaylistEntry(trackNo: 1, contentID: "2")])),
            .playlist(edit: .addTracks(playlist: .new("f"), contentIDs: ["1"])),
            .playlist(edit: .create(key: "f", name: "합성 같은 key", isFolder: false, parent: .root)),
            .playlist(edit: .rename(playlist: .id("1"), name: "합성 목록")),
        ], withLocal: false)
        #expect(result.outcome(1) == .written)
        #expect(Self.isBlocked(result.outcome(2), "notFolder"))
        #expect(Self.isBlocked(result.outcome(3), "moveIntoSelf"))
        #expect(Self.isBlocked(result.outcome(4), "entryMismatch"))
        #expect(Self.isBlocked(result.outcome(5), "notTrackList"))
        #expect(Self.isBlocked(result.outcome(6), "duplicateKey"))
        // 이름이 같으면 바꿀 것이 없다
        #expect(result.outcome(7) == .unchanged)
    }
}
