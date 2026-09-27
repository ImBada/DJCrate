import DJCDomain
import Foundation

/// D 파일(취소 가능): 음원 → 분석 파일 → 아트워크 → 그 밖. 파일마다 저널 항목을 먼저 적고
/// 같은 폴더 임시 이름에 써서 fsync → (덮어쓰기면 대상 해시·PPTH, 만들기면 충돌을 다시 보고) → rename → `._` 두 이름 → 폴더 fsync → done.
extension UsbWriteRun {
    enum FileItem {
        case copy(UsbFileCopy)
        case write(UsbFileWrite)

        var destination: String {
            switch self {
            case let .copy(copy): copy.destination
            case let .write(write): write.destination
            }
        }

        var disposition: UsbDisposition {
            switch self {
            case let .copy(copy): copy.disposition
            case let .write(write): write.disposition
            }
        }

        var size: Int64 {
            switch self {
            case let .copy(copy): copy.size
            case let .write(write): write.size
            }
        }
    }

    static func orderedItems(_ changes: UsbChangeSet) -> [FileItem] {
        func rank(_ write: UsbFileWrite) -> Int {
            UsbPath.isAnalysis(write.destination) ? 0 : UsbPath.isArtwork(write.destination) ? 1 : 2
        }
        let writes = changes.writes.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        return changes.copies.map(FileItem.copy) + writes.map(FileItem.write)
    }

    func writeFiles(_ changes: UsbChangeSet, isCancelled: @Sendable () -> Bool) throws {
        try checkRekordbox()
        let items = Self.orderedItems(changes)
        let totalBytes = items.filter { $0.disposition != .reuse }.reduce(Int64(0)) { $0 + $1.size }
        var doneBytes: Int64 = 0
        emit(.files, total: items.count, totalBytes: totalBytes, cancellable: true)
        for (index, item) in items.enumerated() {
            if isCancelled() { throw UsbWriteFailure.cancelled }
            try ensureMounted()
            try place(item) { bytes in
                self.emit(.files, done: index, total: items.count, bytes: doneBytes + bytes, totalBytes: totalBytes, cancellable: true)
            }
            if item.disposition != .reuse { doneBytes += item.size }
            emit(.files, done: index + 1, total: items.count, bytes: doneBytes, totalBytes: totalBytes, cancellable: true)
        }
        try journal.move(to: .filesWritten)
        try saveJournal()
    }

    /// 없는 폴더를 위에서부터 한 단계씩 만든다. 저널에 먼저 적고 만든 뒤 부모의 정확한 `._<폴더>`를 지운다
    func ensureParents(_ destination: String) throws {
        var path = ""
        for component in UsbPath.parent(destination).split(separator: "/") {
            path = UsbPath.join(path, String(component))
            if let info = try fs.stat(usb(path)) {
                guard info.kind == .directory else { throw UsbWriteFailure.failed("not a directory: \(path)") }
                continue
            }
            journal.createdDirs.append(path)
            try saveJournal()
            try ensureMounted()
            try fs.makeDirectory(usb(path))
            try removeExactAppleDouble(parent: UsbPath.parent(path), name: UsbPath.name(path))
        }
    }

    func place(_ item: FileItem, progress: (Int64) -> Void) throws {
        let destination = item.destination
        let parent = UsbPath.parent(destination), name = UsbPath.name(destination)
        try ensureParents(destination)
        if item.disposition == .reuse {
            try reuse(item)
            return
        }
        let temp = nextTempName()
        let tempURL = usb(UsbPath.join(parent, temp))
        let appleDouble = try fs.stat(usb(UsbPath.join(parent, UsbLayout.appleDoubleName(for: name)))) != nil
        var newSHA256: String?
        var oldSHA256: String?
        if case let .write(write) = item {
            newSHA256 = write.sha256
            oldSHA256 = write.disposition == .overwrite ? write.expectedExistingSHA256 : nil
        }
        // 임시 파일을 쓰기 전에 항목을 먼저 내린다(끊기면 회복이 이 임시 이름을 찾는다)
        journal.entries.append(.init(destination: destination, tempName: temp,
                                     disposition: item.disposition == .overwrite ? .overwritten : .created,
                                     oldSHA256: oldSHA256, newSHA256: newSHA256, size: item.size,
                                     appleDoublePreexisted: appleDouble, state: .pending))
        let entry = journal.entries.count - 1
        try saveJournal()

        try ensureMounted()
        switch item {
        case let .copy(copy):
            let result = try fs.copyDataNew(from: URL(filePath: copy.source), to: tempURL, progress: progress)
            guard result.size == copy.size, copy.sourceSHA1.map({ $0 == result.sha1 }) ?? true else {
                throw UsbWriteFailure.failed("source changed while copying: \(copy.source)")
            }
            try fs.setModificationDate(tempURL, copy.modificationDate)
            try fs.fullSync(tempURL)
            journal.entries[entry].newSHA256 = result.sha256
            try saveJournal()
        case let .write(write):
            let data = try readStaged(write.staged, sha256: write.sha256, size: write.size)
            try fs.writeNew(data, to: tempURL)
            if let date = write.modificationDate { try fs.setModificationDate(tempURL, date) }
            try fs.fullSync(tempURL)
            progress(write.size)
            if write.disposition == .overwrite { try checkOverwriteTarget(write) }
        }
        if item.disposition == .create {
            try ensureMounted()
            try recheckCollision(destination, temp: temp)
        }
        try ensureMounted()
        try fs.rename(tempURL, to: usb(destination))
        try removeExactAppleDouble(parent: parent, name: name)
        try removeExactAppleDouble(parent: parent, name: temp)
        try fs.syncDirectory(usb(parent))
        journal.entries[entry].state = .done
        try saveJournal()
        if item.disposition == .overwrite { report.filesOverwritten += 1 } else { report.filesCreated += 1 }
    }

    /// 재사용: USB 파일이 계획과 같은지만 본다(쓰지 않는다)
    func reuse(_ item: FileItem) throws {
        let url = usb(item.destination)
        guard let info = try fs.stat(url), info.kind == .file, info.size == item.size else {
            throw UsbWriteFailure.failed("reused file differs: \(item.destination)")
        }
        var sha: String?
        if case let .write(write) = item {
            sha = try fs.sha256(url, uncached: false)
            guard sha == write.sha256 else { throw UsbWriteFailure.failed("reused file differs: \(item.destination)") }
        }
        journal.entries.append(.init(destination: item.destination, tempName: nil, disposition: .reused, oldSHA256: sha, newSHA256: sha,
                                     size: item.size, appleDoublePreexisted: false, state: .done))
        try saveJournal()
        report.filesReused += 1
    }

    /// 덮어쓸 대상이 계획 때 그 파일인지(해시), 분석 파일이면 같은 곡 것인지(PPTH)
    func checkOverwriteTarget(_ write: UsbFileWrite) throws {
        let url = usb(write.destination)
        guard try fs.sha256(url, uncached: false) == write.expectedExistingSHA256 else {
            throw UsbWriteFailure.failed("overwrite target changed: \(write.destination)")
        }
        if UsbPath.isAnalysis(write.destination), let expected = write.expectedExistingPPTH, let ppthReader {
            let found = ppthReader(try fs.read(url, maxBytes: 64 << 20)).map(UsbLayout.nfc)
            guard found == UsbLayout.nfc(expected) else {
                throw UsbWriteFailure.failed("analysis file belongs to another track: \(write.destination)")
            }
        }
    }

    /// rename 직전: 우리 임시 파일이 아닌 같은 충돌 키의 이름이 생겼으면 rename하지 않는다(그 파일은 우리 것이 아니다)
    func recheckCollision(_ destination: String, temp: String) throws {
        let key = UsbLayout.collisionKey(UsbPath.name(destination))
        let listed = try fs.list(usb(UsbPath.parent(destination)))
        if listed.contains(where: { $0 != temp && UsbLayout.collisionKey($0) == key }) {
            throw UsbWriteFailure.failed("destination appeared: \(destination)")
        }
    }
}
