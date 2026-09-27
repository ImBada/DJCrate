import DJCTestSupport
import Foundation
import Testing

/// 추가한 곡 키 칸 화면 확인용 합성 라이브러리(#124): rekordbox 곡 하나와, 아직 추가하지 않은 합성 음원
/// (화음 진행 WAV 3개·TKEY 태그가 있는 MP3 하나). 실데이터는 쓰지 않는다.
/// `DJC_STAGED_KEY_FIXTURE=<폴더> swift test --filter StagedKeyFixtureCapture` 뒤
/// `DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=<폴더> .build/debug/DJCrate --db <폴더>/master.db --add-files <폴더>/staged/…`
struct StagedKeyFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_STAGED_KEY_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_STAGED_KEY_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        let root = URL(filePath: path)
        var track = TrackSpec(id: "1")
        track.title = "rekordbox 합성 곡"
        try fixture.add(track)
        let staged = fixture.root.appending(path: "staged")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        _ = try ChordFixture.wav(ChordFixture.aMinor, seconds: 60, in: staged, name: "A단조 합성곡.wav")
        _ = try ChordFixture.wav(ChordFixture.cMajor, seconds: 60, in: staged, name: "C장조 합성곡.wav")
        _ = try ChordFixture.wav(ChordFixture.dMajor, seconds: 60, in: staged, name: "D장조 합성곡.wav")
        _ = try AudioFixture.mp3(try TestResources.url("mp3-notag-cbr.mp3"),
                                 textFrames: [("TIT2", "태그 키 합성곡"), ("TKEY", "Fm")], in: staged, name: "태그 키 합성곡.mp3")
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }
}
