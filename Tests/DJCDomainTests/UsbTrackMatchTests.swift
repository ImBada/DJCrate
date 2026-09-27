import DJCDomain
import Foundation
import Testing

@Suite("USB 곡 ↔ 로컬 곡 짝짓기")
struct UsbTrackMatchTests {
    /// 지어낸 로컬 DB ID
    let localDBID: Int64 = 424_242

    let local = [
        UsbLocalTrackKey(contentID: "11", masterSongID: "501", fileNameL: "a.mp3"),
        UsbLocalTrackKey(contentID: "12", masterSongID: "502", fileNameL: "b.mp3"),
    ]

    @Test("마스터 DB ID·곡 ID·파일 이름이 모두 같으면 그 로컬 곡")
    func matchesByMasterIDsAndFileName() {
        let usb = UsbTrackKey(masterDbId: localDBID, masterContentId: 502, fileName: "b.mp3")
        #expect(UsbTrackMatch.match(usb, localDBID: localDBID, local: local) == "12")
        // 다른 라이브러리에서 내보낸 곡
        #expect(UsbTrackMatch.match(usb, localDBID: localDBID + 1, local: local) == nil)
        // 파일 이름이 다르면 다른 곡
        let renamed = UsbTrackKey(masterDbId: localDBID, masterContentId: 502, fileName: "b (2).mp3")
        #expect(UsbTrackMatch.match(renamed, localDBID: localDBID, local: local) == nil)
        let other = UsbTrackKey(masterDbId: localDBID, masterContentId: 999, fileName: "b.mp3")
        #expect(UsbTrackMatch.match(other, localDBID: localDBID, local: local) == nil)
    }

    @Test("NFD로 적힌 파일 이름도 짝이 된다")
    func nfdFileNameMatches() {
        let locals = [UsbLocalTrackKey(contentID: "21", masterSongID: "601", fileNameL: "Caf\u{00E9}.mp3")]
        let usb = UsbTrackKey(masterDbId: localDBID, masterContentId: 601, fileName: "Cafe\u{0301}.mp3")
        #expect(UsbTrackMatch.match(usb, localDBID: localDBID, local: locals) == "21")
    }

    @Test("짝이 둘 이상이면 고르지 않는다")
    func ambiguousIsNil() {
        let locals = local + [UsbLocalTrackKey(contentID: "13", masterSongID: "502", fileNameL: "b.mp3")]
        let usb = UsbTrackKey(masterDbId: localDBID, masterContentId: 502, fileName: "b.mp3")
        #expect(UsbTrackMatch.match(usb, localDBID: localDBID, local: locals) == nil)
    }
}
