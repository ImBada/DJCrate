import DJCDomain
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// 합성 USB(임시 폴더)에 선택 파일을 실제 쓰기 절차(UsbWriter.write)로 쓴다. 값은 모두 지어낸 것이다.
@Suite("USB 동기화 선택 파일 쓰기")
struct UsbSyncSelectionWriteTests {
    func localDBID(_ env: UsbEditFixture) throws -> Int64 {
        let db = try env.local.open()
        defer { db.close() }
        return try UsbLocalSource(database: db).localDBID()
    }

    /// 앱 세션처럼 준비 폴더를 쓰기 경로의 준비 루트 아래에 둔다(선택 파일 사전 확인이 그 루트 아래만 읽는다).
    func plan(_ env: UsbEditFixture, _ edits: [UsbLibraryEdit]) throws -> UsbEditResult {
        let source = try env.source()
        let db = try env.local.open()
        defer { db.close() }
        let session = UsbLayout.newSessionID()
        return try UsbEditEngine.plan(source: source, edits: edits, localDatabase: db, share: env.local.share, volume: env.usb.volume,
                                      existingFiles: env.usb.root, fileSystem: env.usb.fileSystem(),
                                      staging: env.usb.paths.staging.appending(path: session), session: session,
                                      highWater: env.usb.journal()?.changes.idHighWater ?? [:],
                                      snapshotTakenAt: env.snapshotTakenAt, localAppVersion: env.appVersion)
    }

    /// 두 형식에 같은 선택 파일을 둔다(rekordbox가 만든 USB처럼)
    func seed(_ env: UsbEditFixture, _ data: Data) -> [UsbFormat: Data] {
        for format in UsbFormat.allCases { env.usb.write(UsbSyncSelectionFile.relativePath(for: format), data) }
        return Dictionary(uniqueKeysWithValues: UsbFormat.allCases.map { ($0, data) })
    }

    @Test("켜짐만 바꾸는 쓰기는 두 선택 파일의 AutomaticSync만 바꾸고 DB는 그대로 둔다")
    func enabledOnlyWriteChangesOnlyAutomaticSync() throws {
        let env = try UsbEditEngineTests.exported()
        let dbid = try #require(UsbSyncSelectionXML.databaseID(try localDBID(env)))
        let base = UsbSyncSelectionFileTests.file([
            UsbSyncSelectionFileTests.node("0", folder: true, device: 0, check: 2),
            UsbSyncSelectionFileTests.node("C", device: 1),
        ], dbid: dbid, automaticSync: "1")
        let baseFiles = seed(env, base)
        let databases = UsbWriter.databaseOrder.map { env.usb.data($0) }
        let result = try plan(env, [.syncSelection(draft: .enabledOnly(localDBID: try localDBID(env), enabled: false,
                                                                       baseFiles: baseFiles))])
        #expect(result.blocks.map(\.code) == [])
        #expect(try env.write(result).outcome == .written)
        #expect(result.outcomes.map(\.outcome) == [.written])
        let expected = Data(String(decoding: base, as: UTF8.self)
            .replacingOccurrences(of: "AutomaticSync=\"1\"", with: "AutomaticSync=\"0\"").utf8)
        for format in UsbFormat.allCases {
            #expect(env.usb.data(UsbSyncSelectionFile.relativePath(for: format)) == expected)
        }
        #expect(UsbWriter.databaseOrder.map { env.usb.data($0) } == databases)
    }

    @Test("선택 쓰기는 체크한 목록을 USB 목록 번호와 masterPlaylists6 Timestamp로 rekordbox 모양 그대로 쓴다")
    func selectionWriteUsesConfirmedLayout() throws {
        let env = try UsbEditEngineTests.exported()
        let local = try localDBID(env)
        let dbid = try #require(UsbSyncSelectionXML.databaseID(local))
        let usbID = try #require(env.read().playlists.first { $0.attribute == 0 }?.id)
        let baseFiles = seed(env, UsbSyncSelectionFileTests.file([], dbid: dbid))
        let draft = UsbSyncSelectionDraft(localDBID: local,
                                          sourceNodes: [.init(id: "900", parentID: nil, isFolder: false, timestamp: 1_700_000_000_900)],
                                          selection: .init(selectedIDs: ["900"]), enabled: true,
                                          playlistRefs: ["900": .id(String(usbID))], baseFiles: baseFiles)
        let planned = try plan(env, [.syncSelection(draft: draft)])
        #expect(planned.blocks.map(\.code) == [])
        #expect(try env.write(planned).outcome == .written)
        let expected = """
        <?xml version="1.0" encoding="UTF-8"?>\r
        \r
        <Sync DBID="\(dbid)" AutomaticSync="1" AllPlaylists="0" IncludeCue="1" ForcedSync="0" Timestamp="0">\r
          <Playlists>\r
            <NODE Id="0" ParentId="0" Attribute="1" Lib_Type="0" Dev_ID="0" Timestamp="0" CheckType="2"/>\r
            <NODE Id="384" ParentId="0" Attribute="0" Lib_Type="0" Dev_ID="\(usbID)" Timestamp="1700000000900" CheckType="1"/>\r
          </Playlists>\r
        </Sync>\r

        """
        for format in UsbFormat.allCases {
            #expect(env.usb.data(UsbSyncSelectionFile.relativePath(for: format)) == Data(expected.utf8))
        }
        // 해제하면 행만 빠지고 USB 목록은 남는다.
        let written = Dictionary(uniqueKeysWithValues: UsbFormat.allCases.map {
            ($0, env.usb.data(UsbSyncSelectionFile.relativePath(for: $0))!)
        })
        let cleared = UsbSyncSelectionDraft(localDBID: local, sourceNodes: draft.sourceNodes, selection: .init(), enabled: true,
                                            playlistRefs: draft.playlistRefs, baseFiles: written)
        #expect(try env.write(plan(env, [.syncSelection(draft: cleared)])).outcome == .written)
        #expect(env.usb.data(UsbSyncSelectionFile.relativePath(for: .oneLibrary))
            == UsbSyncSelectionFileTests.file([], dbid: dbid, automaticSync: "1"))
        #expect(try env.read().playlists.contains { $0.id == usbID })
    }

    @Test("masterPlaylists6.xml에 없는 목록을 체크하면 백업 전에 묶음 전체를 막는다")
    func missingMasterNodeBlocksBeforeWriting() throws {
        let env = try UsbEditEngineTests.exported()
        let local = try localDBID(env)
        let dbid = try #require(UsbSyncSelectionXML.databaseID(local))
        let baseFiles = seed(env, UsbSyncSelectionFileTests.file([], dbid: dbid))
        let before = env.usb.tree()
        let draft = UsbSyncSelectionDraft(localDBID: local, sourceNodes: [.init(id: "900", parentID: nil, isFolder: false)],
                                          selection: .init(selectedIDs: ["900"]), enabled: true,
                                          playlistRefs: ["900": .id("1")], baseFiles: baseFiles)
        let result = try plan(env, [.syncSelection(draft: draft)])
        #expect(result.blocks.map(\.code) == ["syncSelectionSourceNode"])
        #expect(result.changes == nil && env.usb.tree() == before)
    }

    // MARK: - 새 선택 파일(2026-10-08 빈 USB 실험)

    /// rekordbox 라이브러리는 있지만 선택 파일이 없는 USB에 체크한 목록 하나를 쓰는 초안
    func newFileDraft(_ env: UsbEditFixture) throws -> (draft: UsbSyncSelectionDraft, dbid: String, usbID: Int) {
        let local = try localDBID(env)
        let dbid = try #require(UsbSyncSelectionXML.databaseID(local))
        let usbID = try #require(env.read().playlists.first { $0.attribute == 0 }?.id)
        let draft = UsbSyncSelectionDraft(localDBID: local,
                                          sourceNodes: [.init(id: "900", parentID: nil, isFolder: false, timestamp: 1_700_000_000_900)],
                                          selection: .init(selectedIDs: ["900"]), enabled: true,
                                          playlistRefs: ["900": .id(String(usbID))], baseFiles: [:])
        return (draft, dbid, usbID)
    }

    func newFileBytes(dbid: String, usbID: Int) -> Data {
        UsbSyncSelectionFileTests.file([
            UsbSyncSelectionFileTests.node("0", folder: true, library: 0, device: 0, check: 2),
            UsbSyncSelectionFileTests.node("384", library: 0, device: usbID, timestamp: 1_700_000_000_900),
        ], dbid: dbid, automaticSync: "1")
    }

    @Test("선택 파일이 없는 USB에는 두 형식의 파일을 새로 만들고 되돌리면 지운다")
    func newSelectionFilesAreCreatedAndRestoreDeletesThem() throws {
        let env = try UsbEditEngineTests.exported()
        let (draft, dbid, usbID) = try newFileDraft(env)
        let before = env.usb.tree()
        let databases = UsbWriter.databaseOrder.map { env.usb.data($0) }
        let planned = try plan(env, [.syncSelection(draft: draft)])
        #expect(planned.blocks.map(\.code) == [])
        let writes = planned.changes?.writes.filter { UsbSyncSelectionStage.isSelectionPath($0.destination) } ?? []
        #expect(writes.count == 2 && writes.allSatisfy { $0.disposition == .create && $0.expectedExistingSHA256 == nil })
        #expect(try env.write(planned).outcome == .written)
        for format in UsbFormat.allCases {
            #expect(env.usb.data(UsbSyncSelectionFile.relativePath(for: format)) == newFileBytes(dbid: dbid, usbID: usbID))
        }
        #expect(UsbWriter.databaseOrder.map { env.usb.data($0) } == databases)
        // 백업에는 "없던 파일"로 남아 되돌리면 지운다.
        #expect(try env.usb.restore().outcome == .restored)
        #expect(env.usb.tree() == before)
    }

    @Test("선택 파일이 없는 USB에서 켜기만 하면 행 없는 파일을 만들고, 끄기만 하면 쓰지 않는다")
    func enabledOnlyOnUsbWithoutFiles() throws {
        let env = try UsbEditEngineTests.exported()
        let local = try localDBID(env)
        let dbid = try #require(UsbSyncSelectionXML.databaseID(local))
        let before = env.usb.tree()
        let off = try plan(env, [.syncSelection(draft: .enabledOnly(localDBID: local, enabled: false, baseFiles: [:]))])
        #expect(off.blocks.isEmpty && off.changes == nil)
        #expect(off.outcomes.map(\.outcome) == [.unchanged])
        #expect(env.usb.tree() == before)

        let databases = UsbWriter.databaseOrder.map { env.usb.data($0) }
        let on = try plan(env, [.syncSelection(draft: .enabledOnly(localDBID: local, enabled: true, baseFiles: [:]))])
        #expect(on.blocks.map(\.code) == [])
        #expect(try env.write(on).outcome == .written)
        for format in UsbFormat.allCases {
            #expect(env.usb.data(UsbSyncSelectionFile.relativePath(for: format))
                == UsbSyncSelectionFileTests.file([], dbid: dbid, automaticSync: "1"))
        }
        #expect(UsbWriter.databaseOrder.map { env.usb.data($0) } == databases)
    }

    @Test("새 선택 파일을 확정하다 끊기면 회복이 만든 파일을 지우고 쓰기 전으로 돌린다")
    func interruptedNewSelectionFilesRecoverToBefore() throws {
        let env = try UsbEditEngineTests.exported()
        let (draft, _, _) = try newFileDraft(env)
        let before = env.usb.tree()
        let planned = try plan(env, [.syncSelection(draft: draft)])
        let changes = try #require(planned.changes)
        // OneLibrary 파일을 확정한 뒤 Device Library 파일의 rename에서 프로세스가 죽은 것처럼
        let fs = env.usb.fileSystem()
        fs.failAt = (operation: .rename, occurrence: 1, mode: .crash)
        fs.failMatching = { $0 == UsbSyncSelectionFile.relativePath(for: .deviceLibrary) }
        let preexisting = try UsbInvariantVerifier.appleDoubles(on: env.usb.root)
        #expect(throws: (any Error).self) {
            try UsbWriter.write(changes, root: env.usb.root, paths: env.usb.paths, guard: env.usb.writeGuard(), fileSystem: fs,
                                verifiers: planned.verifiers(preexistingAppleDoubles: preexisting), inspectors: [UsbEditInspector()],
                                ppthReader: UsbExportAssembly.ppthReader)
        }
        #expect(env.usb.exists(UsbSyncSelectionFile.relativePath(for: .oneLibrary)))
        #expect(!env.usb.exists(UsbSyncSelectionFile.relativePath(for: .deviceLibrary)))
        #expect(try env.usb.recover().outcome == .rolledBack)
        #expect(env.usb.tree() == before)
        #expect(env.usb.journal()?.state == .rolledBack)
    }

    @Test("한 형식의 선택 파일만 있는 USB는 백업 전에 막는다")
    func oneFormatSelectionFileIsRefused() throws {
        let env = try UsbEditEngineTests.exported()
        let local = try localDBID(env)
        let dbid = try #require(UsbSyncSelectionXML.databaseID(local))
        let base = UsbSyncSelectionFileTests.file([], dbid: dbid, automaticSync: "1")
        for present in UsbFormat.allCases {
            let existing = env.usb.tree().keys.filter(UsbSyncSelectionStage.isSelectionPath)
            for path in existing { try FileManager.default.removeItem(at: env.usb.usb(path)) }
            env.usb.write(UsbSyncSelectionFile.relativePath(for: present), base)
            let before = env.usb.tree(), backups = env.usb.backupFolders()
            for draft in [UsbSyncSelectionDraft.enabledOnly(localDBID: local, enabled: false, baseFiles: [present: base]),
                          try newFileDraft(env).draft.with(baseFiles: [present: base])] {
                let result = try plan(env, [.syncSelection(draft: draft)])
                #expect(result.blocks.map(\.code) == ["syncSelectionPartialFiles"])
                #expect(result.changes == nil)
                #expect(env.usb.tree() == before && env.usb.backupFolders() == backups)
            }
        }
    }
}

private extension UsbSyncSelectionDraft {
    func with(baseFiles: [UsbFormat: Data]) -> Self {
        Self(localDBID: localDBID, sourceNodes: sourceNodes, selection: selection, enabled: enabled, playlistRefs: playlistRefs,
             baseFiles: baseFiles, enabledOnly: enabledOnly)
    }
}
