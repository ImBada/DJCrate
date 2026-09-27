import DJCDomain
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// `usb-restore`: 끝난 쓰기를 그 쓰기의 백업으로 되돌린다
@Suite("USB 쓰기 되돌리기")
struct UsbRestoreTests {
    func refusal(_ body: () throws -> Void) -> [String] {
        do {
            try body()
            Issue.record("막히지 않았다")
            return []
        } catch let UsbError.writeRefused(blocks) {
            return blocks.map(\.code)
        } catch {
            Issue.record("다른 오류: \(error)")
            return []
        }
    }

    @Test("rekordbox가 켜져 있으면 미룬다")
    func restoreGuardRekordboxRunningPending() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        try fixture.write(fixture.editChanges())
        let after = fixture.tree()
        fixture.rekordboxRunning = true
        #expect {
            try fixture.restore()
        } throws: { error in
            if case UsbError.restorePending = error { true } else { false }
        }
        #expect(fixture.tree() == after)
    }

    @Test("그 뒤 USB가 바뀌었으면(기기 기록 등) 막는다")
    func restoreRefusesIfDeviceChanged() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        try fixture.write(fixture.editChanges())
        fixture.write(UsbLayout.oneLibrary + "-wal", Data("device".utf8))
        let after = fixture.tree()
        #expect(refusal { _ = try fixture.restore() } == ["deviceChanged"])
        #expect(fixture.tree() == after)
        // DB 내용이 바뀐 것도
        try FileManager.default.removeItem(at: fixture.usb(UsbLayout.oneLibrary + "-wal"))
        fixture.write(UsbLayout.exportExtPdb, UsbChangeSetFixture.random(100))
        #expect(refusal { _ = try fixture.restore() } == ["deviceChanged"])
    }

    @Test("--discard-device-changes면 기기 변경을 버리고 되돌린다")
    func discardDeviceChangesRestores() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let before = fixture.tree()
        try fixture.write(fixture.editChanges())
        fixture.write(UsbLayout.oneLibrary + "-wal", Data("device".utf8))
        fixture.write(UsbLayout.exportExtPdb, UsbChangeSetFixture.random(100))
        let report = try fixture.restore(discardDeviceChanges: true)
        #expect(report.outcome == .restored)
        #expect(fixture.tree() == before)
    }

    @Test("드라이 런은 아무것도 바꾸지 않는다")
    func restoreDryRun() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        try fixture.write(fixture.editChanges())
        let after = fixture.tree()
        #expect(try fixture.restore(dryRun: true).outcome == .dryRun)
        #expect(fixture.tree() == after)
    }

    @Test("만든 파일은 지우고 재사용한 파일은 그대로")
    func restoreDeletesCreatedKeepsReused() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let before = fixture.tree()
        let changes = try fixture.editChanges(removals: false)
        try fixture.write(changes)
        let fs = fixture.fileSystem()
        _ = try fixture.restore(fileSystem: fs)
        #expect(!fixture.exists(UsbChangeSetFixture.newAudio))
        #expect(!fixture.directories().contains("Contents/New"))
        #expect(fixture.tree() == before)
        for reused in [UsbChangeSetFixture.keepAudio, UsbChangeSetFixture.keepArtwork[0]] {
            #expect(!fs.calls.contains { $0.hasSuffix(reused) && ($0.hasPrefix("remove ") || $0.hasPrefix("rename ")) })
        }
    }

    @Test("지웠던 음원은 로컬 원본 SHA-1이 같을 때만 다시 복사한다")
    func restoreRecopiesRemovedAudioIfSHA1Matches() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let before = fixture.tree()
        try fixture.write(fixture.editChanges())
        #expect(!fixture.exists(UsbChangeSetFixture.goneAudio))
        #expect(try fixture.restore().outcome == .restored)
        #expect(fixture.tree() == before)

        // 원본이 바뀌었으면 다시 복사하지 않고 알린다
        let other = UsbChangeSetFixture()
        defer { other.remove() }
        other.seedEdit()
        try other.write(other.editChanges())
        try UsbChangeSetFixture.random(100).write(to: other.sources.appending(path: "gone/gone.mp3"))
        let report = try other.restore()
        #expect(!other.exists(UsbChangeSetFixture.goneAudio))
        #expect(report.notes.contains { $0.contains(UsbChangeSetFixture.goneAudio) })
        for path in UsbChangeSetFixture.goneAnalysis { #expect(other.exists(path)) }
    }

    @Test("실물 USB는 되돌리기도 막는다")
    func restoreRefusesPhysicalBeforeB17() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        try fixture.write(fixture.editChanges())
        let after = fixture.tree()
        fixture.volume = FakeUsbVolume.physicalFAT32(uuid: fixture.volumeKey)
        let gate = FakeUsbVolume.gate(allow: [fixture.volumeKey])
        let codes = refusal {
            _ = try UsbWriter.restore(root: fixture.root, paths: fixture.paths, backup: nil, guard: fixture.writeGuard(gate: gate),
                                      fileSystem: fixture.fileSystem(), confirmName: "DJCPHYS")
        }
        #expect(codes.contains("physicalDisabled"))
        #expect(fixture.tree() == after)
    }

    @Test("내보내기 뒤 되돌리면 쓰기 전(빈 USB) 트리")
    func restoreAfterExportRemovesCreatedData() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.write("Contents/keep.mp3", Data("user".utf8))
        fixture.write("Contents/._keep.mp3", Data(count: 4096))
        let before = fixture.tree()
        let beforeDirs = fixture.directories()
        try fixture.write(fixture.exportChanges(), fileSystem: fixture.fileSystem(appleDouble: true))
        #expect(fixture.journal()?.state == .verified)
        // 저널 파일을 다른 드라이 런으로 덮어 둔다
        try fixture.write(fixture.smallEditChanges(), options: UsbWriteOptions(dryRun: true))
        let report = try fixture.restore(fileSystem: fixture.fileSystem(appleDouble: true))
        #expect(report.outcome == .restored)
        #expect(fixture.tree() == before)
        #expect(fixture.directories() == beforeDirs)
        for name in ["exportLibrary.db", "exportLibrary.db-wal", "exportLibrary.db-shm", "exportLibrary.db-journal", "._exportLibrary.db"] {
            #expect(!fixture.exists("PIONEER/rekordbox/" + name))
        }

        // 기기가 사이드카와 ._를 남긴 경우: 기본은 막고, 버리기를 주면 정확한 이름으로 지운다
        try fixture.write(fixture.exportChanges())
        fixture.write(UsbLayout.oneLibrary + "-wal", Data("device".utf8))
        fixture.write("PIONEER/rekordbox/._exportLibrary.db", Data(count: 4096))
        #expect(refusal { _ = try fixture.restore() } == ["deviceChanged"])
        _ = try fixture.restore(discardDeviceChanges: true)
        #expect(fixture.tree() == before)
        #expect(fixture.directories() == beforeDirs)
    }

    @Test("수정 뒤 되돌리면 덮어쓴 DB·사이드카·._·분석 파일이 쓰기 전 바이트")
    func restoreAfterEditRestoresOverwrittenDB() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit(extraSidecar: true, extraAppleDouble: true)
        let before = fixture.tree()
        let beforeDirs = fixture.directories()
        let changes = try fixture.editChanges(removals: false)
        try fixture.write(changes)
        let journal = try #require(fixture.journal())
        #expect(journal.databases.allSatisfy { $0.disposition == .overwritten })
        #expect(!fixture.exists(UsbLayout.oneLibrary + "-wal"))
        #expect(!fixture.exists("PIONEER/rekordbox/._export.pdb"))
        #expect(try fixture.restore().outcome == .restored)
        #expect(fixture.tree() == before)
        #expect(fixture.directories() == beforeDirs)
        #expect(!fixture.exists(UsbChangeSetFixture.newAudio))
    }

    @Test("되돌릴 백업이 없으면 막는다")
    func noBackupRefused() {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        #expect(refusal { _ = try fixture.restore() } == ["noBackup"])
    }
}
