import DJCDomain
import Darwin
import Foundation
import RekordboxKit

/// USB(마운트된 볼륨 또는 USB 모양 폴더)를 읽기만 해서 무엇이 있는지·건강한지 본다(`djc usb-info`·앱 사이드바).
/// DB는 `UsbSnapshot`으로 뜬 사본에서만 열고, 분석 파일은 DB가 가리키는 파일만 읽는다. USB에는 아무것도 쓰지 않고
/// 열지 않는 경로(`UsbLayout.neverRead`)는 열지도 이름을 내보내지도 않는다.
public enum UsbRead {
    /// 폴더 대상(Mac 시동·데이터 볼륨)의 마운트 지점
    static let startupMounts: Set<String> = ["/", "/System/Volumes/Data"]

    /// 대상 경로가 든 볼륨. 마운트 지점이 아닌 하위 폴더여도 그 볼륨으로 본다(실물 볼륨 안 폴더로 비켜 가지 못하게).
    /// 시동 볼륨(Mac 데이터 볼륨의 폴더)이면 nil. 마운트 지점을 알 수 없으면 읽지 않는다
    public static func volume(for root: URL, mountedOn: (String) -> String? = UsbScratchRoots.mountedOn,
                              volumeInfo: (URL) throws -> UsbVolumeInfo = { try UsbVolumes.info(root: $0) }) throws -> UsbVolumeInfo? {
        guard let real = UsbScratchRoots.realPath(root.path) else {
            throw UsbError.readFailed(detail: "realpath \(root.path): \(String(cString: strerror(errno)))")
        }
        guard let mount = mountedOn(real) else { throw UsbError.readFailed(detail: "statfs \(root.path)") }
        if startupMounts.contains(mount) { return nil }
        return try volumeInfo(URL(filePath: real))
    }

    /// 실물 읽기 허용 판정(순수). nil이면 읽어도 된다. 순서: 거부 목록의 UUID → 디스크 이미지는 허용 → 목록이 깨짐 →
    /// 고정 위치 목록이 없거나 비었음 → 볼륨 UUID를 모름. 거부 목록이 증거용 USB를 가려낼 유일한 수단이라, 목록 없이는
    /// 실물을 읽지 않고, UUID를 모르는 실물은 목록과 맞춰 볼 수 없으니 읽지 않는다(쓰기 관문과 같은 fail-closed)
    public static func readRefusal(volume: UsbVolumeInfo, lists: UsbPhysicalLists.Loaded) -> String? {
        let uuid = volume.volumeUUID?.uppercased()
        if let uuid, lists.deny.contains(where: { $0.uppercased() == uuid }) { return "denylisted" }
        if volume.isDiskImage { return nil }
        if lists.denyStatus.fixedLocation == .corrupt || lists.denyStatus.userData == .corrupt { return "denyListUnreadable" }
        if lists.denyStatus.fixedLocation == .missing || lists.denyStatus.fixedPhysicalCount < 1 { return "denyListNotRegistered" }
        guard let uuid, !uuid.isEmpty else { return "noVolumeUUID" }
        return nil
    }

    /// 막힘 code → 이유와 할 일
    public static func refusalMessage(_ code: String) -> String {
        switch code {
        case "denylisted": String(ui: "쓰기 금지 목록의 USB라 읽지 않습니다")
        case "denyListUnreadable": String(ui: "쓰기 금지 목록 파일을 읽을 수 없어 실물 USB를 읽지 않습니다. 목록 파일을 고친 뒤 다시 시도하세요")
        case "denyListNotRegistered": String(ui: "쓰기 금지 목록이 비어 있어 실물 USB를 읽지 않습니다. 쓰면 안 되는 USB를 사이드바의 ‘쓰기 금지 목록에 넣기…’나 djc usb-deny로 먼저 등록하세요")
        case "noVolumeUUID": String(ui: "USB의 볼륨 UUID를 읽지 못해 실물 USB를 읽지 않습니다. USB를 다시 연결한 뒤 시도하세요")
        default: UsbError.readFailed(detail: code).errorDescription ?? code
        }
    }

    /// 막힘 code 목록
    public static let refusalCodes: Set<String> = ["denylisted", "denyListUnreadable", "denyListNotRegistered", "noVolumeUUID"]

    /// 사본을 떠서(UsbSnapshot) 읽는다. USB에 아무것도 쓰지 않는다. neverRead를 열지 않는다.
    /// - volume: 대상이 든 볼륨(`volume(for:)`), 폴더 대상이면 nil. 볼륨이면 먼저 `readRefusal`로 보고, 막히면 사본도 뜨지 않고
    ///   `UsbError.readFailed(detail: <막힘 code>)`를 던진다. nil이면 대상이 정말 Mac 시동·데이터 볼륨 위인지 다시 보고,
    ///   아니면 `volumeNotChecked`를 던진다(부르는 쪽이 볼륨을 빠뜨려도 목록 판정을 건너뛰지 않게)
    /// - scratch: 사본을 뜰 Mac 쪽 폴더(없거나 비어 있어야 한다. 아니면 `scratch not empty`). 끝나면 이 호출이 뜬 사본만 지운다
    /// - lists: 쓰기 금지 목록 상태. 시험은 임시 값을 넘긴다
    /// - mountedOn: statfs 마운트 지점(시험은 가짜를 넘긴다)
    public static func info(root: URL, scratch: URL, volume: UsbVolumeInfo?, lists: UsbPhysicalLists.Loaded = UsbPhysicalLists.load(),
                            mountedOn: (String) -> String? = UsbScratchRoots.mountedOn,
                            appVersion: () -> String? = { RekordboxCompatibility.installedAppVersion() }) throws -> UsbInfo {
        if let volume {
            if let code = readRefusal(volume: volume, lists: lists) { throw UsbError.readFailed(detail: code) }
        } else {
            guard let real = UsbScratchRoots.realPath(root.path), let mount = mountedOn(real), startupMounts.contains(mount) else {
                throw UsbError.readFailed(detail: "volumeNotChecked")
            }
        }
        // 이미 무엇이 든 폴더(USB 루트 포함)를 사본 폴더로 받으면 끝낼 때 남의 파일을 지울 수 있다
        let fm = FileManager.default
        if fm.fileExists(atPath: scratch.path), (try? fm.contentsOfDirectory(atPath: scratch.path))?.isEmpty != true {
            throw UsbError.readFailed(detail: "scratch not empty")
        }
        let usb = UsbRoot(root)
        var info = UsbInfo(root: root.path)
        info.volume = volume.map(volumePart)
        let version = appVersion()
        info.localCompatibility = UsbInfo.Local(rekordboxVersion: version, verified: isVerified(version))

        let names = try rekordboxFileNames(usb)
        let hasOneLibrary = names.contains((UsbLayout.oneLibrary as NSString).lastPathComponent)
        let hasPdb = names.contains((UsbLayout.exportPdb as NSString).lastPathComponent)
        info.formats = (hasOneLibrary ? [UsbFormat.oneLibrary.rawValue] : []) + (hasPdb ? [UsbFormat.deviceLibrary.rawValue] : [])
        info.settings = settings(usb)
        if info.settings.contains(where: { $0.status == .invalid || $0.status == .unreadable }) {
            info.warnings.append(UsbInfo.Warning(code: "settingsInvalid",
                message: String(ui: "설정 파일을 확인하지 못했으므로 rekordbox에서 기기 설정을 다시 저장한 뒤 USB로 내보내세요")))
        }
        guard hasOneLibrary || hasPdb else { return info }

        let createdScratch = !fm.fileExists(atPath: scratch.path)
        let databaseCopy = scratch.appending(path: "db"), pdbCopy = scratch.appending(path: "pdb")
        defer {
            for url in [databaseCopy, pdbCopy] { try? fm.removeItem(at: url) }
            if createdScratch { try? fm.removeItem(at: scratch) }
        }

        var warnings = info.warnings
        func warn(_ code: String, _ message: String) { warnings.append(UsbInfo.Warning(code: code, message: message)) }
        var oneLibrary: UsbLibrary?, deviceLibrary: UsbLibrary?
        var report: PdbReadReport?
        var roundTrip: [String]?

        do {
            let snapshot = try UsbSnapshot.take(root: usb, into: databaseCopy)
            if let copy = snapshot.oneLibrary {
                var part = UsbInfo.OneLibraryPart(schemaOK: true, headerMode: snapshot.flags.headerMode == .rollback ? "rollback" : "wal",
                                                  walPresent: snapshot.flags.walPresent, journalPresent: snapshot.flags.journalPresent,
                                                  integrityOK: true, tracks: 0, playlists: 0, myTags: 0, histories: 0)
                do {
                    let library = try OneLibraryReader.read(copyAt: copy)
                    oneLibrary = library
                    part.tracks = library.tracks.count
                    part.playlists = library.playlists.count
                    part.myTags = library.myTags.count
                    part.histories = library.histories.count
                } catch let error as UsbError {
                    guard case .formatUnsupported = error else { throw error }
                    part.schemaOK = false
                    warn("oneLibraryUnsupported", String(ui: "이 USB의 OneLibrary는 DJCrate가 확인하지 않은 모양입니다. DJCrate 업데이트를 확인하세요"))
                }
                info.oneLibrary = part
            }
            report = try readDeviceLibrary(snapshot.exportPdb.map { ($0, snapshot.exportExtPdb) }, into: &deviceLibrary,
                                           roundTrip: &roundTrip, warn: warn)
        } catch let error as UsbError where hasOneLibrary && isOneLibraryFailure(error) {
            // OneLibrary 사본이 온전하지 않다(무결성·암호). Device Library는 따로 떠서 읽는다
            info.oneLibrary = UsbInfo.OneLibraryPart(schemaOK: false, headerMode: "unknown",
                                                     walPresent: exists(usb, UsbLayout.oneLibrary + "-wal"),
                                                     journalPresent: exists(usb, UsbLayout.oneLibrary + "-journal"),
                                                     integrityOK: false, tracks: 0, playlists: 0, myTags: 0, histories: 0)
            warn("oneLibraryUnreadable", String(ui: "OneLibrary(exportLibrary.db)가 손상돼 읽지 못했습니다. rekordbox로 USB를 다시 내보내세요"))
            report = try readDeviceLibrary(try copyPdb(usb, into: pdbCopy), into: &deviceLibrary, roundTrip: &roundTrip, warn: warn)
        }

        if let part = info.oneLibrary, part.walPresent || part.journalPresent {
            warn("oneLibrarySidecar", String(ui: "OneLibrary에 기기가 쓰다 남긴 파일(-wal·-journal)이 있습니다. 기기에서 USB를 정상적으로 꺼낸 뒤 다시 읽으세요"))
        }
        if let report {
            info.deviceLibrary = deviceLibraryPart(report, library: deviceLibrary, roundTrip: roundTrip)
            if report.exportHeader.flag10 != 5 || (report.extHeader.map { $0.flag10 != 5 } ?? false) {
                warn("pdbOpenFlag", String(ui: "rekordbox에 이 USB를 연결했다가 정상적으로 꺼낸 뒤 다시 시도하세요"))
            }
            if let part = info.deviceLibrary {
                if part.unknownTableRows > 0 {
                    warn("unknownTableRows", String(ui: "Device Library에 DJCrate가 모르는 표의 행이 있습니다. 고치기 전에 rekordbox로 USB를 다시 내보내세요"))
                }
                if part.structureIssues > 0 {
                    warn("pdbStructure", String(ui: "Device Library 구조에 문제가 있습니다. rekordbox로 USB를 다시 내보내세요"))
                }
                if let roundTrip, !roundTrip.isEmpty {
                    // 문제 수만 적는다(곡 제목·경로·칸 값 없이)
                    warn("pdbRoundTripFailed", String(ui: "이 USB의 Device Library는 DJCrate가 다시 쓸 수 없는 모양입니다(문제 \(roundTrip.count)개). 고치려면 rekordbox로 USB를 다시 내보내세요"))
                }
            }
        }

        info.consistency = consistency(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary)
        if info.consistency.editBlocked {
            warn("formatMismatch", String(ui: "두 형식(OneLibrary·Device Library)의 곡이나 재생 목록이 서로 달라 이 USB는 고칠 수 없습니다. rekordbox로 USB를 다시 내보내세요"))
        }
        info.analysis = analysis(usb, oneLibrary: oneLibrary, deviceLibrary: deviceLibrary)
        if info.analysis.missingFiles > 0 {
            warn("analysisMissing", String(ui: "분석 파일이 없는 곡이 있습니다. rekordbox로 USB를 다시 내보내세요"))
        }
        if info.analysis.ppthMismatches > 0 {
            warn("analysisPathMismatch", String(ui: "분석 파일에 적힌 곡 경로가 DB와 다른 곡이 있습니다. rekordbox로 USB를 다시 내보내세요"))
        }
        info.media = media(usb, oneLibrary: oneLibrary, deviceLibrary: deviceLibrary)
        if info.media.missingFiles > 0 {
            warn("mediaMissing", String(ui: "음원 파일이 없는 곡이 있으므로 rekordbox로 USB를 다시 내보내세요"))
        }
        info.warnings = warnings
        return info
    }

    // MARK: - 부분

    static func isVerified(_ version: String?) -> Bool {
        guard let version else { return false }
        return (try? RekordboxCompatibility.checkApp(version: version)) != nil
    }

    static func volumePart(_ volume: UsbVolumeInfo) -> UsbInfo.Volume {
        let export = UsbVolumePolicy.problems(volume, purpose: .export).map(\.code)
        let edit = UsbVolumePolicy.problems(volume, purpose: .edit).map(\.code)
        var problems: [String] = []
        for code in export + edit where !problems.contains(code) { problems.append(code) }
        return UsbInfo.Volume(fileSystem: volume.fileSystem.displayName, partitionScheme: volume.partitionScheme.rawValue,
                              isDiskImage: volume.isDiskImage, writableForExport: export.isEmpty, writableForEdit: edit.isEmpty,
                              problems: problems)
    }

    /// PIONEER/rekordbox 바로 아래 일반 파일 이름(없으면 빈 집합). 다른 폴더는 열지 않는다
    static func rekordboxFileNames(_ usb: UsbRoot) throws -> Set<String> {
        guard exists(usb, UsbLayout.rekordboxDir) else { return [] }
        let depth = UsbLayout.rekordboxDir.split(separator: "/").count + 1
        return Set(try UsbTree.walk(usb, under: UsbLayout.rekordboxDir)
            .filter { !$0.isDirectory && !$0.isSymlink && $0.relativePath.split(separator: "/").count == depth }
            .compactMap { $0.relativePath.split(separator: "/").last.map(String.init) })
    }

    /// lstat으로 있는지(링크도 있음으로 본다). 열지 않는 경로는 없음
    static func exists(_ usb: UsbRoot, _ relative: String) -> Bool {
        guard let url = try? usb.url(for: relative) else { return false }
        var info = Darwin.stat()
        return lstat(url.path, &info) == 0
    }

    /// `UsbSnapshot.take`가 OneLibrary 사본을 확인하다 멈춘 오류(무결성·암호·WAL 합치기)
    static func isOneLibraryFailure(_ error: UsbError) -> Bool {
        guard case let .readFailed(detail) = error else { return false }
        let name = (UsbLayout.oneLibrary as NSString).lastPathComponent
        return ["integrity_check", "cipher_integrity_check", "wal_checkpoint busy", name].contains { detail.hasPrefix($0) }
    }

    /// OneLibrary 사본이 온전하지 않을 때 pdb 둘만 사본으로 뜬다(복사 전후 크기·시각이 같아야 한다)
    static func copyPdb(_ usb: UsbRoot, into directory: URL, fileSystem: SnapshotFileAccess = .posix) throws -> (URL, URL?)? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var copies: [String: URL] = [:]
        for relative in [UsbLayout.exportPdb, UsbLayout.exportExtPdb] {
            let source = try usb.url(for: relative)
            guard let before = try fileSystem.stat(source) else { continue }
            guard before.isRegularFile else { throw UsbError.readFailed(detail: "not a regular file: \(relative)") }
            let target = directory.appending(path: source.lastPathComponent)
            try fileSystem.copyData(source, target)
            guard let after = try fileSystem.stat(source), after.size == before.size, after.modificationDate == before.modificationDate else {
                throw DJCError.sourceChangedDuringCopy(path: source.path)
            }
            copies[relative] = target
        }
        return copies[UsbLayout.exportPdb].map { ($0, copies[UsbLayout.exportExtPdb]) }
    }

    /// pdb 사본을 읽는다. 머리가 달라 읽지 못하면 경고만 남긴다.
    /// 읽었으면 왕복 검사(읽기 → 모델 → 다시 쓰기 → 다시 읽기, `PdbRoundTrip`)의 문제 목록도 채운다(빈 배열 = 통과)
    static func readDeviceLibrary(_ files: (URL, URL?)?, into library: inout UsbLibrary?, roundTrip: inout [String]?,
                                  warn: (String, String) -> Void) throws -> PdbReadReport? {
        guard let (export, ext) = files else { return nil }
        do {
            let exportData = try Data(contentsOf: export), extData = try ext.map { try Data(contentsOf: $0) }
            let (read, report) = try PdbReader.read(export: exportData, exportExt: extData)
            library = read
            do {
                roundTrip = try PdbRoundTrip.check(export: exportData, exportExt: extData)
            } catch {
                roundTrip = ["unreadable"]
            }
            return report
        } catch let error as UsbError {
            guard case .readFailed = error else { throw error }
            warn("deviceLibraryUnreadable", String(ui: "Device Library(export.pdb)를 읽지 못했습니다. rekordbox로 USB를 다시 내보내세요"))
            return nil
        }
    }

    static func deviceLibraryPart(_ report: PdbReadReport, library: UsbLibrary?, roundTrip: [String]?) -> UsbInfo.DeviceLibraryPart {
        let history = [PdbTableType.historyPlaylists.name, PdbTableType.historyEntries.name].reduce(0) { $0 + (report.tableCounts[$1]?.live ?? 0) }
        return UsbInfo.DeviceLibraryPart(
            exportFlag10: Int(report.exportHeader.flag10), extFlag10: report.extHeader.map { Int($0.flag10) },
            roundTripChecked: roundTrip != nil, roundTripOK: roundTrip.map(\.isEmpty),
            tracks: library?.tracks.count ?? 0, playlists: library?.playlists.count ?? 0, historyRows: history,
            unknownTableRows: report.unknownRows.filter { $0.format == .deviceLibrary }.reduce(0) { $0 + $1.liveRows },
            structureIssues: report.issues.count)
    }

    static func consistency(oneLibrary: UsbLibrary?, deviceLibrary: UsbLibrary?) -> UsbInfo.Consistency {
        let (_, mismatches) = UsbLibrary.merge(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary)
        var playlists: Set<Int> = []
        var result = UsbInfo.Consistency()
        for mismatch in mismatches {
            switch mismatch {
            case .trackOnlyIn: result.trackIDsMatch = false
            case .trackPathDiffers: result.pathsMatch = false
            case let .playlistConflict(id), let .playlistEntriesDiffer(id), let .playlistOnlyIn(_, id): playlists.insert(id)
            default: break
            }
        }
        result.playlistMismatches = playlists.count
        result.editBlocked = mismatches.contains(where: \.blocksEditing)
        let tracks = (oneLibrary?.tracks ?? []) + (deviceLibrary?.tracks ?? [])
        result.masterDbIdConsistent = Set(tracks.map(\.masterDbId)).count <= 1
        if let oneLibrary, let deviceLibrary {
            result.myTagMasterDBIDConsistent = oneLibrary.property.myTagMasterDBID == deviceLibrary.property.myTagMasterDBID
        }
        return result
    }

    /// 곡마다 두 DB가 가리키는 분석 파일(같은 경로는 한 번): 셋의 존재, .DAT PPTH = 곡 경로, 파일 번호 > 0
    static func analysis(_ usb: UsbRoot, oneLibrary: UsbLibrary?, deviceLibrary: UsbLibrary?) -> UsbInfo.Analysis {
        let tracks = (oneLibrary?.tracks ?? []) + (deviceLibrary?.tracks ?? [])
        var result = UsbInfo.Analysis(tracksChecked: Set(tracks.map(\.id)).count)
        var seen: Set<String> = [], ppthBad: Set<Int> = []
        for track in tracks {
            let path = track.analysisDataPath
            guard seen.insert("\(track.id)\u{0}\(path)\u{0}\(UsbLayout.nfc(track.path))").inserted else { continue }
            let relative = String(path.drop { $0 == "/" })
            let base = relative.uppercased().hasSuffix(".DAT") ? String(relative.dropLast(4)) : relative
            if let number = slotNumber(base), number > 0 { result.slotCollisions += 1 }
            for ext in [".DAT", ".EXT", ".2EX"] where path.isEmpty || !isRegularFile(usb, base + ext) { result.missingFiles += 1 }
            guard !path.isEmpty, isRegularFile(usb, base + ".DAT") else { continue }
            let ppth = (try? usb.url(for: base + ".DAT")).flatMap { try? AnlzFile(data: Data(contentsOf: $0)) }?.tag("PPTH")
                .flatMap { try? AnlzPathTag.decode($0.bytes) }
            if ppth.map(UsbLayout.nfc) != UsbLayout.nfc(track.path) { ppthBad.insert(track.id) }
        }
        result.ppthMismatches = ppthBad.count
        return result
    }

    /// "…/ANLZ000N" → N(16진)
    static func slotNumber(_ base: String) -> Int? {
        let name = (base as NSString).lastPathComponent.uppercased()
        guard name.hasPrefix("ANLZ") else { return nil }
        return Int(name.dropFirst(4), radix: 16)
    }

    /// 링크가 아닌 일반 파일. 열지 않는 경로·링크를 거쳐 가는 경로는 없음으로 센다
    static func isRegularFile(_ usb: UsbRoot, _ relative: String) -> Bool {
        guard let url = try? usb.url(for: relative) else { return false }
        var info = Darwin.stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }
}
