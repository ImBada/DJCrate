import DJCDomain
import Foundation
import RekordboxKit

extension UsbRead {
    /// 앱 사이드바: 사본을 떠서(`UsbSnapshot`) 두 형식을 읽고 합친다. USB에는 아무것도 쓰지 않는다.
    /// 막힘(쓰기 금지 목록·목록 미등록·볼륨 확인 안 됨)은 `info`와 같고, 막히면 사본 폴더도 만들지 않는다.
    /// 사본은 `snapshots/<볼륨키>/<시각>/`에 새로 떠서 남기고, 그 볼륨의 사본 폴더는 최근 `keep`개만 둔다.
    public static func library(root: URL, snapshots: URL, volumeKey: String, volume: UsbVolumeInfo?,
                               lists: UsbPhysicalLists.Loaded = UsbPhysicalLists.load(), now: Date = Date(), keep: Int = 5,
                               mountedOn: (String) -> String? = UsbScratchRoots.mountedOn) throws -> (library: UsbLibrary, mismatches: [UsbFormatMismatch]) {
        // 볼륨키는 사본 폴더 이름 한 성분이다
        guard !volumeKey.isEmpty, volumeKey != ".", volumeKey != "..", !volumeKey.contains("/") else {
            throw UsbError.readFailed(detail: "bad volume key")
        }
        if let volume {
            if let code = readRefusal(volume: volume, lists: lists) { throw UsbError.readFailed(detail: code) }
        } else {
            guard let real = UsbScratchRoots.realPath(root.path), let mount = mountedOn(real), startupMounts.contains(mount) else {
                throw UsbError.readFailed(detail: "volumeNotChecked")
            }
        }
        let usb = UsbRoot(root)
        let names = try rekordboxFileNames(usb)
        let hasOneLibrary = names.contains((UsbLayout.oneLibrary as NSString).lastPathComponent)
        let hasPdb = names.contains((UsbLayout.exportPdb as NSString).lastPathComponent)
        guard hasOneLibrary || hasPdb else { throw UsbError.readFailed(detail: "noLibrary") }

        let base = snapshots.appending(path: volumeKey)
        let folder = snapshotFolder(in: base, now: now)
        var oneLibrary: UsbLibrary?, deviceLibrary: UsbLibrary?
        do {
            do {
                let snapshot = try UsbSnapshot.take(root: usb, into: folder)
                if let copy = snapshot.oneLibrary { oneLibrary = try readOneLibrary(copy) }
                deviceLibrary = try readDeviceLibrary { try PdbReader.read(snapshot: snapshot)?.0 }
            } catch let error as UsbError where hasOneLibrary && isOneLibraryFailure(error) {
                // OneLibrary 사본이 온전하지 않다(무결성·암호). Device Library만 따로 떠서 읽는다
                if let (export, ext) = try copyPdb(usb, into: folder.appending(path: "pdb")) {
                    deviceLibrary = try readDeviceLibrary {
                        try PdbReader.read(export: Data(contentsOf: export), exportExt: ext.map { try Data(contentsOf: $0) }).0
                    }
                }
            }
            guard oneLibrary != nil || deviceLibrary != nil else { throw UsbError.readFailed(detail: "noReadableLibrary") }
        } catch {
            // 읽지 못한 사본은 남기지 않는다(이 호출이 만든 폴더만)
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        pruneSnapshots(in: base, keep: keep)
        return UsbLibrary.merge(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary)
    }

    /// 모르는 모양의 OneLibrary는 건너뛰고 Device Library만 쓴다(`info`의 경고와 같은 판정)
    static func readOneLibrary(_ copy: URL) throws -> UsbLibrary? {
        do {
            return try OneLibraryReader.read(copyAt: copy)
        } catch let error as UsbError {
            guard case .formatUnsupported = error else { throw error }
            return nil
        }
    }

    /// 머리가 달라 읽지 못한 Device Library는 건너뛴다(`info`는 경고로 알린다)
    static func readDeviceLibrary(_ read: () throws -> UsbLibrary?) throws -> UsbLibrary? {
        do {
            return try read()
        } catch let error as UsbError {
            guard case .readFailed = error else { throw error }
            return nil
        }
    }

    /// `<시각>`(UTC, 초까지) 폴더. 같은 이름이 있으면 `-2`, `-3`…
    static func snapshotFolder(in base: URL, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let name = formatter.string(from: now)
        var candidate = base.appending(path: name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.appending(path: "\(name)-\(index)")
            index += 1
        }
        return candidate
    }

    /// 이 볼륨의 사본 폴더 중 이름(시각) 순으로 최근 `keep`개만 남긴다. 시각 모양이 아닌 항목은 건드리지 않는다
    static func pruneSnapshots(in base: URL, keep: Int) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
            .filter { $0.range(of: #"^[0-9]{8}T[0-9]{6}(-[0-9]+)?$"#, options: .regularExpression) != nil }
            .sorted { lhs, rhs in
                // "-10"이 "-9"보다 앞서지 않게 번호는 수로 비교한다
                let (a, b) = (lhs.split(separator: "-"), rhs.split(separator: "-"))
                if a[0] != b[0] { return a[0] < b[0] }
                return (a.count > 1 ? Int(a[1]) ?? 0 : 1) < (b.count > 1 ? Int(b[1]) ?? 0 : 1)
            }
        for name in names.dropLast(max(keep, 0)) { try? FileManager.default.removeItem(at: base.appending(path: name)) }
    }
}
