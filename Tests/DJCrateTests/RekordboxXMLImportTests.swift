@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// 파일 메뉴의 "rekordbox XML 가져오기…"(#72): XML을 메인 스레드 밖에서 읽어 차이를 보이고, 고른 차이를 초안으로만 만든다.
/// 합성 사본과 임시 초안 폴더만 쓴다.
@Suite("rekordbox XML 가져오기 화면 흐름")
@MainActor
struct RekordboxXMLImportTests {
    func library() throws -> RekordboxFixture { try LibraryXMLExportTests().library() }

    func loadedStore(_ fixture: RekordboxFixture) async -> LibraryStore {
        let store = LibraryStore(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in })
        await store.load(snapshot: fixture.database)
        return store
    }

    /// 사본을 내보낸 XML을 고쳐 파일로 둔다: 제목·핫큐 A를 바꾸고 새 재생 목록을 더한다.
    func changedXML(_ fixture: RekordboxFixture) throws -> URL {
        let collection = try RekordboxLibraryXML.load(snapshot: fixture.database, shareRoot: fixture.shareRoot)
        let xml = RekordboxLibraryXML.document(collection)
            .replacingOccurrences(of: #"Name="합성 곡 A""#, with: #"Name="가져온 제목""#)
            .replacingOccurrences(of: #"Start="20.000" Num="0""#, with: #"Start="24.000" Num="0""#)
            .replacingOccurrences(of: #"<NODE Name="합성 목록""#, with: #"<NODE Name="가져온 목록""#)
        let url = fixture.root.appending(path: "import.xml")
        try Data(xml.utf8).write(to: url)
        return url
    }

    @Test func 메뉴는_파일_메뉴에_있고_불러온_라이브러리에서만_켜진다() async throws {
        #expect(LibraryMenuAction.importRekordboxXML.title == "rekordbox XML 가져오기…")
        #expect(LibraryMenuAction.fileActions.contains(.importRekordboxXML))
        let empty = LibraryStore(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in })
        #expect(!LibraryMenuAction.importRekordboxXML.isEnabled(in: empty))
        let store = await loadedStore(try library())
        #expect(LibraryMenuAction.importRekordboxXML.isEnabled(in: store))
        store.isReadingXMLImport = true
        #expect(!LibraryMenuAction.importRekordboxXML.isEnabled(in: store))
        #expect(LibraryMenuAction.importRekordboxXML.disabledReason(in: store)?.contains("끝난 뒤") == true)
    }

    @Test func 읽으면_차이_미리_보기를_연다() async throws {
        let fixture = try library()
        let store = await loadedStore(fixture)
        store.importRekordboxXML(from: try changedXML(fixture), shareRoot: fixture.shareRoot)
        #expect(store.isReadingXMLImport, "시작하자마자 읽는 중이 되고 메인 스레드를 막지 않는다")
        await store.xmlImportTask?.value
        #expect(!store.isReadingXMLImport)
        let preview = try #require(store.xmlImportPreview)
        #expect(preview.fileName == "import.xml")
        #expect(preview.diff.counts.cueTracks == 1 && preview.diff.counts.tagTracks == 1 && preview.diff.counts.missingPlaylists == 1)
        #expect(preview.diff.matching.matched == 1)
    }

    @Test func 고른_차이만_초안으로_만들고_rekordbox_사본은_그대로다() async throws {
        let fixture = try library()
        let store = await loadedStore(fixture)
        let home = fixture.root.appending(path: "home")
        let before = try Data(contentsOf: fixture.database)
        store.importRekordboxXML(from: try changedXML(fixture), shareRoot: fixture.shareRoot)
        await store.xmlImportTask?.value
        let preview = try #require(store.xmlImportPreview)
        var selection = XMLImportDrafts.Selection.all
        selection.kinds = [.tag, .playlist]
        let result = await store.makeXMLImportDrafts(preview, selection: selection, home: home)
        #expect(result.tags == 1 && result.cues == 0 && result.playlists == 1)
        #expect(store.tagDrafts["uuid-101"]?.fields.title == "가져온 제목", "만든 태그 초안을 바로 다시 읽는다")
        #expect(store.playlistDraft.project(onto: store.rekordboxPlaylists).layout.children(of: PlaylistLayout.root)
            .contains { $0.name == "가져온 목록" && $0.trackIDs == ["101"] })
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "cue-drafts/uuid-101.json").path))
        #expect(try Data(contentsOf: fixture.database) == before)
    }

    @Test func 메모리의_초안이_있는_곡은_덮지_않는다() async throws {
        let fixture = try library()
        let store = await loadedStore(fixture)
        let row = try #require(store.rows.first { $0.track.id == "101" })
        var draft = TagDraft(track: row.track)
        draft.fields.comment = "편집 중"
        store.tagDrafts[row.track.uuid] = draft
        store.importRekordboxXML(from: try changedXML(fixture), shareRoot: fixture.shareRoot)
        await store.xmlImportTask?.value
        let preview = try #require(store.xmlImportPreview)
        let result = await store.makeXMLImportDrafts(preview, selection: XMLImportDrafts.Selection(kinds: [.tag]),
                                                     home: fixture.root.appending(path: "home"))
        #expect(result.tags == 0 && result.skipped.count == 1)
        #expect(store.tagDrafts[row.track.uuid]?.fields.comment == "편집 중")
    }

    @Test func rekordbox_XML이_아니면_이유를_알리고_미리_보기를_열지_않는다() async throws {
        let fixture = try library()
        let store = await loadedStore(fixture)
        let bad = fixture.root.appending(path: "bad.xml")
        try Data("<plist/>".utf8).write(to: bad)
        store.importRekordboxXML(from: bad, shareRoot: fixture.shareRoot)
        await store.xmlImportTask?.value
        #expect(store.xmlImportPreview == nil && !store.isReadingXMLImport)
        #expect(store.stagingMessage?.kind == .failure && store.stagingMessage?.text.contains("DJ_PLAYLISTS") == true)
    }
}
