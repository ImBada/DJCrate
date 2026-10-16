import DJCDomain
import Foundation
import Testing

/// LINK로 내어 줄 라이브러리(#273): 내어 줄 곡 고르기, 번호 매기기, 형식 번호, 큐, 재생 목록 나무.
@Suite("LINK 라이브러리 만들기")
struct LinkLibraryTests {
    static func row(_ id: String, path: String = "/Users/dj/Music/Song.mp3", deleted: Bool = false, cues: [Cue] = [],
                    missing: Bool = false) -> TrackRow {
        let track = Track(id: id, uuid: "uuid-\(id)", title: "곡 \(id)", artist: "아티스트", album: nil, albumArtist: nil, genre: "House",
                          composer: nil, releaseYear: nil, trackNumber: nil, key: "Am", bpm: 124.5, lengthSeconds: 200,
                          folderPath: path, comment: "메모", importedOn: nil,
                          analysisDataPath: "/PIONEER/USBANLZ/P01/0001/ANLZ0000.DAT", imagePath: nil, isDeleted: deleted,
                          bitrateKbps: 320, rating: 3)
        var row = TrackRow(track: track, cues: cues, playCount: 0)
        row.fileMissing = missing
        return row
    }

    static func cue(kind: Int, at ms: Int, out: Int = 0, color: Int? = nil) -> Cue {
        Cue(id: "c\(kind)-\(ms)", contentID: "1", kind: kind, inMsec: ms, name: "", colorTableIndex: color, outMsec: out)
    }

    @Test func 내어_줄_수_없는_곡은_빼고_번호는_1부터_차례로_매긴다() {
        let rows = [
            Self.row("10"),
            Self.row("djc-1"),
            Self.row("usb:VOL:5"),
            Self.row("11", deleted: true),
            Self.row("12", path: "spotify:track:x"),
            Self.row("13", missing: true),
            Self.row("14", path: "/Users/dj/Music/Song.ogg"),
            Self.row("15", path: "/Users/dj/Music/Song.wav"),
        ]
        let library = LinkLibrary.build(rows: rows, playlists: PlaylistLayout())
        #expect(library.tracks.map(\.contentID) == ["10", "15"])
        #expect(library.tracks.map(\.id) == [1, 2])
        #expect(library.linkID(of: "15") == 2)
        #expect(library.linkID(of: "djc-1") == nil)
        #expect(library.linkID(of: "13") == nil)
    }

    @Test func 곡_값을_옮긴다() throws {
        let track = try #require(LinkLibrary.build(rows: [Self.row("10")], playlists: PlaylistLayout()).tracks.first)
        #expect(track.title == "곡 10")
        #expect(track.key == "Am")
        #expect(track.bpmX100 == 12450)
        #expect(track.lengthSeconds == 200)
        #expect(track.path == "/Users/dj/Music/Song.mp3")
        #expect(track.analysisPath == "/PIONEER/USBANLZ/P01/0001/ANLZ0000.DAT")
        #expect(track.fileType == 1)
        #expect(track.bitrateKbps == 320)
        #expect(track.rating == 3)
    }

    @Test func 형식_번호는_rekordbox_번호를_쓰고_모르는_형식은_뺀다() {
        #expect(LinkLibrary.fileType(ofExtension: "MP3") == 1)
        #expect(LinkLibrary.fileType(ofExtension: "wav") == 11)
        #expect(LinkLibrary.fileType(ofExtension: "aiff") == 12)
        #expect(LinkLibrary.fileType(ofExtension: "m4a") == 4)
        #expect(LinkLibrary.fileType(ofExtension: "flac") == 5)
        #expect(LinkLibrary.fileType(ofExtension: "ogg") == nil)
    }

    @Test func 메모리_큐와_A부터_H까지의_핫_큐만_옮긴다() throws {
        let cues = [Self.cue(kind: 0, at: 1000), Self.cue(kind: 1, at: 2000, color: 3), Self.cue(kind: 4, at: 3000),
                    Self.cue(kind: 9, at: 4000, out: 8000)]
        let track = try #require(LinkLibrary.build(rows: [Self.row("10", cues: cues)], playlists: PlaylistLayout()).tracks.first)
        #expect(track.cues == [
            LinkLibrary.Cue(positionMs: 1000, outMs: 0, hotCue: nil, colour: 0),
            LinkLibrary.Cue(positionMs: 2000, outMs: 0, hotCue: "A", colour: 3),
            LinkLibrary.Cue(positionMs: 4000, outMs: 8000, hotCue: "H", colour: 0),
        ])
    }

    @Test func 재생_목록은_폴더_나무와_곡_순서를_지키고_스마트_목록과_못_내어_주는_곡은_뺀다() {
        let layout = PlaylistLayout([
            (PlaylistLayout.Item(id: "f", name: "201X", isFolder: true), 0),
            (PlaylistLayout.Item(id: "p1", name: "Bass House", parentID: "f",
                                 entries: [PlaylistEntry(trackNo: 1, contentID: "11"), PlaylistEntry(trackNo: 2, contentID: "djc-1"),
                                           PlaylistEntry(trackNo: 3, contentID: "10"), PlaylistEntry(trackNo: 4, contentID: "11")]), 0),
            (PlaylistLayout.Item(id: "s", name: "Smart", isSmart: true), 1),
            (PlaylistLayout.Item(id: "p2", name: "Dance"), 2),
        ])
        let library = LinkLibrary.build(rows: [Self.row("10"), Self.row("11"), Self.row("djc-1")], playlists: layout)
        #expect(library.playlists == [
            LinkLibrary.Playlist(name: "201X", parent: nil, isFolder: true, trackIDs: []),
            LinkLibrary.Playlist(name: "Bass House", parent: 0, isFolder: false, trackIDs: [2, 1, 2]),
            LinkLibrary.Playlist(name: "Dance", parent: nil, isFolder: false, trackIDs: []),
        ])
    }
}
