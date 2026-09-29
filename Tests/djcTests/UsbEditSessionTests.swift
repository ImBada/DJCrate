import CryptoKit
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// USB 수정 세션: 합성 로컬 사본 + DJCrate 내보내기로 만든 임시 폴더 USB(마운트 흉내, 디스크 이미지로 보이는 가짜 가드).
/// 맥 쪽 폴더(백업·저널·준비·초안·사본)는 모두 임시 폴더다. 실제 DJCrate 데이터 폴더는 읽거나 쓰지 않는다.
@Suite("USB 수정 세션")
struct UsbEditSessionTests {
    final class Env {
        let fixture: UsbEditFixture
        let copies: URL
        let drafts: UsbDraftStore
        var usb: UsbChangeSetFixture { fixture.usb }

        /// 곡 101·102·103과 목록 900을 내보낸 USB(곡 id 1·2·3, 목록 id 1)
        init() throws {
            fixture = try UsbEditFixture()
            try fixture.addLocal(["101", "102", "103"])
            try fixture.local.local.addPlaylist(id: "900", name: "합성 목록", seq: 1, contentIDs: ["101", "102", "103"])
            try fixture.export(tracks: [], playlists: ["900"])
            copies = fixture.usb.home.appending(path: "usb-snapshots")
            drafts = UsbDraftStore(directory: fixture.usb.home.appending(path: "usb-drafts"))
        }

        func session(database: URL? = nil, noDatabase: Bool = false, fileSystem: FaultyUsbFileSystem? = nil,
                     localCopy: (@Sendable (URL, URL) throws -> URL)? = nil, gate: UsbPhysicalWriteGate = FakeUsbVolume.gate()) -> UsbEditSession {
            UsbEditSession(root: usb.usbURL, database: noDatabase ? nil : (database ?? fixture.local.database), share: fixture.local.share,
                           guard: usb.writeGuard(gate: gate), paths: usb.paths, fileSystem: fileSystem ?? usb.fileSystem(),
                           localCopy: localCopy ?? UsbEditSession.defaultLocalCopy, localCopies: copies, drafts: drafts,
                           appVersion: { "7.2.18" })
        }

        /// 세션이 끝난 뒤 남은 사본 폴더(local-… 로컬 사본, usb-… USB DB 사본)
        var leftoverCopies: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: copies.path)) ?? []).filter { $0.hasPrefix("local-") || $0.hasPrefix("usb-") }
        }

        var leftoverStaging: [String] { (try? FileManager.default.contentsOfDirectory(atPath: usb.paths.staging.path)) ?? [] }
    }

    static let time = "2100-01-01T00:00:00Z"

    static func write(_ session: UsbEditSession, _ edits: [UsbLibraryEdit], dryRun: Bool = false) throws -> (UsbEditResult, UsbWriteReport?) {
        try session.write(edits, options: UsbWriteOptions(dryRun: dryRun), snapshotTime: time, progress: { _ in }, isCancelled: { false })
    }

    /// 로컬 사본을 떴는지 기록하고 실제 사본을 뜬다
    final class CopyLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(database: URL, into: URL)] = []
        var all: [(database: URL, into: URL)] { lock.withLock { calls } }
        func record(_ database: URL, _ into: URL) throws -> URL {
            lock.withLock { calls.append((database, into)) }
            return try UsbEditSession.defaultLocalCopy(database, into)
        }
    }

    static let edits: [UsbLibraryEdit] = [.removeTracks(usbContentIDs: [3]), .playlist(edit: .rename(playlist: .id("1"), name: "합성 바뀐 이름"))]

    @Test("드라이 런은 USB에 쓰지 않고 저널을 dryRun으로 닫는다")
    func dryRunNoWrite() throws {
        let env = try Env()
        let before = env.usb.tree()
        let (result, report) = try Self.write(env.session(), Self.edits, dryRun: true)
        #expect(result.outcomes.allSatisfy { $0.outcome == .written })
        #expect(report?.outcome == .dryRun)
        #expect(env.usb.tree() == before)
        #expect(env.usb.journal()?.state == .dryRun)
        #expect(env.leftoverCopies.isEmpty && env.leftoverStaging.isEmpty)
    }

    @Test("드라이 런 뒤 같은 편집으로 쓰면 막히지 않는다")
    func dryRunThenWriteNotBlocked() throws {
        let env = try Env()
        _ = try Self.write(env.session(), Self.edits, dryRun: true)
        let (_, report) = try Self.write(env.session(), Self.edits)
        #expect(report?.outcome == .written)
        #expect(env.usb.journal()?.state == .verified)
        #expect(try env.fixture.read().tracks.map(\.id) == [1, 2])
    }

    @Test("초안을 만든 뒤 USB가 바뀌면 지금 상태에 다시 계획해 쓰고 초안을 지운다")
    func baseChangedReplans() throws {
        let env = try Env()
        try env.session().addToDraft(.playlist(edit: .rename(playlist: .id("1"), name: "합성 초안 이름")))
        try env.session().addToDraft(.removeTracks(usbContentIDs: [2]))
        let key = env.usb.volumeKey
        #expect(try env.drafts.load(volumeKey: key)?.edits.count == 2)
        // 그 사이 다른 쓰기가 USB를 바꿨다
        _ = try Self.write(env.session(), [.removeTracks(usbContentIDs: [3])])
        let (result, report) = try env.session().writeDraft(options: UsbWriteOptions(), snapshotTime: Self.time, progress: { _ in },
                                                            isCancelled: { false })
        #expect(result.notes.contains("USB가 그 사이 바뀌어 다시 계획했습니다"))
        #expect(report?.outcome == .written)
        #expect(try env.drafts.load(volumeKey: key) == nil)
        let after = try env.fixture.read()
        #expect(after.tracks.map(\.id) == [1] && after.playlists.map(\.name) == ["합성 초안 이름"])
    }

    @Test("초안을 쓴 뒤에는 막힌 편집만 쓴 뒤 지문을 base로 남기고, 쓸 것이 없고 막힌 것도 없으면 초안을 지운다")
    func draftKeepsOnlyBlockedEdits() throws {
        let env = try Env()
        let key = env.usb.volumeKey
        let blocked: UsbLibraryEdit = .playlist(edit: .rename(playlist: .id("999"), name: "합성 없는 목록"))
        try env.session().addToDraft(.playlist(edit: .rename(playlist: .id("1"), name: "합성 초안 이름")))
        try env.session().addToDraft(blocked)
        try env.session().addToDraft(.removeTracks(usbContentIDs: [3]))
        let createdAt = try #require(try env.drafts.load(volumeKey: key)?.createdAt)
        let (result, report) = try env.session().writeDraft(options: UsbWriteOptions(), snapshotTime: Self.time, progress: { _ in },
                                                            isCancelled: { false })
        #expect(report?.outcome == .written)
        guard case .blocked = result.outcome(2) else { Issue.record("막지 않음"); return }
        let kept = try #require(try env.drafts.load(volumeKey: key))
        #expect(kept.edits == [blocked])
        #expect(kept.createdAt == createdAt)
        #expect(kept.base.sameContent(as: try UsbWriter.databaseFingerprint(root: env.usb.root, fileSystem: env.usb.fileSystem())))
        #expect(try env.fixture.read().tracks.map(\.id) == [1, 2])

        // 남은 초안을 다시 쓰면 또 막히므로 그대로 남는다(쓸 것 없음)
        let (again, none) = try env.session().writeDraft(options: UsbWriteOptions(), snapshotTime: Self.time, progress: { _ in },
                                                         isCancelled: { false })
        #expect(none == nil && again.changes == nil)
        #expect(try env.drafts.load(volumeKey: key)?.edits == [blocked])

        // 바꿀 것이 없고 막힌 것도 없으면 초안을 지운다
        try env.drafts.discard(volumeKey: key)
        try env.session().addToDraft(.playlist(edit: .rename(playlist: .id("1"), name: "합성 초안 이름")))
        let (same, nothing) = try env.session().writeDraft(options: UsbWriteOptions(), snapshotTime: Self.time, progress: { _ in },
                                                           isCancelled: { false })
        #expect(nothing == nil && same.changes == nil && same.outcome(1) == .unchanged)
        #expect(try env.drafts.load(volumeKey: key) == nil)
    }

    @Test("쓴 뒤 되돌리면 트리가 쓰기 전과 같다(지운 음원·분석 파일·아트워크 포함)")
    func writeThenRestoreTreeEqual() throws {
        let env = try Env()
        try env.fixture.addLocal(["104"])
        let before = env.usb.tree()
        let (_, report) = try Self.write(env.session(), Self.edits + [.addTracks(localContentIDs: ["104"], playlist: .id("1"))])
        #expect(report?.outcome == .written)
        #expect(env.usb.tree() != before)
        let restored = try UsbWriter.restore(root: env.usb.root, paths: env.usb.paths, backup: nil, guard: env.usb.writeGuard(),
                                             fileSystem: env.usb.fileSystem())
        #expect(restored.outcome == .restored)
        #expect(env.usb.tree() == before)
    }

    @Test("실물 볼륨은 관문이 막고 USB를 열거하지도 사본을 뜨지도 않는다")
    func physicalBlocked() throws {
        let env = try Env()
        env.usb.volume = FakeUsbVolume.physicalFAT32()
        let before = env.usb.tree()
        let fileSystem = env.usb.fileSystem()
        let log = CopyLog()
        let gate = FakeUsbVolume.gate(allow: [FakeUsbVolume.physicalUUID])
        let options = UsbWriteOptions(confirmName: "DJCPHYS", allowProvisional: Set(UsbProvisionalRule.allCases.filter { !$0.isGateOnly }))
        let session = env.session(fileSystem: fileSystem, localCopy: { try log.record($0, $1) }, gate: gate)
        let edits: [UsbLibraryEdit] = [.refreshTracks(usbContentIDs: [1], parts: [.info])]
        let preview = try session.preview(edits, options: options, snapshotTime: Self.time)
        #expect(preview.blocks.contains { $0.code == "physicalDisabled" })
        #expect(preview.changes == nil)
        do {
            _ = try session.write(edits, options: options, snapshotTime: Self.time, progress: { _ in }, isCancelled: { false })
            Issue.record("막히지 않음")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.contains { $0.code == "physicalDisabled" })
        }
        #expect(!fileSystem.calls.contains { $0.hasPrefix("list ") || $0.hasPrefix("stat ") })
        #expect(log.all.isEmpty && env.leftoverCopies.isEmpty)
        #expect(env.usb.tree() == before)
    }

    @Test("회복이 needsReplan으로 닫은 볼륨의 초안은 지금 USB 상태로 다시 계획해 쓰고 기기가 바꾼 행을 남긴다")
    func needsReplanThenDraftReplans() throws {
        let env = try Env()
        try env.session().addToDraft(.playlist(edit: .rename(playlist: .id("1"), name: "합성 초안 이름")))
        // 첫 DB 교체에서 끊긴다(프로세스가 죽은 것처럼)
        let crashing = env.usb.fileSystem()
        crashing.failAt = (operation: .writeNew, occurrence: 1, mode: .crash)
        crashing.failMatching = { $0.hasPrefix("PIONEER/rekordbox/") }
        #expect(throws: (any Error).self) {
            try env.session(fileSystem: crashing).writeDraft(options: UsbWriteOptions(), snapshotTime: Self.time, progress: { _ in },
                                                            isCancelled: { false })
        }
        #expect(crashing.isCrashed)
        #expect(env.usb.journal()?.isClosed == false)
        // 기기가 USB DB를 바꿨다(옛 해시도 새 해시도 아님)
        try env.fixture.oneLibrarySQL("UPDATE content SET rating = 5 WHERE content_id = 1")
        let recovered = try UsbWriter.recover(root: env.usb.root, paths: env.usb.paths, guard: env.usb.writeGuard(),
                                              fileSystem: env.usb.fileSystem(), ppthReader: UsbExportAssembly.ppthReader)
        #expect(recovered.outcome == .needsReplan)
        #expect(env.usb.journal()?.state == .needsReplan)

        let (result, report) = try env.session().writeDraft(options: UsbWriteOptions(), snapshotTime: Self.time, progress: { _ in },
                                                            isCancelled: { false })
        #expect(result.notes.contains("USB가 그 사이 바뀌어 다시 계획했습니다"))
        #expect(report?.outcome == .written)
        let oneLibrary = try #require(try env.fixture.read(.oneLibrary))
        #expect(oneLibrary.playlists.map(\.name) == ["합성 초안 이름"])
        #expect(oneLibrary.tracks.first { $0.id == 1 }?.rating == 5)
    }

    @Test("세션 사본은 넘긴 사본에서 세션 전용 폴더로만 뜨고 곡 빼기·목록 편집만 있으면 뜨지 않는다")
    func sessionCopyNeverTouchesDefaultSnapshots() throws {
        let env = try Env()
        try env.fixture.addLocal(["104"])
        let log = CopyLog()
        let edits: [UsbLibraryEdit] = [.addTracks(localContentIDs: ["104"], playlist: nil)]
        _ = try env.session(localCopy: { try log.record($0, $1) }).preview(edits, options: UsbWriteOptions(), snapshotTime: Self.time)
        _ = try Self.write(env.session(localCopy: { try log.record($0, $1) }), edits)
        #expect(log.all.count == 2)
        for call in log.all {
            #expect(call.database == env.fixture.local.database)
            #expect(call.into.deletingLastPathComponent().path == env.copies.path)
            #expect(call.into.lastPathComponent.hasPrefix("local-"))
        }
        #expect(env.leftoverCopies.isEmpty)

        // 곡 빼기·목록 편집만: 로컬 사본을 뜨지 않는다
        let untouched = CopyLog()
        _ = try Self.write(env.session(localCopy: { try untouched.record($0, $1) }), Self.edits)
        #expect(untouched.all.isEmpty)

        // 실패·취소로 끝나도 사본 폴더를 남기지 않는다
        let cancelled = CopyLog()
        try env.fixture.addLocal(["105"])
        #expect(throws: UsbError.self) {
            try env.session(localCopy: { try cancelled.record($0, $1) }).write(
                [.addTracks(localContentIDs: ["105"], playlist: nil)], options: UsbWriteOptions(), snapshotTime: Self.time,
                progress: { _ in }, isCancelled: { true })
        }
        #expect(env.leftoverCopies.isEmpty && env.leftoverStaging.isEmpty)
        env.usb.rekordboxRunning = true
        #expect(throws: UsbError.self) { try Self.write(env.session(), [.addTracks(localContentIDs: ["105"], playlist: nil)]) }
        #expect(env.leftoverCopies.isEmpty && env.leftoverStaging.isEmpty)
    }

    @Test("기본 사본 뜨기: 목적지 아래에만 만들고 옆 스냅샷은 그대로, 원본 곁 -wal은 사본 안에서 합친다")
    func defaultLocalCopyKeepsSnapshotsAndMergesWAL() throws {
        let env = try Env()
        let root = env.usb.folder.appending(path: "copyroot")
        let snapshots = root.appending(path: "snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        for name in ["master-2026-01-01T000000.db", "master-2026-01-02T000000.db"] {
            try Data("합성".utf8).write(to: snapshots.appending(path: name))
        }
        func stamp(_ url: URL) throws -> (Int, Date, String) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            return ((attributes[.size] as? Int) ?? -1, attributes[.modificationDate] as? Date ?? .distantPast, hash)
        }
        let snapshotStamps = try ["master-2026-01-01T000000.db", "master-2026-01-02T000000.db"].map { try stamp(snapshots.appending(path: $0)) }

        let database = env.fixture.local.database
        let db = try env.fixture.local.local.open()
        defer { db.close() }
        var mode = ""
        try db.query("PRAGMA journal_mode=WAL") { mode = $0.string(0) ?? "" }
        #expect(mode.lowercased() == "wal")
        try db.execute("PRAGMA wal_autocheckpoint=0")
        _ = try db.run("""
            INSERT INTO djmdArtist (ID, Name, rb_local_deleted, created_at, updated_at)
            VALUES ('7777', '합성 WAL 아티스트', 0, '2026-01-01 00:00:00.000 +00:00', '2026-01-01 00:00:00.000 +00:00')
            """, [])
        let wal = URL(filePath: database.path + "-wal")
        #expect(((try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0) > 0)
        let databaseBefore = try stamp(database), walBefore = try stamp(wal)

        let into = root.appending(path: "local-test")
        let copy = try UsbEditSession.defaultLocalCopy(database, into)
        #expect(copy.deletingLastPathComponent().path == into.path)
        #expect(!FileManager.default.fileExists(atPath: copy.path + "-wal") && !FileManager.default.fileExists(atPath: copy.path + "-shm"))
        let reopened = try CipherDatabase(path: copy.path, key: RekordboxKey.derive())
        var names: [String] = []
        try reopened.query("SELECT Name FROM djmdArtist WHERE ID = '7777'") { names.append($0.string(0) ?? "") }
        reopened.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: copy.path + suffix) }
        #expect(names == ["합성 WAL 아티스트"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["snapshots", "local-test"])
        let after = try ["master-2026-01-01T000000.db", "master-2026-01-02T000000.db"].map { try stamp(snapshots.appending(path: $0)) }
        #expect(zip(after, snapshotStamps).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 })
        let databaseAfter = try stamp(database), walAfter = try stamp(wal)
        #expect(databaseAfter.0 == databaseBefore.0 && databaseAfter.1 == databaseBefore.1 && databaseAfter.2 == databaseBefore.2)
        #expect(walAfter.0 == walBefore.0 && walAfter.1 == walBefore.1 && walAfter.2 == walBefore.2)
    }

    @Test("초안이 없으면 막고, 끝나지 않은 쓰기가 있으면 회복을 먼저 하라고 막는다")
    func draftAndJournalBlocks() throws {
        let env = try Env()
        do {
            _ = try env.session().writeDraft(options: UsbWriteOptions(), progress: { _ in }, isCancelled: { false })
            Issue.record("막히지 않음")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.code) == ["noDraft"])
        }
        let crashing = env.usb.fileSystem()
        crashing.failAt = (operation: .writeNew, occurrence: 1, mode: .crash)
        crashing.failMatching = { $0.hasPrefix("PIONEER/rekordbox/") }
        #expect(throws: (any Error).self) { try Self.write(env.session(fileSystem: crashing), Self.edits) }
        let preview = try env.session().preview(Self.edits, options: UsbWriteOptions())
        #expect(preview.blocks.map(\.code) == ["recoveryNeeded"])
    }
}
