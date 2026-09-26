import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import Testing

@Suite("곡 편집 결과를 곡 넣기 흐름으로")
struct EditStagingTests {
    let grid = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]

    func source() -> Track {
        Track(id: "101", uuid: "src-uuid", title: "원곡", artist: "아티스트", album: "앨범", albumArtist: nil, genre: "House",
              composer: nil, releaseYear: 2024, trackNumber: 3, key: nil, bpm: 120, lengthSeconds: 100,
              folderPath: "/음원/원곡.mp3", comment: "코멘트", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
    }

    @Test func 추가한_곡과_그리드·큐·태그_초안을_만든다() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-edit-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let output = try AudioFixture.wav(seconds: 132, in: home, name: "원곡 (Edit).wav")
        let edit = try TrackEdit(grid: grid, sourceDuration: 100.5, bars: BarRange.list("1-16,1-16,17-50"))
        let carried = edit.carry([EditableCue(kind: .hot(0), time: 32.5, name: "드롭"), EditableCue(kind: .memory, time: 0.5)])

        let staged = try await EditStaging.stage(fileAt: output, edit: edit, cues: carried.placed, source: source(), home: home)
        #expect(staged.path == output.path.precomposedStringWithCanonicalMapping && staged.bpm == 120 && staged.gridConfident == true)
        #expect(StagingStore.load(url: home.appending(path: "staged.json")).map(\.uuid) == [staged.uuid])

        let gridDraft = try #require(GridDraftStore.load(trackUUID: staged.uuid, directory: home.appending(path: "grid-drafts")))
        #expect(gridDraft.base.isEmpty && gridDraft.segments == [edit.outputGrid])
        let cueDraft = try #require(CueDraftStore.load(trackUUID: staged.uuid, directory: home.appending(path: "cue-drafts")))
        #expect(cueDraft.base.isEmpty && cueDraft.cues.map(\.time) == [0, 64] && cueDraft.cues.map(\.kind) == [.memory, .hot(0)])
        // 곡 정보는 원곡에서, 제목은 편집본 표시를 붙여 태그 초안으로(곡 넣기·XML 내보내기가 이 값을 쓴다)
        let tags = try #require(TagDraftStore.load(trackUUID: staged.uuid, directory: home.appending(path: "tag-drafts")))
        #expect(tags.fields.title == "원곡 (Edit)" && tags.fields.artist == "아티스트" && tags.fields.album == "앨범")
        #expect(tags.fields.genre == "House" && tags.fields.year == "2024" && tags.fields.comment == "코멘트")

        // 같은 파일을 두 번 넣지 않는다
        await #expect(throws: DJCError.self) {
            _ = try await EditStaging.stage(fileAt: output, edit: edit, cues: [], source: self.source(), home: home)
        }
        #expect(StagingStore.load(url: home.appending(path: "staged.json")).count == 1)
    }
}
