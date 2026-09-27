import Foundation

/// USB 안 파일 위치와 이름 규칙. 경로는 모두 USB 루트 기준 상대 경로("/" 구분, 앞 "/" 없음)다.
public enum UsbLayout {
    public static let rekordboxDir = "PIONEER/rekordbox"
    public static let oneLibrary = "PIONEER/rekordbox/exportLibrary.db"
    public static let oneLibrarySidecarSuffixes = ["-wal", "-shm", "-journal"]
    public static let exportPdb = "PIONEER/rekordbox/export.pdb"
    public static let exportExtPdb = "PIONEER/rekordbox/exportExt.pdb"
    public static let analysisRoot = "PIONEER/USBANLZ"
    public static let artworkRoot = "PIONEER/Artwork"
    public static let contents = "Contents"
    /// 열지도 복사하지도 않는다(자격 증명·프로필). 트리 순회는 여기로 내려가지 않는다.
    public static let neverRead = ["PIONEER/extracted", "PIONEER/CDP", "PIONEER/djprofile.nxs"]
    /// macOS가 만드는 폴더: 비교·지문에서 뺀다
    public static let systemIgnored = [".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems"]
    /// 쓰는 도중의 임시 파일 접두어
    public static let tempPrefix = ".djc-part-"

    /// ".djc-part-<session>-<%06d>". 원래 이름과 무관하게 지어 "._"(AppleDouble) 모양과 겹치지 않게 한다.
    public static func tempName(session: String, sequence: Int) -> String {
        tempPrefix + session + "-" + String(format: "%06d", sequence)
    }

    public static func isTemp(_ name: String) -> Bool { name.hasPrefix(tempPrefix) }

    /// macOS가 FAT에 남기는 확장 속성 파일("._이름")
    public static func isAppleDouble(_ name: String) -> Bool { name.hasPrefix("._") }

    public static func appleDoubleName(for name: String) -> String { "._" + name }

    /// 열지 않는 경로이거나 그 아래인지. 성분 단위로 충돌 키(대소문자·정규화 무시)로 비교한다.
    public static func isNeverRead(_ relativePath: String) -> Bool {
        let components = keys(relativePath)
        return neverRead.contains { hasPrefix(components, keys($0)) }
    }

    /// macOS가 만드는 폴더이거나 그 아래인지(볼륨 맨 위에만 생긴다)
    public static func isSystemIgnored(_ relativePath: String) -> Bool {
        guard let first = keys(relativePath).first else { return false }
        return systemIgnored.contains { collisionKey($0) == first }
    }

    /// FAT(macOS msdos)가 같은 이름으로 보는 이름끼리 같은 키. 대소문자와 NFC·NFD를 가리지 않는다.
    public static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    public static func nfc(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }

    /// 소문자 base32 8자
    public static func newSessionID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    private static func keys(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map { collisionKey(String($0)) }
    }

    private static func hasPrefix(_ components: [String], _ prefix: [String]) -> Bool {
        components.count >= prefix.count && zip(components, prefix).allSatisfy { $0 == $1 }
    }
}
