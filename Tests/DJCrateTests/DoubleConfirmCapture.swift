@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import SwiftUI
import Testing

/// 이중 확인 줄이기(#212) 화면 확인용. 합성 라이브러리·지어낸 실물 USB 볼륨 정보로 그리기만 하고 쓰지 않는다.
/// - `<모양>-usb-sheet.png`: 실물 USB "USB로 내보내기" 시트(미리 본 뒤)
/// - `<모양>-merge.png`: 중복 합치기 초안 창(취소)
/// 실제 마우스·키보드 초점을 쓰지 않는다.
/// `DJC_HOME=<임시> DJC_DOUBLE_CONFIRM_CAPTURE=<폴더> swift test --filter DoubleConfirmCapture`
@MainActor
struct DoubleConfirmCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_DOUBLE_CONFIRM_CAPTURE"] != nil && LiveDraftHome.isIsolated),
          arguments: ["light", "dark"])
    func capture(_ appearance: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_DOUBLE_CONFIRM_CAPTURE"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let look = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let fixture = try RekordboxFixture()
        for (id, title) in [("100", "합성 곡 남길 곡"), ("200", "합성 곡 뺄 곡")] {
            var spec = TrackSpec(id: id, uuid: "dc-\(appearance)-\(id)-\(UUID())")
            spec.title = title; spec.dataStatus = 0; spec.fileType = 11; spec.length = 30
            spec.folderPath = try AudioFixture.wav(seconds: 30, in: fixture.audio, name: id + ".wav").path
            try fixture.add(spec)
        }
        try fixture.add(PlaylistSpec(id: "1002", name: "합성 목록", seq: 1, contentIDs: ["100", "200"]))
        let store = LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.dc.\(UUID())")!, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 backupDirectory: fixture.backups, playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in },
                                 playlistImportURL: nil, stagingSaver: { _ in }, draftHome: fixture.root.appending(path: "drafts"))
        store.rekordboxDatabase = fixture.database
        store.rekordboxShareRoot = fixture.shareRoot
        await store.load(snapshot: fixture.database, arguments: ["test", "--db", fixture.database.path], environment: [:])

        // 실물 USB 내보내기 시트: 미리 본 뒤 모습(볼륨 줄과 [USB에 쓰기])
        let volume = FakeUsbVolume.physicalFAT32(name: "DJC 합성 USB")
        let usbHost = FakeUsbHost([volume])
        usbHost.serveEmpty(volume)
        let usb = UsbStore(host: usbHost, readPolicy: .all, localLibrary: { nil }, journal: { _ in .none })
        let job = UsbExportJob(database: fixture.database, share: fixture.shareRoot, volume: volume, selection: .playlists(["1002"]),
                               formats: UsbFormat.defaultSet, snapshotTime: nil)
        let summary = UsbTestData.summary(tracks: 2, playlists: 1, testVolume: false)
        let sheet = NSHostingController(rootView: UsbExportSheet(store: store, usb: usb,
                                                                 request: UsbExportSheetRequest(volume: volume, job: job, summary: summary)))
        let window = NSWindow(contentViewController: sheet)
        window.isReleasedWhenClosed = false
        window.appearance = look
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(800))
        try WriteConfirmCapture.save(window.contentView?.superview ?? window.contentView,
                                     to: folder.appending(path: "\(appearance)-usb-sheet.png"))

        // 시트 다음에 뜨던 확인 창(시트를 거친 내보내기는 #212 뒤로 띄우지 않는다)
        _ = CapturingPrompter(folder: folder, appearance: appearance).show(UsbWriteCoordinator.confirmation(summary, job: job))
        try FileManager.default.moveItem(at: folder.appending(path: "\(appearance)-prompt-1.png"),
                                         to: folder.appending(path: "\(appearance)-usb-confirm.png"))

        // 합치기 초안 창
        // 임시 폴더 경로는 캡처에 남기지 않는다
        let prompter = RedactingPrompter(inner: CapturingPrompter(folder: folder, appearance: appearance),
                                         from: fixture.audio.path, to: "~/Music/합성")
        await store.prepareMerge(keeping: "100", removing: ["200"], prompter: prompter)
        let shot = folder.appending(path: "\(appearance)-prompt-1.png"), merge = folder.appending(path: "\(appearance)-merge.png")
        try? FileManager.default.removeItem(at: merge)
        try FileManager.default.moveItem(at: shot, to: merge)
    }
}

/// 창 문구의 경로를 바꿔 넘긴다(캡처에 임시 폴더 경로가 남지 않게)
@MainActor
struct RedactingPrompter: ReflectionPrompter {
    let inner: any ReflectionPrompter
    let from: String, to: String
    func show(_ prompt: ReflectionPrompt) -> Bool { inner.show(redacted(prompt)) }
    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice { inner.choose(redacted(prompt)) }
    private func redacted(_ prompt: ReflectionPrompt) -> ReflectionPrompt {
        var prompt = prompt
        prompt.details = prompt.details.map { $0.replacingOccurrences(of: from, with: to) }
        return prompt
    }
}
