import DJCTestSupport
import Foundation
import Testing

/// #176 안내를 같은 합성 곡으로 전후 비교한다. 출력은 임시 폴더로만 만든다.
struct BlockedReasonsFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_BLOCKED_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_BLOCKED_FIXTURE"] else { return }
        let root = URL(filePath: path).resolvingSymlinksInPath()
        let temporary = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        try #require(root.path.hasPrefix(temporary + "/") || root.path.hasPrefix("/private/tmp/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try RekordboxFixture()
        let destination = root.appending(path: "rekordbox")
        for index in 1...3 {
            var spec = TrackSpec(id: String(index), uuid: "blocked-fixture-\(index)")
            spec.title = ["합성 곡 · 분석 없음", "합성 곡 · 분석 읽기 실패", "합성 곡 · 스트리밍"][index - 1]
            spec.fileType = 11
            spec.length = 20
            let audio = try AudioFixture.wav(seconds: 20, in: fixture.audio, name: "sample-\(index).wav")
            spec.folderPath = index == 3 ? "streaming:synthetic" : destination.appending(path: "audio/\(audio.lastPathComponent)").path
            if index == 2 { spec.analysisDataPath = "/PIONEER/USBANLZ/test/ANLZ0000.DAT" }
            try fixture.add(spec)
            if index == 2 {
                try fixture.putAnalysis(for: spec, dat: Data("broken".utf8), ext: nil)
            }
        }
        try FileManager.default.copyItem(at: fixture.root, to: destination)
    }
}
