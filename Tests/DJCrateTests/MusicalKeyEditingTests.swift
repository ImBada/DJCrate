@testable import DJCrate
import AppKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// 태그의 키 고르기(#5): 인스펙터·시트가 Camelot 이름(1A~12B)과 "없음"에서만 고르고, DJCrate 추정은 제안으로만 보이며,
/// 목록의 키 칸은 보기 전용이고, 추가한 곡은 키를 고를 수 없다.
@Suite("태그 키 고르기", .serialized)
@MainActor
struct MusicalKeyEditingTests {
    static func row(_ id: String, key: String? = nil, staged: Bool = false, streaming: Bool = false) -> TrackRow {
        TrackRow(track: Track(id: staged ? "djc-\(id)" : id, uuid: "uuid-\(id)", title: "곡 \(id)", artist: "가수", album: nil, albumArtist: nil,
                              genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: key, bpm: 120, lengthSeconds: 30,
                              folderPath: streaming ? "spotify:track:\(id)" : "/x/\(id).mp3", comment: "",
                              importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false),
                 cues: [], playCount: 0)
    }

    func store() -> LibraryStore { LibraryStore(saveTagDrafts: { _ in }) }

    // MARK: 목록 칸은 보기 전용

    @Test func 목록의_키_칸은_보기_전용이고_키_칸_이름은_태그_칸과_겹치지_않는다() {
        #expect(TrackListTagEditing.key(forColumn: "key") == nil)
        #expect(!TrackColumn.all.contains { $0.id == TagFields.Key.musicalKey.rawValue })
        // 곡 목록에서 키를 고치는 길이 없다(행 편집은 태그 칸 이름으로만 시작한다)
        #expect(TrackColumn.all.first { $0.id == "key" } != nil)
    }

    // MARK: 고르기 규칙

    @Test func 고르기는_없음과_스물네_이름이고_옛_표기_값은_맨_앞에_보인다() {
        #expect(KeyPicker.choices(current: "5A").count == 24 && KeyPicker.choices(current: "").first == "1A")
        #expect(KeyPicker.choices(current: "Em").first == "Em" && KeyPicker.choices(current: "Em").count == 25)
    }

    @Test func 추가한_곡_스트리밍_곡은_키를_고를_수_없고_이유를_알린다() throws {
        let staged = Self.row("1", staged: true), library = Self.row("2"), streaming = Self.row("3", streaming: true)
        #expect(KeyPicker.unavailableReason(library) == nil)
        let reason = try #require(KeyPicker.unavailableReason(staged))
        #expect(reason.contains("rekordbox에 넣은 뒤") && TrackListTagEditing.unavailableReason(staged, key: .title) == nil)
        #expect(KeyPicker.unavailableReason(streaming) != nil)
        #expect(KeyPicker.targets([staged, library, streaming]).map(\.track.id) == ["2"])
        #expect(KeyPicker.isEditable([staged, library]) && !KeyPicker.isEditable([staged, streaming]))
    }

    // MARK: 초안에 넣기

    @Test func 키를_고르면_키만_바뀐_초안이_생기고_같은_값은_초안을_만들지_않는다() throws {
        let store = store()
        let row = Self.row("1", key: "5A")
        store.setTag(.musicalKey, "5A", rows: [row])
        #expect(store.tagDrafts.isEmpty, "지금 값과 같으면 초안이 없다")
        store.setTag(.musicalKey, "8A", rows: [row])
        let draft = try #require(store.tagDrafts[row.track.uuid])
        #expect(draft.changedKeys == [.musicalKey] && draft.base.musicalKey == "5A" && draft.fields.musicalKey == "8A")
        #expect(store.tagCell(row, .musicalKey) == "8A" && store.isTagEdited(row, .musicalKey))
        store.setTag(.musicalKey, "", rows: [row])
        #expect(store.tagDrafts[row.track.uuid]?.fields.musicalKey == "")
        store.setTag(.musicalKey, "5A", rows: [row])
        #expect(store.tagDrafts.isEmpty, "처음 값으로 되돌리면 초안이 사라진다")
    }

    @Test(arguments: [("8a", "8A"), (" 12b ", "12B"), ("", "")]) func 입력은_정확한_이름으로_다듬어_받는다(raw: String, expected: String) throws {
        let store = store()
        let row = Self.row("1", key: "5A")
        store.setTag(.musicalKey, raw, rows: [row])
        #expect(store.tagDrafts[row.track.uuid]?.fields.musicalKey == expected)
    }

    @Test(arguments: ["Am", "C", "13A", "0B", "키", "8A8A"]) func Camelot_이름이_아닌_값은_초안에_넣지_않는다(raw: String) {
        let store = store()
        let row = Self.row("1", key: "5A")
        store.setTag(.musicalKey, raw, rows: [row])
        #expect(store.tagDrafts.isEmpty)
    }

    @Test func 추가한_곡의_키는_초안에_넣지_않는다() {
        let store = store()
        let staged = Self.row("1", key: "8A", staged: true)
        store.setTag(.musicalKey, "6A", rows: [staged])
        #expect(store.tagDrafts.isEmpty)
        // 다른 칸은 그대로 고칠 수 있다
        store.setTag(.title, "새 제목", rows: [staged])
        #expect(store.tagDrafts[staged.track.uuid]?.changedKeys == [.title])
    }

    @Test func 옛_표기_키를_가진_곡의_초안을_버리면_옛_표기_기준으로_돌아간다() throws {
        let store = store()
        let row = Self.row("1", key: "Em")
        store.setTag(.musicalKey, "8A", rows: [row])
        #expect(store.tagDrafts[row.track.uuid]?.changedKeys == [.musicalKey])
        store.revertTags(rows: [row])
        #expect(store.tagDrafts.isEmpty, "옛 표기 기준으로 되돌리는 것은 Camelot 이름이 아니어도 받는다")
        #expect(store.tagCell(row, .musicalKey) == "Em")
    }

    @Test func 여러_곡을_고르면_고칠_수_있는_곡만_고친다() throws {
        let store = store()
        let a = Self.row("1", key: "5A"), b = Self.row("2", key: "6A"), staged = Self.row("3", staged: true)
        let value = store.tagValue(.musicalKey, rows: [a, b])
        #expect(value.mixed)
        store.setTag(.musicalKey, "8A", rows: KeyPicker.targets([a, b, staged]))
        #expect(store.tagDrafts.keys.sorted() == ["uuid-1", "uuid-2"])
        #expect(store.tagValue(.musicalKey, rows: [a, b]) == (value: "8A", mixed: false))
    }

    // MARK: 키 칸이 없던 옛 초안

    @Test func 옛_초안이_있는_곡도_키는_지금_값으로_보이고_다른_칸을_고쳐도_키_기준이_어긋나지_않는다() throws {
        let store = store()
        let row = Self.row("1", key: "5A")
        var legacy = TagDraft(trackUUID: row.track.uuid, base: TagFields(track: Self.row("1").track))   // 키 칸이 비어 있던 시절
        legacy.fields.title = "옛 초안 제목"
        store.tagDrafts[row.track.uuid] = legacy
        #expect(legacy.base.musicalKey == "" && store.tagCell(row, .musicalKey) == "5A", "고르기에는 지금 키가 보인다")
        #expect(!store.isTagEdited(row, .musicalKey))
        // 이어서 다른 칸을 고쳐도 키는 안 고친 칸이고 기준이 지금 값으로 맞춰진다
        store.setTag(.comment, "새 코멘트", rows: [row])
        let draft = try #require(store.tagDrafts[row.track.uuid])
        #expect(draft.changedKeys == [.title, .comment] && draft.base.musicalKey == "5A" && draft.fields.musicalKey == "5A")
        // 키를 고르면 지금 값이 기준이다(쓰기가 기준 어긋남으로 막지 않는다)
        store.setTag(.musicalKey, "8A", rows: [row])
        #expect(store.tagDrafts[row.track.uuid]?.base.musicalKey == "5A")
    }

    // MARK: DJCrate 추정은 제안이다

    @Test func 분석_캐시의_크로마로_키를_추정하고_캐시가_없으면_계산하지_않는다() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "djc-key-suggest-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = try ChordFixture.wav(ChordFixture.aMinor, seconds: 30, in: directory, name: "a-minor.wav")
        let uuid = "suggest-\(UUID())"
        // 캐시가 없으면 곡을 분석하지 않고 nil이다(인스펙터에서 곡 전체를 읽지 않는다)
        #expect(KeyPicker.cachedEstimate(uuid: uuid, file: wav, duration: 30) == nil)
        #expect(AnalysisCache.chroma(key: uuid, file: wav) == nil, "묻기만 해서는 캐시가 생기지 않는다")
        AnalysisCache.store(try KeyAnalyzer.chroma(fileAt: wav), key: uuid, file: wav)
        defer { AnalysisCache.removeAll(key: uuid) }
        #expect(KeyPicker.cachedEstimate(uuid: uuid, file: wav, duration: 30) == "8A")
    }

    @Test func 제안은_키가_빈_곡_하나에만_보이고_자동으로_초안을_만들지_않는다() throws {
        let store = store()
        let empty = Self.row("1"), keyed = Self.row("2", key: "5A"), staged = Self.row("3", staged: true), other = Self.row("4")
        func suggestion(_ rows: [TrackRow], estimate: String? = "8A") -> String? {
            KeyPicker.suggestion(estimate: estimate, rows: rows, current: store.tagValue(.musicalKey, rows: rows))
        }
        #expect(suggestion([empty]) == "8A")
        #expect(store.tagDrafts.isEmpty, "제안을 구하고 보여도 초안은 없다: 사용자가 눌러야 들어간다")
        #expect(store.tagCell(empty, .musicalKey) == "")
        #expect(suggestion([keyed]) == nil && suggestion([staged]) == nil && suggestion([empty, other]) == nil)
        #expect(suggestion([empty], estimate: nil) == nil && suggestion([empty], estimate: "Am") == nil)
        #expect(KeyPicker.suggestionTarget(rows: [empty])?.uuid == "uuid-1")
        #expect(KeyPicker.suggestionTarget(rows: [keyed]) == nil && KeyPicker.suggestionTarget(rows: [staged]) == nil)
        // 사용자가 누르면(고르면) 그때 초안이 생긴다
        store.setTag(.musicalKey, "8A", rows: KeyPicker.targets([empty]))
        #expect(store.tagDrafts[empty.track.uuid]?.changedKeys == [.musicalKey])
    }

    @Test func 키를_고친_초안이_있는_추가한_곡은_넣지_않고_이유를_알린다() async throws {
        // 곡을 rekordbox에 넣을 때는 키를 쓰지 않는다(KeyID '0'). 고르기는 추가한 곡에서 막혀 있어 직접 고친 초안 파일만 이 길로 온다.
        // 조용히 버리지 않고 그 곡을 빼고 이유를 알린다. 다른 칸만 고친 곡은 그대로 넣을 수 있다.
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())   // 라이브러리 공통값
        let store = LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.musicalkey.\(UUID())")!, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture.backups,
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
        let database = fixture.database
        store.takeLiveSnapshot = { _ in database }
        store.rekordboxDatabase = database
        store.rekordboxShareRoot = fixture.shareRoot
        store.launchArguments = ["test"]
        store.launchEnvironment = [:]
        let path = try TestResources.url("mp3-notag-cbr.mp3").path
        let staged = try JSONDecoder().decode(StagedTrack.self, from: Data("""
            {"uuid":"\(UUID().uuidString)","path":"\(path)","title":"합성 추가 곡","comment":"","duration":2,"addedOn":"2026-10-04"}
            """.utf8))
        store.staged = [staged]
        let row = TrackRow(track: staged.track, cues: [], playCount: 0)
        var draft = TagDraft(track: staged.track)
        draft.fields.musicalKey = "8A"
        store.tagDrafts[staged.uuid] = draft
        let blocked = try await store.previewTrackAdd(rows: [row])
        #expect(blocked.plans.isEmpty && blocked.unreadable.count == 1)
        #expect(blocked.unreadable.first?.contains("합성 추가 곡") == true && blocked.unreadable.first?.contains("키") == true)
        // 키 초안을 버리면(다른 칸만 고치면) 넣을 수 있다
        draft.fields.musicalKey = draft.base.musicalKey
        draft.fields.title = "새 제목"
        store.tagDrafts[staged.uuid] = draft
        let ready = try await store.previewTrackAdd(rows: [row])
        #expect(ready.plans.count == 1 && ready.unreadable.isEmpty)
    }

    // MARK: 추정 불러오기 경합

    /// 곡을 옮길 때 늦게 끝난 앞 곡의 추정이 뒤 곡 것을 덮지 않는다(인스펙터의 `.task(id:)`가 앞 작업을 취소해도 백그라운드 계산은 끝까지 돈다).
    @Test(arguments: [true, false]) func 앞_곡의_늦은_추정이_뒤_곡의_추정을_덮지_않는다(cancelled: Bool) async throws {
        let loader = KeyEstimateLoader()
        let a = KeyPicker.Target(uuid: "A", path: "/x/a.mp3", duration: 30), b = KeyPicker.Target(uuid: "B", path: "/x/b.mp3", duration: 30)
        let gate = DispatchSemaphore(value: 0)
        // A: 캐시가 있어 계산이 느리다(문이 열릴 때까지). B: 캐시가 없어 바로 nil.
        let first = Task { await loader.load(a) { _ in gate.wait(); return "8A" } }
        while loader.uuid != "A" { await Task.yield() }
        if cancelled { first.cancel() }
        await loader.load(b) { _ in nil }
        #expect(loader.uuid == "B" && loader.estimate == nil)
        gate.signal()
        await first.value
        #expect(loader.estimate == nil && loader.uuid == "B", "늦게 끝난 A의 8A가 B에 보이면 안 된다")
        // 정상 흐름: 같은 곡의 결과는 들어온다
        await loader.load(a) { _ in "6A" }
        #expect(loader.estimate == "6A" && loader.uuid == "A")
        // 곡이 없으면(고른 곡이 없거나 못 고치는 곡) 비운다
        await loader.load(nil) { _ in "8A" }
        #expect(loader.estimate == nil && loader.uuid == nil)
    }

    @Test func 제안은_불러온_추정이_지금_곡의_것일_때만_쓴다() async {
        let loader = KeyEstimateLoader()
        let row = Self.row("1"), other = Self.row("2")
        #expect(KeyPicker.estimate(of: loader, for: [row]) == nil)
        await loader.load(KeyPicker.suggestionTarget(rows: [row])) { _ in "8A" }
        #expect(KeyPicker.estimate(of: loader, for: [row]) == "8A")
        #expect(KeyPicker.estimate(of: loader, for: [other]) == nil, "다른 곡을 고른 첫 화면에 앞 곡의 추정이 비치지 않는다")
        #expect(KeyPicker.estimate(of: loader, for: [row, other]) == nil)
    }

    // MARK: 확인 창

    @Test func 확인_창은_키를_고친_곡의_칸_이름을_키로_알린다() throws {
        // Report는 안쪽 init이 없어 보고서 JSON으로 만든다(옛 보고서를 읽는 것과 같은 길)
        let json = """
            {"outcomes":[],"dryRun":true,"createdAt":"x","tagOutcomes":[
            {"trackUUID":"k","title":"곡 k","status":"written","removed":0,"added":1,"fields":["musicalKey"]},
            {"trackUUID":"m","title":"곡 m","status":"written","removed":0,"added":2,"fields":["title","musicalKey"]},
            {"trackUUID":"x","title":"곡 x","status":"blocked","reason":"rekordbox 키 목록에 '12B' 줄이 없습니다. rekordbox에서 이 곡의 키를 직접 고르세요","removed":0,"added":0}]}
            """
        let report = try JSONDecoder().decode(RekordboxWriter.Report.self, from: Data(json.utf8))
        let prompt = ReflectionCoordinator.confirmation(report)
        #expect(prompt.details.contains("• 곡 k — 태그(키)") && prompt.details.contains("• 곡 m — 태그(제목·키)"))
        #expect(prompt.details.contains { $0.contains("곡 x") && $0.contains("rekordbox에서 이 곡의 키를 직접 고르세요") })
        #expect(prompt.details.contains { $0.contains("음원 파일의 태그는 그대로") })
    }

    // MARK: 태그 시트

    @Test func 시트의_키_열은_보기_열과_같은_이름으로_정렬하고_태그_칸에_이어진다() throws {
        let column = try #require(SheetColumn.all.first { $0.key == .musicalKey })
        #expect(column.id == "key" && column.title == "키")
        #expect(TrackColumn.comparator(key: column.id, ascending: true) != nil)
    }

    @Test func 시트는_키_칸에_글자_편집기를_열지_않고_고르기_메뉴를_보인다() throws {
        let h = SheetKeyHarness()
        defer { h.window.close() }
        let column = h.keyColumn
        let menu = try #require(h.coordinator.keyMenu(row: 0))
        let titles = menu.items.map(\.title)
        #expect(titles == ["없음"] + KeyNotation.camelotNames, "키 없는 곡: 없음에 체크, 24개 이름")
        #expect(menu.items.first?.state == .on)
        let keyed = try #require(h.coordinator.keyMenu(row: 1))
        #expect(keyed.items.first { $0.state == .on }?.title == "5A")
        let legacy = try #require(h.coordinator.keyMenu(row: 2))
        #expect(legacy.items.first?.title == "Em" && legacy.items.first?.action == nil && legacy.items.first?.state == .on, "옛 표기는 고를 수 없는 현재 값")
        #expect(h.coordinator.keyMenu(row: 3) == nil, "추가한 곡은 메뉴가 없다")
        #expect(h.coordinator.editableKey(row: 3, column: column) == nil && h.coordinator.editableKey(row: 0, column: column) == .musicalKey)
        // 더블클릭·Return·타이핑이 시작하는 편집은 키 칸에서 글자 입력이 아니다
        h.coordinator.select(.init(row: 3, column: column), extend: false)
        h.coordinator.beginEditing()
        #expect(!h.coordinator.isEditing)
    }

    @Test func 시트에서_메뉴로_고른_키는_초안이_되고_같은_곡을_가리킨다() throws {
        let h = SheetKeyHarness()
        defer { h.window.close() }
        let menu = try #require(h.coordinator.keyMenu(row: 0))
        let item = try #require(menu.items.first { $0.title == "8A" })
        // 메뉴가 열려 있는 동안 줄 순서가 바뀌어도 고른 곡에 들어간다
        h.coordinator.update(rows: h.coordinator.rows.reversed(), revision: h.store.tagRevision + 1)
        h.coordinator.pickKey(item)
        #expect(h.store.tagDrafts["uuid-1"]?.changedKeys == [.musicalKey] && h.store.tagDrafts["uuid-1"]?.fields.musicalKey == "8A")
        #expect(h.store.tagDrafts.count == 1)
    }

    @Test func 시트_붙여넣기와_채우기는_Camelot_이름과_빈칸만_키_칸에_넣고_건너뛴_수를_알린다() throws {
        let h = SheetKeyHarness()
        defer { h.window.close() }
        var announced: [String] = []
        h.coordinator.announce = { announced.append($0) }
        let column = h.keyColumn
        // 한 값 붙이기: 소문자도 받는다
        h.coordinator.select(.init(row: 0, column: column), extend: false)
        h.coordinator.paste(string: "8a")
        #expect(h.store.tagCell(h.coordinator.rows[0], .musicalKey) == "8A")
        // Camelot이 아닌 값은 건너뛴다
        h.coordinator.select(.init(row: 1, column: column), extend: false)
        h.coordinator.paste(string: "Am")
        #expect(h.store.tagCell(h.coordinator.rows[1], .musicalKey) == "5A")
        #expect(announced.last?.contains("1A~12B") == true)
        // 채우기: 옛 표기(Em) 값을 아래 칸으로 채우려 해도 건너뛴다(가운데 줄은 추가한 곡이라 어차피 못 고친다)
        h.coordinator.select(.init(row: 2, column: column), extend: false)
        h.coordinator.select(.init(row: 4, column: column), extend: true)
        h.coordinator.fillDown()
        #expect(h.store.tagCell(h.coordinator.rows[2], .musicalKey) == "Em" && h.store.tagCell(h.coordinator.rows[3], .musicalKey) == "")
        #expect(h.store.tagCell(h.coordinator.rows[4], .musicalKey) == "" && announced.last?.contains("1A~12B") == true)
        // Delete: 빈칸은 받는다(키 지우기)
        h.coordinator.select(.init(row: 1, column: column), extend: false)
        h.coordinator.clearSelection()
        #expect(h.store.tagCell(h.coordinator.rows[1], .musicalKey) == "")
        #expect(h.store.tagDrafts["uuid-2"]?.changedKeys == [.musicalKey])
    }

    // MARK: 추가한 곡

    @Test func 곡_편집_결과의_태그_초안은_원곡의_키를_고친_칸으로_담지_않는다() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-edit-stage-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let output = try AudioFixture.wav(seconds: 8, in: home, name: "원곡 (Edit).wav")
        let grid = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]
        let edit = try TrackEdit(grid: grid, sourceDuration: 100.5, bars: BarRange.list("1-4"))
        let source = Self.row("src", key: "5A").track
        let staged = try await EditStaging.stage(fileAt: output, edit: edit, cues: [], source: source, home: home)
        let tags = try #require(TagDraftStore.load(trackUUID: staged.uuid, directory: home.appending(path: "tag-drafts")))
        #expect(!tags.changedKeys.contains(.musicalKey) && tags.fields.musicalKey == tags.base.musicalKey)
        #expect(tags.fields.title == "곡 src (Edit)")
    }
}

/// 키 있는 곡·없는 곡·옛 표기 곡·추가한 곡이 든 시트
@MainActor
private final class SheetKeyHarness {
    let store = LibraryStore(saveTagDrafts: { _ in })
    let coordinator: SheetCoordinator
    let table = SheetTableView()
    let window: NSWindow
    let keyColumn: Int

    init() {
        _ = NSApplication.shared
        coordinator = SheetCoordinator(store: store)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        table.coordinator = coordinator
        coordinator.table = table
        table.delegate = coordinator
        table.dataSource = coordinator
        table.rowHeight = 22
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for spec in SheetColumn.all {
            let column = NSTableColumn(identifier: .init(spec.id))
            column.width = spec.width
            table.addTableColumn(column)
        }
        keyColumn = SheetColumn.all.firstIndex { $0.key == .musicalKey }!
        let scroll = NSScrollView()
        scroll.documentView = table
        window.contentView = scroll
        coordinator.update(rows: [MusicalKeyEditingTests.row("1"), MusicalKeyEditingTests.row("2", key: "5A"),
                                  MusicalKeyEditingTests.row("3", key: "Em"), MusicalKeyEditingTests.row("4", staged: true),
                                  MusicalKeyEditingTests.row("5")], revision: 0)
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
