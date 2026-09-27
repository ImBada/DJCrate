import DJCDomain
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// 쓰는 도중 크래시(그 뒤 모든 연산 실패) → 새 파일 시스템으로 회복
@Suite("USB 쓰기 회복")
struct UsbRecoverTests {
    func expected(_ changes: UsbChangeSet) -> [String: String] {
        changes.target.mustExist.mapValues { $0.sha256 ?? "" }
    }

    /// 크래시를 흉내 내 쓰기를 끊는다(던진 오류는 무엇이든 받는다)
    func crash(_ fixture: UsbChangeSetFixture, _ changes: UsbChangeSet, _ configure: (FaultyUsbFileSystem) -> Void) {
        let fs = fixture.fileSystem()
        configure(fs)
        #expect(throws: (any Error).self) { try fixture.write(changes, fileSystem: fs) }
        #expect(fs.isCrashed)
    }

    func backupFiles(_ journal: UsbJournal?) throws -> (journal: UsbJournal, report: UsbWriteReport) {
        let folder = URL(filePath: try #require(journal?.backupDirectory))
        let copy = try UsbJournal.decoder().decode(UsbJournal.self, from: Data(contentsOf: folder.appending(path: "journal.json")))
        let report = try JSONDecoder().decode(UsbWriteReport.self, from: Data(contentsOf: folder.appending(path: "report.json")))
        return (copy, report)
    }

    func currentDatabases(_ fixture: UsbChangeSetFixture) -> [String: String] {
        fixture.tree().filter { FixtureOrder.databases.contains($0.key) }
    }

    @Test("대상을 지운 뒤 rename 전에 끊겨도 DB가 사라지지 않는다")
    func crashAfterTargetDeletedBeforeRename() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges()
        crash(fixture, changes) { $0.renameTwoPhaseOn = UsbLayout.oneLibrary }
        #expect(!fixture.exists(UsbLayout.oneLibrary))
        let report = try fixture.recover()
        #expect(report.outcome == .recovered)
        #expect(fixture.exists(UsbLayout.oneLibrary))
        var tree = fixture.tree()
        for path in changes.target.mustNotExist { #expect(tree[path] == nil) }
        tree = tree.filter { changes.target.mustExist[$0.key] != nil }
        #expect(tree == expected(changes))
        #expect(fixture.tempCount() == 0)
        #expect(fixture.journal()?.state == .recovered)
    }

    @Test("파일 단계에서 끊기면 만든 파일을 지우고 옛 DB 그대로", arguments: [false, true])
    func crashDuringFiles_beforeCommit(edit: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        if edit { fixture.seedEdit() }
        let changes = edit ? try fixture.editChanges() : fixture.exportChanges()
        let before = fixture.tree()
        crash(fixture, changes) { $0.failAt = (operation: edit ? .writeNew : .copyDataNew, occurrence: 2, mode: .crash) }
        #expect(fixture.tempCount() == 1)
        let report = try fixture.recover()
        #expect(report.outcome == .rolledBack)
        #expect(fixture.tree() == before)
        #expect(fixture.journal()?.state == .rolledBack)
    }

    @Test("DB 사이에서 끊기면 준비 폴더가 온전할 때 마저 쓴다")
    func crashBetweenDBCommits() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit(extraSidecar: true)
        let changes = try fixture.editChanges()
        crash(fixture, changes) { fs in
            fs.failAt = (operation: .writeNew, occurrence: 2, mode: .crash)
            fs.failMatching = { $0.hasPrefix("PIONEER/rekordbox/") }
        }
        #expect(fixture.tree()[UsbLayout.oneLibrary] == changes.databases[0].sha256)
        #expect(fixture.tree()[UsbLayout.exportPdb] != changes.databases[1].sha256)
        let report = try fixture.recover()
        #expect(report.outcome == .recovered)
        #expect(currentDatabases(fixture) == Dictionary(uniqueKeysWithValues: changes.databases.map { ($0.destination, $0.sha256) }))
        #expect(fixture.tempCount() == 0)
        #expect(!fixture.exists(UsbLayout.oneLibrary + "-wal"))
        for path in changes.target.mustNotExist { #expect(!fixture.exists(path)) }
    }

    @Test("기기가 DB를 바꿨으면 이어 쓰지 않고 임시만 지운다")
    func deviceChangedDBBlocksResume() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges()
        crash(fixture, changes) { fs in
            fs.failAt = (operation: .writeNew, occurrence: 2, mode: .crash)
            fs.failMatching = { $0.hasPrefix("PIONEER/rekordbox/") }
        }
        #expect(fixture.tempCount() == 1)
        let device = UsbChangeSetFixture.random(3000)
        fixture.write(UsbLayout.exportPdb, device)
        let fs = fixture.fileSystem()
        let report = try fixture.recover(fileSystem: fs)
        #expect(report.outcome == .needsReplan)
        #expect(report.notes.contains { $0.hasPrefix("USB가 기기에서 바뀌어 이어 쓰지 않았습니다") })
        #expect(fixture.data(UsbLayout.exportPdb) == device)
        #expect(fixture.tempCount() == 0)
        #expect(!fs.calls.contains { $0.hasPrefix("rename ") && !$0.contains("mac:") })
        #expect(fixture.journal()?.state == .needsReplan)
    }

    @Test("needsReplan은 새 계획은 받고 옛 계획은 usbChanged로 막는다")
    func needsReplanAllowsNewPlan() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges()
        crash(fixture, changes) { fs in
            fs.failAt = (operation: .writeNew, occurrence: 2, mode: .crash)
            fs.failMatching = { $0.hasPrefix("PIONEER/rekordbox/") }
        }
        fixture.write(UsbLayout.exportPdb, UsbChangeSetFixture.random(3000))
        #expect(try fixture.recover().outcome == .needsReplan)
        let journal = try #require(fixture.journal())
        #expect(journal.isClosed)
        #expect(UsbWriter.pendingJournal(paths: fixture.paths, volumeKey: fixture.volumeKey) == nil)
        let (copy, report) = try backupFiles(journal)
        #expect(copy.state == .needsReplan)
        #expect(!copy.databases.isEmpty)
        #expect(report.outcome == .needsReplan)
        #expect(report.resultDatabases == currentDatabases(fixture))
        let replanBackup = try #require(journal.backupDirectory)

        // ① 옛 계획은 recoveryNeeded가 아니라 usbChanged
        let before = fixture.tree()
        do {
            try fixture.write(changes)
            Issue.record("막히지 않았다")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.code).contains("usbChanged"))
            #expect(!blocks.map(\.code).contains("recoveryNeeded"))
        }
        #expect(fixture.tree() == before)

        // ② 그 사이 끝난(되돌린) 쓰기 다섯 개가 쌓여도 needsReplan 백업은 남는다(더 새 verified가 없음)
        for _ in 0..<5 {
            let small = try fixture.smallEditChanges()
            let fs = fixture.fileSystem()
            fs.failAt = (operation: .rename, occurrence: 1, mode: .error)
            #expect(throws: UsbError.self) { try fixture.write(small, fileSystem: fs) }
        }
        #expect(fixture.backupFolders().count == 6)
        #expect(FileManager.default.fileExists(atPath: replanBackup))

        // 그 백업으로 되돌리기는 --discard-device-changes 없이는 막힌다
        do {
            _ = try fixture.restore(backup: URL(filePath: replanBackup))
            Issue.record("막히지 않았다")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.code) == ["deviceChanged"])
        }

        // ③ 지금 USB 지문으로 새로 만든 계획은 쓴다. 그 뒤 정리에서야 needsReplan 백업을 지울 수 있다
        let fresh = try fixture.smallEditChanges()
        #expect(try fixture.write(fresh).outcome == .written)
        #expect(fixture.journal()?.state == .verified)
        #expect(!FileManager.default.fileExists(atPath: replanBackup))
    }

    @Test("회복으로 닫은 쓰기도 백업으로 되돌릴 수 있다", arguments: [false, true])
    func recoveredWriteIsRestorable(export: Bool) throws {
        // ① E 도중 크래시 → recovered → 되돌리기
        do {
            let fixture = UsbChangeSetFixture()
            defer { fixture.remove() }
            if export { fixture.write("Contents/keep.mp3", Data("user".utf8)); fixture.write("Contents/._keep.mp3", Data(count: 4096)) } else { fixture.seedEdit() }
            let before = fixture.tree()
            let changes = export ? fixture.exportChanges() : try fixture.editChanges()
            crash(fixture, changes) { fs in
                fs.failAt = (operation: .writeNew, occurrence: 2, mode: .crash)
                fs.failMatching = { $0.hasPrefix("PIONEER/rekordbox/") }
            }
            #expect(try fixture.recover().outcome == .recovered)
            let (copy, report) = try backupFiles(fixture.journal())
            #expect(copy.state == .recovered)
            #expect(copy.databases.count == 3)
            #expect(copy.databases.allSatisfy { $0.state == .done && $0.disposition == (export ? .created : .overwritten) })
            #expect(report.resultDatabases == currentDatabases(fixture))
            #expect(report.resultDatabases == Dictionary(uniqueKeysWithValues: changes.databases.map { ($0.destination, $0.sha256) }))
            // 저널 파일을 드라이 런으로 덮어 둔다(되돌리기는 백업 폴더의 journal.json을 읽어야 한다)
            try fixture.write(fixture.smallEditChanges(), options: UsbWriteOptions(dryRun: true))
            #expect(fixture.journal()?.state == .dryRun)
            let restored = try fixture.restore()
            #expect(restored.outcome == .restored)
            #expect(fixture.tree() == before)
            #expect(fixture.appleDoubleCount() == (export ? 1 : 0))
        }
        // ② D 도중 크래시 → rolledBack → 백업에 두 파일, 되돌려도 그대로
        do {
            let fixture = UsbChangeSetFixture()
            defer { fixture.remove() }
            if !export { fixture.seedEdit() }
            let before = fixture.tree()
            let changes = export ? fixture.exportChanges() : try fixture.editChanges()
            crash(fixture, changes) { $0.failAt = (operation: .writeNew, occurrence: 2, mode: .crash) }
            #expect(try fixture.recover().outcome == .rolledBack)
            let (copy, report) = try backupFiles(fixture.journal())
            #expect(copy.state == .rolledBack)
            #expect(report.resultDatabases == currentDatabases(fixture))
            #expect(try fixture.restore().outcome == .restored)
            #expect(fixture.tree() == before)
        }
        // ③ C 전 크래시(백업 폴더 없음) → 두 파일 없이 notes 한 줄, 저널은 닫힘
        do {
            let fixture = UsbChangeSetFixture()
            defer { fixture.remove() }
            if !export { fixture.seedEdit() }
            let changes = export ? fixture.exportChanges() : try fixture.editChanges()
            crash(fixture, changes) { $0.failAt = (operation: .mountedOn, occurrence: 2, mode: .crash) }
            #expect(fixture.journal()?.state == .staged)
            let report = try fixture.recover()
            #expect(report.outcome == .rolledBack)
            #expect(report.backup == nil)
            #expect(report.notes.count == 1)
            #expect(fixture.journal()?.isClosed == true)
            #expect(fixture.journal()?.backupDirectory == nil)
        }
    }

    @Test("임시 파일은 판정이 끝난 뒤에만 지운다")
    func tempRemovedOnlyAfterDecision() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges()
        crash(fixture, changes) { $0.failAt = (operation: .copyDataNew, occurrence: 1, mode: .crash) }
        #expect(fixture.tempCount() == 1)
        let fs = fixture.fileSystem()
        #expect(try fixture.recover(fileSystem: fs).outcome == .rolledBack)
        let calls = fs.calls
        let removeTemp = try #require(calls.firstIndex { $0.hasPrefix("remove ") && $0.contains(".djc-part-") })
        // DB 셋을 모두 읽어 판정한 뒤에야 임시 파일을 지운다
        #expect(Set(calls[..<removeTemp].filter { $0.hasPrefix("sha256 PIONEER/rekordbox/") }).count == 3)
        #expect(fixture.tempCount() == 0)
    }

    @Test("저널이 없으면 임시 파일을 보고만 하고, --discard-temp일 때 지운다")
    func noJournalOnlyReportsTemp() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.write("Contents/A/.djc-part-zzzzzzzz-000001", Data("partial".utf8))
        fixture.write("PIONEER/USBANLZ/P001/.djc-part-zzzzzzzz-000002", Data("partial".utf8))
        let report = try fixture.recover()
        #expect(fixture.tempCount() == 2)
        #expect(report.notes.contains { $0.contains("2") })
        #expect(fixture.journal() == nil)
        _ = try fixture.recover(discardTemp: true)
        #expect(fixture.tempCount() == 0)
        #expect(fixture.backupFolders().isEmpty)
    }

    @Test("실물 USB는 회복도 막는다(쓰기가 열리기 전)")
    func recoverRefusesPhysicalBeforeB17() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        crash(fixture, changes) { $0.failAt = (operation: .copyDataNew, occurrence: 2, mode: .crash) }
        let before = fixture.tree()
        let journal = fixture.journal()
        fixture.volume = FakeUsbVolume.physicalFAT32(uuid: fixture.volumeKey)
        let fs = fixture.fileSystem()
        let gate = FakeUsbVolume.gate(allow: [fixture.volumeKey])
        do {
            _ = try UsbWriter.recover(root: fixture.root, paths: fixture.paths, guard: fixture.writeGuard(gate: gate), fileSystem: fs,
                                      confirmName: "DJCPHYS")
            Issue.record("막히지 않았다")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.code).contains("physicalDisabled"))
        }
        #expect(fixture.tree() == before)
        #expect(fixture.journal() == journal)
        #expect(!fs.calls.contains { $0.hasPrefix("rename ") || $0.hasPrefix("remove ") })
    }

    @Test("저널 없이 임시 파일 지우기도 실물이면 막는다")
    func discardTempRefusesPhysical() {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.write("Contents/A/.djc-part-zzzzzzzz-000001", Data("partial".utf8))
        fixture.volume = FakeUsbVolume.physicalFAT32()
        #expect(throws: UsbError.self) { try fixture.recover(discardTemp: true) }
        #expect(fixture.tempCount() == 1)
    }

    @Test("회복은 관문을 지난 뒤에만 USB 파일을 연다")
    func recoverChecksGateBeforeAnyFileOp() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        crash(fixture, changes) { $0.failAt = (operation: .copyDataNew, occurrence: 2, mode: .crash) }
        let fs = fixture.fileSystem()
        fixture.recorder = fs
        _ = try fixture.recover(fileSystem: fs)
        let calls = fs.calls.filter { !$0.contains("mac:") }
        #expect(calls[0] == "mountedOn .")
        #expect(calls[1] == "guard.volume")
        #expect(calls[2] == "guard.rekordbox")
        #expect(calls.count > 3)
    }
}
