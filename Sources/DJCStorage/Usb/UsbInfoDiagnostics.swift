import DJCDomain
import Darwin
import Foundation
import RekordboxKit

extension UsbRead {
    static func media(_ usb: UsbRoot, oneLibrary: UsbLibrary?, deviceLibrary: UsbLibrary?) -> UsbInfo.Media {
        let tracks = (oneLibrary?.tracks ?? []) + (deviceLibrary?.tracks ?? [])
        let paths = Set(tracks.map { UsbLayout.nfc($0.path) })
        let missing = paths.filter { path in
            path.isEmpty || !isRegularFile(usb, String(path.drop { $0 == "/" }))
        }.count
        return UsbInfo.Media(tracksChecked: Set(tracks.map(\.id)).count, filesChecked: paths.count, missingFiles: missing)
    }

    /// 고정 이름만 연다. 파일 크기가 확인한 소형 파일과 다르면 내용을 읽지 않는다
    static func settings(_ usb: UsbRoot) -> [UsbInfo.Setting] {
        DeviceSettingFile.Kind.allCases.map { setting(usb, kind: $0) }
    }

    private static func setting(_ usb: UsbRoot, kind: DeviceSettingFile.Kind) -> UsbInfo.Setting {
        func result(_ status: UsbInfo.Setting.Status, _ issue: String? = nil, crcOK: Bool? = nil) -> UsbInfo.Setting {
            UsbInfo.Setting(fileName: kind.fileName, status: status, issue: issue, crcOK: crcOK)
        }
        guard let url = try? usb.url(for: "PIONEER/" + kind.fileName) else { return result(.unreadable, "unsafePath") }
        // 링크로 바뀌어도 따라가지 않으며 FIFO로 바뀌어도 열기에서 멈추지 않는다
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT ? result(.missing) : result(.unreadable, "readFailed") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0 else { return result(.unreadable, "readFailed") }
        guard info.st_mode & S_IFMT == S_IFREG else { return result(.unreadable, "notRegularFile") }
        guard info.st_size == kind.size else { return result(.invalid, "wrongSize") }
        let bytes: Data
        do {
            // 검사 뒤 커져도 읽는 양을 제한하고, 크기 변경은 파서가 거부한다
            bytes = try handle.read(upToCount: kind.size + 1) ?? Data()
        } catch {
            return result(.unreadable, "readFailed")
        }
        let pair = bytes.count == kind.size ? DeviceSettingFile.crcPair(kind: kind, bytes: bytes) : nil
        let crcOK = pair.map { $0.stored == $0.computed }
        do {
            _ = try DeviceSettingFile(kind: kind, bytes: bytes)
            return result(.valid, crcOK: crcOK)
        } catch let error as DeviceSettingError {
            let issue: String
            switch error {
            case .wrongSize: issue = "wrongSize"
            case .wrongStringsLength: issue = "wrongStringsLength"
            case .wrongDataLength: issue = "wrongDataLength"
            case .crcMismatch: issue = "crcMismatch"
            case .trailerNotZero: issue = "trailerNotZero"
            default: issue = "readFailed"
            }
            return result(.invalid, issue, crcOK: crcOK)
        } catch {
            return result(.unreadable, "readFailed")
        }
    }
}
