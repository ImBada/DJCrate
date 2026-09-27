import Foundation

/// USB 분석 파일(`PIONEER/USBANLZ/…`) 폴더 이름을 짓는 방법
public protocol UsbAnalysisNaming: Sendable {
    /// 이 구현이 쓰면 계획에 싣는 규칙(nil = 확인된 규칙)
    var rule: UsbProvisionalRule? { get }
    /// USBANLZ 아래 폴더 "P%03X/%08X". 이름을 못 지으면 nil
    func folder(contentsPath: String, contentID: Int) -> String?
}

/// DJCrate 고유 이름: content ID로 짓는다. rekordbox의 폴더 이름 규칙을 흉내 내지 않는다.
/// 기존 곡은 DB에 적힌 경로를 그대로 쓰고, 새 곡에만 쓴다(확인 전까지 `analysisFolderNaming` 규칙).
public struct IdentifierAnalysisNaming: UsbAnalysisNaming {
    public init() {}

    public var rule: UsbProvisionalRule? { .analysisFolderNaming }

    public func folder(contentsPath: String, contentID: Int) -> String? {
        String(format: "P%03X/%08X", (contentID >> 12) & 0xFFF, contentID)
    }
}

/// 한 분석 폴더 안의 파일 번호(ANLZ0000, ANLZ0001 …)
public enum UsbAnalysisSlot {
    /// 폴더에 이미 있는 (번호, PPTH). 같은 PPTH가 있으면 그 번호(재사용), 아니면 가장 작은 빈 번호.
    /// 다른 곡의 파일은 절대 덮어쓰지 않는다.
    public static func choose(existing: [(slot: Int, ppth: String)], contentsPath: String) -> (slot: Int, reuse: Bool) {
        let path = UsbLayout.nfc(contentsPath)
        if let same = existing.filter({ UsbLayout.nfc($0.ppth) == path }).map(\.slot).min() { return (same, true) }
        let used = Set(existing.map(\.slot))
        return ((0...).first { !used.contains($0) }!, false)
    }

    /// "ANLZ%04X"
    public static func fileStem(slot: Int) -> String {
        String(format: "ANLZ%04X", slot)
    }

    /// "/PIONEER/USBANLZ/<folder>/ANLZ%04X.DAT"
    public static func analysisPath(folder: String, slot: Int) -> String {
        "/" + UsbLayout.analysisRoot + "/" + folder + "/" + fileStem(slot: slot) + ".DAT"
    }
}
