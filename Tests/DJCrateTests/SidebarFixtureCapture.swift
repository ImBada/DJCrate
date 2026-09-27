import DJCStorage
import DJCDomain
import RekordboxKit
import DJCTestSupport
import Foundation
import Testing

/// 사이드바 섹션을 모두 채운 합성 사본(#120): rekordbox 재생 목록·iTunes 동기화 목록·재생 기록.
struct SidebarFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_SIDEBAR_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_SIDEBAR_FIXTURE"] else { return }
        let root = URL(filePath: path), fixture = try RekordboxFixture()
        var paths: [String] = []
        for index in 1...6 {
            let audio = try AudioFixture.wav(seconds: 2, in: fixture.audio, name: "sidebar-\(index).wav")
            var track = TrackSpec(id: String(index))
            track.title = "사이드바 시험 \(index)"
            track.folderPath = root.appending(path: "audio/\(audio.lastPathComponent)").path
            track.fileType = 11
            track.length = 2
            try fixture.add(track)
            paths.append(track.folderPath)
        }
        try fixture.add(PlaylistSpec(id: "10", name: "합성 폴더", seq: 1, isFolder: true))
        try fixture.add(PlaylistSpec(id: "11", name: "합성 목록 A", parentID: "10", seq: 1, contentIDs: ["1", "2", "3"]))
        try fixture.add(PlaylistSpec(id: "12", name: "합성 목록 B", seq: 2, contentIDs: ["4", "5"]))
        for (id, name, date, seq) in [("h1", "합성 기록", "2026-09-01", 1), ("h2", "합성 기록", "2026-09-14", 2)] {
            try fixture.insert("djmdHistory", ["ID": .text(id), "Name": .text(name), "DateCreated": .text(date),
                "Seq": .int(seq), "Attribute": .int(0), "ParentID": .text("root"), "rb_local_deleted": .int(0)])
            try fixture.insert("djmdSongHistory", ["ID": .text("\(id)-1"), "HistoryID": .text(id),
                "ContentID": .text("1"), "TrackNo": .int(1), "rb_local_deleted": .int(0)])
        }
        try FileManager.default.copyItem(at: fixture.root, to: root)
        let selected: [ITunesLibrarySnapshot.Playlist] = [
            .init(id: "F", name: "iTunes 합성 폴더", isFolder: true),
            .init(id: "A", name: "iTunes 합성 목록", parentID: "F", paths: [paths[0], paths[1]]),
        ]
        var snapshot = ITunesLibrarySnapshot(playlists: selected, sourcePlaylists: selected, selectedIDs: ["A"])
        let empty = Data("<SYNC_ITUNES_PLAYLIST Version=\"3.0.0\"><PLAYLISTS/></SYNC_ITUNES_PLAYLIST>".utf8)
        let data = try RekordboxITunesSyncChange(base: empty, source: snapshot.selectionNodes,
                                                selection: ITunesSyncSelection(selectedIDs: ["A"])).render()
        snapshot = try snapshot.applyingRekordboxSelection(data)
        try data.write(to: root.appending(path: "playlists3.sync"))
        try snapshot.save(for: root.appending(path: "master.db"))
    }
}
