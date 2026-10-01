import DJCDomain
import Foundation

/// 곡 편집 결과(렌더한 파일)를 곡 넣기 흐름에 잇는다.
///
/// "추가한 곡"에 넣고, 그리드는 추정하지 않고 편집으로 변환한 그리드를, 큐는 출력 위치로 옮긴 큐를 초안으로 둔다.
/// 곡 정보는 원곡 값을 태그 초안으로 둔다(렌더한 WAV에는 태그가 없다). 이후 rekordbox에 넣기·XML 내보내기는 기존 흐름 그대로다.
/// 출력은 PCM이라 인코더 지연이 없어 초안의 rekordbox 시간축 = 출력 파일 시간축이다.
public enum EditStaging {
    public static func stage(fileAt url: URL, edit: TrackEdit, cues: [EditableCue], source: Track?, title: String? = nil,
                             home: URL = DJCPaths.userData, now: Date = .now) async throws -> StagedTrack {
        let list = home.appending(path: "staged.json")
        var tracks = StagingStore.load(url: list)
        let path = url.path.precomposedStringWithCanonicalMapping
        guard !tracks.contains(where: { $0.path.precomposedStringWithCanonicalMapping == path }) else {
            throw DJCError.editRefused(String(ui: "\(url.lastPathComponent)은 이미 추가한 곡입니다. 추가 목록에서 확인하세요"))
        }
        var staged = try await StagedTrack.make(fileAt: url, addedOn: String(ISO8601DateFormatter().string(from: now).prefix(10)))
        staged.path = path
        staged.bpm = edit.outputGrid.bpm
        staged.gridConfident = true

        var cueDraft = CueDraft(trackUUID: staged.uuid, rekordboxCues: [])
        for cue in cues { cueDraft.place(cue) }
        var tags = TagDraft(track: staged.track)
        if let source { tags.fields = TagFields(track: source) }
        tags.fields.title = title ?? source.map { "\($0.title) (Edit)" } ?? staged.title

        // 중간에 실패하면 이 작업이 만든 초안만 되돌린다(전에 있던 파일은 그 내용으로 되살린다, #174).
        var touched = Touched()
        do {
            let grids = home.appending(path: "grid-drafts"), cueDirectory = home.appending(path: "cue-drafts")
            let tagDirectory = home.appending(path: "tag-drafts")
            try touched.remember(grids.appending(path: "\(staged.uuid).json"))
            try GridDraftStore.save(GridDraft(trackUUID: staged.uuid, base: [], segments: [edit.outputGrid]), directory: grids)
            try touched.remember(cueDirectory.appending(path: "\(staged.uuid).json"))
            try CueDraftStore.save(cueDraft, directory: cueDirectory)
            try touched.remember(tagDirectory.appending(path: "\(staged.uuid).json"))
            try TagDraftStore.save(tags, directory: tagDirectory)

            tracks.append(staged)
            try StagingStore.save(tracks, url: list)
        } catch {
            touched.rollBack()
            throw error
        }
        return staged
    }

    /// 넣기가 바꾼 초안 파일과 그 전 내용(nil이면 없던 파일)
    struct Touched {
        private var files: [(url: URL, previous: Data?)] = []

        /// 바꾸기 전 내용을 적어 둔다. 있던 파일을 읽지 못하면 되돌릴 수 없으므로 바꾸지 않는다.
        mutating func remember(_ url: URL) throws {
            let previous = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            files.append((url, previous))
        }

        func rollBack() {
            for file in files.reversed() {
                if let previous = file.previous { try? previous.write(to: file.url, options: .atomic) }
                else { try? FileManager.default.removeItem(at: file.url) }
            }
        }
    }
}
