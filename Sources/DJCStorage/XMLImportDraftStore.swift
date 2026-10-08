import DJCDomain
import Foundation
import RekordboxKit

/// rekordbox XML 가져오기(#72)의 초안 저장. 스냅샷 사본·분석 파일·기존 초안을 읽어 계획(`XMLImportDrafts.plan`)을 세우고,
/// 초안 폴더에만 쓴다. rekordbox 라이브러리에는 쓰지 않는다.
public enum XMLImportDraftStore {
    /// 초안 자리. 앱·CLI는 `DJCPaths.userData`(DJC_HOME), 시험은 임시 폴더를 준다.
    public struct Folders: Sendable, Equatable {
        public var cues: URL
        public var grids: URL
        public var tags: URL
        public var playlists: URL

        public init(home: URL) {
            cues = home.appending(path: "cue-drafts")
            grids = home.appending(path: "grid-drafts")
            tags = home.appending(path: "tag-drafts")
            playlists = home.appending(path: "playlist-drafts.json")
        }

        public static var user: Folders { Folders(home: DJCPaths.userData) }

        func directory(_ kind: XMLImportDrafts.Kind) -> URL? {
            switch kind {
            case .cue: cues
            case .grid: grids
            case .tag: tags
            case .playlist: nil
            }
        }

        /// 곡의 초안 파일이 있는지(읽지 못하는 파일도 있는 것으로 본다: 덮지 않는다)
        func hasDraft(_ kind: XMLImportDrafts.Kind, uuid: String) -> Bool {
            guard let directory = directory(kind) else { return false }
            return FileManager.default.fileExists(atPath: directory.appending(path: "\(uuid).json").path)
        }
    }

    public struct Result: Sendable, Equatable {
        public var plan: XMLImportDrafts.Plan
        /// 계획을 세운 뒤 저장하기 전에 생긴 초안이 있어 건너뛴 것
        public var raced: [XMLImportDrafts.Note] = []
    }

    /// 사본·분석 파일·기존 초안을 읽어 계획을 세운다(쓰지 않는다).
    /// - Parameters:
    ///   - shareRoot: 분석 파일 뿌리. nil이면 그리드 초안을 만들지 않는다.
    ///   - playlistDraft: 기존 재생 목록 초안. nil이면 파일에서 읽는다(앱은 메모리 초안을 준다).
    ///   - existing: 파일 말고도 이미 있는 것으로 볼 초안(곡 UUID, 앱의 저장 전 입력)
    public static func plan(diff: XMLLibraryDiff.Result, selection: XMLImportDrafts.Selection, snapshot: URL, shareRoot: URL?,
                            folders: Folders, playlistDraft: PlaylistDraft? = nil,
                            existing extra: [XMLImportDrafts.Kind: Set<String>] = [:]) throws -> XMLImportDrafts.Plan {
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        let wanted = Set(diff.tracks.map(\.libraryKey)).filter { key in
            XMLImportDrafts.Kind.allCases.contains { selection.includes($0, track: key) }
        }
        let listed = Set(library.playlists.filter { !$0.isFolder }.flatMap(\.trackIDs))
        var sources: [String: XMLImportDrafts.TrackSource] = [:]
        for track in library.tracks where wanted.contains(track.id) {
            let grid = selection.kinds.contains(.grid)
                ? shareRoot.flatMap { RekordboxShare.analysisURL(track.analysisDataPath, root: $0) }.flatMap { try? BeatGrid.load(anlz: $0) }
                : nil
            let existing = Set(XMLImportDrafts.Kind.allCases.filter {
                folders.hasDraft($0, uuid: track.uuid) || extra[$0]?.contains(track.uuid) == true
            })
            sources[track.id] = XMLImportDrafts.TrackSource(track: track, cues: library.cues(for: track), grid: grid,
                                                            inPlaylist: listed.contains(track.id), existing: existing)
        }
        return XMLImportDrafts.plan(diff: diff, selection: selection, sources: sources,
                                    layout: PlaylistLayout(rekordbox: library.playlists),
                                    playlistDraft: playlistDraft ?? PlaylistDraftStore.load(url: folders.playlists))
    }

    /// 계획의 초안을 저장한다. 계획을 세운 뒤 그 사이에 생긴 초안(곡별 파일, 바뀐 재생 목록 초안)은 덮지 않고 `raced`로 돌려준다.
    @discardableResult
    public static func save(_ plan: XMLImportDrafts.Plan, folders: Folders, playlistBase: PlaylistDraft) throws -> Result {
        var result = Result(plan: plan)
        func raced(_ kind: XMLImportDrafts.Kind, _ uuid: String) -> Bool {
            guard folders.hasDraft(kind, uuid: uuid) else { return false }
            result.raced.append(XMLImportDrafts.Note(kind: kind, libraryKey: nil, subject: uuid, reason: XMLImportDrafts.existingReason(kind)))
            return true
        }
        for draft in plan.cueDrafts where !raced(.cue, draft.trackUUID) { try CueDraftStore.save(draft, directory: folders.cues) }
        for draft in plan.gridDrafts where !raced(.grid, draft.trackUUID) { try GridDraftStore.save(draft, directory: folders.grids) }
        for draft in plan.tagDrafts where !raced(.tag, draft.trackUUID) { try TagDraftStore.save(draft, directory: folders.tags) }
        if let draft = plan.playlistDraft {
            if PlaylistDraftStore.load(url: folders.playlists) == playlistBase {
                try PlaylistDraftStore.save(draft, url: folders.playlists)
            } else {
                result.raced.append(XMLImportDrafts.Note(kind: .playlist, libraryKey: nil, subject: "",
                                                         reason: XMLImportDrafts.existingReason(.playlist)))
            }
        }
        return result
    }
}
