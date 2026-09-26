import AnicueDomain
import Foundation

/// anicue가 쓰는 사용자 데이터(초안·추가한 곡) 위치.
/// `ANICUE_HOME`을 주면 그쪽을 쓴다(테스트가 사용자 초안을 건드리지 않게). 스냅샷·분석 캐시는 공유한다.
public enum AnicuePaths {
    public static var userData: URL {
        if let override = ProcessInfo.processInfo.environment["ANICUE_HOME"], !override.isEmpty {
            return URL(filePath: override)
        }
        return URL.applicationSupportDirectory.appending(path: "anicue")
    }

    /// anicue가 rekordbox에 쓰기 직전에 뜬 백업
    public static var rekordboxBackups: URL { userData.appending(path: "rekordbox-backups") }
}
