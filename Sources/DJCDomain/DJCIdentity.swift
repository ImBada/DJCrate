import Foundation

/// 앱 이름과 데이터 위치. 이름이 박히는 곳은 여기 한 곳에서 가져간다.
public enum DJCIdentity {
    public static let name = "DJCrate"
    public static let shortName = "DJC"
    /// 2026-09-26 이전 이름(데이터 폴더·설정을 옮길 때 찾는다)
    public static let legacyName = "anicue"
    public static let legacyBundleID = "com.fotone.anicue"

    /// `~/Library/Application Support/DJCrate`: 초안·스냅샷·백업·분석 캐시
    public static var supportDirectory: URL { URL.applicationSupportDirectory.appending(path: name) }
}
