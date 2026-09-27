import Foundation

/// USB 곡 행에서 로컬 곡을 찾는 열쇠(OneLibrary content의 master_db_id·master_content_id·파일 이름)
public struct UsbTrackKey: Sendable, Hashable {
    public var masterDbId: Int64
    public var masterContentId: Int64
    public var fileName: String

    public init(masterDbId: Int64, masterContentId: Int64, fileName: String) {
        self.masterDbId = masterDbId
        self.masterContentId = masterContentId
        self.fileName = fileName
    }
}

/// 로컬 곡 쪽 열쇠(djmdContent)
public struct UsbLocalTrackKey: Sendable, Hashable {
    public var contentID: String
    public var masterSongID: String
    public var fileNameL: String

    public init(contentID: String, masterSongID: String, fileNameL: String) {
        self.contentID = contentID
        self.masterSongID = masterSongID
        self.fileNameL = fileNameL
    }
}

public enum UsbTrackMatch {
    /// 이 로컬 라이브러리에서 내보낸 곡이고(DB ID), 곡 ID와 파일 이름(NFC)이 같은 로컬 곡 하나. 없거나 둘 이상이면 nil
    public static func match(_ usb: UsbTrackKey, localDBID: Int64, local: [UsbLocalTrackKey]) -> String? {
        guard usb.masterDbId == localDBID else { return nil }
        let name = UsbLayout.nfc(usb.fileName)
        let found = Set(local.filter {
            Int64($0.masterSongID) == usb.masterContentId && UsbLayout.nfc($0.fileNameL) == name
        }.map(\.contentID))
        return found.count == 1 ? found.first : nil
    }
}
