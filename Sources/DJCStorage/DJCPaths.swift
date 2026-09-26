import DJCDomain
import Foundation

/// DJCrate가 쓰는 사용자 데이터(초안·추가한 곡) 위치.
/// `DJC_HOME`을 주면 그쪽을 쓴다(테스트가 사용자 초안을 건드리지 않게). 스냅샷·분석 캐시는 공유한다.
public enum DJCPaths {
    public static var userData: URL {
        if let override = ProcessInfo.processInfo.environment["DJC_HOME"], !override.isEmpty {
            return URL(filePath: override)
        }
        return DJCIdentity.supportDirectory
    }

    /// DJCrate가 rekordbox에 쓰기 직전에 뜬 백업
    public static var rekordboxBackups: URL { userData.appending(path: "rekordbox-backups") }
}
