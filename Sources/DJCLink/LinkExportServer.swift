internal import DJLinkExport
internal import DJLinkExportModel
internal import DJLinkExportProtocol
internal import DJLinkKit

/// CDJ에 내어 줄 곡 하나(#273). DJLinkExport 타입을 밖에 내지 않으려고 쓰는 값만 옮긴다.
public struct LinkExportTrack: Equatable, Sendable {
    /// CDJ가 곡을 가리키는 번호(싣기 명령에 쓴다). 0은 쓰지 않는다
    public var id: UInt32
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    /// 조성 이름(예: "Am", "8A")
    public var key: String
    public var bpmX100: UInt32
    public var lengthSeconds: UInt32
    /// 음원의 절대 경로
    public var path: String
    /// 공유 뿌리(`shareRoot`) 아래 분석 파일(.DAT) 상대 경로. 없으면 빈 문자열(파형·그리드 없이 실린다)
    public var analysisPath: String
    /// rekordbox 파일 형식 번호(MP3 1, WAV 11). CDJ가 이 값으로 디코더를 고른다
    public var fileType: UInt8
    public var bitrate: UInt32
    public var rating: UInt8
    public var comment: String
    public var cues: [LinkExportCue]

    public init(id: UInt32, title: String, artist: String, album: String, genre: String, key: String, bpmX100: UInt32,
                lengthSeconds: UInt32, path: String, analysisPath: String, fileType: UInt8, bitrate: UInt32, rating: UInt8,
                comment: String, cues: [LinkExportCue]) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.key = key
        self.bpmX100 = bpmX100
        self.lengthSeconds = lengthSeconds
        self.path = path
        self.analysisPath = analysisPath
        self.fileType = fileType
        self.bitrate = bitrate
        self.rating = rating
        self.comment = comment
        self.cues = cues
    }
}

/// 메모리 큐·핫 큐 하나. 끝(`outMs`)이 시작보다 뒤면 루프다
public struct LinkExportCue: Equatable, Sendable {
    public var positionMs: UInt32
    public var outMs: UInt32
    /// 핫 큐 글자(A~H). nil이면 메모리 큐
    public var hotCue: Character?
    /// rekordbox 큐 색 번호(0은 색 없음)
    public var colour: UInt8

    public init(positionMs: UInt32, outMs: UInt32, hotCue: Character?, colour: UInt8) {
        self.positionMs = positionMs
        self.outMs = outMs
        self.hotCue = hotCue
        self.colour = colour
    }
}

/// 재생 목록·폴더 하나. 부모는 이 목록 배열 안의 순번이다(nil이면 맨 위)
public struct LinkExportPlaylist: Equatable, Sendable {
    public var name: String
    public var parent: Int?
    public var isFolder: Bool
    /// 곡 번호(`LinkExportTrack.id`) 순서대로, 겹쳐도 된다
    public var trackIDs: [UInt32]

    public init(name: String, parent: Int?, isFolder: Bool, trackIDs: [UInt32]) {
        self.name = name
        self.parent = parent
        self.isFolder = isFolder
        self.trackIDs = trackIDs
    }
}

/// 서버의 지금 상태
public struct LinkExportStatus: Equatable, Sendable {
    /// 참여한 장치 번호(rekordbox 범위: 유선 17·18, 무선 41). 참여 전이면 nil
    public var deviceNumber: Int?
    /// 참여하지 못한 이유(번호 충돌 등). 정상이면 nil
    public var down: String?
    /// 라이브러리를 마운트한 장치의 IPv4 주소
    public var mounted: Set<String>

    public init(deviceNumber: Int?, down: String?, mounted: Set<String>) {
        self.deviceNumber = deviceNumber
        self.down = down
        self.mounted = mounted
    }
}

public enum LinkExportError: Error, Equatable, Sendable {
    /// 그 장치로 가는 네트워크 인터페이스를 찾지 못함
    case noInterface(peer: String)
    /// 포트를 열지 못함(rekordbox·nfsd가 쓰는 중 등). DJLinkKit의 설명
    case bind(String)
    /// 아직 네트워크에 참여하지 못함
    case notJoined
    /// 그 플레이어가 네트워크에 없음
    case playerMissing(Int)
    /// 그 플레이어가 아직 라이브러리를 마운트하지 않음
    case notMounted(Int)
    case other(String)
}

/// DJCrate 라이브러리를 rekordbox처럼 CDJ에 내어 주는 서버(DJLinkKit `DJLinkExport`, #273).
/// 알림·상태를 보내고 dbserver·NFS를 연다. 음원·분석 파일은 읽기만 한다. 사용자가 LINK 단추로 막대를 펼쳤을 때만 만든다(LNK-2).
public final class LinkExportServer: Sendable {
    private let export: LinkExport

    private init(export: LinkExport) {
        self.export = export
    }

    /// 곡과 재생 목록으로 서버를 띄운다. `peer`(보이는 CDJ 하나의 주소)로 가는 인터페이스에 참여한다.
    /// 시험 프로세스에서는 DJLinkKit이 소켓을 만들지 않고 바로 실패한다.
    public static func start(tracks: [LinkExportTrack], playlists: [LinkExportPlaylist], shareRoot: String,
                             peer: String) async throws -> LinkExportServer {
        try await Task { @DJLinkActor in
            guard let address = try? LinkAddress(peer), let interface = interface(toward: address) else {
                throw LinkExportError.noInterface(peer: peer)
            }
            let source = ExportSource(library: library(tracks: tracks, playlists: playlists), shareRoot: shareRoot,
                                      tracks: tracks)
            do {
                return LinkExportServer(export: try await LinkExport.start(source, interface))
            } catch let error as LinkError {
                throw LinkExportError.bind(error.description)
            }
        }.value
    }

    /// CDJ와 같은 서브넷에 있는 인터페이스를 먼저 고른다. 경로 조회(`interface_toward`)만 쓰면 169.254/16 경로가
    /// Wi‑Fi(en0)에도 있을 때 유선 대신 Wi‑Fi 주소가 나와, 알림이 CDJ에 닿지 않는다(2026-10-16 실기).
    private static func interface(toward peer: LinkAddress) -> Interface? {
        let all = interfaces()
        let candidates = all.map { (address: $0.address.octets, netmask: $0.netmask.octets) }
        if let index = LinkSubnet.pick(peer: peer.octets, among: candidates) { return all[index] }
        return interface_toward(all, peer)
    }

    /// 서버를 내리고 포트를 모두 돌려준다.
    public func stop() async {
        await Task { @DJLinkActor [export] in await export.stop() }.value
    }

    public func status() async -> LinkExportStatus {
        await Task { @DJLinkActor [export] in
            let snapshot = export.snapshot()
            let number: Int?, down: String?
            switch snapshot.link {
            case let .up(value): (number, down) = (Int(value), nil)
            case let .down(why): (number, down) = (nil, why)
            case .waiting, .joining: (number, down) = (nil, nil)
            }
            return LinkExportStatus(deviceNumber: number, down: down, mounted: Set(snapshot.mounted.map(\.description)))
        }.value
    }

    /// 플레이어에 곡을 싣게 한다(플레이어가 이 서버의 라이브러리를 마운트한 뒤에만 된다).
    public func load(player: Int, trackID: UInt32) async throws {
        try await Task { @DJLinkActor [export] in
            guard let number = UInt8(exactly: player) else { throw LinkExportError.playerMissing(player) }
            let snapshot = export.snapshot()
            guard case .up = snapshot.link else { throw LinkExportError.notJoined }
            guard let target = snapshot.players.first(where: { $0.number == number }) else {
                throw LinkExportError.playerMissing(player)
            }
            guard snapshot.mounted.contains(target.address) else { throw LinkExportError.notMounted(player) }
            do {
                try await export.load_track(number, trackID)
            } catch {
                throw LinkExportError.other("\(error)")
            }
        }.value
    }

    /// DJLinkExport 열 기반 라이브러리. 분석 파일 경로는 `library_from`이 비워 두므로 따로 채운다
    @DJLinkActor
    static func library(tracks: [LinkExportTrack], playlists: [LinkExportPlaylist]) -> Library {
        let library = library_from(tracks.map { track in
            TestTrack(id: UInt64(track.id), title: track.title, artist: track.artist, album: track.album,
                      comment: track.comment, bpm_x100: track.bpmX100, length_sec: track.lengthSeconds,
                      rating: track.rating, key: track.key, cues: track.cues.map(cue), path: track.path, genre: track.genre,
                      bitrate: track.bitrate, file_type: track.fileType)
        })
        var analysis = StrColumn()
        for track in tracks { analysis.push(track.analysisPath) }
        library.analysis_path = analysis
        let rowOfID = Dictionary(tracks.enumerated().map { ($0.element.id, Row($0.offset)) }, uniquingKeysWith: { first, _ in first })
        var lists = Playlists()
        for (index, playlist) in playlists.enumerated() {
            lists.ids.append(1000 + UInt64(index))
            lists.names.push(playlist.name)
            lists.parent.append(playlist.parent.flatMap { UInt32(exactly: $0) } ?? NO_ID)
            lists.seq.append(UInt32(index))
            lists.attribute.append(playlist.isFolder ? ATTRIBUTE_FOLDER : 0)
            lists.smart.push("")
            lists.members.append(playlist.trackIDs.compactMap { rowOfID[$0] })
        }
        library.set_playlists(lists)
        return library
    }

    private static func cue(_ cue: LinkExportCue) -> DJLinkExportModel.Cue {
        DJLinkExportModel.Cue(position_ms: cue.positionMs, out_ms: cue.outMs,
            kind: cue.hotCue.flatMap { DJLinkExportModel.Cue.kind_of_letter($0) } ?? DJLinkExportModel.Cue.MEMORY, colour: cue.colour)
    }
}

/// 고정 라이브러리. `StaticSource`와 같되 곡 정보(`details`)에 파일 형식을 실어 준다.
/// 형식이 0이면 서버가 MP3(1)로 보내 WAV가 E-8305로 실리지 않는다(DJLinkKit docs/LINK-EXPORT-HARDWARE.md).
/// 곡 정보를 주면 서버는 목록 둘째 열(아티스트·앨범·장르·레이블)과 비트레이트도 그 값을 쓰므로 함께 채운다.
@DJLinkActor
private final class ExportSource: Source {
    private let snapshot: Library
    private let root: String
    private let details: [String: DJLinkExportModel.TrackDetails]

    init(library: Library, shareRoot: String, tracks: [LinkExportTrack]) {
        snapshot = library
        root = shareRoot
        var details: [String: DJLinkExportModel.TrackDetails] = [:]
        for (row, track) in tracks.enumerated() {
            func id(_ column: [UInt32]) -> UInt32 { column.indices.contains(row) ? column[row] : 0 }
            details[String(track.id)] = DJLinkExportModel.TrackDetails(
                id: String(track.id), title: track.title, artist_id: id(library.artist_ids), artist: track.artist,
                album_id: id(library.album_ids), album: track.album, genre_id: id(library.genre_ids), genre: track.genre,
                label_id: id(library.label_ids), key: track.key, comment: track.comment, rating: track.rating,
                bpm_x100: track.bpmX100, duration_sec: track.lengthSeconds, file_type: UInt32(track.fileType),
                bitrate: track.bitrate, path: track.path)
        }
        self.details = details
    }

    func library() -> Library? { snapshot }
    func share_root() -> String { root }
    func details(_ id: String) -> DJLinkExportModel.TrackDetails? { details[id] }
}
