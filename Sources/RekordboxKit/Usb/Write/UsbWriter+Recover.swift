import DJCDomain
import Foundation

/// 회복: 끊긴 쓰기를 대상(DB)부터 보고 마저 쓰거나 되돌린다. 쓰기와 같은 확인(관문 포함)을 거친 뒤에만 USB 파일을 연다.
/// 1. DB마다 분류(옛 해시·새 해시·없음·그 밖). 그 밖이 하나라도 있으면(기기가 바꿈) 우리 임시 파일만 지우고 "다시 계획"으로 닫는다.
/// 2. rename 도중 끊긴 항목(대상 없음 + 임시 완전)은 rename을 마친다.
/// 3. 모든 DB가 새것이면 지우기·검증을 다시 → recovered. 일부만이면 준비 폴더가 온전할 때 마저 쓴다. 아니면 되돌린다.
/// 저널에 적힌 임시 파일은 이 판정들이 끝난 뒤 지운다. 닫을 때 백업 폴더에 journal.json·report.json을 남긴다.
/// 끊긴 되돌리기(usb-restore가 연 저널)는 되돌리기로 마저 한다. 저널·백업 기록의 경로가 USB 루트 밖을 가리키면 아무것도 하지 않는다.
extension UsbWriteRun {
    enum DatabaseState: Equatable { case absent, old, new, other }

    func recover(discardTemp: Bool, confirmName: String?) throws -> UsbWriteReport {
        let blocks = environmentBlocks(purpose: .edit, required: [], confirmName: confirmName)
        if !blocks.isEmpty { throw UsbError.writeRefused(blocks) }
        switch UsbWriter.journalStatus(paths: paths, volumeKey: volumeKey) {
        case .missing, .closed:
            return try recoverWithoutJournal(discardTemp: discardTemp)
        case .corrupt:
            throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
        case let .open(found):
            // 깨졌거나 누가 고친 기록이 USB 루트 밖을 가리키면 파일 연산 전에 막는다
            guard UsbWriter.unsafeEntries(in: found).isEmpty else { throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock]) }
            journal = found
        }
        // 백업 폴더는 이 볼륨의 usb-backups 아래만. 없어진 폴더는 없는 것으로 본다(기록을 새로 만들지 않는다)
        if let directory = journal.backupDirectory, FileManager.default.fileExists(atPath: directory) {
            let folder = URL(filePath: directory)
            guard isOurBackupFolder(folder) else { throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock]) }
            backupFolder = folder
            manifest = try? UsbJournal.decoder().decode(UsbManifest.self, from: Data(contentsOf: folder.appending(path: "manifest.json")))
            if let manifest, !UsbWriter.unsafeEntries(in: manifest).isEmpty { throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock]) }
        }
        report = UsbWriteReport(outcome: .recovered, session: journal.session, backup: backupFolder?.path)
        report.filesCreated = journal.entries.filter { $0.disposition == .created && $0.state == .done }.count
        emit(.recover, cancellable: false)
        do {
            return try recoverOpenJournal()
        } catch UsbWriteFailure.volumeLost {
            throw volumeGone
        }
    }

    private func recoverOpenJournal() throws -> UsbWriteReport {
        try ensureSameVolume()
        if journal.restoringBackup {
            // 끊긴 되돌리기: 기기 변경 여부는 되돌리기를 시작할 때 이미 판정했다. 같은 방식으로 마저 되돌린다
            guard let backupFolder else { throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock]) }
            return try finishRestore(errors: rollback(mode: .restore), folder: backupFolder, reason: String(ui: "회복"))
        }
        if [.planned, .staged].contains(journal.state) {
            // 백업 전에 끊겼다: USB에 쓴 것이 없다
            try removeSessionTemps()
            if backupFolder == nil {
                report.notes.append(String(ui: "쓰기 전에 끊겨 USB에 쓴 것이 없습니다(백업 기록 없음)"))
            }
            try closeJournal(.rolledBack, outcome: .rolledBack)
            return report
        }
        if try classifyDatabases().values.contains(.other) {
            try removeSessionTemps()
            report.notes.append(String(ui: "USB가 기기에서 바뀌어 이어 쓰지 않았습니다. 지금 USB 상태로 다시 미리 보기한 뒤 쓰세요"))
            try closeJournal(.needsReplan, outcome: .needsReplan)
            return report
        }
        let rollbackOnly = [.restorePending, .restoreFailed].contains(journal.state)
        var mustRollBack = rollbackOnly
        if !rollbackOnly { mustRollBack = try !completeInterruptedRenames() }
        let states = try classifyDatabases()
        let allNew = states.values.allSatisfy { $0 == .new }
        let someNew = states.values.contains(.new)
        // 파일 단계를 마친 뒤(DB 교체가 시작된 뒤)에만 앞으로 간다
        let filesDone = journal.entries.allSatisfy { $0.state == .done }
            && [.filesWritten, .committing, .committed, .cleaned].contains(journal.state)
        if !mustRollBack, filesDone, allNew || (someNew && canResume(states)) {
            do {
                if !allNew { try resumeCommit(states) }
                if [.filesWritten, .committing].contains(journal.state) { try journal.move(to: .committed) }
                try saveJournal()
                try cleanup(journal.changes)
                try verify(journal.changes, verifiers: [UsbFingerprintVerifier()])
                try removeSessionTemps()
                try closeJournal(.recovered, outcome: .recovered)
                return report
            } catch UsbWriteFailure.volumeLost {
                throw UsbWriteFailure.volumeLost
            } catch let error as UsbError {
                throw error
            } catch {
                report.notes.append(String(ui: "마저 쓰지 못해 되돌렸습니다: \(String(describing: error))"))
            }
        }
        let errors = try rollback(mode: .recover)
        if errors.isEmpty {
            try closeJournal(.rolledBack, outcome: .rolledBack)
            return report
        }
        try closeJournal(.restoreFailed, outcome: .restoreFailed)
        throw UsbError.restoreFailed(reason: String(ui: "회복"), restoreError: errors.joined(separator: "\n"),
                                     backup: backupFolder?.path ?? "")
    }

    /// DB 대상마다: 옛 해시(없던 DB는 없음이 옛것)·새 해시·없음(rename 도중)·그 밖(기기가 바꿈)
    func classifyDatabases() throws -> [String: DatabaseState] {
        var states: [String: DatabaseState] = [:]
        for database in journal.changes.databases {
            let planned = journal.plannedDatabases.first { $0.destination == database.destination }
            let url = usb(database.destination)
            guard let info = try fs.stat(url) else {
                states[database.destination] = planned?.disposition == .created ? .old : .absent
                continue
            }
            guard info.kind == .file else {
                states[database.destination] = .other
                continue
            }
            let sha = try fs.sha256(url, uncached: true)
            if sha == database.sha256 {
                states[database.destination] = .new
            } else if planned?.disposition == .overwritten, sha == planned?.oldSHA256 {
                states[database.destination] = .old
            } else {
                states[database.destination] = .other
            }
        }
        return states
    }

    /// 대상이 없고 임시가 완전(새 해시)하면 rename을 마친다. 대상이 없고 임시가 불완전하면 덮어쓴 것은 백업에서 되살린다.
    /// 만들 파일 자리에 남의 파일이 생겼으면 false(되돌려야 한다)
    func completeInterruptedRenames() throws -> Bool {
        var ok = true
        for index in journal.databases.indices where journal.databases[index].state == .pending {
            let entry = journal.databases[index]
            let parent = UsbPath.parent(entry.destination)
            let temp = UsbPath.join(parent, entry.tempName)
            guard try !exists(entry.destination) else { continue }
            if try isComplete(temp, sha256: entry.newSHA256) {
                if entry.disposition == .created, try collides(entry.destination, temp: entry.tempName) {
                    ok = false
                    continue
                }
                try finishRename(temp: temp, destination: entry.destination)
                journal.databases[index].state = .done
                try saveJournal()
            } else if entry.disposition == .overwritten {
                try restoreFromBackup(entry.destination)
            }
        }
        for index in journal.entries.indices where journal.entries[index].state == .pending {
            let entry = journal.entries[index]
            guard let tempName = entry.tempName else { continue }
            let temp = UsbPath.join(UsbPath.parent(entry.destination), tempName)
            guard try !exists(entry.destination) else { continue }
            if let sha = entry.newSHA256, try isComplete(temp, sha256: sha) {
                if entry.disposition == .created, try collides(entry.destination, temp: tempName) {
                    ok = false
                    continue
                }
                try finishRename(temp: temp, destination: entry.destination)
                journal.entries[index].state = .done
                try saveJournal()
            } else if entry.disposition == .overwritten {
                try restoreFromBackup(entry.destination)
            }
        }
        return ok
    }

    func isComplete(_ relative: String, sha256: String) throws -> Bool {
        guard let info = try fs.stat(usb(relative)), info.kind == .file else { return false }
        return try fs.sha256(usb(relative), uncached: true) == sha256
    }

    func collides(_ destination: String, temp: String) throws -> Bool {
        do {
            try recheckCollision(destination, temp: temp)
            return false
        } catch UsbWriteFailure.failed {
            return true
        }
    }

    func finishRename(temp: String, destination: String) throws {
        let parent = UsbPath.parent(destination)
        try ensureMounted()
        try fs.rename(usb(temp), to: usb(destination))
        try removeExactAppleDouble(parent: parent, name: UsbPath.name(destination))
        try removeExactAppleDouble(parent: parent, name: UsbPath.name(temp))
        try fs.syncDirectory(usb(parent))
    }

    /// 남은 DB가 모두 옛것이고 준비 폴더의 새 DB가 온전하면 마저 쓸 수 있다
    func canResume(_ states: [String: DatabaseState]) -> Bool {
        for database in journal.changes.databases where states[database.destination] != .new {
            guard states[database.destination] == .old else { return false }
            let url = URL(filePath: database.staged)
            guard (try? fs.stat(url))??.size == database.size, (try? fs.sha256(url, uncached: false)) == database.sha256 else { return false }
        }
        return true
    }

    /// 아직 옛것인 DB를 이어서 교체한다(끊긴 항목의 임시 파일은 지우고 새로 쓴다)
    func resumeCommit(_ states: [String: DatabaseState]) throws {
        let remaining = Set(journal.changes.databases.map(\.destination).filter { states[$0] != .new })
        for index in journal.databases.indices.reversed() where remaining.contains(journal.databases[index].destination) {
            let entry = journal.databases[index]
            try removeIfPresent(UsbPath.join(UsbPath.parent(entry.destination), entry.tempName))
            journal.databases.remove(at: index)
        }
        try saveJournal()
        try commitDatabases(journal.changes, only: remaining)
    }

    /// 저널이 없으면 우리 폴더의 임시 파일을 알리기만 하고, `discardTemp`일 때만 지운다
    func recoverWithoutJournal(discardTemp: Bool) throws -> UsbWriteReport {
        var report = UsbWriteReport(outcome: .recovered, session: "")
        do {
            try ensureSameVolume()
            let temps = try UsbWriter.tempFiles(root: root, fileSystem: fs)
            if temps.isEmpty {
                report.notes.append(String(ui: "끝나지 않은 쓰기가 없습니다"))
            } else if discardTemp {
                for temp in temps {
                    try ensureMounted()
                    try fs.remove(usb(temp))
                }
                report.notes.append(String(ui: "끝나지 않은 쓰기의 임시 파일 \(temps.count)개를 지웠습니다"))
            } else {
                report.notes.append(String(ui: "쓰기 기록은 없고 임시 파일 \(temps.count)개가 있습니다. 지우려면 --discard-temp를 주세요"))
            }
        } catch UsbWriteFailure.volumeLost {
            throw volumeGone
        }
        return report
    }
}
