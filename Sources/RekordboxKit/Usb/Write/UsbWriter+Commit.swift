import DJCDomain
import Foundation

/// E DB 교체(커밋 지점, 순서 고정: exportLibrary.db → export.pdb → exportExt.pdb).
/// DB마다 rekordbox·마운트를 다시 보고, 항목을 저널에 먼저 적은 뒤 임시 이름에 써서 fsync → (OneLibrary면 사이드카 지우기) → rename.
/// 맞바꾸기 rename은 FAT에서 맞바꾸지 않고 덮어써 쓰지 않는다.
extension UsbWriteRun {
    static func orderedDatabases(_ changes: UsbChangeSet) -> [UsbDatabaseReplacement] {
        changes.databases.sorted {
            (UsbWriter.databaseOrder.firstIndex(of: $0.destination) ?? 99) < (UsbWriter.databaseOrder.firstIndex(of: $1.destination) ?? 99)
        }
    }

    static func stage(for database: String) -> UsbWriteStage {
        switch database {
        case UsbLayout.oneLibrary: .commitOneLibrary
        case UsbLayout.exportPdb: .commitExport
        default: .commitExportExt
        }
    }

    func commitDatabases(_ changes: UsbChangeSet, only destinations: Set<String>? = nil) throws {
        let databases = Self.orderedDatabases(changes).filter { destinations?.contains($0.destination) ?? true }
        for (index, database) in databases.enumerated() {
            emit(.commit, done: index, total: databases.count, cancellable: false)
            try commitDatabase(database)
            stageReached(Self.stage(for: database.destination))
        }
        emit(.commit, done: databases.count, total: databases.count, cancellable: false)
        if journal.state != .committed { try journal.move(to: .committed) }
        try saveJournal()
    }

    func commitDatabase(_ database: UsbDatabaseReplacement) throws {
        let destination = database.destination
        let parent = UsbPath.parent(destination), name = UsbPath.name(destination)
        try ensureParents(destination)
        try checkRekordbox()
        try ensureMounted()
        guard let planned = journal.plannedDatabases.first(where: { $0.destination == destination }) else {
            throw UsbWriteFailure.failed("unplanned database: \(destination)")
        }
        // 쓰기 전 확인에서 정한 처리와 지금 USB가 맞아야 한다
        let exists = try fs.stat(usb(destination))?.kind == .file
        guard exists == (planned.disposition == .overwritten) else { throw UsbWriteFailure.failed("database changed: \(destination)") }
        var sidecars: [String] = []
        if database.format == .oneLibrary {
            for suffix in UsbLayout.oneLibrarySidecarSuffixes where try fs.stat(usb(destination + suffix)) != nil {
                sidecars.append(destination + suffix)
            }
        }
        let appleDouble = try fs.stat(usb(UsbPath.join(parent, UsbLayout.appleDoubleName(for: name)))) != nil
        let temp = nextTempName()
        let tempURL = usb(UsbPath.join(parent, temp))
        journal.databases.append(.init(destination: destination, format: database.format, tempName: temp, disposition: planned.disposition,
                                       oldSHA256: planned.oldSHA256, newSHA256: database.sha256, appleDoublePreexisted: appleDouble,
                                       sidecarsPreexisted: sidecars, state: .pending))
        let entry = journal.databases.count - 1
        if journal.state != .committing { try journal.move(to: .committing) }
        try saveJournal()

        let data = try readStaged(database.staged, sha256: database.sha256, size: database.size)
        try ensureMounted()
        try fs.writeNew(data, to: tempURL)
        try fs.fullSync(tempURL)
        if !sidecars.isEmpty {
            // 옛 WAL이 새 DB에 겹쳐 읽히지 않게 rename 전에 지운다(백업에 있다)
            journal.deletedSidecars += sidecars
            try saveJournal()
            for sidecar in sidecars {
                try ensureMounted()
                try fs.remove(usb(sidecar))
            }
        }
        try ensureMounted()
        try fs.rename(tempURL, to: usb(destination))
        try removeExactAppleDouble(parent: parent, name: name)
        try removeExactAppleDouble(parent: parent, name: temp)
        try fs.syncDirectory(usb(parent))
        journal.databases[entry].state = .done
        try saveJournal()
    }
}
