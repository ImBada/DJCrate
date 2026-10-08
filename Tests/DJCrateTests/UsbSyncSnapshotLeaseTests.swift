@testable import DJCStorage
import Foundation
import Testing

@Suite("USB native 전용 스냅샷 수명")
struct UsbSyncSnapshotLeaseTests {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-sync-lease-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "master-2026-10-08T000000.db")
        try Data("합성 A".utf8).write(to: source)
        return (root, source)
    }

    @Test func 같은_URL을_바꿔도_전용_사본은_처음_바이트와_원본_시각을_유지한다() throws {
        let (root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provenance = try UsbSyncSnapshotProvenance.capture(source)
        let lease = try UsbSyncSnapshotLease.capture(provenance, directory: root.appending(path: "copies"))
        try Data("합성 B".utf8).write(to: source, options: .atomic)
        #expect(try Data(contentsOf: lease.database) == Data("합성 A".utf8))
        #expect(lease.provenance == provenance)
        #expect(lease.provenance.sourceURL == source)
        #expect(lease.provenance.snapshotTime == "2026-10-08T00:00:00Z")
        #expect(lease.database != source)
    }

    @Test func 목록을_채택한_지문과_다른_DB를_복사하면_거부하고_실패_폴더를_남기지_않는다() throws {
        let (root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provenance = try UsbSyncSnapshotProvenance.capture(source)
        try Data("합성 B".utf8).write(to: source, options: .atomic)
        let copies = root.appending(path: "copies")
        #expect(throws: UsbSyncSnapshotError.self) { try UsbSyncSnapshotLease.capture(provenance, directory: copies) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: copies.path))?.isEmpty ?? true)
    }

    @Test func 약한_job_참조는_사본을_남기지_않고_재시도_소유자는_수명을_유지한다() throws {
        let (root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var owner: UsbSyncSnapshotLease? = try .capture(.capture(source), directory: root.appending(path: "copies"))
        let reference = try #require(owner).reference
        let database = try #require(owner).database
        var retryOwner = reference.lease
        owner = nil
        #expect(FileManager.default.fileExists(atPath: database.path))
        #expect(retryOwner?.database == database)
        retryOwner = nil
        #expect(reference.lease == nil)
        #expect(!FileManager.default.fileExists(atPath: database.path))
    }

    @Test func 복사_중_취소와_원본_변경은_부분_사본을_지운다() throws {
        let (root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provenance = try UsbSyncSnapshotProvenance.capture(source)
        let copies = root.appending(path: "copies")
        #expect(throws: CancellationError.self) {
            try UsbSyncSnapshotLease.capture(provenance, directory: copies, afterCopy: { throw CancellationError() })
        }
        #expect(throws: UsbSyncSnapshotError.self) {
            try UsbSyncSnapshotLease.capture(provenance, directory: copies, afterCopy: {
                try Data("합성 B".utf8).write(to: source, options: .atomic)
            })
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: copies.path)).isEmpty)
    }

    @Test func 쓰기중_WAL과_링크_원본은_기본_DB만_복사하는_fallback없이_거부한다() throws {
        let (root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let wal = URL(filePath: source.path + "-wal")
        try Data("합성 WAL".utf8).write(to: wal)
        #expect(throws: UsbSyncSnapshotError.self) { try UsbSyncSnapshotProvenance.capture(source) }
        try FileManager.default.removeItem(at: wal)
        let link = root.appending(path: "link.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: UsbSyncSnapshotError.self) { try UsbSyncSnapshotProvenance.capture(link) }
    }
}
