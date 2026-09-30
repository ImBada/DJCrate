import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing
@testable import djc

/// `UsbRead.info`·`djc usb-info`: 합성 USB 폴더를 읽기만 한다(가짜 볼륨·시험이 만든 목록 상태만 쓴다)
@Suite("USB 정보")
struct UsbInfoTests {
    static let otherUUID = "00000000-0000-0000-0000-00000000BEEF"

    static func lists(_ fixed: UsbDenyListStatus.State = .missing, entries: Int = 0, userData: UsbDenyListStatus.State = .missing,
                      deny: Set<String> = []) -> UsbPhysicalLists.Loaded {
        UsbPhysicalLists.Loaded(allow: [], deny: deny,
                                denyStatus: UsbDenyListStatus(fixedLocation: fixed, fixedEntryCount: entries, userData: userData),
                                allowState: .missing)
    }

    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "djc-usbinfo-\(UUID().uuidString)")
    }

    /// 합성 USB를 만들어 body에 넘기고 끝나면 지운다
    func withUsb(_ configure: (inout UsbLibraryFixture) -> Void = { _ in }, _ body: (UsbTreeFixture) throws -> Void) throws {
        var usb = UsbLibraryFixture()
        // Device Library의 My Tag 연결은 DJCrate가 다시 쓸 수 없어 왕복 경고가 난다(UsbInfoRoundTripTests가 따로 본다)
        usb.myTagLinks = []
        configure(&usb)
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        try usb.write(to: tree)
        try body(tree)
    }

    func info(_ tree: UsbTreeFixture, volume: UsbVolumeInfo? = nil, lists: UsbPhysicalLists.Loaded = UsbInfoTests.lists(),
              appVersion: String? = "7.2.18") throws -> UsbInfo {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let result = try UsbRead.info(root: tree.base, scratch: scratch, volume: volume, lists: lists, appVersion: { appVersion })
        // 읽은 뒤 사본을 남기지 않는다
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        return result
    }

    /// 막힌 code(사본 폴더는 만들어지지 않아야 한다)
    func refusal(_ tree: UsbTreeFixture, volume: UsbVolumeInfo, lists: UsbPhysicalLists.Loaded) -> String? {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            _ = try UsbRead.info(root: tree.base, scratch: scratch, volume: volume, lists: lists, appVersion: { nil })
            return nil
        } catch let UsbError.readFailed(detail) {
            #expect(!FileManager.default.fileExists(atPath: scratch.path))
            return detail
        } catch {
            Issue.record("다른 오류: \(error)")
            return "other"
        }
    }

    // MARK: - 형식

    @Test func formatsNone_OneLibraryOnly_PdbOnly_Both() throws {
        let empty = UsbTreeFixture()
        defer { empty.remove() }
        empty.mkdir("PIONEER/rekordbox")
        let none = try info(empty)
        #expect(none.formats.isEmpty)
        #expect(none.oneLibrary == nil && none.deviceLibrary == nil)
        #expect(none.analysis.tracksChecked == 0)
        #expect(none.warnings.isEmpty)
        #expect(none.schemaVersion == 1)

        try withUsb({ $0.formats = [.oneLibrary] }) { tree in
            let result = try info(tree)
            #expect(result.formats == ["oneLibrary"])
            let ol = try #require(result.oneLibrary)
            #expect(ol.schemaOK && ol.integrityOK && !ol.walPresent && !ol.journalPresent)
            #expect(ol.headerMode == "wal")
            #expect([ol.tracks, ol.playlists, ol.myTags, ol.histories] == [3, 1, 2, 0] as [Int])
            #expect(result.deviceLibrary == nil)
            #expect(result.analysis.tracksChecked == 3 && result.analysis.missingFiles == 0 && result.analysis.ppthMismatches == 0)
            #expect(result.warnings.isEmpty)
        }
        try withUsb({ $0.formats = [.deviceLibrary] }) { tree in
            let result = try info(tree)
            #expect(result.formats == ["deviceLibrary"])
            #expect(result.oneLibrary == nil)
            let dl = try #require(result.deviceLibrary)
            #expect(dl.exportFlag10 == 5 && dl.extFlag10 == 5)
            #expect(dl.roundTripChecked && dl.roundTripOK == true)
            #expect([dl.tracks, dl.playlists, dl.historyRows, dl.unknownTableRows, dl.structureIssues] == [3, 1, 0, 0, 0] as [Int])
            #expect(result.analysis.tracksChecked == 3 && result.analysis.missingFiles == 0)
            #expect(result.warnings.isEmpty)
        }
        try withUsb { tree in
            let result = try info(tree)
            #expect(result.formats == ["oneLibrary", "deviceLibrary"])
            let consistency = result.consistency
            #expect(consistency.trackIDsMatch && consistency.pathsMatch && consistency.playlistMismatches == 0)
            #expect(consistency.masterDbIdConsistent && consistency.myTagMasterDBIDConsistent && !consistency.editBlocked)
            #expect(result.analysis == UsbInfo.Analysis(tracksChecked: 3, missingFiles: 0, ppthMismatches: 0, slotCollisions: 0))
            #expect(result.localCompatibility?.rekordboxVersion == "7.2.18" && result.localCompatibility?.verified == true)
            #expect(result.warnings.isEmpty)
        }
    }

    @Test func walPresentFlagged() throws {
        try withUsb({ $0.oneLibraryWAL = true }) { tree in
            let result = try info(tree)
            let ol = try #require(result.oneLibrary)
            #expect(ol.walPresent && !ol.journalPresent && ol.integrityOK)
            #expect(ol.tracks == 3)
            #expect(result.warnings.map(\.code) == ["oneLibrarySidecar"])
        }
    }

    @Test func pdbFlag10NotFiveWarned() throws {
        try withUsb({ $0.pdbFlag10 = 1 }) { tree in
            let result = try info(tree)
            #expect(result.deviceLibrary?.exportFlag10 == 1)
            let warning = try #require(result.warnings.first { $0.code == "pdbOpenFlag" })
            #expect(warning.message == "rekordbox에 이 USB를 연결했다가 정상적으로 꺼낸 뒤 다시 시도하세요")
            #expect(result.warnings.count == 1)
        }
    }

    @Test func playlistMismatchCounted() throws {
        try withUsb({
            $0.playlists = [UsbLibraryFixture.Playlist(id: 10, name: "시험 목록", oneLibraryEntries: [1, 2, 3], deviceLibraryEntries: [1, 1, 2, 3])]
        }) { tree in
            let result = try info(tree)
            #expect(result.consistency.playlistMismatches == 1)
            // 항목만 다른 목록은 고치기를 막지 않는다
            #expect(!result.consistency.editBlocked && result.consistency.trackIDsMatch && result.consistency.pathsMatch)
            #expect(result.warnings.isEmpty)
        }
    }

    @Test func editBlockedWhenTrackOnlyInOneFormat() throws {
        try withUsb({ $0.deviceOnlyTrackIDs = [4] }) { tree in
            let result = try info(tree)
            #expect(!result.consistency.trackIDsMatch && result.consistency.editBlocked)
            #expect(result.warnings.map(\.code) == ["formatMismatch"])
        }
    }

    @Test func identifierConsistencyWithoutValues() throws {
        try withUsb({
            $0.masterDbIDs = [2: 1_000_777]
            $0.deviceMyTagMasterDBID = 654_321
        }) { tree in
            let result = try info(tree)
            #expect(!result.consistency.masterDbIdConsistent && !result.consistency.myTagMasterDBIDConsistent)
        }
    }

    @Test func missingAnalysisCounted() throws {
        try withUsb { tree in
            let second = String(UsbLibraryFixture.analysisPath(2).dropFirst().dropLast(4))
            let third = String(UsbLibraryFixture.analysisPath(3).dropFirst().dropLast(4))
            try FileManager.default.removeItem(at: tree.url(second + ".EXT"))
            for ext in [".DAT", ".EXT", ".2EX"] { try FileManager.default.removeItem(at: tree.url(third + ext)) }
            let result = try info(tree)
            #expect(result.analysis.tracksChecked == 3)
            #expect(result.analysis.missingFiles == 4)
            #expect(result.analysis.ppthMismatches == 0)
            #expect(result.warnings.map(\.code) == ["analysisMissing"])
        }
    }

    @Test func ppthMismatchCounted() throws {
        try withUsb { tree in
            let first = String(UsbLibraryFixture.analysisPath(1).dropFirst())
            tree.write(first, UsbLibraryFixture.dat(path: "/Contents/시험 아티스트/다른 곡.mp3", hotCueA: nil))
            let result = try info(tree)
            #expect(result.analysis.ppthMismatches == 1 && result.analysis.missingFiles == 0)
            #expect(result.warnings.map(\.code) == ["analysisPathMismatch"])
        }
    }

    @Test func slotAboveZeroCounted() throws {
        try withUsb({ $0.analysisPaths = [2: "/PIONEER/USBANLZ/P000/00000002/ANLZ0001.DAT"] }) { tree in
            let result = try info(tree)
            #expect(result.analysis.slotCollisions == 1 && result.analysis.missingFiles == 0)
            #expect(result.warnings.isEmpty)
        }
    }

    @Test func unknownTableRowsWarned() throws {
        try withUsb({ $0.pdbUnknownRows = 2 }) { tree in
            let result = try info(tree)
            #expect(result.deviceLibrary?.unknownTableRows == 2)
            // 모르는 표 행은 다시 쓰면 잃으므로 왕복 검사도 실패한다
            #expect(result.deviceLibrary?.roundTripOK == false)
            #expect(result.warnings.map(\.code) == ["unknownTableRows", "pdbRoundTripFailed"])
        }
    }

    @Test func unsupportedOneLibraryReported() throws {
        try withUsb({ $0.oneLibraryDBVersion = "2000" }) { tree in
            let result = try info(tree)
            let ol = try #require(result.oneLibrary)
            #expect(!ol.schemaOK && ol.integrityOK && ol.tracks == 0)
            #expect(result.deviceLibrary?.tracks == 3)
            #expect(result.warnings.map(\.code) == ["oneLibraryUnsupported"])
        }
    }

    @Test func corruptOneLibraryReported() throws {
        try withUsb { tree in
            tree.write(UsbLayout.oneLibrary, Data(repeating: 0x5A, count: 8_192))
            let before = tree.tree()
            let result = try info(tree)
            let ol = try #require(result.oneLibrary)
            #expect(!ol.integrityOK && !ol.schemaOK && ol.headerMode == "unknown" && ol.tracks == 0)
            // Device Library는 따로 떠서 읽는다
            #expect(result.deviceLibrary?.tracks == 3)
            #expect(result.warnings.map(\.code) == ["oneLibraryUnreadable"])
            #expect(tree.tree() == before)
        }
    }

    // MARK: - JSON

    /// 값 → 모양(키와 타입만)
    static func shape(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]: return dictionary.mapValues(shape)
        case let array as [Any]: return array.first.map { [shape($0)] } ?? []
        case is NSNull: return "null"
        case let number as NSNumber: return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        case is String: return "string"
        default: return "?"
        }
    }

    @Test func jsonShapeV1() throws {
        let masterDbId: Int64 = 3_141_592_653, myTagID: Int64 = 2_718_281_828
        try withUsb({
            $0.masterDbIDs = [1: masterDbId, 2: masterDbId, 3: masterDbId]
            $0.myTagMasterDBID = myTagID
        }) { tree in
            let volume = FakeUsbVolume.diskImageFAT32()
            let result = try info(tree, volume: volume)
            let data = try ReadJSON.encode(command: "usb-info", data: result)
            let text = String(decoding: data, as: UTF8.self)
            // 개인 식별값은 내지 않는다(볼륨 이름은 root에만 나올 수 있다 — 여기 root는 임시 폴더)
            for secret in [String(masterDbId), String(myTagID), try #require(volume.volumeUUID), volume.name] {
                #expect(!text.contains(secret))
            }
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["command"] as? String == "usb-info")
            let body = try #require(json["data"] as? [String: Any])
            let expected: [String: Any] = [
                "schemaVersion": "number", "root": "string", "formats": ["string"],
                "volume": ["fileSystem": "string", "partitionScheme": "string", "isDiskImage": "bool", "writableForExport": "bool",
                           "writableForEdit": "bool", "problems": [Any]()],
                "oneLibrary": ["schemaOK": "bool", "headerMode": "string", "walPresent": "bool", "journalPresent": "bool",
                               "integrityOK": "bool", "tracks": "number", "playlists": "number", "myTags": "number", "histories": "number"],
                "deviceLibrary": ["exportFlag10": "number", "extFlag10": "number", "roundTripChecked": "bool", "roundTripOK": "bool",
                                  "tracks": "number", "playlists": "number", "historyRows": "number", "unknownTableRows": "number",
                                  "structureIssues": "number"],
                "consistency": ["trackIDsMatch": "bool", "pathsMatch": "bool", "playlistMismatches": "number",
                                "masterDbIdConsistent": "bool", "myTagMasterDBIDConsistent": "bool", "editBlocked": "bool"],
                "analysis": ["tracksChecked": "number", "missingFiles": "number", "ppthMismatches": "number", "slotCollisions": "number"],
                "media": ["tracksChecked": "number", "filesChecked": "number", "missingFiles": "number"],
                "settings": [["fileName": "string", "status": "string", "issue": "null", "crcOK": "null"]],
                "localCompatibility": ["rekordboxVersion": "string", "verified": "bool"],
                "warnings": [Any](),
            ]
            #expect(NSDictionary(dictionary: Self.shape(body) as? [String: Any] ?? [:]).isEqual(to: expected))
            #expect(body["schemaVersion"] as? Int == 1)
            #expect((body["volume"] as? [String: Any])?["fileSystem"] as? String == "FAT32")
            #expect((body["volume"] as? [String: Any])?["partitionScheme"] as? String == "mbr")
            #expect((body["deviceLibrary"] as? [String: Any])?["roundTripChecked"] as? Bool == true)
        }
        // 폴더 대상·한 형식: 없는 부분도 키는 남는다(null)
        try withUsb({ $0.formats = [.oneLibrary] }) { tree in
            let data = try ReadJSON.encode(command: "usb-info", data: try info(tree, appVersion: nil))
            let body = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any])
            #expect(body["volume"] is NSNull && body["deviceLibrary"] is NSNull)
            #expect((body["localCompatibility"] as? [String: Any])?["rekordboxVersion"] is NSNull)
            #expect((body["localCompatibility"] as? [String: Any])?["verified"] as? Bool == false)
            let decoded = try JSONDecoder().decode(UsbInfo.self, from: JSONSerialization.data(withJSONObject: body))
            #expect(decoded.formats == ["oneLibrary"] && decoded.volume == nil && decoded.oneLibrary?.tracks == 3)
        }
    }

    // MARK: - 볼륨·목록

    @Test func denyListedVolumeNotRead() throws {
        try withUsb { tree in
            let image = FakeUsbVolume.diskImageFAT32()
            let physical = FakeUsbVolume.physicalFAT32()
            for volume in [image, physical] {
                let lists = Self.lists(.ok, entries: 1, deny: [try #require(volume.volumeUUID)])
                #expect(refusal(tree, volume: volume, lists: lists) == "denylisted")
                // 목록을 손으로 만든 값이어도 UUID 대소문자와 무관하게 막는다
                let lower = UsbPhysicalLists.Loaded(allow: [], deny: [try #require(volume.volumeUUID).lowercased()],
                                                    denyStatus: UsbDenyListStatus(fixedLocation: .ok, fixedEntryCount: 1, userData: .missing),
                                                    allowState: .missing)
                #expect(refusal(tree, volume: volume, lists: lower) == "denylisted")
            }
            #expect(UsbRead.refusalMessage("denylisted") == "쓰기 금지 목록의 USB라 읽지 않습니다")
        }
    }

    @Test func corruptDenyListVolumeNotRead() throws {
        try withUsb { tree in
            let physical = FakeUsbVolume.physicalFAT32()
            #expect(refusal(tree, volume: physical, lists: Self.lists(.corrupt)) == "denyListUnreadable")
            #expect(refusal(tree, volume: physical, lists: Self.lists(.ok, entries: 1, userData: .corrupt)) == "denyListUnreadable")
            #expect(UsbRead.refusalMessage("denyListUnreadable").contains("쓰기 금지 목록"))
        }
    }

    @Test func physicalReadRequiresDenyList() throws {
        try withUsb { tree in
            let cases: [(UsbPhysicalLists.Loaded, String?)] = [
                (Self.lists(.missing), "denyListNotRegistered"),
                (Self.lists(.ok, entries: 0), "denyListNotRegistered"),
                (Self.lists(.corrupt), "denyListUnreadable"),
                (Self.lists(.ok, entries: 1, deny: [Self.otherUUID]), nil),
            ]
            for (lists, code) in cases {
                #expect(UsbRead.readRefusal(volume: FakeUsbVolume.physicalFAT32(), lists: lists) == code)
                #expect(refusal(tree, volume: FakeUsbVolume.physicalFAT32(), lists: lists) == code)
                // 디스크 이미지는 목록 상태와 무관하게 읽는다
                #expect(UsbRead.readRefusal(volume: FakeUsbVolume.diskImageFAT32(), lists: lists) == nil)
                #expect(refusal(tree, volume: FakeUsbVolume.diskImageFAT32(), lists: lists) == nil)
            }
            #expect(UsbRead.refusalMessage("denyListNotRegistered") == "쓰기 금지 목록(증거용 USB)을 먼저 등록해야 실물 USB를 읽습니다")
            let read = try info(tree, volume: FakeUsbVolume.physicalFAT32(), lists: Self.lists(.ok, entries: 1, deny: [Self.otherUUID]))
            #expect(read.volume?.isDiskImage == false && read.oneLibrary?.tracks == 3)
            #expect(read.volume?.writableForExport == true && read.volume?.writableForEdit == true)

            // 볼륨 UUID를 모르는 실물은 거부 목록으로 가려낼 수 없어 읽지 않는다. 디스크 이미지는 읽는다
            let registered = Self.lists(.ok, entries: 1, deny: [Self.otherUUID])
            for uuid in [nil, ""] as [String?] {
                var physical = FakeUsbVolume.physicalFAT32()
                physical.volumeUUID = uuid
                #expect(UsbRead.readRefusal(volume: physical, lists: registered) == "noVolumeUUID")
                #expect(refusal(tree, volume: physical, lists: registered) == "noVolumeUUID")
                // 목록이 없을 때는 목록 막힘이 먼저다
                #expect(UsbRead.readRefusal(volume: physical, lists: Self.lists(.missing)) == "denyListNotRegistered")
                var image = FakeUsbVolume.diskImageFAT32()
                image.volumeUUID = uuid
                #expect(refusal(tree, volume: image, lists: registered) == nil)
            }
            #expect(UsbRead.refusalCodes.contains("noVolumeUUID"))
            #expect(UsbRead.refusalMessage("noVolumeUUID") == "USB의 볼륨 UUID를 읽지 못해 실물 USB를 읽지 않습니다. USB를 다시 연결한 뒤 시도하세요")
        }
    }

    /// info가 던진 readFailed detail(다른 오류면 기록)
    func readFailure(_ body: () throws -> UsbInfo) -> String? {
        do {
            _ = try body()
            return nil
        } catch let UsbError.readFailed(detail) {
            return detail
        } catch {
            Issue.record("다른 오류: \(error)")
            return "other"
        }
    }

    @Test func folderTargetMustBeOnStartupVolume() throws {
        try withUsb { tree in
            // 볼륨을 nil로 넘겨도 대상이 Mac 시동·데이터 볼륨 위가 아니면 목록 판정 없이 읽지 않는다
            let scratch = Self.scratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let before = tree.tree()
            let detail = readFailure {
                try UsbRead.info(root: tree.base, scratch: scratch, volume: nil, lists: Self.lists(), mountedOn: { _ in "/Volumes/DJCPHYS" },
                                 appVersion: { nil })
            }
            #expect(detail == "volumeNotChecked")
            #expect(readFailure {
                try UsbRead.info(root: tree.base, scratch: scratch, volume: nil, lists: Self.lists(), mountedOn: { _ in nil }, appVersion: { nil })
            } == "volumeNotChecked")
            #expect(!FileManager.default.fileExists(atPath: scratch.path))
            #expect(tree.tree() == before)
            // Mac 데이터 볼륨의 폴더는 읽는다
            let read = try UsbRead.info(root: tree.base, scratch: scratch, volume: nil, lists: Self.lists(),
                                        mountedOn: { _ in "/System/Volumes/Data" }, appVersion: { nil })
            #expect(read.oneLibrary?.tracks == 3)
        }
    }

    @Test func nonEmptyScratchRefusedAndKept() throws {
        try withUsb { tree in
            // 사본 폴더에 이미 있던 것은 지우지 않는다(이 호출이 만든 것만 지운다)
            let scratch = Self.scratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let keep = scratch.appending(path: "db/keep")
            try FileManager.default.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic".utf8).write(to: keep)
            #expect(readFailure {
                try UsbRead.info(root: tree.base, scratch: scratch, volume: nil, lists: Self.lists(), appVersion: { nil })
            } == "scratch not empty")
            #expect(FileManager.default.fileExists(atPath: keep.path))
            // USB 루트를 사본 폴더로 주어도 USB 안을 지우지 않는다
            tree.write("db/keep", "synthetic")
            let before = tree.tree()
            #expect(readFailure {
                try UsbRead.info(root: tree.base, scratch: tree.base, volume: nil, lists: Self.lists(), appVersion: { nil })
            } == "scratch not empty")
            #expect(tree.tree() == before)
            // 빈 사본 폴더는 받고, 폴더는 남긴 채 이 호출이 뜬 사본만 지운다
            let emptyScratch = Self.scratch()
            try FileManager.default.createDirectory(at: emptyScratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: emptyScratch) }
            _ = try UsbRead.info(root: tree.base, scratch: emptyScratch, volume: nil, lists: Self.lists(), appVersion: { nil })
            #expect((try FileManager.default.contentsOfDirectory(atPath: emptyScratch.path)).isEmpty)
        }
    }

    @Test func subfolderOfPhysicalVolumeChecked() throws {
        try withUsb { tree in
            // 실물 볼륨 안 하위 폴더: statfs가 그 볼륨 마운트 지점을 돌려준다
            let volume = try #require(try UsbRead.volume(for: tree.base, mountedOn: { _ in "/Volumes/DJCPHYS" },
                                                         volumeInfo: { _ in FakeUsbVolume.notMountPoint() }))
            #expect(refusal(tree, volume: volume, lists: Self.lists(.missing)) == "denyListNotRegistered")
            let read = try info(tree, volume: volume, lists: Self.lists(.ok, entries: 1, deny: [Self.otherUUID]))
            #expect(read.volume?.problems.contains("notMountPoint") == true)
            #expect(read.volume?.writableForExport == false)
            // 폴더 대상(Mac 데이터 볼륨)은 볼륨 정보를 보지 않는다
            for mount in ["/System/Volumes/Data", "/"] {
                let folder = try UsbRead.volume(for: tree.base, mountedOn: { _ in mount }, volumeInfo: { _ in
                    Issue.record("폴더 대상에서 볼륨 정보를 읽었다")
                    return FakeUsbVolume.physicalFAT32()
                })
                #expect(folder == nil)
            }
            // 마운트 지점을 모르면 읽지 않는다
            #expect(throws: UsbError.self) { try UsbRead.volume(for: tree.base, mountedOn: { _ in nil }, volumeInfo: { _ in FakeUsbVolume.physicalFAT32() }) }
        }
    }

    @Test func folderTargetHasNoVolume() throws {
        try withUsb { (tree: UsbTreeFixture) in
            let volume = try UsbRead.volume(for: tree.base)
            #expect(volume == nil)
            let read = try info(tree, lists: Self.lists(.corrupt))
            #expect(read.volume == nil && read.oneLibrary?.tracks == 3)
        }
    }

    @Test func neverReadNotOpened() throws {
        try withUsb { tree in
            let locked = ["PIONEER/extracted", "PIONEER/CDP", "PIONEER/djprofile.nxs"]
            tree.write("PIONEER/extracted/a.bin", "synthetic")
            tree.write("PIONEER/CDP/b.bin", "synthetic")
            tree.write("PIONEER/djprofile.nxs", "synthetic")
            for path in locked { #expect(chmod(tree.url(path).path, 0) == 0) }
            defer { for path in locked { chmod(tree.url(path).path, 0o755) } }
            let result = try info(tree)
            #expect(result.oneLibrary?.tracks == 3 && result.deviceLibrary?.tracks == 3)
            #expect(result.warnings.isEmpty)
        }
    }

    @Test func sourceUnchanged() throws {
        try withUsb({ $0.oneLibraryWAL = true }) { tree in
            let before = tree.tree()
            _ = try info(tree)
            #expect(tree.tree() == before)
        }
    }

    // MARK: - 명령

    @Test func humanLinesHaveCountsWithoutTitlesOrPaths() throws {
        try withUsb({ $0.pdbFlag10 = 1 }) { tree in
            let lines = UsbCommands.infoLines(try info(tree, volume: FakeUsbVolume.diskImageFAT32()))
            let text = lines.joined(separator: "\n")
            #expect(text.contains("OneLibrary") && text.contains("Device Library"))
            #expect(lines.contains { $0.hasPrefix("OneLibrary: 곡 3") })
            #expect(lines.contains { $0.contains("rekordbox에 이 USB를 연결했다가") })
            for secret in ["시험 곡", "test1", "Contents", tree.base.path, "DJCTEST"] { #expect(!text.contains(secret)) }
        }
    }

    func run(_ arguments: [String], in directory: URL? = nil, language: String = "ko") throws -> (status: Int32, stdout: String, stderr: String) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let home = Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        process.environment = ProcessInfo.processInfo.environment.merging(["DJC_HOME": home.path, "DJC_LANG": language]) { _, new in new }
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile(), err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 사본은 DJC_HOME 안에 떴다가 지워진다
        #expect((try? FileManager.default.contentsOfDirectory(atPath: home.appending(path: "usb-snapshots").path))?.isEmpty ?? true)
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    @Test func commandPrintsJSONAndText() throws {
        try withUsb { tree in
            let before = tree.tree()
            let json = try run(["usb-info", tree.base.path, "--json"])
            #expect(json.status == 0)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
            #expect(object["command"] as? String == "usb-info")
            #expect((object["data"] as? [String: Any])?["formats"] as? [String] == ["oneLibrary", "deviceLibrary"])
            #expect((object["data"] as? [String: Any])?["media"] as? [String: Int] == ["tracksChecked": 3, "filesChecked": 3, "missingFiles": 0])
            // root는 받은 경로를 절대 경로로 바꿔 그대로 적는다(볼륨이면 볼륨 이름이 들어갈 수 있다)
            #expect((object["data"] as? [String: Any])?["root"] as? String == tree.base.path)
            let relative = try run(["usb-info", tree.base.lastPathComponent, "--json"], in: tree.base.deletingLastPathComponent())
            let relativeRoot = ((try JSONSerialization.jsonObject(with: Data(relative.stdout.utf8)) as? [String: Any])?["data"]
                as? [String: Any])?["root"] as? String
            #expect(relativeRoot?.hasPrefix("/") == true && relativeRoot?.hasSuffix("/" + tree.base.lastPathComponent) == true)
            let text = try run(["usb-info", tree.base.path])
            #expect(text.status == 0)
            #expect(text.stdout.contains("OneLibrary: 곡 3"))
            #expect(text.stdout.contains("음원: 곡 3 · 파일 3 · 없는 파일 0"))
            #expect(!text.stdout.contains("시험 곡") && !text.stdout.contains("test1"))
            #expect(tree.tree() == before)

            let usage = try run(["usb-info"])
            #expect(usage.stdout.contains("usb-info"))
            let bad = try run(["usb-info", "--json"])
            #expect(bad.status == 1 && bad.stdout.isEmpty && bad.stderr.contains("invalid_arguments"))
            let missing = try run(["usb-info", tree.base.path + "/none", "--json"])
            #expect(missing.status == 1 && missing.stderr.contains("\"code\""))
        }
    }

    @Test func commandRefusesLiveLibrary() throws {
        let live = NSHomeDirectory() + "/Library/Pioneer/rekordbox"
        let result = try run(["usb-info", live])
        #expect(result.status == 1)
        #expect(result.stderr.contains("rekordbox 라이브러리나 DJCrate 데이터 폴더는 USB가 아닙니다"))
    }
}
