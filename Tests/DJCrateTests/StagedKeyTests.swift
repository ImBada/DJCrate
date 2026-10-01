@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import Testing

/// 추가한 곡의 키(#124): 파일 태그에 키가 있으면 그것, 없으면 조성 추정. 목록 키 칸에 보이고 staged.json에 남는다.
@MainActor
@Suite("추가한 곡 — 키")
struct StagedKeyTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "djc-staged-key-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func store(saved: @escaping ([StagedTrack]) -> Void = { _ in }) -> LibraryStore {
        LibraryStore(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in },
                     mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { saved($0) })
    }

    @Test func 파일_태그의_키를_읽어_Camelot으로_둔다() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let tagged = try AudioFixture.mp3(try TestResources.url("mp3-notag-cbr.mp3"),
                                          textFrames: [("TIT2", "태그 키"), ("TKEY", "Fm")], in: directory, name: "tagged.mp3")
        let track = try await StagedTrack.make(fileAt: tagged, addedOn: "2026-09-28")
        #expect(track.title == "태그 키")
        #expect(track.key == "4A" && track.keySource == .tag && !track.needsKey && !track.keyEstimated)
        // 태그에 키가 없으면 비워 두고 백그라운드에서 추정한다.
        let plain = try await StagedTrack.make(fileAt: try TestResources.url("mp3-notag-cbr.mp3"), addedOn: "2026-09-28")
        #expect(plain.key == nil && plain.needsKey)
    }

    @Test func 태그가_없으면_합성_음원의_조성을_추정한다() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let minor = try ChordFixture.wav(ChordFixture.aMinor, seconds: 30, in: directory, name: "a-minor.wav")
        let found = try #require(await LibraryStore.stagedKey(fileAt: minor, grid: nil, offset: 0, duration: 30, cacheKey: nil))
        #expect(found.key == "8A" && found.source == .estimate)
        let major = try ChordFixture.wav(ChordFixture.dMajor, seconds: 30, in: directory, name: "d-major.wav")
        #expect(await LibraryStore.stagedKey(fileAt: major, grid: nil, offset: 0, duration: 30, cacheKey: nil)?.key == "10B")
        // 태그가 있으면 추정하지 않는다.
        let tagged = try AudioFixture.mp3(try TestResources.url("mp3-notag-cbr.mp3"), textFrames: [("TKEY", "C#m")],
                                          in: directory, name: "tagged.mp3")
        let fromTag = await LibraryStore.stagedKey(fileAt: tagged, grid: nil, offset: 0, duration: 1, cacheKey: nil)
        #expect(fromTag?.key == "12A" && fromTag?.source == .tag)
        // 읽을 수 없는 파일은 표시하지 않고 다음에 다시 본다.
        #expect(await LibraryStore.stagedKey(fileAt: directory.appending(path: "없음.wav"), grid: nil, offset: 0,
                                              duration: 1, cacheKey: nil) == nil)
    }

    @Test func 찾은_키를_목록_행과_추가_목록_파일에_남긴다() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var saved: [[StagedTrack]] = []
        let store = store { saved.append($0) }
        let staged = StagedTrack(uuid: "s1", path: "/fixtures/a.wav", title: "합성 곡", duration: 30, addedOn: "2026-09-28")
        store.staged = [staged]
        store.rebuildStagedRows()
        #expect(store.stagedRows.first?.keyName == "" && store.stagedRows.first?.keyEstimated == false)

        store.setStagedKey(uuid: "s1", key: "8A", source: .estimate)
        let row = try #require(store.stagedRows.first)
        #expect(row.keyName == "8A" && row.keyEstimated)
        #expect(store.rowsByUUID["s1"]?.keyName == "8A")
        #expect(saved.last?.first?.key == "8A" && saved.last?.first?.keySource == .estimate)

        // 태그 키는 추정 표시를 하지 않는다.
        store.setStagedKey(uuid: "s1", key: "4A", source: .tag)
        #expect(store.stagedRows.first?.keyName == "4A" && store.stagedRows.first?.keyEstimated == false)
        // 이미 찾은 곡은 다시 읽어도(다음 실행) 추정하지 않는다.
        #expect(saved.last?.first?.needsKey == false)
    }

    @Test func 추정_키_칸은_기울임_툴팁_VoiceOver로도_알린다() {
        func spoken(_ cell: TrackTextCell) -> String? {
            let value = cell.label.accessibilityValue()
            return value
        }
        let cell = TrackTextCell()
        cell.set("8A", color: UIColors.suggestion.nsColor, estimated: true)
        #expect(NSFontManager.shared.traits(of: cell.label.font!).contains(.italicFontMask))
        #expect(cell.toolTip?.isEmpty == false)
        #expect(spoken(cell) == "8A, 추정")
        // 같은 칸을 다른 줄에 다시 쓰면(스크롤) 추정 표시가 남지 않는다.
        cell.set("4A", color: .secondaryLabelColor)
        #expect(!NSFontManager.shared.traits(of: cell.label.font!).contains(.italicFontMask))
        #expect(cell.toolTip == nil && spoken(cell) == "4A")
    }
}
