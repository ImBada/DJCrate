import DJCStorage
import DJCTestSupport
import Foundation
import Testing

/// 실제 Music 접근 없이 iTunes 읽기 전용 목록과 덱·태그 편집을 확인하는 합성 사본.
struct ITunesFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_ITUNES_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_ITUNES_FIXTURE"] else { return }
        let root = URL(filePath: path), fixture = try RekordboxFixture()
        var paths: [String] = []
        for id in ["1", "2"] {
            let audio = try AudioFixture.wav(seconds: 2, in: fixture.audio, name: "itunes-\(id).wav")
            var track = TrackSpec(id: id)
            track.title = "iTunes 합성 곡 \(id)"
            track.folderPath = root.appending(path: "audio/\(audio.lastPathComponent)").path
            track.fileType = 11
            track.length = 2
            try fixture.add(track)
            paths.append(track.folderPath)
        }
        try FileManager.default.copyItem(at: fixture.root, to: root)
        try ITunesLibrarySnapshot(playlists: [
            .init(id: "F", name: "iTunes 합성 폴더", isFolder: true),
            .init(id: "A", name: "iTunes 합성 목록", parentID: "F", paths: [paths[1], paths[0], paths[1], nil]),
            .init(id: "B", name: "빈 동기화 목록", parentID: "F"),
        ]).save(for: root.appending(path: "master.db"))
    }
}
