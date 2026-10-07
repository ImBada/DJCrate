@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import AudioToolbox
import Synchronization
import RekordboxKit
import Testing

@MainActor
@Suite("오래된 완료와 현재 명령 실패 안내")
struct AsyncFailureGuidanceTests {
    private func replacing(_ row: TrackRow, id: String? = nil, uuid: String? = nil, title: String? = nil) -> TrackRow {
        let t = row.track
        return TrackRow(track: Track(id: id ?? t.id, uuid: uuid ?? t.uuid, title: title ?? t.title,
                                    artist: t.artist, album: t.album, albumArtist: t.albumArtist, genre: t.genre,
                                    composer: t.composer, releaseYear: t.releaseYear, trackNumber: t.trackNumber,
                                    key: t.key, bpm: t.bpm, lengthSeconds: t.lengthSeconds, folderPath: t.folderPath,
                                    comment: t.comment, importedOn: t.importedOn, analysisDataPath: t.analysisDataPath,
                                    imagePath: t.imagePath, isDeleted: t.isDeleted), cues: row.cues, playCount: row.playCount)
    }
    private func store(_ fixture: RekordboxFixture) -> LibraryStore {
        let store = LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.async.\(UUID())")!, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                                 backupDirectory: fixture.backups, playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in },
                                 playlistImportURL: nil, stagingSaver: { _ in }, draftHome: fixture.root.appending(path: "drafts"))
        store.rekordboxDatabase = fixture.database
        store.rekordboxShareRoot = fixture.shareRoot
        return store
    }

    @Test func 사본_열기_실패는_생성_실패로_알리지_않고_이전_목록을_보존한다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = store(fixture), args = ["test", "--db", fixture.database.path]
        await store.load(snapshot: fixture.database, arguments: args, environment: [:])
        let before = store.rows
        await store.load(snapshot: fixture.root.appending(path: "missing.db"), quiet: true, arguments: args, environment: [:])
        #expect(store.rows == before)
        #expect(store.lastError?.contains("열지 못") == true)
        #expect(store.lastError?.contains("이전 목록") == true)
        #expect(store.lastError?.contains("확인") == true)
        #expect(store.lastError?.contains("새로 뜨지") == false)
    }

    /// 목록 위 오류 줄은 닫을 수 있다(#230). 닫아도 오류 상태(`lastError`)는 남아 그 상태를 보는 흐름은 그대로이고, 새 오류가 오면 다시 보인다.
    @Test func 목록_위_오류_줄을_닫아도_상태는_남고_새_오류는_다시_보인다() throws {
        let fixture = try RekordboxFixture()
        let store = store(fixture)
        #expect(store.visibleLastError == nil)
        store.reportLibraryError("라이브러리를 열지 못했습니다")
        #expect(store.visibleLastError == "라이브러리를 열지 못했습니다")
        store.dismissLastError()
        #expect(store.visibleLastError == nil && store.lastError == "라이브러리를 열지 못했습니다")
        store.reportLibraryError("라이브러리를 열지 못했습니다")
        #expect(store.visibleLastError == "라이브러리를 열지 못했습니다")
        store.dismissLastError()
        store.reportLibraryError("다른 오류")
        #expect(store.visibleLastError == "다른 오류")
    }

    @Test func 삭제된_큐의_현재_명령은_다시_선택을_안내한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let before = h.deck.draft
        h.deck.rename(UUID(), "입력 보존")
        #expect(h.deck.draft == before)
        #expect(h.deck.toast?.text.contains("다시 선택") == true)
    }

    @Test func UUID가_다른_현재_초안은_고치지_않고_다시_불러오기를_안내한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let other = CueDraft(trackUUID: "other-track", rekordboxCues: [])
        h.deck.draft = other
        h.deck.addMemoryCue(at: 1)
        #expect(h.deck.draft == other)
        #expect(h.deck.toast?.text.contains("다시 불러") == true)
        h.deck.toast = nil
        h.deck.reloadExternalCueDraft(other)
        #expect(h.deck.toast == nil)
    }

    @Test func 재생_준비_전에는_지원_밖_형식으로_단정하지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.canPlay = false
        #expect(h.deck.playbackUnavailableReason?.contains("불러오기") == true)
        #expect(h.deck.playbackUnavailableReason?.contains("파일 형식") == false)
    }

    @Test(arguments: [true, false])
    func 재생_성공은_출력_준비_안내를_지우고_다른_명령_안내는_남긴다(_ preparing: Bool) async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let preparingMessage = try #require(AudioSourceState.preparing.unavailableReason)
        let message = preparing ? preparingMessage : DeckModel.audioUnavailableMessage
        h.deck.showToast(message)
        h.deck.startPlayback(from: 0)
        #expect(h.deck.isPlaying && h.audio.isPlaying)
        #expect(h.deck.toast == nil)

        h.deck.rename(UUID(), "큐 입력")
        let selectionMessage = try #require(h.deck.toast?.text)
        h.deck.startPlayback(from: 0)
        #expect(h.deck.toast?.text == selectionMessage)
    }

    @Test func XML_미리_보기는_변경_없는_선택도_이유와_함께_남긴다() throws {
        let fixture = try RekordboxFixture(), store = store(fixture)
        let row = ReflectionCoordinatorTests.row("unchanged")
        let plans = store.reflectionPlans(for: [row])
        #expect(plans.count == 1)
        #expect(plans.first?.isEligible == false)
        #expect(plans.first?.blockers.contains(where: { $0.contains("변경") }) == true)
    }

    @Test func 이전_스냅샷_생성_실패는_새로_읽은_목록에_경고하지_않는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = store(fixture)
        let gate = DispatchSemaphore(value: 0)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let old = Task {
            await store.takeSnapshot(snapshotDirectory: fixture.root, snapshotCopy: { _ in
                signal.yield(())
                gate.wait()
                throw FixtureFailure()
            }, arguments: ["test"], environment: ["DJC_REKORDBOX_DIR": fixture.root.path])
        }
        for await _ in started { break }
        await store.load(snapshot: fixture.database, arguments: ["test", "--db", fixture.database.path], environment: [:])
        gate.signal()
        await old.value
        #expect(store.lastError == nil)
        #expect(store.rows.count == 1)
        if case .loaded = store.phase { } else { Issue.record("이전 요청의 실패가 새 목록의 상태를 덮음") }
    }

    @Test(arguments: [true, false])
    func 같은_URL을_다시_읽어도_이전_복사의_완료와_실패는_버린다(_ fails: Bool) async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = store(fixture), database = fixture.database
        let args = ["test", "--db", database.path]
        await store.load(snapshot: database, arguments: args, environment: [:])
        let gate = DispatchSemaphore(value: 0)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let old = Task {
            await store.takeSnapshot(refreshITunes: false, snapshotDirectory: fixture.root, snapshotCopy: { _ in
                signal.yield(())
                gate.wait()
                if fails { throw FixtureFailure() }
                return database
            }, arguments: ["test"], environment: ["DJC_REKORDBOX_DIR": fixture.root.path])
        }
        for await _ in started { break }
        await store.load(snapshot: database, arguments: args, environment: [:])
        let before = store.rows, count = store.completedLoadCount
        gate.signal()
        await old.value
        #expect(store.completedLoadCount == count && store.rows == before)
        #expect(store.lastError == nil && store.lastReadFailure == nil)
        if case .loaded = store.phase { } else { Issue.record("이전 복사가 같은 URL의 새 읽기를 덮음") }
    }

    @Test func 이전_곡의_뷰_콜백은_새_곡의_초안과_알림을_건드리지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let before = h.deck.draft
        h.deck.rename(UUID(), "오래된 입력", expectedTrackUUID: "previous-track")
        h.deck.move(UUID(), to: 3, expectedTrackUUID: "previous-track")
        #expect(h.deck.draft == before)
        #expect(h.deck.toast == nil)
    }

    @Test func 같은_ID로_돌아와도_이전_UUID의_느린_완료를_버린다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let row = try #require(h.deck.row)
        let gate = DispatchSemaphore(value: 0), calls = Mutex(0)
        let (started, signal) = AsyncStream<Void>.makeStream()
        var storage = DeckStorage.memory(h.drafts)
        storage.loadCueDraft = { uuid in
            let count = calls.withLock { $0 += 1; return $0 }
            if uuid == row.track.uuid, count == 2 { signal.yield(()); gate.wait() }
            return CueDraft(trackUUID: uuid, rekordboxCues: [])
        }
        let deck = DeckModel(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)
        deck.load(row)
        await deck.loadTask?.value
        let changed = replacing(row, title: "새 메타데이터")
        deck.softReload(changed)
        let old = deck.softReloadTask
        for await _ in started { break }
        let other = replacing(row, id: "2", uuid: "other-track")
        deck.load(other)
        let returned = replacing(row, uuid: "new-uuid-with-same-id")
        deck.load(returned)
        await deck.loadTask?.value
        let before = deck.draft
        gate.signal()
        await old?.value
        #expect(deck.draft == before)
        #expect(deck.draft?.trackUUID == returned.track.uuid)
        #expect(deck.toast == nil)
    }

    @Test func 권한_디코딩_지원_밖_오류를_타입으로_나눈다() {
        #expect(AudioSourceFailure.state(for: CocoaError(.fileReadNoPermission)) == .readFailed)
        #expect(AudioSourceFailure.state(for: NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFileInvalidFileError))) == .decodeFailed)
        #expect(AudioSourceFailure.state(for: NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFileUnsupportedDataFormatError))) == .unsupportedFormat)
        #expect(AudioSourceFailure.state(for: NSError(domain: "unknown", code: Int(kAudioFileUnsupportedDataFormatError))) == .readFailed)
    }

    @Test func 사본_내용_실패는_열기_실패와_구별하고_기존_태그를_보존한다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = store(fixture), args = ["test", "--db", fixture.database.path]
        await store.load(snapshot: fixture.database, arguments: args, environment: [:])
        let before = store.rows
        try fixture.execute("DROP TABLE djmdCue")
        await store.load(snapshot: fixture.database, quiet: true, arguments: args, environment: [:])
        #expect(store.lastReadFailure?.stage == .contents)
        #expect(store.lastError?.contains("내용을 읽지") == true)
        #expect(store.rows == before)
    }

    @Test func 취소한_현재_읽기는_로딩_상태와_경고를_남기지_않는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = store(fixture), args = ["test", "--db", fixture.database.path]
        await store.load(snapshot: fixture.database, arguments: args, environment: [:])
        let before = store.rows, count = store.completedLoadCount
        let gate = DispatchSemaphore(value: 0)
        let database = fixture.database
        let (started, signal) = AsyncStream<Void>.makeStream()
        let read = Task {
            await store.takeSnapshot(refreshITunes: false, snapshotDirectory: fixture.root, snapshotCopy: { _ in
                signal.yield(())
                gate.wait()
                return database
            }, arguments: ["test"], environment: ["DJC_REKORDBOX_DIR": fixture.root.path])
        }
        for await _ in started { break }
        read.cancel()
        gate.signal()
        await read.value
        #expect(store.lastError == nil && store.completedLoadCount == count && store.rows == before)
        if case .loaded = store.phase { } else { Issue.record("취소한 읽기가 로딩 상태로 남음") }
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 미리_보기는_주입한_합성_라이브러리를_쓴다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec(id: "1", uuid: "async-preview-\(UUID())")
        try fixture.add(spec)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0")
        let store = store(fixture), args = ["test", "--db", fixture.database.path]
        await store.load(snapshot: fixture.database, arguments: args, environment: [:])
        let row = try #require(store.rows.first)
        var draft = TagDraft(track: row.track)
        draft.fields.comment = "합성 코멘트"
        try TagDraftStore.save(draft)
        defer { try? TagDraftStore.remove(trackUUID: spec.uuid, directory: TagDraftStore.directory) }
        store.tagDrafts[spec.uuid] = draft
        let preview = try await store.previewWrite(rows: [row], playlists: false)
        #expect(preview.report.tagWritten.count == 1)
        #expect(try RekordboxLibrary.load(snapshot: fixture.database).tracks.first?.comment == "")
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 제외_이유는_곡과_종류별로_보이고_XML의_지원_범위를_유지한다() throws {
        let fixture = try RekordboxFixture(), store = store(fixture)
        let row = ReflectionCoordinatorTests.row("exclusions-\(UUID())")
        let staged = replacing(row, id: "djc-synthetic")
        #expect(store.draftExclusionReasons(for: [staged]).first?.contains("추가한 곡") == true)
        #expect(store.draftExclusionReasons(for: [row]).first?.contains("변경이 없") == true)
        store.draftChanged(trackUUID: row.track.uuid, kind: .cue, exists: true)
        let missing = store.draftExclusionReasons(for: [row])
        #expect(missing.first?.contains(row.title) == true && missing.first?.contains("큐 쓰지") == true)
        #expect(missing.first?.contains("불러오지 못") == true)
        var cue = CueDraft(trackUUID: row.track.uuid, rekordboxCues: [])
        cue.cues.append(EditableCue(kind: .memory, time: 1))
        try CueDraftStore.save(cue)
        var tag = TagDraft(track: row.track)
        tag.fields.comment = "합성 태그"
        try TagDraftStore.save(tag)
        defer {
            try? CueDraftStore.remove(trackUUID: row.track.uuid, directory: CueDraftStore.directory)
            try? TagDraftStore.remove(trackUUID: row.track.uuid, directory: TagDraftStore.directory)
        }
        store.tagDrafts[row.track.uuid] = tag
        #expect(store.reflectionPlans(for: [row]).first?.isEligible == true)
        #expect(store.draftExclusionReasons(for: [row], xml: true).first?.contains("태그 쓰지") == true)
        #expect(store.draftExclusionReasons(for: [row], xml: true).first?.contains("큐·그리드만") == true)
        #expect(store.draftExclusionReasons(for: [row]).isEmpty)
    }

    /// 쓰기 확인 목록에는 막힌 초안만 남긴다. 고르기만 한 곡·추가한 곡·바꿀 것 없는 초안은 줄로 넣지 않는다(#211).
    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 쓰기_미리_보기의_제외_줄은_막힌_초안만_남긴다() throws {
        let fixture = try RekordboxFixture(), store = store(fixture)
        let row = ReflectionCoordinatorTests.row("blocked-only-\(UUID())")
        let staged = replacing(row, id: "djc-synthetic")
        #expect(store.draftExclusionReasons(for: [staged, row], blockedOnly: true).isEmpty)
        // 초안 파일을 읽지 못한 곡은 막힌 이유로 남긴다
        store.draftChanged(trackUUID: row.track.uuid, kind: .cue, exists: true)
        let missing = store.draftExclusionReasons(for: [row], blockedOnly: true)
        #expect(missing.count == 1 && missing.first?.contains("큐 쓰지") == true)
        // 읽을 수 있는 초안이면 줄이 없다
        var cue = CueDraft(trackUUID: row.track.uuid, rekordboxCues: [])
        cue.cues.append(EditableCue(kind: .memory, time: 1))
        try CueDraftStore.save(cue)
        defer { try? CueDraftStore.remove(trackUUID: row.track.uuid, directory: CueDraftStore.directory) }
        #expect(store.draftExclusionReasons(for: [row], blockedOnly: true).isEmpty)
    }

    @Test func 사라진_선택으로_실행한_현재_불러오기_명령만_다시_선택을_안내한다() throws {
        let fixture = try RekordboxFixture(), store = store(fixture)
        let row = ReflectionCoordinatorTests.row("selected")
        store.loadToDeck(row)
        store.selection = ["deleted"]
        store.loadSelectionToDeck()
        #expect(store.deckTrackID == row.track.id)
        #expect(store.stagingMessage?.text.contains("다시 선택") == true)
    }

    @Test func 파일_읽기_실패는_초안과_형식_판정을_섞지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let row = try #require(h.deck.row)
        h.deck.load(nil)
        h.audio.loadError = CocoaError(.fileReadNoPermission)
        h.deck.load(row)
        await h.deck.loadTask?.value
        #expect(h.deck.audioSourceState == .readFailed)
        #expect(h.deck.waveformError?.contains("접근 권한") == true)
        #expect(h.deck.draft?.trackUUID == row.track.uuid)
        #expect(!h.deck.canPlay)
    }

    @Test(arguments: [false, true])
    func Music_현재_완료만_적용하고_취소한_완료는_버린다(cancelled: Bool) async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = store(fixture)
        await store.load(snapshot: fixture.database, arguments: ["test", "--db", fixture.database.path], environment: [:])
        let before = store.iTunesSnapshot
        let gate = DispatchSemaphore(value: 0)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = try #require(store.startSimulatedITunesRefresh(quiet: false) {
            signal.yield(())
            gate.wait()
            return ITunesLibrarySnapshot(status: .unavailable)
        })
        for await _ in started { break }
        #expect(store.isLoading)
        if cancelled { task.cancel() }
        gate.signal()
        await task.value
        #expect(store.iTunesSnapshot == (cancelled ? before : ITunesLibrarySnapshot(status: .unavailable)))
        #expect(store.iTunesRefresh == nil)
        #expect(store.lastError == nil)
        if case .loaded = store.phase { } else { Issue.record("Music 취소가 로딩 상태를 남김") }
    }
}
