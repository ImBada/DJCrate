import DJCDomain
import Foundation

/// H 되돌리기(D 이후 실패·취소·검증 실패)와 `usb-restore`.
/// 먼저 볼륨이 아직 붙어 있는지 보고(사라졌으면 되돌리지 않고 멈춘다), rekordbox가 켜져 있으면 미룬다.
/// 저널 항목대로: rename 전(pending)이면 임시 파일만 지우고, 만든 것은 지우고, 덮어쓴 것은 백업에서 되살린다.
/// 저널 상태가 늦었을 수 있어(끊긴 뒤 회복) 실제 파일도 본다: 임시가 없고 대상이 새 해시면 rename까지 된 것이다.
extension UsbWriteRun {
    enum RollbackMode { case write, recover, restore }

    /// 되돌리기. 실패한 연산을 모아 돌려준다(빈 배열 = 되돌림). 볼륨이 사라지면 `UsbWriteFailure.volumeLost`
    func rollback(mode: RollbackMode) throws -> [String] {
        try ensureMounted()
        if writeGuard.isRekordboxRunning() {
            if journal.state != .restorePending { try journal.move(to: .restorePending) }
            try saveJournal()
            throw UsbError.restorePending(reason: String(ui: "rekordbox가 켜져 있습니다"))
        }
        emit(.restore, cancellable: false)
        if manifest == nil, let backupFolder {
            manifest = try? UsbJournal.decoder().decode(UsbManifest.self, from: Data(contentsOf: backupFolder.appending(path: "manifest.json")))
        }
        var errors: [String] = []
        func attempt(_ what: String, _ body: () throws -> Void) throws {
            do {
                try ensureMounted()
                try body()
            } catch UsbWriteFailure.volumeLost {
                throw UsbWriteFailure.volumeLost
            } catch {
                errors.append("\(what): \(error)")
            }
        }
        // F 되돌리기(검증 실패로 온 경우)
        for index in journal.removals.indices.reversed() where journal.removals[index].state == .removed {
            let path = journal.removals[index].path
            try attempt(path) {
                try restoreRemoved(path, strict: mode != .restore)
                journal.removals[index].state = .pending
            }
        }
        // E 되돌리기
        for entry in journal.databases.reversed() {
            try attempt(entry.destination) { try rollbackDatabase(entry) }
        }
        // D 되돌리기
        for entry in journal.entries.reversed() {
            try attempt(entry.destination) { try rollbackFile(entry) }
        }
        for folder in journal.createdDirs.reversed() {
            try attempt(folder) {
                if try fs.removeDirectoryIfEmpty(usb(folder)) {
                    try removeExactAppleDouble(parent: UsbPath.parent(folder), name: UsbPath.name(folder))
                }
            }
        }
        try attempt("temp") { try removeSessionTemps() }
        try ensureMounted()
        let mismatches = try fingerprintMismatches()
        if mode == .restore {
            report.notes += mismatches.map { String(ui: "쓰기 전과 다른 파일이 남았습니다: \($0)") }
        } else {
            errors += mismatches.map { "fingerprint: \($0)" }
        }
        return errors
    }

    /// 쓰기 전 지문(manifest)과 건드린 경로를 비교한다
    func fingerprintMismatches() throws -> [String] {
        guard let manifest else { return [] }
        var mismatches: [String] = []
        for (path, stamp) in manifest.before.sorted(by: { $0.key < $1.key }) {
            let url = usb(path)
            guard let info = try fs.stat(url), info.kind == .file, info.size == stamp.size else {
                mismatches.append(path)
                continue
            }
            if let expected = stamp.sha256, try fs.sha256(url, uncached: false) != expected { mismatches.append(path) }
        }
        // 쓰기 전에 없던 자리: 우리가 쓴 내용이 남았을 때만 틀린 것이다(그 사이 남이 만든 파일은 우리 것이 아니라 두었다)
        var ours: [String: String] = [:]
        for entry in journal.entries { if let sha = entry.newSHA256 { ours[entry.destination] = sha } }
        for entry in journal.databases { ours[entry.destination] = entry.newSHA256 }
        for path in manifest.absentBefore {
            guard let sha = ours[path], let info = try fs.stat(usb(path)), info.kind == .file else { continue }
            if try fs.sha256(usb(path), uncached: false) == sha { mismatches.append(path) }
        }
        return mismatches
    }

    func exists(_ relative: String) throws -> Bool { try fs.stat(usb(relative)) != nil }

    func removeIfPresent(_ relative: String) throws {
        guard try exists(relative) else { return }
        try ensureMounted()
        try fs.remove(usb(relative))
    }

    /// 이 파일이 우리가 쓴 새 내용인지(임시 파일이 없고 대상 해시 = 새 해시)
    func holdsNewContent(_ relative: String, newSHA256: String?, oldSHA256: String?) throws -> Bool {
        guard let newSHA256, let info = try fs.stat(usb(relative)), info.kind == .file else { return false }
        let sha = try fs.sha256(usb(relative), uncached: false)
        return sha == newSHA256 && sha != oldSHA256
    }

    func rollbackFile(_ entry: UsbJournal.FileEntry) throws {
        guard entry.disposition != .reused, let temp = entry.tempName else { return }
        let parent = UsbPath.parent(entry.destination)
        let tempPath = UsbPath.join(parent, temp)
        let hadTemp = try exists(tempPath)
        if hadTemp {
            // rename 전: 대상 이름의 파일은 우리 것이 아닐 수 있어 건드리지 않는다
            try removeIfPresent(tempPath)
            try removeExactAppleDouble(parent: parent, name: temp)
        }
        switch entry.disposition {
        case .created:
            var applied = entry.state == .done
            if !applied, !hadTemp { applied = try holdsNewContent(entry.destination, newSHA256: entry.newSHA256, oldSHA256: nil) }
            guard applied else { return }
            try removeIfPresent(entry.destination)
            try restoreAppleDouble(of: entry.destination, preexisted: entry.appleDoublePreexisted)
        case .overwritten:
            let destinationExists = try exists(entry.destination)
            var applied = entry.state == .done || !destinationExists
            if !applied, !hadTemp {
                applied = try holdsNewContent(entry.destination, newSHA256: entry.newSHA256, oldSHA256: entry.oldSHA256)
            }
            guard applied else { return }
            try restoreFromBackup(entry.destination)
            try restoreAppleDouble(of: entry.destination, preexisted: entry.appleDoublePreexisted)
        case .reused:
            return
        }
    }

    func rollbackDatabase(_ entry: UsbJournal.DatabaseEntry) throws {
        let parent = UsbPath.parent(entry.destination)
        let tempPath = UsbPath.join(parent, entry.tempName)
        let hadTemp = try exists(tempPath)
        if hadTemp {
            try removeIfPresent(tempPath)
            try removeExactAppleDouble(parent: parent, name: entry.tempName)
        }
        let sidecars = UsbLayout.oneLibrarySidecarSuffixes.map { entry.destination + $0 }
        switch entry.disposition {
        case .created:
            // 쓰기 전에 없던 DB: DB와 사이드카(그 사이 기기·SQLite가 만들었을 수 있다), 정확한 이름의 ._만 지운다
            var applied = entry.state == .done
            if !applied, !hadTemp { applied = try holdsNewContent(entry.destination, newSHA256: entry.newSHA256, oldSHA256: nil) }
            guard applied else { return }
            try removeIfPresent(entry.destination)
            for sidecar in sidecars { try removeIfPresent(sidecar) }
            for name in [entry.destination] + sidecars {
                try removeExactAppleDouble(parent: parent, name: UsbPath.name(name))
            }
            try removeExactAppleDouble(parent: parent, name: entry.tempName)
        case .overwritten:
            let destinationExists = try exists(entry.destination)
            var applied = entry.state == .done || !destinationExists
            if !applied, !hadTemp {
                applied = try holdsNewContent(entry.destination, newSHA256: entry.newSHA256, oldSHA256: entry.oldSHA256)
            }
            if applied {
                for sidecar in sidecars { try removeIfPresent(sidecar) }
                try restoreFromBackup(entry.destination)
                for sidecar in entry.sidecarsPreexisted { try restoreFromBackup(sidecar) }
                try restoreAppleDouble(of: entry.destination, preexisted: entry.appleDoublePreexisted)
            } else {
                // rename 전에 사이드카만 지웠다: 백업에서 되살린다
                for sidecar in entry.sidecarsPreexisted where journal.deletedSidecars.contains(sidecar) {
                    if !(try exists(sidecar)) { try restoreFromBackup(sidecar) }
                }
            }
        case .reused:
            return
        }
    }

    /// `._<이름>`이 원래 있었으면 백업에서 되살리고, 없었으면 정확한 그 이름만 지운다
    func restoreAppleDouble(of path: String, preexisted: Bool) throws {
        guard let companion = UsbRemovalPolicy.appleDoubleCompanion(of: path) else { return }
        if preexisted, manifest?.files[companion] != nil {
            try restoreFromBackup(companion)
        } else {
            try removeExactAppleDouble(parent: UsbPath.parent(path), name: UsbPath.name(path))
        }
    }

    /// 백업 폴더의 파일을 같은 폴더 임시 이름으로 복사해 fsync한 뒤 rename한다
    func restoreFromBackup(_ path: String) throws {
        guard let backupFolder, let stamp = manifest?.files[path] else { throw UsbWriteFailure.failed("no backup of \(path)") }
        let source = backupFolder.appending(path: "files").appending(path: path)
        try makeParents(path)
        let parent = UsbPath.parent(path)
        let temp = nextTempName()
        let tempURL = usb(UsbPath.join(parent, temp))
        try ensureMounted()
        let copied = try fs.copyDataNew(from: source, to: tempURL) { _ in }
        guard copied.sha256 == stamp.sha256 else {
            try? fs.remove(tempURL)
            throw UsbWriteFailure.failed("backup damaged: \(path)")
        }
        try fs.setModificationDate(tempURL, stamp.mtime)
        try fs.fullSync(tempURL)
        try ensureMounted()
        try fs.rename(tempURL, to: usb(path))
        if !UsbLayout.isAppleDouble(UsbPath.name(path)) { try removeExactAppleDouble(parent: parent, name: temp) }
        try fs.syncDirectory(usb(parent))
    }

    /// 지운 파일을 되살린다. 음원은 로컬 원본의 SHA-1이 manifest와 같을 때만 다시 복사한다
    func restoreRemoved(_ path: String, strict: Bool) throws {
        if UsbPath.isAudio(path) {
            guard let audio = manifest?.removedAudio.first(where: { $0.path == path }), let original = audio.localOriginal else {
                throw UsbWriteFailure.failed("no local original for \(path)")
            }
            try makeParents(path)
            let parent = UsbPath.parent(path)
            let temp = nextTempName()
            let tempURL = usb(UsbPath.join(parent, temp))
            try ensureMounted()
            let copied = try fs.copyDataNew(from: URL(filePath: original), to: tempURL) { _ in }
            guard audio.localOriginalSHA1.map({ $0 == copied.sha1 }) ?? false else {
                try fs.remove(tempURL)
                try removeExactAppleDouble(parent: parent, name: temp)
                let note = String(ui: "음원 원본이 바뀌어 다시 복사하지 못했습니다: \(path)")
                if strict { throw UsbWriteFailure.failed(note) }
                report.notes.append(note)
                return
            }
            if let date = audio.modificationDate { try fs.setModificationDate(tempURL, date) }
            try fs.fullSync(tempURL)
            try ensureMounted()
            try fs.rename(tempURL, to: usb(path))
            try removeExactAppleDouble(parent: parent, name: temp)
            try restoreAppleDouble(of: path, preexisted: manifest?.appleDoublesPreexisting.contains(UsbRemovalPolicy.appleDoubleCompanion(of: path) ?? "") ?? false)
            try fs.syncDirectory(usb(parent))
            return
        }
        try restoreFromBackup(path)
        let companion = UsbRemovalPolicy.appleDoubleCompanion(of: path) ?? ""
        try restoreAppleDouble(of: path, preexisted: manifest?.appleDoublesPreexisting.contains(companion) ?? false)
    }

    /// 이 세션 이름으로 시작하는 임시 파일(저널에 적힌 것 + 되돌리며 만든 것)을 지운다
    func removeSessionTemps() throws {
        let prefix = UsbLayout.tempPrefix + journal.session + "-"
        var known = Set(journal.entries.compactMap { entry in entry.tempName.map { UsbPath.join(UsbPath.parent(entry.destination), $0) } })
        known.formUnion(journal.databases.map { UsbPath.join(UsbPath.parent($0.destination), $0.tempName) })
        for temp in try UsbWriter.tempFiles(root: root, fileSystem: fs) where UsbPath.name(temp).hasPrefix(prefix) {
            known.insert(temp)
        }
        for temp in known.sorted() where try exists(temp) {
            try removeIfPresent(temp)
            try removeExactAppleDouble(parent: UsbPath.parent(temp), name: UsbPath.name(temp))
        }
    }

    // MARK: - usb-restore

    func restore(backup: URL?, discardDeviceChanges: Bool, confirmName: String?, dryRun: Bool) throws -> UsbWriteReport {
        if writeGuard.isRekordboxRunning() {
            throw UsbError.restorePending(reason: String(ui: "rekordbox가 켜져 있습니다"))
        }
        let blocks = environmentBlocks(purpose: .edit, required: [], allowProvisional: [], confirmName: confirmName, checkRekordbox: false)
        if !blocks.isEmpty { throw UsbError.writeRefused(blocks) }
        switch UsbWriter.loadJournal(paths: paths, volumeKey: volumeKey) {
        case .open, .corrupt:
            throw UsbError.writeRefused([UsbBlock(code: "recoveryNeeded", scope: .volume,
                                                  message: String(ui: "지난 USB 쓰기가 끝나지 않았습니다. `djc usb-recover`로 먼저 회복하세요"))])
        case .missing, .closed: break
        }
        func refuse(_ code: String, _ message: String) -> UsbError {
            .writeRefused([UsbBlock(code: code, scope: .volume, message: message)])
        }
        guard let folder = backup ?? UsbWriter.backups(paths: paths, volumeKey: volumeKey).first(where: {
            FileManager.default.fileExists(atPath: $0.appending(path: "journal.json").path)
                && FileManager.default.fileExists(atPath: $0.appending(path: "report.json").path)
        }) else {
            throw refuse("noBackup", String(ui: "되돌릴 백업이 없습니다. 이 USB에 DJCrate로 쓴 기록이 있는지 확인하세요"))
        }
        let decoder = UsbJournal.decoder()
        guard let savedManifest = try? decoder.decode(UsbManifest.self, from: Data(contentsOf: folder.appending(path: "manifest.json"))),
              let saved = try? decoder.decode(UsbJournal.self, from: Data(contentsOf: folder.appending(path: "journal.json"))),
              let savedReport = try? decoder.decode(UsbWriteReport.self, from: Data(contentsOf: folder.appending(path: "report.json")))
        else {
            throw refuse("backupUnreadable", String(ui: "백업 폴더를 읽지 못했습니다. 다른 백업 폴더를 --backup으로 주세요"))
        }
        guard savedManifest.volumeUUID.uppercased() == volumeKey else {
            throw refuse("backupOtherVolume", String(ui: "다른 USB의 백업입니다. 이 USB의 백업 폴더를 주세요"))
        }
        backupFolder = folder
        manifest = savedManifest
        report = UsbWriteReport(outcome: .restored, session: saved.session, backup: folder.path)
        if saved.state == .rolledBack || savedReport.outcome == .rolledBack {
            report.notes.append(String(ui: "그 쓰기는 이미 되돌려져 있어 바꿀 것이 없습니다"))
            report.resultDatabases = try currentDatabaseHashes()
            return report
        }
        // 그 뒤 기기가 USB를 바꿨으면(기록·사이드카) 되돌리면 그 내용을 잃는다
        let current = try currentDatabaseHashes()
        var sidecarPresent = false
        for suffix in ["-wal", "-journal"] where try exists(UsbLayout.oneLibrary + suffix) { sidecarPresent = true }
        let changed = current != savedReport.resultDatabases || sidecarPresent || savedReport.outcome == .needsReplan
        if changed, !discardDeviceChanges {
            throw refuse("deviceChanged",
                         String(ui: "USB가 그 뒤에 바뀌었습니다(기기가 쓴 기록 등). 되돌리면 그 내용을 잃습니다. 그래도 되돌리려면 --discard-device-changes를 주세요"))
        }
        if dryRun {
            report.outcome = .dryRun
            report.filesCreated = saved.entries.filter { $0.disposition == .created }.count
            report.filesOverwritten = saved.entries.filter { $0.disposition == .overwritten }.count
            report.filesRemoved = saved.removals.filter { $0.state == .removed }.count
            report.resultDatabases = current
            return report
        }
        // 되돌리기도 USB 쓰기다: 끊기면 회복이 이어서 되돌리도록 저널을 restorePending으로 연다
        journal = saved
        journal.state = .restorePending
        journal.backupDirectory = folder.path
        try saveJournal()
        options = UsbWriteOptions()
        let errors: [String]
        do {
            errors = try rollback(mode: .restore)
        } catch UsbWriteFailure.volumeLost {
            throw UsbError.volumeLost(volumeName: volume.name)
        }
        report.filesRemoved = journal.entries.filter { $0.disposition == .created }.count
        report.filesOverwritten = journal.entries.filter { $0.disposition == .overwritten }.count
        report.resultDatabases = try currentDatabaseHashes()
        if !errors.isEmpty {
            report.outcome = .restoreFailed
            try journal.move(to: .restoreFailed)
            try saveJournal()
            throw UsbError.restoreFailed(reason: String(ui: "되돌리기"), restoreError: errors.joined(separator: "\n"), backup: folder.path)
        }
        try journal.move(to: .restored)
        try saveJournal()
        report.outcome = .restored
        return report
    }
}
