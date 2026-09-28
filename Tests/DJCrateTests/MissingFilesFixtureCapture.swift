import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// 파일이 없는 곡 화면 확인용 합성 사본(#126). 곡마다 따로 만든 합성 음원 중 일부를 지우고,
/// 연결되지 않은 외장 디스크 경로의 곡과 스트리밍 곡을 섞는다. 실데이터는 쓰지 않는다.
/// `DJC_MISSING_FILES_FIXTURE=<폴더> swift test --filter MissingFilesFixtureCapture`
struct MissingFilesFixtureCapture {
    /// 연결되지 않은 외장 디스크(합성 이름, 이 경로의 볼륨은 만들지 않는다)
    static let unmountedVolume = "/Volumes/DJC 합성 외장 디스크"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_MISSING_FILES_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_MISSING_FILES_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        let root = URL(filePath: path)
        try fixture.insert("djmdArtist", ["ID": .text("a1"), "Name": .text("합성 아티스트")])
        enum Kind { case present, deleted, external, streaming }
        let entries: [(String, Kind)] = [
            ("음원 있는 곡 1", .present), ("음원 지운 곡 1", .deleted), ("스트리밍 곡 1", .streaming),
            ("음원 있는 곡 2", .present), ("외장 디스크 곡 1", .external), ("음원 지운 곡 2", .deleted),
            ("음원 있는 곡 3", .present), ("외장 디스크 곡 2", .external), ("스트리밍 곡 2", .streaming),
            ("음원 있는 곡 4", .present), ("음원 지운 곡 3", .deleted), ("음원 있는 곡 5", .present),
        ]
        var deleted: [String] = []
        for (index, entry) in entries.enumerated() {
            var track = TrackSpec(id: String(index + 1))
            track.title = entry.0
            track.artistID = "a1"
            track.bpm100 = 12000 + index * 100
            track.length = 180
            switch entry.1 {
            case .present, .deleted:
                let name = "missing-\(index + 1).wav"
                _ = try AudioFixture.wav(seconds: 1, in: fixture.audio, name: name)
                track.folderPath = root.appending(path: "audio/\(name)").path
                track.fileType = 11
                if entry.1 == .deleted { deleted.append(name) }
            case .external:
                track.folderPath = "\(Self.unmountedVolume)/Music/external-\(index + 1).mp3"
            case .streaming:
                track.folderPath = "apple-music:\(9_100_000 + index)"
                track.length = 240
            }
            try fixture.add(track)
        }
        // 기본 정렬(임포트 최신순)에서 위 순서대로 보이게 ID 순서대로 날짜를 하루씩 앞당긴다.
        try fixture.execute("""
            UPDATE djmdContent SET created_at = date('2026-09-20', '-' || (CAST(ID AS INTEGER) - 1) || ' days') || ' 00:00:00.000 +00:00'
            """)
        try FileManager.default.copyItem(at: fixture.root, to: root)
        // 음원을 옮기거나 지운 뒤의 라이브러리처럼 일부 곡의 음원만 지운다.
        for name in deleted { try FileManager.default.removeItem(at: root.appending(path: "audio/\(name)")) }
    }
}
