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

    @Test func 원곡의_키·평점·곡_색은_편집본의_고친_칸으로_담지_않는다() async throws {
        // 원곡 값은 편집본에서 사용자가 고른 값이 아니다. 고친 칸이면 곡을 넣을 때 쓰이고, 평점·곡 색은 확인한 범위(#65) 밖이면 막혀
        // 다른 칸까지 못 쓴다. 추가한 곡에서 고르면 넣을 때 함께 쓴다.
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-edit-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let output = try AudioFixture.wav(seconds: 132, in: home, name: "원곡 (Edit).wav")
        let edit = try TrackEdit(grid: grid, sourceDuration: 100.5, bars: BarRange.list("1-16,1-16,17-50"))
        let plain = source()
        let rated = Track(id: plain.id, uuid: plain.uuid, title: plain.title, artist: plain.artist, album: plain.album, albumArtist: nil,
                          genre: plain.genre, composer: nil, releaseYear: plain.releaseYear, trackNumber: plain.trackNumber, key: "8A", bpm: 120,
                          lengthSeconds: 100, folderPath: plain.folderPath, comment: plain.comment, importedOn: nil, analysisDataPath: nil,
                          imagePath: nil, isDeleted: false, rating: 4, colorID: "2")

        let staged = try await EditStaging.stage(fileAt: output, edit: edit, cues: [], source: rated, home: home)
        let tags = try #require(TagDraftStore.load(trackUUID: staged.uuid, directory: home.appending(path: "tag-drafts")))
        #expect(tags.fields.musicalKey == tags.base.musicalKey && tags.fields.rating == tags.base.rating && tags.fields.color == tags.base.color)
        #expect(Set(tags.changedKeys).isDisjoint(with: TagFields.Key.independent), "\(tags.changedKeys)")
        #expect(tags.fields.artist == "아티스트" && tags.fields.title == "원곡 (Edit)", "다른 칸은 원곡에서 가져온다")
    }

    @Test func 그리드_없이_넣으면_그리드_초안을_두지_않는다() async throws {
        // 원곡에 그리드가 없던 Flip: 추가한 곡에서 그리드를 추정하도록 그리드 초안·BPM을 비운다.
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-edit-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let output = try AudioFixture.wav(seconds: 3, in: home, name: "원곡 (Flip).wav")
        let staged = try await EditStaging.stage(fileAt: output, grid: [], cues: [EditableCue(kind: .memory, time: 1)], source: source(),
                                                 title: "원곡 (Flip)", home: home)
        #expect(staged.gridConfident != true)
        #expect(GridDraftStore.load(trackUUID: staged.uuid, directory: home.appending(path: "grid-drafts")) == nil)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "grid-drafts/\(staged.uuid).json").path))
        let cues = try #require(CueDraftStore.load(trackUUID: staged.uuid, directory: home.appending(path: "cue-drafts")))
        #expect(cues.cues.map(\.time) == [1])
        let tags = try #require(TagDraftStore.load(trackUUID: staged.uuid, directory: home.appending(path: "tag-drafts")))
        #expect(tags.fields.title == "원곡 (Flip)")
    }

    @Test func 여러_템포_구간을_그대로_그리드_초안으로_둔다() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-edit-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let output = try AudioFixture.wav(seconds: 3, in: home, name: "원곡 (Flip).wav")
        let segments = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1), GridSegment(start: 1.7, bpm: 120, firstBeatNumber: 3),
                        GridSegment(start: 2.4, bpm: 128, firstBeatNumber: 1)]
        let staged = try await EditStaging.stage(fileAt: output, grid: segments, cues: [], source: source(), title: nil, home: home)
        // BPM은 첫 구간, 제목을 주지 않으면 렌더한 파일 이름
        #expect(staged.bpm == 120 && staged.gridConfident == true)
        let draft = try #require(GridDraftStore.load(trackUUID: staged.uuid, directory: home.appending(path: "grid-drafts")))
        #expect(draft.base.isEmpty && draft.segments == segments)
        let tags = try #require(TagDraftStore.load(trackUUID: staged.uuid, directory: home.appending(path: "tag-drafts")))
        #expect(tags.fields.title == staged.title)
    }
}
