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

    public init(deviceNumber: Int? = nil, down: String? = nil, mounted: Set<String> = []) {
        self.deviceNumber = deviceNumber
        self.down = down
        self.mounted = mounted
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
    /// 켜기·끄기 차례. 서버를 띄우는 사이 끄기가 끼어들면 띄운 서버를 바로 내린다(rekordbox가 켜졌거나 창을 닫았다)
    private var generation = 0

    public init(source: LinkServerSource) {
        self.source = source
    }

    public var isConnected: Bool { library != nil }

    /// 연결을 켠다. rekordbox가 켜져 있으면 포트를 열지 않는다(LNK-3). 내어 준 곡 수를 돌려준다
    @discardableResult
    public func connect(rows: [TrackRow], playlists: PlaylistLayout, shareRoot: String, peers: [LinkDevice]) async throws(LinkProblem) -> Int {
        let source = source
        if await BlockingWork.run(qos: .utility, { source.isRekordboxRunning() }) { throw .rekordboxRunning }
        // 참여할 인터페이스는 플레이어(없으면 아무 장치) 쪽으로 고른다
        guard let peer = peers.first(where: \.hasDeck) ?? peers.first(where: { $0.kind != .rekordbox }) else { throw .noDevice }
        generation += 1
        let mine = generation
        let built = LinkLibrary.build(rows: rows, playlists: playlists)
        try await source.start(built, shareRoot, peer.address)
        guard generation == mine else {
            await source.stop()
            throw .cancelled
        }
        library = built
        return built.tracks.count
    }

    /// 연결을 끈다. 켜는 중이어도 끈다(띄우고 있는 서버는 다 띄운 뒤 `connect`가 내린다)
    public func disconnect() async {
        generation += 1
        library = nil
        await source.stop()
    }

    public func status() async -> LinkServerStatus? {
        guard library != nil else { return nil }
        return await source.status()
    }

    /// rekordbox 곡(`contentID`)을 플레이어에 싣는다
    public func load(contentID: String, player: Int) async throws(LinkProblem) {
        guard let library else { throw .notConnected }
        guard let id = library.linkID(of: contentID) else { throw .trackNotShared }
        try await source.load(player, id)
    }
}
