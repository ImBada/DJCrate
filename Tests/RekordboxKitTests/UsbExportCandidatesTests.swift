import DJCDomain
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// 합성 라이브러리(구조만 있는 DB + 임시 share·음원)에서 USB 내보내기 후보를 읽는다.
@Suite("USB 내보내기 후보 읽기")
struct UsbExportCandidatesTests {
    /// 지어낸 마스터 DB ID
    let dbid = "424242"

    func open(_ fixture: RekordboxFixture) throws -> CipherDatabase {
        try CipherDatabase(path: fixture.database.path, key: RekordboxKey.derive())
    }

    /// 음원 파일·분석 파일 셋이 모두 있는 곡
    @discardableResult
    func addTrack(_ fixture: RekordboxFixture, id: String, bytes: Int = 300, analysis: String? = nil) throws -> TrackSpec {
        var track = TrackSpec(id: id)
        track.folderPath = try fixture.writeAudio(named: "\(id).mp3", bytes: bytes).path
        try fixture.add(track)
        try fixture.setIdentity(track: track, masterSongID: "9\(id)", masterDBID: dbid, fileNameL: "\(id).mp3")
        try fixture.setFileSize(track: track, Int64(bytes))
        let path = analysis ?? "/PIONEER/USBANLZ/a\(id)/b\(id)/ANLZ0000.DAT"
        try fixture.setAnalysisPath(track: track, path)
        try fixture.writeLocalAnalysis(analysisPath: path, dat: Data(count: 10), ext: Data(count: 20), twoEx: Data(count: 30))
        return track
    }

    @Test("곡 칸·크기·분석·아트워크·큐를 그대로 옮긴다")
    func readsSizesAnalysisArtworkCues() throws {
        let fixture = try RekordboxFixture()
        try fixture.addArtist(id: "1", name: "Track Artist")
        try fixture.addArtist(id: "2", name: "Album Artist")
        try fixture.addAlbum(id: "5", name: "Album", albumArtistID: "2", compilation: 1)
        var track = TrackSpec(id: "101")
        track.title = "Title"
        track.fileType = 4
        track.artistID = "1"
        track.albumID = "5"
        track.folderPath = try fixture.writeAudio(named: "a.m4a", bytes: 1_234).path
        track.cues = [CueSpec(kind: 0, inMsec: 1_000)]
        try fixture.add(track)
        try fixture.setIdentity(track: track, masterSongID: "777", masterDBID: dbid, fileNameL: "a.m4a")
        try fixture.setFileSize(track: track, 1_234)
        try fixture.setAnalysisPath(track: track, "/PIONEER/USBANLZ/x/y/ANLZ0000.DAT")
        let modified = Date(timeIntervalSince1970: 1_750_000_000)
        try fixture.writeLocalAnalysis(analysisPath: "/PIONEER/USBANLZ/x/y/ANLZ0000.DAT", dat: Data(count: 10), ext: Data(count: 20),
                                       twoEx: Data(count: 30), modified: modified)
        try fixture.writeArtwork(track: track, imagePath: "/PIONEER/Artwork/00/abc/artwork.jpg", small: Data(count: 11), medium: Data(count: 22))
        try fixture.setMetadata(track: track, rating: 3, searchStr: "tt")
        try fixture.setStrings(track: track, comment: "comment", isrc: "ISRC0", releaseDate: "2026-01-01")

        let db = try open(fixture)
        let candidates = try UsbExportCandidates.load(database: db, share: fixture.shareRoot, contentIDs: ["101"])
        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(candidate.localContentID == "101")
        #expect(candidate.masterSongID == "777")
        #expect(candidate.masterDBID == dbid)
        // 폴더는 곡 아티스트(앨범 아티스트가 아님)
        #expect(candidate.artistName == "Track Artist")
        #expect(candidate.albumName == "Album")
        #expect(candidate.fileNameL == "a.m4a")
        #expect(candidate.sourcePath == track.folderPath)
        #expect(!candidate.isStreaming)
        #expect(candidate.fileType == 4)
        #expect(candidate.fileSize == 1_234)
        #expect(candidate.actualFileSize == 1_234)
        #expect(candidate.analysis == .complete)
        #expect(candidate.analysisModifiedAt == modified)
        #expect(candidate.analysisFileBytes == [10, 20, 30])
        #expect(candidate.artwork?.smallBytes == 11)
        #expect(candidate.artwork?.mediumBytes == 22)
        #expect(!candidate.artworkPathSetButMissing)
        #expect(candidate.cues == [UsbCueTraits(kind: 0, colorTableIndex: nil, color: -1, inMsec: 1_000, outMsec: -1)])
        #expect(candidate.metadata == UsbTrackMetadataFlags(hasRating: true, hasSearchString: true, isCompilation: true))
        #expect(Set(candidate.pdbStrings).isSuperset(of: ["Title", "comment", "ISRC0", "2026-01-01"]))
    }

    @Test("분석 파일 경로는 DB 값 그대로(ANLZ0000으로 가정하지 않음)")
    func analysisPathFromShareNotANLZ0000() throws {
        let fixture = try RekordboxFixture()
        try addTrack(fixture, id: "201", analysis: "/PIONEER/USBANLZ/p/q/ANLZ0001.DAT")
        let candidate = try #require(try UsbExportCandidates.load(database: open(fixture), share: fixture.shareRoot, contentIDs: ["201"]).first)
        #expect(candidate.analysis == .complete)
        #expect(!FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/USBANLZ/p/q/ANLZ0000.DAT").path))
    }

    @Test("아트워크는 ImagePath와 같은 폴더의 작은·중간 그림")
    func artworkSameFolderSmallMedium() throws {
        let fixture = try RekordboxFixture()
        let track = try addTrack(fixture, id: "301")
        try fixture.writeArtwork(track: track, imagePath: "/PIONEER/Artwork/01/def/artwork.jpg", small: Data(count: 5), medium: Data(count: 7))
        let artwork = try #require(try UsbExportCandidates.load(database: open(fixture), share: fixture.shareRoot, contentIDs: ["301"]).first?.artwork)
        let folder = fixture.shareRoot.appending(path: "PIONEER/Artwork/01/def")
        #expect(URL(filePath: artwork.smallPath).standardizedFileURL == folder.appending(path: "artwork_s.jpg").standardizedFileURL)
        #expect(URL(filePath: artwork.mediumPath).standardizedFileURL == folder.appending(path: "artwork_m.jpg").standardizedFileURL)
        #expect(artwork.smallBytes == 5 && artwork.mediumBytes == 7)
        // artwork.jpg 자체는 없어도 된다
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "artwork.jpg").path))
    }

    @Test("큐 특성은 djmdCue에서, 지운 행은 뺀다")
    func cueTraitsFromDjmdCueSkipsDeleted() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec(id: "401")
        track.folderPath = try fixture.writeAudio(named: "401.mp3", bytes: 100).path
        var hot = CueSpec(id: "c1", kind: 1, inMsec: 2_000)
        hot.colorTableIndex = 3
        hot.color = 5
        hot.outMsec = 6_000
        hot.activeLoop = 1
        hot.beatLoopSize = 8 << 16 | 1
        track.cues = [hot, CueSpec(id: "c2", kind: 0, inMsec: 500)]
        try fixture.add(track)
        try fixture.execute("UPDATE djmdCue SET rb_local_deleted = 1 WHERE ID = 'c2'")
        try fixture.execute("UPDATE djmdCue SET InMpegFrame = 1234 WHERE ID = 'c1'")
        let candidate = try #require(try UsbExportCandidates.load(database: open(fixture), share: fixture.shareRoot, contentIDs: ["401"]).first)
        #expect(candidate.cues == [UsbCueTraits(kind: 1, colorTableIndex: 3, color: 5, inMsec: 2_000, outMsec: 6_000, activeLoop: 1,
                                                beatLoopSize: 8 << 16 | 1, inMpegFrame: 1_234)])
    }

    @Test("실제 크기는 음원 파일 stat, 없으면 nil")
    func actualSizeFromStat() throws {
        let fixture = try RekordboxFixture()
        let track = try addTrack(fixture, id: "501", bytes: 250)
        try fixture.setFileSize(track: track, 100)
        var missing = TrackSpec(id: "502")
        missing.folderPath = fixture.audio.appending(path: "none.mp3").path
        try fixture.add(missing)
        // 폴더는 일반 파일이 아니다
        var folder = TrackSpec(id: "503")
        folder.folderPath = fixture.audio.path
        try fixture.add(folder)
        let candidates = try UsbExportCandidates.load(database: open(fixture), share: fixture.shareRoot, contentIDs: ["501", "502", "503"])
        #expect(candidates.map(\.localContentID) == ["501", "502", "503"])
        #expect(candidates.map(\.fileSize) == [100, 0, 0])
        #expect(candidates.map(\.actualFileSize) == [250, nil, nil])
        #expect(candidates[1].sourcePath == missing.folderPath)
    }

    @Test("분석 상태: 셋 다·DAT만·EXT까지·없음")
    func analysisStateComplete_datOnly_missing2EX_missing() throws {
        let fixture = try RekordboxFixture()
        try addTrack(fixture, id: "601")
        let datOnly = try addTrack(fixture, id: "602", analysis: "/PIONEER/USBANLZ/d/o/ANLZ0000.DAT")
        let twoExMissing = try addTrack(fixture, id: "603", analysis: "/PIONEER/USBANLZ/m/e/ANLZ0000.DAT")
        let none = try addTrack(fixture, id: "604", analysis: "/PIONEER/USBANLZ/n/n/ANLZ0000.DAT")
        let empty = try addTrack(fixture, id: "605")
        try FileManager.default.removeItem(at: fixture.shareRoot.appending(path: "PIONEER/USBANLZ/d/o/ANLZ0000.EXT"))
        try FileManager.default.removeItem(at: fixture.shareRoot.appending(path: "PIONEER/USBANLZ/d/o/ANLZ0000.2EX"))
        try FileManager.default.removeItem(at: fixture.shareRoot.appending(path: "PIONEER/USBANLZ/m/e/ANLZ0000.2EX"))
        try FileManager.default.removeItem(at: fixture.shareRoot.appending(path: "PIONEER/USBANLZ/n/n/ANLZ0000.DAT"))
        try fixture.setAnalysisPath(track: empty, nil)
        _ = (datOnly, twoExMissing, none)
        let candidates = try UsbExportCandidates.load(database: open(fixture), share: fixture.shareRoot,
                                                      contentIDs: ["601", "602", "603", "604", "605"])
        #expect(candidates.map(\.analysis) == [.complete, .datOnly, .missing2EX, .missing, .missing])
        #expect(candidates[4].analysisModifiedAt == nil)
        #expect(candidates[1].analysisFileBytes == [10])
    }

    @Test("ImagePath가 있는데 그림 파일이 없으면 그림 없음과 표시")
    func artworkPathSetButFileMissing() throws {
        let fixture = try RekordboxFixture()
        let half = try addTrack(fixture, id: "701")
        try fixture.writeArtwork(track: half, imagePath: "/PIONEER/Artwork/02/x/artwork.jpg", small: Data(count: 3), medium: nil)
        try addTrack(fixture, id: "702")
        let candidates = try UsbExportCandidates.load(database: open(fixture), share: fixture.shareRoot, contentIDs: ["701", "702"])
        #expect(candidates[0].artwork == nil)
        #expect(candidates[0].artworkPathSetButMissing)
        #expect(candidates[1].artwork == nil)
        #expect(!candidates[1].artworkPathSetButMissing)
    }

    @Test("FolderPath가 /로 시작하지 않으면 스트리밍")
    func streamingDetected() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec(id: "801")
        track.fileType = 26
        track.folderPath = "service:tracks:12345"
        try fixture.add(track)
        let candidate = try #require(try UsbExportCandidates.load(database: open(fixture), share: fixture.shareRoot, contentIDs: ["801"]).first)
        #expect(candidate.isStreaming)
        #expect(candidate.actualFileSize == nil)
    }

    @Test("지운 곡은 빼고, 순서는 준 ID 순서")
    func skipsDeletedKeepsOrder() throws {
        let fixture = try RekordboxFixture()
        for id in ["901", "902", "903"] { try addTrack(fixture, id: id) }
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '902'")
        let candidates = try UsbExportCandidates.load(database: open(fixture), share: fixture.shareRoot,
                                                      contentIDs: ["903", "902", "901", "903", "999"])
        #expect(candidates.map(\.localContentID) == ["903", "901"])
    }

    @Test("목록 트리는 깊이 우선·Seq 순, 곡은 TrackNo 순")
    func playlistTreeOrderBySeq() throws {
        let fixture = try RekordboxFixture()
        try fixture.addPlaylist(id: "10", name: "폴더", seq: 1, attribute: 1)
        try fixture.addPlaylist(id: "12", name: "둘째", parentID: "10", seq: 2, contentIDs: ["3"])
        try fixture.addPlaylist(id: "11", name: "첫째", parentID: "10", seq: 1, contentIDs: ["2", "1", "2"])
        try fixture.addPlaylist(id: "20", name: "위", seq: 2, contentIDs: ["1"])
        try fixture.execute("UPDATE djmdSongPlaylist SET rb_local_deleted = 1 WHERE ID = '12-0'")
        let db = try open(fixture)
        let tree = try UsbExportCandidates.playlistTree(database: db, rootIDs: ["10", "20"])
        #expect(tree.map(\.localID) == ["10", "11", "12", "20"])
        #expect(tree.map(\.parentLocalID) == [nil, "10", "10", nil])
        #expect(tree.map(\.attribute) == [1, 0, 0, 0])
        #expect(tree.map(\.trackLocalIDs) == [[], ["2", "1", "2"], [], ["1"]])
        #expect(tree.first?.name == "폴더")
        #expect(try UsbExportCandidates.tracks(ofPlaylist: "11", database: db) == ["2", "1", "2"])
        // 폴더 안 목록을 뿌리로 주면 그 목록이 맨 위
        #expect(try UsbExportCandidates.playlistTree(database: db, rootIDs: ["11"]).map(\.parentLocalID) == [nil])
        #expect(throws: (any Error).self) { try UsbExportCandidates.playlistTree(database: db, rootIDs: ["404"]) }
    }

    @Test("스마트 목록은 attribute 4로 넘긴다")
    func smartAttributeKept() throws {
        let fixture = try RekordboxFixture()
        try fixture.addPlaylist(id: "30", name: "스마트", seq: 1, attribute: 4)
        try fixture.addPlaylist(id: "31", name: "규칙", seq: 2, attribute: 0, smartList: "<rule/>")
        try fixture.addPlaylist(id: "32", name: "보통", seq: 3)
        let tree = try UsbExportCandidates.playlistTree(database: open(fixture), rootIDs: ["30", "31", "32"])
        #expect(tree.map(\.attribute) == [4, 4, 0])
    }

    @Test("같은 내용은 크기와 SHA-256이 모두 같을 때만")
    func sameContentBySizeAndHash() throws {
        let fixture = try RekordboxFixture()
        let source = fixture.audio.appending(path: "a.mp3"), same = fixture.audio.appending(path: "b.mp3")
        let other = fixture.audio.appending(path: "c.mp3"), longer = fixture.audio.appending(path: "d.mp3")
        try Data("abcdef".utf8).write(to: source)
        try Data("abcdef".utf8).write(to: same)
        try Data("abcdeg".utf8).write(to: other)
        try Data("abcdefg".utf8).write(to: longer)
        #expect(UsbExportCandidates.sameContent(sourcePath: source.path, usbFile: same))
        #expect(!UsbExportCandidates.sameContent(sourcePath: source.path, usbFile: other))
        #expect(!UsbExportCandidates.sameContent(sourcePath: source.path, usbFile: longer))
        #expect(!UsbExportCandidates.sameContent(sourcePath: source.path, usbFile: fixture.audio.appending(path: "none.mp3")))
    }

    @Test("라이브 master.db면 읽지 않는다")
    func refusesLiveDatabasePath() throws {
        let fixture = try RekordboxFixture()
        try addTrack(fixture, id: "1001")
        let db = try open(fixture)
        #expect(throws: UsbError.self) {
            try UsbExportCandidates.load(database: db, share: fixture.shareRoot, contentIDs: ["1001"], liveDatabase: fixture.database)
        }
        #expect(throws: UsbError.self) {
            try UsbExportCandidates.playlistTree(database: db, rootIDs: [], liveDatabase: fixture.database)
        }
        #expect(throws: UsbError.self) {
            try UsbExportCandidates.tracks(ofPlaylist: "1", database: db, liveDatabase: fixture.database)
        }
        // 링크로 가리켜도 같은 파일
        let link = fixture.root.appending(path: "live-link.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.database)
        #expect(throws: UsbError.self) {
            try UsbExportCandidates.load(database: db, share: fixture.shareRoot, contentIDs: ["1001"], liveDatabase: link)
        }
        #expect(try UsbExportCandidates.load(database: db, share: fixture.shareRoot, contentIDs: ["1001"]).count == 1)
    }
}
