import DJCDomain
import Foundation

/// LINK 서버의 지금 상태(#273)
public struct LinkServerStatus: Equatable, Sendable {
    /// 참여한 장치 번호. 참여하는 중이면 nil
    public var deviceNumber: Int?
    /// 참여하지 못한 이유(번호 충돌 등)
    public var down: String?
    /// 라이브러리를 마운트한 장치의 주소
    public var mounted: Set<String>
    /// 플레이어 번호별 재생 상태
    public var players: [Int: LinkPlayerState]

    public init(deviceNumber: Int? = nil, down: String? = nil, mounted: Set<String> = [], players: [Int: LinkPlayerState] = [:]) {
        self.deviceNumber = deviceNumber
        self.down = down
        self.mounted = mounted
        self.players = players
    }
}

/// 플레이어 하나의 재생 상태(LINK 막대의 간단한 표시)
public struct LinkPlayerState: Equatable, Sendable {
    public var isPlaying: Bool
    public var isMaster: Bool
    public var isSync: Bool
    /// 내어 준 곡을 실었으면 그 번호. 다른 곳(USB 등)의 곡이면 nil
    public var loadedTrackID: UInt32?
    /// 실은 곡 제목. 연결(`LinkSession.status`)이 내어 준 곡에서 찾아 채운다
    public var title: String?
    /// 피치를 반영한 BPM. 모르면 nil
    public var bpm: Double?

    public init(isPlaying: Bool = false, isMaster: Bool = false, isSync: Bool = false, loadedTrackID: UInt32? = nil,
                title: String? = nil, bpm: Double? = nil) {
        self.isPlaying = isPlaying
        self.isMaster = isMaster
        self.isSync = isSync
        self.loadedTrackID = loadedTrackID
        self.title = title
        self.bpm = bpm
    }
}

/// 곡 싣기·연결이 막힌 이유. 화면이 한 문장으로 바꾼다
public enum LinkProblem: Error, Equatable, Sendable {
    /// rekordbox가 같은 포트를 쓰는 중
    case rekordboxRunning
    /// 네트워크에 보이는 장치가 없어 참여할 인터페이스를 고를 수 없음
    case noDevice
    /// 그 장치로 가는 인터페이스를 찾지 못함
    case noInterface
    /// 포트를 열지 못함(DJLinkKit의 설명)
    case portInUse(String)
    /// 연결을 켜지 않음
    case notConnected
    /// 아직 네트워크에 참여하는 중
    case notJoined
    /// 내어 주지 않는 곡(추가 대기·USB·스트리밍·파일 없음·모르는 형식)
    case trackNotShared
    /// 그 플레이어가 네트워크에 없음
    case playerMissing(Int)
    /// 그 플레이어가 아직 라이브러리를 마운트하지 않음
    case notMounted(Int)
    /// 켜는 도중에 끄기를 요청함(알릴 일이 아니다)
    case cancelled
    case failed(String)
}

/// LINK 서버 포트(#273). 실제 구현은 DJLinkKit `DJLinkExport`를 띄운다. 한 번에 서버 하나만 둔다.
public struct LinkServerSource: Sendable {
    /// 라이브러리를 내어 주는 서버를 띄운다(이미 떠 있으면 내리고 새로 띄운다). `peer` 장치로 가는 인터페이스에 참여한다
    public var start: @Sendable (_ library: LinkLibrary, _ shareRoot: String, _ peer: String) async throws(LinkProblem) -> Void
    /// 서버를 내리고 포트를 돌려준다
    public var stop: @Sendable () async -> Void
    public var status: @Sendable () async -> LinkServerStatus?
    /// 플레이어에 곡을 싣게 한다
    public var load: @Sendable (_ player: Int, _ trackID: UInt32) async throws(LinkProblem) -> Void
    /// rekordbox·rekordboxAgent가 켜져 있는지. 프로세스를 띄워 보므로 메인 밖에서 부른다
    public var isRekordboxRunning: @Sendable () -> Bool

    public init(start: @escaping @Sendable (LinkLibrary, String, String) async throws(LinkProblem) -> Void,
                stop: @escaping @Sendable () async -> Void,
                status: @escaping @Sendable () async -> LinkServerStatus?,
                load: @escaping @Sendable (Int, UInt32) async throws(LinkProblem) -> Void,
                isRekordboxRunning: @escaping @Sendable () -> Bool) {
        self.start = start
        self.stop = stop
        self.status = status
        self.load = load
        self.isRekordboxRunning = isRekordboxRunning
    }

    /// 서버를 띄우지 않는다(화면 시험·자가 테스트 실행). 연결을 켜면 쓸 수 없다고 한다
    public static let none = LinkServerSource(start: { _, _, _ throws(LinkProblem) in throw .noInterface }, stop: {},
                                              status: { nil }, load: { _, _ throws(LinkProblem) in throw .notConnected },
                                              isRekordboxRunning: { false })
}

/// LINK 연결(#273·#274): 사용자가 켜면 라이브러리를 만들어 서버를 띄우고, 플레이어에 놓은 곡을 싣는다.
/// 내어 준 라이브러리는 켤 때의 것이다(서버가 공유 폴더를 켤 때 정한다). 라이브러리가 바뀌면 다시 켠다.
public actor LinkSession {
    private let source: LinkServerSource
    private var library: LinkLibrary?
    /// 켜기·끄기 차례. 켜기를 기다리는 사이(rekordbox 확인·서버 띄우기) 끄기가 끼어들면 그 켜기는 서버를 띄우지 않거나 바로 내린다
    private var generation = 0
    /// 서버를 띄워 둔 채인지. 끄기는 띄운 서버가 있을 때만 내린다
    private var serverUp = false
    /// 마지막으로 줄 세운 켜기·끄기. 서버 띄우기·내리기는 부른 차례대로 하나씩 한다(겹쳐 뜨거나 새 서버를 내리지 않게)
    private var tail: Task<Void, Never>?

    public init(source: LinkServerSource) {
        self.source = source
    }

    public var isConnected: Bool { library != nil }

    /// 켜기·끄기 차례(시험이 끄기가 들어온 것을 기다릴 때 읽는다)
    var currentGeneration: Int { generation }

    /// 연결을 켠다. rekordbox가 켜져 있으면 포트를 열지 않는다(LNK-3). 내어 준 곡 수를 돌려준다
    @discardableResult
    public func connect(rows: [TrackRow], playlists: PlaylistLayout, shareRoot: String, peers: [LinkDevice]) async throws(LinkProblem) -> Int {
        // 차례는 기다리기 전에 받는다. 그래야 기다리는 사이 들어온 끄기가 이 켜기를 무른다
        generation += 1
        let mine = generation
        let result = await serialized { session in
            await session.connectNow(rows: rows, playlists: playlists, shareRoot: shareRoot, peers: peers, mine: mine)
        }
        return try result.get()
    }

    /// 연결을 끈다. 켜는 중이어도 끈다(그 켜기는 차례가 바뀐 것을 보고 서버를 띄우지 않거나 내린다)
    public func disconnect() async {
        generation += 1
        library = nil
        await serialized { session in await session.stopNow() }
    }

    private func connectNow(rows: [TrackRow], playlists: PlaylistLayout, shareRoot: String, peers: [LinkDevice],
                            mine: Int) async -> Result<Int, LinkProblem> {
        guard generation == mine else { return .failure(.cancelled) }
        let source = source
        if await BlockingWork.run(qos: .utility, { source.isRekordboxRunning() }) { return .failure(.rekordboxRunning) }
        guard generation == mine else { return .failure(.cancelled) }
        // 참여할 인터페이스는 플레이어(없으면 아무 장치) 쪽으로 고른다
        guard let peer = peers.first(where: \.hasDeck) ?? peers.first(where: { $0.kind != .rekordbox }) else {
            return .failure(.noDevice)
        }
        let built = LinkLibrary.build(rows: rows, playlists: playlists)
        do {
            try await source.start(built, shareRoot, peer.address)
        } catch {
            // 기다리는 사이 껐거나 다시 켰으면 이 실패는 알릴 일이 아니다(화면이 뒤 켜기의 상태를 끄지 않게)
            return .failure(generation == mine ? error : .cancelled)
        }
        serverUp = true
        guard generation == mine else {
            await stopNow()
            return .failure(.cancelled)
        }
        library = built
        return .success(built.tracks.count)
    }

    private func stopNow() async {
        guard serverUp else { return }
        serverUp = false
        await source.stop()
    }

    /// 앞서 줄 세운 일이 끝난 뒤에 `work`를 한다
    private func serialized<T: Sendable>(_ work: @escaping @Sendable (isolated LinkSession) async -> T) async -> T {
        let previous = tail
        let task = Task { () async -> T in
            await previous?.value
            return await work(self)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// 서버 상태. 플레이어가 실은 곡은 내어 준 곡에서 제목을 찾아 채운다
    public func status() async -> LinkServerStatus? {
        // 기다리는 사이 껐거나 다시 켰으면 지금 라이브러리로 찾는다
        guard library != nil, var status = await source.status(), let library else { return nil }
        for (number, player) in status.players {
            status.players[number]?.title = player.loadedTrackID.flatMap(library.title(ofLinkID:))
        }
        return status
    }

    /// rekordbox 곡(`contentID`)을 플레이어에 싣는다
    public func load(contentID: String, player: Int) async throws(LinkProblem) {
        guard let library else { throw .notConnected }
        guard let id = library.linkID(of: contentID) else { throw .trackNotShared }
        try await source.load(player, id)
    }
}
