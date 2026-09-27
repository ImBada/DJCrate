import DJCDomain
import Foundation
import RekordboxKit

extension UsbWriteGuard {
    /// 앱·CLI가 쓰는 가드: DiskArbitration·statfs·hdiutil로 볼륨을 보고, rekordbox 실행·보호 경로·실물 관문(목록 파일)을 본다
    public static var system: UsbWriteGuard {
        UsbWriteGuard(volume: { try UsbVolumes.info(root: $0) },
                      isRekordboxRunning: { LibrarySnapshot.isRekordboxRunning() },
                      protectedRoots: [
                          FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer"),
                          LibrarySnapshot.rekordboxDirectory,
                          DJCIdentity.supportDirectory,
                          DJCPaths.userData,
                      ],
                      gate: UsbPhysicalLists.gate())
    }
}
