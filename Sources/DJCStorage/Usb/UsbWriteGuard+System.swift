import DJCDomain
import Foundation
import RekordboxKit

extension UsbWriteGuard {
    /// 앱·CLI가 쓰는 가드(실물 쓰기 스위치 끔): 디스크 이미지에만 쓴다
    public static var system: UsbWriteGuard { system(physicalWrite: false) }

    /// 앱·CLI가 쓰는 가드: DiskArbitration·statfs·hdiutil로 볼륨을 보고, rekordbox 실행·보호 경로·실물 관문(목록 파일)을 본다.
    /// physicalWrite는 실행 중 스위치(앱 설정 › 실험실 "실물 USB 쓰기", CLI `--allow-physical`)
    public static func system(physicalWrite: Bool) -> UsbWriteGuard {
        UsbWriteGuard(volume: { try UsbVolumes.info(root: $0) },
                      isRekordboxRunning: { LibrarySnapshot.isRekordboxRunning() },
                      protectedRoots: [
                          FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer"),
                          LibrarySnapshot.rekordboxDirectory,
                          DJCIdentity.supportDirectory,
                          DJCPaths.userData,
                      ],
                      gate: UsbPhysicalLists.gate(physicalEnabled: physicalWrite))
    }
}
