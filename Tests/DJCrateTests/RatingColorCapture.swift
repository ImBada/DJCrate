@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import SwiftUI
import Testing

/// 평점·곡 색 화면 확인용(#65). 평점·곡 색이 섞인 합성 라이브러리를 주 창에 그려 PNG로 남긴다(곡 목록·거르기·인스펙터·태그 시트).
/// 같은 합성 데이터로 변경 전·후 코드를 견주려고, 변경 뒤에만 있는 API는 `after-only` 표지 안에 모았다
/// (변경 전 코드로 찍을 때는 그 표지 사이를 지운 사본을 쓴다). 오디오 장치·화면 기록 권한 없이 화면 밖 창을 비트맵으로 떠서 찍고,
/// 사용자 라이브러리·음원·초안은 열지 않는다(`DJC_HOME`·`DJC_REKORDBOX_DIR`은 임시 폴더).
/// `DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=$(mktemp -d) DJC_RATING_COLOR_CAPTURE=<폴더> swift test --filter RatingColorCapture`
/// → `<폴더>/<light|dark>-<list|filter|inspector|sheet>.png`(변경 전에는 filter·list-default-width 없음)
@MainActor
struct RatingColorCapture {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    /// 합성 곡 16곡: (평점, 곡 색 번호). 평점 4 이상·곡 색 Red(2)는 1·3·6·11번이다.
    static let tracks: [(rating: Int, color: String?)] = [
        (5, "2"), (3, "7"), (4, "2"), (0, nil), (2, "5"), (5, "2"), (1, nil), (4, "6"),
        (0, "1"), (3, "4"), (5, "2"), (2, "8"), (4, "3"), (1, nil), (3, "7"), (0, "2"),
    ]

    static func populate(_ fixture: RekordboxFixture) throws {
        try fixture.insert("djmdArtist", ["ID": .text("a1"), "Name": .text("합성 아티스트")])
        try fixture.addColorDefaults()
        for (index, entry) in tracks.enumerated() {
            let name = String(format: "합성 곡 %02d", index + 1)
            var track = TrackSpec(id: String(index + 1))
            track.title = name
            track.artistID = "a1"
            track.bpm100 = 12000 + (index % 7) * 200
            track.length = 180 + index * 7
            track.fileType = 11
            let audio = try AudioFixture.wav(seconds: 1, in: fixture.audio, name: "\(name).wav")
            track.folderPath = audio.path
            try fixture.add(track)
            try fixture.execute("UPDATE djmdContent SET Rating = ?, ColorID = ? WHERE ID = ?",
                                [.int(entry.rating), entry.color.map { .text($0) } ?? .null, .text(track.id)])
        }
        // 기본 정렬(임포트 최신순)에서 번호 순서대로 보이게 날짜를 하루씩 앞당긴다.
        try fixture.execute("""
            UPDATE djmdContent SET created_at = date('2026-09-20', '-' || (CAST(ID AS INTEGER) - 1) || ' days') || ' 00:00:00.000 +00:00'
            """)
    }

    @Test(.enabled(if: ["DJC_RATING_COLOR_CAPTURE", "DJC_HOME", "DJC_REKORDBOX_DIR"].allSatisfy { environment[$0] != nil }),
          .serialized, arguments: ["light", "dark"])
    func capture(_ appearance: String) async throws {
        guard let path = Self.environment["DJC_RATING_COLOR_CAPTURE"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared

        // 이 시험 프로세스의 설정 영역만 쓴다. 칸 배치·보기 설정은 깨끗이 시작하고 끝나면 있던 값으로 되돌린다.
        let defaults = UserDefaults.standard
        let settingNames = [SettingKeys.sidebarVisible.name, SettingKeys.showTagEditor.name, SettingKeys.sheetMode.name]
        func layoutKeys() -> [String] {
            defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("djc.trackList.") || ($0.hasPrefix("NSTableView") && $0.contains("djc.")) }
        }
        let savedSettings = settingNames.map { defaults.object(forKey: $0) }
        let savedLayout = Dictionary(uniqueKeysWithValues: layoutKeys().compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        layoutKeys().forEach { defaults.removeObject(forKey: $0) }
        // 사이드바는 접어 둔다: 비트맵으로 뜰 때 선택된 사이드바 줄이 가끔 검게 나온다(이 확인과 상관없는 부분이라 뺀다).
        defaults.set(false, forKey: SettingKeys.sidebarVisible.name)
        defaults.set(false, forKey: SettingKeys.showTagEditor.name)
        defaults.set(false, forKey: SettingKeys.sheetMode.name)
        defer {
            layoutKeys().forEach { defaults.removeObject(forKey: $0) }
            for (key, value) in savedLayout { defaults.set(value, forKey: key) }
            for (key, value) in zip(settingNames, savedSettings) { defaults.set(value, forKey: key) }
        }

        let fixture = try RekordboxFixture()
        try Self.populate(fixture)
        // 초안은 `DJC_HOME`(임시 폴더) 아래에 저장한다: 창이 열린 뒤 디스크의 초안을 다시 읽어도 만든 초안이 그대로 남게 한다.
        let store = LibraryStore(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }))
        await store.load(snapshot: fixture.database)
        await store.missingFileTask?.value
        try #require(store.rows.count == Self.tracks.count)
        // after-only begin
        // 초안: 평점을 올린 곡, 평점·곡 색을 새로 정한 곡, 곡 색을 지운 곡(목록·시트·인스펙터에 초안 표시)
        func row(_ id: String) throws -> TrackRow { try #require(store.rows.first { $0.track.id == id }) }
        store.setTag(.rating, "5", rows: [try row("2")])
        store.setTag(.color, "2", rows: [try row("2")])
        store.setTag(.rating, "4", rows: [try row("4")])
        store.setTag(.color, "6", rows: [try row("4")])
        store.setTag(.color, "", rows: [try row("9")])
        try #require(store.tagDrafts.count == 3)
        DraftWriter.flush()
        // 시험이 만든 초안은 끝나면 되돌린다(`DJC_HOME`은 임시 폴더지만 다음 시험 실행에 남지 않게)
        defer {
            store.revertTags(rows: store.rows.filter { store.tagDrafts[$0.track.uuid] != nil })
            DraftWriter.flush()
        }
        // after-only end

        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck))
        // 화면 폭에 맞춰 줄이지 않는 창(캡처는 화면이 아니라 뷰를 그린다)
        let window = MemoryCueLimitCapture.UnconstrainedWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 1240, height: 780))
        // 사용자 화면에 비치지 않게 화면 밖에 둔다(그려서 비트맵으로 뜨므로 보이지 않아도 된다).
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(1500))
        // 창 제목은 목록 표시가 한 번 바뀐 뒤에야 "전체"가 된다(처음엔 Untitled): 다른 목록을 거쳐 돌아온다.
        store.sidebar = .pending
        try await Task.sleep(for: .milliseconds(500))
        store.sidebar = .filter(.all)
        try await Task.sleep(for: .milliseconds(1500))
        // 고르는 칸이 한눈에 보이도록 덜 쓰는 칸은 접는다(머리글 오른쪽 클릭 메뉴와 같은 일). 변경 전·후 모두 같은 칸을 접는다.
        let list = try #require(Self.findTable(window.contentView?.superview ?? window.contentView, autosaveName: "djc.trackList.v2"))
        for id in ["album", "genre", "comment", "class", "format", "tempo"] {
            list.tableColumns.first { $0.identifier.rawValue == id }?.isHidden = true
        }
        // 접은 칸의 폭이 남은 칸에 얹혀 오른쪽이 잘리지 않게, 보이는 칸을 기본 폭으로 맞추고 늘어나지 않게 둔다.
        list.columnAutoresizingStyle = .noColumnAutoresizing
        for column in list.tableColumns where !column.isHidden {
            guard let spec = TrackColumn.all.first(where: { $0.id == column.identifier.rawValue }) else { continue }
            column.width = ["title": 250, "artist": 170][spec.id] ?? spec.width
        }
        try await Task.sleep(for: .milliseconds(800))

        // 1) 곡 목록
        // after-only begin
        // 평점 칸 기본 폭(66)에서는 별이 "★★★…"로 잘린다. 그 모습도 남기고, 사용자가 칸을 넓힌 모습으로 이어 찍는다.
        let ratingColumn = try #require(list.tableColumns.first { $0.identifier.rawValue == "rating" })
        try #require(ratingColumn.width == 66)
        try save(window, to: folder.appending(path: "\(appearance)-list-default-width.png"))
        ratingColumn.width = 84
        try await Task.sleep(for: .milliseconds(500))
        // after-only end
        try save(window, to: folder.appending(path: "\(appearance)-list.png"))

        // after-only begin
        // 2) 거르기: 평점 4개 이상 · 곡 색 Red
        store.minimumRating = 4
        store.colorFilter = "2"
        try await Task.sleep(for: .milliseconds(800))
        try #require(store.rows.count == Self.tracks.count && store.displayRows.count == 4)
        try save(window, to: folder.appending(path: "\(appearance)-filter.png"))
        store.minimumRating = 0
        store.colorFilter = nil
        try await Task.sleep(for: .milliseconds(500))
        // after-only end

        // 3) 인스펙터: 초안이 있는 곡(2번)을 고른다(세로로 긴 패널이라 창을 높게)
        window.setContentSize(NSSize(width: 1440, height: 900))
        try await Task.sleep(for: .milliseconds(800))
        store.selection = [try #require(store.rows.first { $0.track.id == "2" }).id]
        defaults.set(true, forKey: SettingKeys.showTagEditor.name)
        try await settle(window)
        try save(window, to: folder.appending(path: "\(appearance)-inspector.png"))
        defaults.set(false, forKey: SettingKeys.showTagEditor.name)
        store.selection = []
        try await settle(window)

        // 4) 태그 시트(열이 모두 보이게 넓은 창)
        window.setContentSize(NSSize(width: 1700, height: 800))
        defaults.set(true, forKey: SettingKeys.sheetMode.name)
        try await settle(window)
        try save(window, to: folder.appending(path: "\(appearance)-sheet.png"))
    }

    /// 화면 밖 창은 설정이 바뀌어도 배치가 늦게 돌아 인스펙터·시트가 한 박자 늦게 나타난다: 창 크기를 1점 흔들어 다시 배치시키고 기다린다.
    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(600))
        let size = window.contentView?.frame.size ?? .zero
        window.setContentSize(NSSize(width: size.width + 1, height: size.height))
        try await Task.sleep(for: .milliseconds(400))
        window.setContentSize(size)
        try await Task.sleep(for: .milliseconds(1500))
    }

    private static func findTable(_ view: NSView?, autosaveName: String) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView, table.autosaveName == autosaveName { return table }
        for sub in view.subviews { if let found = findTable(sub, autosaveName: autosaveName) { return found } }
        return nil
    }

    private func save(_ window: NSWindow, to url: URL) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(window.contentView?.superview ?? window.contentView)
        // 뷰를 따로 그리면(cacheDisplay) 선택 줄의 효과 레이어(합성 필터)가 검게 나온다: 캡처할 때만 비강조 선택 색으로 칠한다.
        var selection: CGColor?
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            selection = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
        }
        // 효과 레이어가 어느 깊이에 있든(사이드바 선택 줄은 가끔 한 겹 더 깊다) 합성 필터가 붙은 레이어를 찾아 칠한다.
        func clearFilters(_ layer: CALayer) {
            if layer.compositingFilter != nil {
                layer.compositingFilter = nil
                layer.backgroundColor = selection
            }
            layer.sublayers?.forEach(clearFilters)
        }
        func flatten(_ view: NSView) {
            if let row = view as? NSTableRowView, row.isSelected {
                for layer in row.subviews.compactMap({ ($0 as? NSVisualEffectView)?.layer }).flatMap({ $0.sublayers ?? [] }) {
                    layer.compositingFilter = nil
                    layer.backgroundColor = selection
                }
                if let layer = row.layer { clearFilters(layer) }
            }
            view.subviews.forEach(flatten)
        }
        flatten(view)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
