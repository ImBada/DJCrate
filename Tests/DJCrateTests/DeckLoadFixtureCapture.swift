import DJCTestSupport
import Foundation
import Testing

/// #93 화면·덱 전환 확인용 합성 라이브러리. 같은 자료로 수정 전후를 비교한다.
/// `DJC_DECK_LOAD_FIXTURE=<폴더> swift test --filter DeckLoadFixtureCapture`
struct DeckLoadFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_DECK_LOAD_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_DECK_LOAD_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        let root = URL(filePath: path)
        let audio = try EditLayoutFixtureCapture.song(bpm: 128, first: 0.35, seconds: 90,
                                                     to: fixture.audio.appending(path: "sample.wav"))
        try fixture.execute("""
            INSERT INTO djmdArtist (ID, Name, created_at, updated_at)
            VALUES ('1', '합성 아티스트', '2026-01-01', '2026-01-01')
            """)
        for index in 1...4 {
            var track = TrackSpec(id: String(index))
            track.title = index < 3 ? "합성 곡 \(index)" : "합성 중복 곡"
            track.artistID = "1"
            let name = "sample-\(index).wav"
            try FileManager.default.copyItem(at: audio, to: fixture.audio.appending(path: name))
            track.folderPath = root.appending(path: "audio/\(name)").path
            track.fileType = 11
            track.length = 90
            track.analysisDataPath = "/PIONEER/USBANLZ/test\(index)/ANLZ0000.DAT"
            track.cues = [CueSpec(kind: 1, inMsec: 350)]
            try fixture.add(track)
            let beats = AnlzBuilder.beats(bpm: 128, first: 350, count: 190)
            try fixture.putAnalysis(for: track, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        }
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }
}
