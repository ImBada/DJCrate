import AppKit
import CryptoKit
import DJCDomain
import DJCTestSupport
import Foundation
@testable import DJCrate
import RekordboxKit
import SwiftUI
import Testing

/// 시점 스냅샷 창(#224·#225) 화면 확인용(합성 라이브러리만, 평소에는 건너뛴다).
/// `DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=$(mktemp -d) DJC_POINT_SNAPSHOT_CAPTURE=<폴더> swift test --filter PointSnapshotCapture`
/// → `<폴더>/point-snapshots-list.png`(시점 스냅샷·쓰기 전 백업 목록, 고정 하나), `point-snapshots-created.png`(이름 붙여 남긴 직후).
/// 합성 사본(`RekordboxFixture`)에 그리드를 한 번 써서 쓰기 전 백업을 만든다. 창은 화면 밖에서 그린다.
@MainActor
struct PointSnapshotCapture {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    /// 128 BPM 분석 파일이 있는 곡
    static func gridTrack(_ fixture: RekordboxFixture, title: String) throws -> TrackSpec {
        let uuid = UUID().uuidString.lowercased()
        var track = TrackSpec(uuid: uuid)
        track.title = title
        track.fileType = 11
        track.folderPath = try AudioFixture.wav(seconds: 60, in: fixture.audio, name: "\(uuid).wav").path
        track.analysisDataPath = "/PIONEER/USBANLZ/\(uuid.prefix(3))/\(uuid.dropFirst(3))/ANLZ0000.DAT"
        try fixture.add(track)
        let beats = AnlzBuilder.beats(bpm: 128, first: 500.3, count: 126)
        let dat = AnlzBuilder.dat(beats: beats)
        try fixture.putAnalysis(for: track, dat: dat, ext: AnlzBuilder.ext(beats: beats))
        try fixture.addContentFile(for: track, hash: Insecure.MD5.hash(data: dat).map { String(format: "%02x", $0) }.joined(), size: dat.count)
        return track
    }

    /// 시점 스냅샷 셋(고정한 수동·자동·수동)과 쓰기 전 백업 하나가 있는 합성 사본
    static func scene() throws -> RekordboxFixture {
        let fixture = try RekordboxFixture()
        let track = try gridTrack(fixture, title: "Synthetic Groove")
        _ = try gridTrack(fixture, title: "Test Pattern 120")
        let copyGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })
        let folder = fixture.root.appending(path: "point-snapshots")
        let day = 86_400.0, now = Date()
        let pinned = try RekordboxPointSnapshot.create(name: "공연 전 세트 정리", database: fixture.database, shareRoot: nil, in: folder,
                                                       autoDays: 7, now: now.addingTimeInterval(-5 * day), guard: copyGuard)
        try RekordboxPointSnapshot.setPinned(true, pinned.url, in: folder)
        _ = try RekordboxPointSnapshot.create(name: "", kind: .auto, database: fixture.database, shareRoot: nil, in: folder,
                                              autoDays: 7, now: now.addingTimeInterval(-2 * day), guard: copyGuard)
        _ = try RekordboxPointSnapshot.create(name: "큰 정리 전", database: fixture.database, shareRoot: nil, in: folder,
                                              autoDays: 7, now: now.addingTimeInterval(-3_600), guard: copyGuard)
        var grid = GridDraft(trackUUID: track.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: track)))
        grid.setBPM(130, at: 0)
        _ = try RekordboxWriter.write(drafts: [], grids: [grid], to: fixture.database, dryRun: false, backups: fixture.backups,
                                      shareRoot: fixture.shareRoot, guard: copyGuard)
        return fixture
    }

    static func model(_ fixture: RekordboxFixture) -> PointSnapshotModel {
        PointSnapshotModel(database: fixture.database, shareRoot: fixture.shareRoot, snapshots: fixture.root.appending(path: "point-snapshots"),
                           backups: fixture.backups,
                           guard: RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" }))
    }

    @Test(.enabled(if: environment["DJC_POINT_SNAPSHOT_CAPTURE"] != nil && LiveDraftHome.isIsolated))
    func 시점_스냅샷_창() async throws {
        guard let path = Self.environment["DJC_POINT_SNAPSHOT_CAPTURE"] else { return }
        let out = URL(filePath: path)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let fixture = try Self.scene()
        let model = Self.model(fixture)
        let window = StorageSettingsCapture.window(PointSnapshotView(model: model), title: String(ui: "시점 스냅샷"))
        window.setContentSize(NSSize(width: 760, height: 520))
        defer { window.close() }
        await model.refresh()
        model.selection = model.rows.first { $0.pinned }?.id
        try await Task.sleep(for: .milliseconds(800))
        try StorageSettingsCapture.save(window, to: out.appending(path: "point-snapshots-list.png"))

        model.newName = "녹음 전"
        await model.create()
        #expect(model.isError == false, "\(model.message ?? "")")
        try await Task.sleep(for: .milliseconds(800))
        try StorageSettingsCapture.save(window, to: out.appending(path: "point-snapshots-created.png"))
    }
}
