import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// #159 화면·쓰기 자가 테스트용 합성 사본. 개인 라이브러리와 음원은 쓰지 않는다.
/// `DJC_SYNC_FIXTURE=<임시 폴더> swift test --filter SyncWriteFixtureCapture`
/// 사본의 `home`을 DJC_HOME으로, `rekordbox`를 DJC_REKORDBOX_DIR로 준다.
struct SyncWriteFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_SYNC_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_SYNC_FIXTURE"] else { return }
        let root = URL(filePath: path).resolvingSymlinksInPath()
        let temporary = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        #expect(root.path.hasPrefix(temporary + "/") || root.path.hasPrefix("/private/tmp/"))
        guard root.path.hasPrefix(temporary + "/") || root.path.hasPrefix("/private/tmp/") else { return }
        let fixture = try RekordboxFixture()
        let destination = root.appending(path: "rekordbox")
        let home = root.appending(path: "home")
        let first = AnlzBuilder.beats(bpm: 244, first: 500.3, count: 9)
        let second = AnlzBuilder.beats(bpm: 128, first: first.last!.time + 60_000 / 244, count: 100)
        let titles = ["合成テスト・グリッド", "合成テスト・インスペクター", "合成テスト・一覧"]
        for (index, title) in titles.enumerated() {
            var track = TrackSpec(id: String(101 + index), uuid: "00000000-0000-0000-0000-00000000010\(index + 1)")
            track.title = title
            track.fileType = 11
            track.length = 60
            let audio = try AudioFixture.wav(seconds: 60, in: fixture.audio, name: "sync-\(index).wav")
            track.folderPath = destination.appending(path: "audio/\(audio.lastPathComponent)").path
            track.analysisDataPath = "/PIONEER/USBANLZ/\(track.uuid.prefix(3))/\(track.uuid.dropFirst(3))/ANLZ0000.DAT"
            track.bpm100 = index == 0 ? 24400 : 12800
            try fixture.add(track)
            try fixture.execute("UPDATE djmdContent SET rb_data_status = 0, Commnt = '元のコメント' WHERE ID = ?", [.text(track.id)])
            let beats = index == 0 ? first + second : AnlzBuilder.beats(bpm: 128, first: 500.3, count: 126)
            try fixture.putAnalysis(for: track, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
            if index == 0 {
                var grid = GridDraft(trackUUID: track.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: track)))
                #expect(grid.base.count == 2 && abs(grid.base[0].bpm - 244) > 0.01)
                grid.shift(by: 0.01)
                try GridDraftStore.save(grid, directory: home.appending(path: "grid-drafts"))
            }
        }
        try fixture.add(PlaylistSpec(id: "1001", name: "합성 목록", seq: 1, contentIDs: ["101", "102"]))
        let track = try #require(RekordboxLibrary.load(snapshot: fixture.database).tracks.first { $0.id == "101" })
        var tag = TagDraft(trackUUID: track.uuid, base: TagFields(track: track))
        tag.fields.comment = "日本語の合成コメント\n二行目・保存確認"
        try TagDraftStore.save(tag, directory: home.appending(path: "tag-drafts"))
        #expect(TagDraftStore.load(trackUUID: track.uuid, directory: home.appending(path: "tag-drafts")) == tag)
        try FileManager.default.copyItem(at: fixture.root, to: destination)
    }
}
