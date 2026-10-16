import Foundation

/// LINK로 CDJ에 내어 줄 라이브러리(#273). rekordbox 컬렉션의 곡과 재생 목록을 Link Export가 쓰는 꼴로 옮긴다.
/// 곡 번호는 1부터 차례로 새로 매긴다(rekordbox 곡 ID가 CDJ 번호 범위에 맞는다는 보장이 없다). 싣기는 이 번호로 한다.
public struct LinkLibrary: Equatable, Sendable {
    public struct Track: Equatable, Sendable {
        /// CDJ가 곡을 가리키는 번호(1부터)
        public var id: UInt32
        /// rekordbox 곡 ID(`djmdContent.ID`)
        public var contentID: String
        public var title: String
        public var artist: String
        public var album: String
        public var genre: String
        public var key: String
        public var bpmX100: UInt32
        public var lengthSeconds: UInt32
        /// 음원 절대 경로
        public var path: String
        /// share 뿌리 아래 분석 파일(.DAT) 경로. 없으면 빈 문자열
        public var analysisPath: String
        public var fileType: UInt8
        public var bitrateKbps: UInt32
        public var rating: UInt8
        public var comment: String
        public var cues: [Cue]
    }

    /// 메모리 큐·핫 큐. 끝이 시작보다 뒤면 루프다
    public struct Cue: Equatable, Sendable {
        public var positionMs: UInt32
        public var outMs: UInt32
        /// 핫 큐 글자(A~H). nil이면 메모리 큐
        public var hotCue: Character?
        public var colour: UInt8

        public init(positionMs: UInt32, outMs: UInt32, hotCue: Character?, colour: UInt8) {
            self.positionMs = positionMs
            self.outMs = outMs
            self.hotCue = hotCue
            self.colour = colour
        }
    }

    /// 재생 목록·폴더. 부모는 `playlists` 안의 순번(nil이면 맨 위)
    public struct Playlist: Equatable, Sendable {
        public var name: String
        public var parent: Int?
        public var isFolder: Bool
        public var trackIDs: [UInt32]

        public init(name: String, parent: Int? = nil, isFolder: Bool, trackIDs: [UInt32]) {
            self.name = name
            self.parent = parent
            self.isFolder = isFolder
            self.trackIDs = trackIDs
        }
    }

    public private(set) var tracks: [Track] = []
    public private(set) var playlists: [Playlist] = []
    private var idsByContent: [String: UInt32] = [:]

    public init() {}

    /// 그 rekordbox 곡의 CDJ 번호. 내어 주지 않는 곡이면 nil
    public func linkID(of contentID: String) -> UInt32? { idsByContent[contentID] }

    /// 그 CDJ 번호로 내어 준 곡의 제목. 번호는 1부터 차례로 매기므로 자리로 찾는다
    public func title(ofLinkID id: UInt32) -> String? {
        let index = Int(id) - 1
        guard tracks.indices.contains(index), tracks[index].id == id else { return nil }
        return tracks[index].title
    }

    /// rekordbox 컬렉션의 곡과 재생 목록으로 만든다. 내어 줄 수 없는 곡(`isShareable`)은 빼고, 재생 목록에서도 뺀다.
    /// 스마트 재생 목록은 규칙을 옮기지 않으므로 뺀다.
    public static func build(rows: [TrackRow], playlists layout: PlaylistLayout) -> LinkLibrary {
        var library = LinkLibrary()
        for row in rows where isShareable(row) && library.idsByContent[row.track.id] == nil {
            guard let fileType = fileType(ofExtension: row.track.fileExtension) else { continue }
            let id = UInt32(library.tracks.count + 1)
            library.idsByContent[row.track.id] = id
            library.tracks.append(track(row, id: id, fileType: fileType))
        }
        library.addPlaylists(of: PlaylistLayout.root, parent: nil, layout: layout)
        return library
    }

    /// LINK로 내어 줄 수 있는 곡: rekordbox 컬렉션에 들어 있고(추가 대기·USB 곡이 아님), 지우지 않았고, 이 Mac에 파일이 있는 곡
    public static func isShareable(_ row: TrackRow) -> Bool {
        !row.isStaged && !row.isUsb && !row.track.isDeleted && !row.track.isStreaming && !row.fileMissing
            && fileType(ofExtension: row.track.fileExtension) != nil
    }

    /// rekordbox 파일 형식 번호(`djmdContent.FileType`). CDJ가 이 값으로 디코더를 고른다.
    /// 실기로 확인한 것은 MP3(1)·WAV(11)뿐이다(DJLinkKit docs/LINK-EXPORT-HARDWARE.md, CDJ-2000nexus).
    public static func fileType(ofExtension ext: String) -> UInt8? {
        switch ext.lowercased() {
        case "mp3": 1
        case "m4a", "aac", "mp4": 4
        case "flac": 5
        case "wav": 11
        case "aif", "aiff": 12
        default: nil
        }
    }

    private static func track(_ row: TrackRow, id: UInt32, fileType: UInt8) -> Track {
        let track = row.track
        return Track(id: id, contentID: track.id, title: track.title, artist: track.artist ?? "", album: track.album ?? "",
                     genre: track.genre ?? "", key: track.key ?? "", bpmX100: UInt32(max(0, ((track.bpm ?? 0) * 100).rounded())),
                     lengthSeconds: UInt32(max(0, track.lengthSeconds)), path: track.folderPath,
                     analysisPath: track.analysisDataPath ?? "", fileType: fileType,
                     bitrateKbps: UInt32(max(0, track.bitrateKbps ?? 0)), rating: UInt8(clamping: track.rating),
                     comment: track.comment, cues: row.cues.compactMap(cue))
    }

    /// 메모리 큐와 A~H 핫 큐만 옮긴다(뜻을 모르는 종류는 뺀다)
    private static func cue(_ cue: DJCDomain.Cue) -> Cue? {
        guard cue.inMsec >= 0, cue.isMemoryCue || cue.hotCueSlot != nil else { return nil }
        return Cue(positionMs: UInt32(cue.inMsec), outMs: cue.isLoop ? UInt32(cue.outMsec) : 0, hotCue: cue.hotCueSlot,
                   colour: UInt8(clamping: cue.colorTableIndex ?? 0))
    }

    private mutating func addPlaylists(of parentID: String, parent: Int?, layout: PlaylistLayout) {
        for item in layout.children(of: parentID) where !item.isSmart {
            let index = playlists.count
            playlists.append(Playlist(name: item.name, parent: parent, isFolder: item.isFolder,
                                      trackIDs: item.isFolder ? [] : item.entries.compactMap { idsByContent[$0.contentID] }))
            if item.isFolder { addPlaylists(of: item.id, parent: index, layout: layout) }
        }
    }
}
