@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import SwiftUI
import Testing

/// 쓰기 확인 창 화면 확인용(#211·#210): 합성 라이브러리(곡 셋·재생 목록 하나)에서 곡 하나에 태그 초안, 곡 하나는 고르기만,
/// 새 재생 목록 초안 하나를 두고 툴바의 "rekordbox에 쓰기"를 앱 흐름(`ReflectionCoordinator`) 그대로 부른다.
/// 뜬 창은 그려서 `<폴더>/<모양>-prompt-<n>.png`로 남기고 취소한다(확인 창이 없으면 그대로 쓰고 토스트가 뜬 주 창을 `<모양>-window.png`로).
/// 쓰기는 합성 사본에만 한다. 실제 마우스·키보드 초점을 쓰지 않는다.
/// `DJC_HOME=<임시> DJC_WRITE_CONFIRM_CAPTURE=<폴더> swift test --filter WriteConfirmCapture`
@MainActor
struct WriteConfirmCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_WRITE_CONFIRM_CAPTURE"] != nil && LiveDraftHome.isIsolated),
          arguments: ["light", "dark"])
    func capture(_ appearance: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_WRITE_CONFIRM_CAPTURE"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let fixture = try RekordboxFixture()
        for (index, title) in ["합성 곡 하나", "합성 곡 둘", "합성 곡 셋"].enumerated() {
            var track = TrackSpec(id: String(101 + index), uuid: "confirm-\(appearance)-\(index)-\(UUID())")
            track.title = title
            try fixture.add(track)
        }
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0")
        try fixture.add(PlaylistSpec(id: "1002", name: "합성 목록", seq: 1, contentIDs: ["101", "102"]))
        let xml = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#, "",
            #"<MASTER_PLAYLIST Version="3.0.0" AutomaticSync="0">"#,
            #"  <PRODUCT Name="rekordbox" Version="7.2.18" Company="AlphaTheta"/>"#,
            "  <PLAYLISTS>",
            #"    <NODE Id="3EA" ParentId="0" Attribute="0" Timestamp="1790400600945" Lib_Type="0" CheckType="0"/>"#,
            "  </PLAYLISTS>", "</MASTER_PLAYLIST>", "",
        ].joined(separator: "\r\n")
        try xml.write(to: fixture.root.appending(path: "masterPlaylists6.xml"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: fixture.root.appending(path: "share/PIONEER/USBANLZ"), withIntermediateDirectories: true)

        let store = LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.confirm.\(UUID())")!, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 backupDirectory: fixture.backups, playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in },
                                 playlistImportURL: nil, stagingSaver: { _ in }, draftHome: fixture.root.appending(path: "drafts"))
        store.rekordboxDatabase = fixture.database
        store.rekordboxShareRoot = fixture.shareRoot
        await store.load(snapshot: fixture.database, arguments: ["test", "--db", fixture.database.path], environment: [:])
        let rows = store.rows.sorted { $0.track.id < $1.track.id }
        try #require(rows.count == 3)
        // 곡 하나에 코멘트 초안, 곡 둘은 고르기만, 새 재생 목록 초안 하나
        var draft = TagDraft(track: rows[0].track)
        draft.fields.comment = "합성 코멘트"
        try TagDraftStore.save(draft)
        defer { try? TagDraftStore.remove(trackUUID: rows[0].track.uuid, directory: TagDraftStore.directory) }
        store.tagDrafts[rows[0].track.uuid] = draft
        _ = store.createPlaylist(isFolder: false, name: "합성 새 목록", tracks: [rows[2]])
        store.renamingPlaylistID = nil
        store.sidebar = .filter(.all)
        store.selection = [rows[0].id, rows[1].id]

        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.orderFront(nil)
        defer { window.close() }

        let prompter = CapturingPrompter(folder: folder, appearance: appearance)
        await ReflectionCoordinator(host: store, prompter: prompter, isRekordboxRunning: { false })
            .write(rows: store.reflectionPreviewRows)
        FileHandle.standardError.write(Data("[확인 창 캡처] \(appearance): 창 \(prompter.count)개 · 토스트 \(store.toast?.title ?? "없음")\n".utf8))
        try await Task.sleep(for: .milliseconds(1200))
        try Self.save(window.contentView?.superview ?? window.contentView, to: folder.appending(path: "\(appearance)-window.png"))
    }

    static func save(_ view: NSView?, to url: URL) throws {
        let view = try #require(view)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

/// 뜬 창을 그려 남기고 취소한다(모달로 띄우지 않는다).
@MainActor
final class CapturingPrompter: ReflectionPrompter {
    let folder: URL, appearance: String
    var count = 0
    init(folder: URL, appearance: String) { self.folder = folder; self.appearance = appearance }

    func show(_ prompt: ReflectionPrompt) -> Bool { choose(prompt) == .confirm }

    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice {
        count += 1
        let alert = AlertPrompter().makeAlert(prompt)
        alert.window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        alert.layout()
        try? WriteConfirmCapture.save(alert.window.contentView?.superview ?? alert.window.contentView,
                                      to: folder.appending(path: "\(appearance)-prompt-\(count).png"))
        FileHandle.standardError.write(Data("[확인 창 캡처] \(prompt.title) | \(prompt.details.joined(separator: " / "))\n".utf8))
        return .cancel
    }
}
