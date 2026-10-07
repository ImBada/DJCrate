import Foundation

/// 앱 이름과 데이터 위치. 이름이 박히는 곳은 여기 한 곳에서 가져간다.
public enum DJCIdentity {
    public static let name = "DJCrate"
    public static let shortName = "DJC"
    /// 2026-09-26 이전 이름(데이터 폴더·설정을 옮길 때 찾는다)
    public static let legacyName = "anicue"
    public static let legacyBundleID = "com.fotone.anicue"

    /// rekordbox 환경설정에 한 번 지정하는 연동 XML 파일("XML 만들기"가 늘 덮어쓴다). 다른 XML 내보내기가 이 자리를 쓰지 않게 비교할 때도 쓴다.
    public static var linkedXMLFile: URL {
        URL.documentsDirectory.appending(path: "\(name)/djcrate-rekordbox.xml")
    }

    /// 설치한 앱이 쓰는 실제 사용자 폴더(`~/Library/Application Support/DJCrate`). 환경·시험 여부와 상관없이 늘 이 경로다.
    public static var userSupportDirectory: URL { URL.applicationSupportDirectory.appending(path: name) }

    /// `~/Library/Application Support/DJCrate`: 초안·스냅샷·백업·분석 캐시. 시험 프로세스는 임시 폴더를 쓴다(사용자 백업을 지우지 않게, #182).
    /// `DJC_HOME`을 따르지 않는다(실물 USB 거부 목록 같은 안전 목록의 고정 위치). 초안·캐시는 `dataDirectory`로 찾는다.
    public static var supportDirectory: URL {
        TestProcess.isRunning ? TestProcess.sandbox.appending(path: "support") : userSupportDirectory
    }

    /// 초안·백업·캐시(파형·분석·음량)의 뿌리. `DJC_HOME`을 주면 그쪽(시험·자가 테스트가 사용자 폴더를 건드리지 않게, #195),
    /// 없으면 `supportDirectory`. 이 뿌리를 정하는 곳은 여기 한 곳이다(곡 편집본 위치는 `DJCPaths.editOutput`이 따로 정한다).
    public static var dataDirectory: URL {
        dataDirectory(environment: ProcessInfo.processInfo.environment, support: supportDirectory)
    }

    /// 설치한 앱의 로그 폴더(`~/Library/Logs/DJCrate`). 환경·시험 여부와 상관없이 늘 이 경로다.
    public static var userLogsDirectory: URL { URL.libraryDirectory.appending(path: "Logs/\(name)") }

    /// 오디오 사건 기록 같은 로그의 폴더. `DJC_HOME`을 주면 그 아래 `logs/`, 시험 프로세스는 임시 폴더,
    /// 아니면 `userLogsDirectory`(#218: 시험·자가 테스트가 실제 로그에 썼다).
    public static var logsDirectory: URL {
        logsDirectory(environment: ProcessInfo.processInfo.environment,
                      fallback: TestProcess.isRunning ? TestProcess.sandbox.appending(path: "logs") : userLogsDirectory)
    }

    public static func logsDirectory(environment: [String: String], fallback: URL) -> URL {
        if let override = environment["DJC_HOME"], !override.isEmpty {
            return URL(filePath: override).appending(path: "logs")
        }
        return fallback
    }

    public static func dataDirectory(environment: [String: String], support: URL) -> URL {
        if let override = environment["DJC_HOME"], !override.isEmpty {
            return URL(filePath: override)
        }
        return support
    }
}
