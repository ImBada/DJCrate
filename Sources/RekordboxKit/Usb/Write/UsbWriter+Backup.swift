import DJCDomain
import Foundation

/// C 백업(맥): DB 파일·사이드카, 덮어쓸 파일, 지울 파일(음원 빼고)과 원래 있던 `._<이름>`.
/// 파일마다 복사 전후 크기·mtime이 같아야 하고, 복사본은 F_FULLFSYNC한다. manifest와 저널 backedUp이 디스크에 내려간 뒤에만 D로 간다.
extension UsbWriteRun {
    struct SourceChanged: Error { var path: String }

    func backup(_ changes: UsbChangeSet) throws {
        do {
            try ensureSameVolume()
        } catch {
            // 아직 USB에 쓴 것이 없다. 저널은 staged 그대로 두고 회복이 닫는다
            throw volumeGone
        }
        emit(.backup, cancellable: true)
        var folder: URL?
        do {
            let created = try makeBackupFolder(label: changes.label)
            folder = created
            backupFolder = created
            manifest = try makeManifest(changes, in: created)
            try UsbDurableFile.write(manifest, to: created.appending(path: "manifest.json"), fileSystem: fs)
            journal.backupDirectory = created.path
            try journal.move(to: .backedUp)
            try saveJournal()
        } catch UsbWriteFailure.volumeLost {
            throw volumeGone
        } catch {
            // USB에 쓴 것이 없으니 백업 폴더를 지우고 저널을 닫는다
            if let folder { try? FileManager.default.removeItem(at: folder) }
            backupFolder = nil
            journal.backupDirectory = nil
            if (try? journal.move(to: .rolledBack)) != nil { try? saveJournal() }
            if let changed = error as? SourceChanged {
                throw UsbError.writeRefused([UsbBlock(code: "sourceChangedDuringCopy", scope: .file(changed.path),
                                                      message: String(ui: "백업하는 동안 USB 파일이 바뀌었습니다. 다른 프로그램이 USB를 쓰지 않는지 확인한 뒤 다시 시도하세요"))])
            }
            throw UsbError.writeRolledBack(reason: String(describing: error))
        }
    }

    /// `usb-backups/<볼륨키>/<yyyy-MM-dd'T'HHmmss>-<이름>/`(같은 초면 -2, -3…)
    func makeBackupFolder(label: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let safe = String(label.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }.prefix(40))
        let stem = formatter.string(from: now) + "-" + (safe.isEmpty ? "write" : safe)
        let base = paths.backups.appending(path: volumeKey)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var name = stem
        var suffix = 2
        while FileManager.default.fileExists(atPath: base.appending(path: name).path) {
            name = stem + "-\(suffix)"
            suffix += 1
        }
        let folder = base.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    func makeManifest(_ changes: UsbChangeSet, in folder: URL) throws -> UsbManifest {
        var manifest = UsbManifest(volumeUUID: volumeKey, volumeName: volume.name, appVersion: UsbManifest.currentAppVersion,
                                   session: changes.session, createdAt: Date())
        let audioRemovals = changes.removals.filter { UsbPath.isAudio($0.path) }
        var copyList = UsbWriter.databaseBackupFiles
        copyList += changes.writes.filter { $0.disposition == .overwrite }.map(\.destination)
        copyList += changes.removals.filter { !UsbPath.isAudio($0.path) }.map(\.path)
        // 되돌린 뒤 쓰기 전과 같아야 하는 경로(파일만)
        var touched = copyList
        touched += changes.copies.filter { $0.disposition == .create }.map(\.destination)
        touched += changes.writes.filter { $0.disposition == .create }.map(\.destination)
        touched += changes.databases.map(\.destination)
        touched += audioRemovals.map(\.path)
        touched = unique(touched)
        let companions = touched.compactMap(UsbRemovalPolicy.appleDoubleCompanion(of:))

        for path in unique(copyList) {
            try ensureMounted()
            guard let info = try fs.stat(usb(path)) else { continue }
            guard info.kind == .file else { throw UsbWriteFailure.failed("not a regular file: \(path)") }
            manifest.files[path] = try backupFile(path, info: info, into: folder)
        }
        for companion in unique(companions) {
            try ensureMounted()
            guard let info = try fs.stat(usb(companion)), info.kind == .file else { continue }
            manifest.files[companion] = try backupFile(companion, info: info, into: folder)
            manifest.appleDoublesPreexisting.append(companion)
        }
        for removal in audioRemovals {
            guard let info = try fs.stat(usb(removal.path)), info.kind == .file else { continue }
            manifest.removedAudio.append(.init(path: removal.path, localOriginal: removal.localOriginal,
                                               localOriginalSHA1: removal.localOriginalSHA1, size: info.size,
                                               sha256: removal.expectedSHA256, modificationDate: info.modificationDate))
        }
        for path in unique(touched + companions) {
            if let stamp = manifest.files[path] {
                manifest.before[path] = UsbTreeStamp(size: stamp.size, sha256: stamp.sha256)
            } else if let audio = manifest.removedAudio.first(where: { $0.path == path }) {
                // 음원은 백업하지 않는다(크기만 비교)
                manifest.before[path] = UsbTreeStamp(size: audio.size, sha256: nil)
            } else if try fs.stat(usb(path)) == nil {
                manifest.absentBefore.append(path)
            }
        }
        return manifest
    }

    /// USB 파일 하나를 백업 폴더 `files/<상대 경로>`로(데이터만). 복사하는 동안 바뀌면 `SourceChanged`
    func backupFile(_ path: String, info before: UsbFileStat, into folder: URL) throws -> UsbFingerprint.Stamp {
        let destination = folder.appending(path: "files").appending(path: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let copied = try fs.copyDataNew(from: usb(path), to: destination) { _ in }
        try fs.fullSync(destination)
        guard let after = try fs.stat(usb(path)), after.size == before.size, after.modificationDate == before.modificationDate,
              copied.size == before.size else { throw SourceChanged(path: path) }
        return .init(size: copied.size, mtime: before.modificationDate, sha256: copied.sha256)
    }

    func unique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }
}
