import DJCTestSupport
import Foundation
import Testing

/// 재생 목록 반영 자가 테스트(`--write-selftest`)·화면 확인용 합성 라이브러리: 합성 곡 다섯(테스트 음원),
/// 폴더 "합성 폴더" 안 목록 "합성 목록"(곡 둘), 맨 위 목록 "맨 위 목록"(곡 하나), `masterPlaylists6.xml`. 실데이터는 쓰지 않는다.
/// `DJC_PLAYLIST_FIXTURE=<폴더> swift test --filter PlaylistWriteFixtureCapture` → `DJC_REKORDBOX_DIR=<폴더>`로 앱을 띄운다.
struct PlaylistWriteFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_PLAYLIST_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_PLAYLIST_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        let root = URL(filePath: path)
        for (index, title) in ["합성 곡 하나", "합성 곡 둘", "합성 곡 셋", "합성 곡 넷", "합성 곡 다섯"].enumerated() {
            var track = TrackSpec(id: String(101 + index))
            track.title = title
            try fixture.add(track)
        }
        try fixture.add(PlaylistSpec(id: "1001", name: "합성 폴더", seq: 1, isFolder: true))
        try fixture.add(PlaylistSpec(id: "1002", name: "합성 목록", parentID: "1001", seq: 1, contentIDs: ["101", "102"]))
        try fixture.add(PlaylistSpec(id: "1003", name: "맨 위 목록", seq: 2, contentIDs: ["103"]))
        // rekordbox가 남기는 모양(NODE Id는 16진수, 맨 위 = 0)
        let xml = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#, "",
            #"<MASTER_PLAYLIST Version="3.0.0" AutomaticSync="0">"#,
            #"  <PRODUCT Name="rekordbox" Version="7.2.18" Company="AlphaTheta"/>"#,
            "  <PLAYLISTS>",
            #"    <NODE Id="3E9" ParentId="0" Attribute="1" Timestamp="1790400600945" Lib_Type="0" CheckType="0"/>"#,
            #"    <NODE Id="3EA" ParentId="3E9" Attribute="0" Timestamp="1790400600945" Lib_Type="0" CheckType="0"/>"#,
            #"    <NODE Id="3EB" ParentId="0" Attribute="0" Timestamp="1790400600945" Lib_Type="0" CheckType="0"/>"#,
            "  </PLAYLISTS>", "</MASTER_PLAYLIST>", "",
        ].joined(separator: "\r\n")
        try xml.write(to: fixture.root.appending(path: "masterPlaylists6.xml"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: fixture.root.appending(path: "share/PIONEER/USBANLZ"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }
}
