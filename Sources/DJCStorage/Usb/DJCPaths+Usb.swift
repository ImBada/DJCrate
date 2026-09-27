import DJCDomain
import Foundation
import RekordboxKit

/// USB 쓰기의 맥 쪽 폴더(모두 DJC_HOME 아래)
extension DJCPaths {
    /// 쓰기 전 백업: usb-backups/<볼륨키>/<시각>-<이름>/
    public static var usbBackups: URL { userData.appending(path: "usb-backups") }
    /// USB DB를 맥에서 열려고 뜬 사본
    public static var usbSnapshots: URL { userData.appending(path: "usb-snapshots") }
    public static var usbDrafts: URL { userData.appending(path: "usb-drafts") }
    /// 저널(<볼륨키>.json)·잠금(<볼륨키>.lock)
    public static var usbSessions: URL { userData.appending(path: "usb-sessions") }
    /// 쓰기 전에 만든 파일(분석·아트워크·DB)
    public static var usbStaging: URL { userData.appending(path: "usb-staging") }
}

extension UsbWritePaths {
    /// DJC_HOME 아래 세 폴더(없으면 만든다)
    public static var `default`: UsbWritePaths {
        for url in [DJCPaths.usbBackups, DJCPaths.usbSessions, DJCPaths.usbStaging] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return UsbWritePaths(backups: DJCPaths.usbBackups, sessions: DJCPaths.usbSessions, staging: DJCPaths.usbStaging)
    }
}
