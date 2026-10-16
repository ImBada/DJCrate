import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 창 아래 LINK 막대의 화면 모델(#272·#273·#274). 장치 찾기(`LinkDiscovery`)의 상태를 들고, LINK 단추로 장치 목록을 펼치고 접는다.
/// LINK 단추로 펼치면 라이브러리를 CDJ에 내어 주고(`LinkSession`), 플레이어 칸에 놓은 곡을 그 플레이어에 싣는다.
/// 조립 지점(`AppComposition`)이 한 번 만든다. 찾기는 받기만 하고, 보내는 일은 LINK를 펼쳤을 때만 한다(LNK-1·LNK-2).
@MainActor
@Observable
final class LinkBarModel {
    /// 연결을 켤 때 내어 줄 라이브러리
    struct LibraryInput {
        var rows: [TrackRow]
        var playlists: PlaylistLayout
        /// iTunes 재생 목록(다 읽었을 때만). nil이면 아직 읽는 중이라 다 읽은 뒤 연결 중인 서버에 더한다
        var iTunes: [SyncedITunesLibrary.Node]? = nil
        var shareRoot: String
    }

    enum Connection: Equatable {
        case off
        case connecting
        /// 켜짐. 내어 준 곡 수
        case on(tracks: Int)
    }

    private(set) var state: LinkDiscoveryState = .idle
    /// 장치 목록을 펼쳤는지(rekordbox처럼 LINK 단추로 연다). 펼친 동안 라이브러리를 내어 준다
    private(set) var isExpanded = false
    private(set) var connection: Connection = .off
    /// 켠 서버의 상태(참여 번호·마운트한 장치). 꺼져 있으면 nil
    private(set) var server: LinkServerStatus?

    @ObservationIgnored private let discovery: LinkDiscovery
    @ObservationIgnored private let session: LinkSession
    @ObservationIgnored private let library: () -> LibraryInput?
    @ObservationIgnored private let notify: (_ text: String, _ kind: AppToast.Kind) -> Void
    /// 내어 주기를 껐을 때(LINK 재생 기록을 rekordbox 쓰기 대기에 올린다)
    @ObservationIgnored private let sessionEnded: () -> Void
    /// 펼친 채 rekordbox 때문에 막혔는지. 풀리고 장치가 다시 보이면 내어 주기를 다시 켠다
    @ObservationIgnored private var reconnectWhenFree = false
    /// 켠 서버에 iTunes 목록을 넣었는지(켤 때 아직 읽는 중이었으면 다 읽은 뒤 넣는다)
    @ObservationIgnored private var servesITunes = false
    /// 서버 상태를 다시 볼 간격
    @ObservationIgnored var statusInterval: Duration = .seconds(1)

    init(discovery: LinkDiscovery, session: LinkSession = LinkSession(source: .none), library: @escaping () -> LibraryInput? = { nil },
         notify: @escaping (_ text: String, _ kind: AppToast.Kind) -> Void = { _, _ in }, sessionEnded: @escaping () -> Void = {}) {
        self.discovery = discovery
        self.session = session
        self.library = library
        self.notify = notify
        self.sessionEnded = sessionEnded
    }

    /// 보이는 장치. 연결을 켰으면 DJCrate 자신(서버가 참여한 번호)은 뺀다
    var devices: [LinkDevice] {
        let own = server?.deviceNumber
        return state.devices.filter { $0.number != own }
    }

    /// LINK 단추를 보일지. 장치가 있거나, 연결을 켰거나, rekordbox 때문에 멈춰 이유를 알려야 할 때 보인다
    var isVisible: Bool {
        if connection != .off { return true }
        switch state {
        case let .listening(devices): return !devices.isEmpty
        case .blockedByRekordbox: return true
        case .idle, .unavailable: return false
        }
    }

    /// LINK를 쓸 수 없는 이유(무엇을 하면 되는지까지). 쓸 수 있으면 nil
    var blockReason: String? {
        state == .blockedByRekordbox ? String(ui: "rekordbox가 같은 LINK 포트를 쓰고 있습니다. rekordbox를 끈 뒤 쓰세요") : nil
    }

    /// 펼쳐 장치 목록을 보일지
    var showsDevices: Bool { isExpanded && blockReason == nil && !devices.isEmpty }

    var isConnected: Bool { if case .on = connection { true } else { false } }

    /// LINK 단추 옆 글: 연결 상태. 참여 번호는 단추에 보인다
    var connectionText: String? {
        switch connection {
        case .off: nil
        case .connecting: String(ui: "연결하는 중…")
        case .on:
            if server?.deviceNumber != nil {
                String(ui: "연결됨")
            } else if let down = server?.down {
                String(ui: "참여하지 못했습니다: \(down)")
            } else {
                String(ui: "참여하는 중…")
            }
        }
    }

    /// 막대 가운데에 늘어놓을 차례: rekordbox처럼 플레이어를 반씩 믹서 양쪽에 둔다(1·2 | 믹서 | 3·4). 그 밖의 장치는 오른쪽 끝에 둔다
    var arrangement: LinkArrangement { LinkArrangement(devices) }

    /// 그 플레이어의 재생 상태(서버를 켰을 때만 안다)
    func player(_ device: LinkDevice) -> LinkPlayerState? { server?.players[device.number] }

    /// 그 장치가 DJCrate 라이브러리를 마운트했는지(곡을 실을 수 있는지)
    func isMounted(_ device: LinkDevice) -> Bool { server?.mounted.contains(device.address) ?? false }

    /// 곡을 놓을 수 있는 칸: 연결을 켰고 덱이 있는 장치
    func acceptsDrop(_ device: LinkDevice) -> Bool { isConnected && device.hasDeck }

    /// LINK 단추: 펼치면서 라이브러리를 내어 주고, 접으면서 내어 주기를 끈다(rekordbox의 LINK 단추처럼).
    /// rekordbox 때문에 막혔으면 펼쳐 이유만 보인다
    func toggle() {
        if isExpanded {
            isExpanded = false
            reconnectWhenFree = false
            Task { await disconnect() }
        } else {
            isExpanded = true
            if blockReason == nil { Task { await connect() } } else { reconnectWhenFree = true }
        }
    }

    func connect() async {
        guard connection == .off else { return }
        guard let input = library() else {
            notify(String(ui: "라이브러리를 읽은 뒤 LINK를 다시 누르세요"), .warning)
            return
        }
        connection = .connecting
        do {
            servesITunes = input.iTunes != nil
            let count = try await session.connect(rows: input.rows, playlists: input.playlists, iTunes: input.iTunes ?? [],
                                                  shareRoot: input.shareRoot, peers: state.devices)
            // 기다리는 사이 껐으면(rekordbox 켜짐·끄기) 켜진 것으로 되돌리지 않는다
            guard connection == .connecting else { return }
            connection = .on(tracks: count)
            await refreshStatus()
        } catch .cancelled {
            return
        } catch {
            if connection == .connecting { connection = .off }
            notify(LinkText.problem(error), .warning)
        }
    }

    func disconnect() async {
        guard connection != .off else { return }
        connection = .off
        server = nil
        await session.disconnect()
        sessionEnded()
    }

    /// 플레이어 칸에 놓은 곡(rekordbox 곡 ID)을 그 플레이어에 싣는다
    func drop(contentID: String, on device: LinkDevice) {
        Task { await load(contentID: contentID, on: device) }
    }

    func load(contentID: String, on device: LinkDevice) async {
        do {
            try await session.load(contentID: contentID, player: device.number)
        } catch {
            notify(LinkText.problem(error), .warning)
        }
    }

    /// 창이 떠 있는 동안 장치를 찾고, 연결을 켰으면 서버 상태를 본다(창의 `.task`가 부르고, 창이 닫히면 취소된다).
    func watch() async {
        // 창이 떠 있는 동안만 돈다(창의 `.task`가 취소하면 끝난다). 그동안 모델을 붙잡아도 된다
        let interval = statusInterval
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [discovery] in
                await discovery.run { state in await self.apply(state) }
            }
            group.addTask {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: interval) } catch { return }
                    await self.refreshStatus()
                }
            }
            await group.waitForAll()
        }
        await disconnect()
    }

    func apply(_ state: LinkDiscoveryState) {
        self.state = state
        if state == .blockedByRekordbox, isExpanded { reconnectWhenFree = true }
        // 펼친 채 rekordbox가 꺼지면 다시 내어 준다(펼친 동안 내어 준다). 포트를 다시 열면 빈 목록부터 오므로 장치가 보일 때까지 기다린다
        if reconnectWhenFree, case let .listening(devices) = state, !devices.isEmpty, isExpanded, connection == .off {
            reconnectWhenFree = false
            Task { await connect() }
        }
        // rekordbox가 켜지면 같은 포트를 쓰므로 비켜 준다(LNK-3)
        if state == .blockedByRekordbox, connection != .off {
            connection = .off
            server = nil
            Task { [session, sessionEnded] in
                await session.disconnect()
                sessionEnded()
            }
            notify(String(ui: "rekordbox가 켜져 LINK 연결을 껐습니다"), .warning)
        }
    }

    func refreshStatus() async {
        guard isConnected else { return }
        let status = await session.status()
        if isConnected { server = status }
        await addITunesWhenReady()
    }

    /// 켤 때 iTunes 목록을 아직 읽는 중이었으면, 다 읽은 뒤 켜 둔 서버의 재생 목록에 넣는다(서버를 다시 띄우지 않는다)
    func addITunesWhenReady() async {
        guard isConnected, !servesITunes, let input = library(), let tree = input.iTunes else { return }
        servesITunes = true
        await session.updatePlaylists(input.playlists, iTunes: tree)
    }
}

/// LINK 막대 가운데의 장치 차례
struct LinkArrangement: Equatable {
    var left: [LinkDevice]
    var mixers: [LinkDevice]
    var right: [LinkDevice]

    init(_ devices: [LinkDevice]) {
        let players = devices.filter(\.hasDeck).sorted { $0.number < $1.number }
        let half = (players.count + 1) / 2
        left = Array(players.prefix(half))
        mixers = devices.filter { $0.kind == .mixer }.sorted { $0.number < $1.number }
        right = Array(players.dropFirst(half)) + devices.filter { !$0.hasDeck && $0.kind != .mixer }.sorted { $0.number < $1.number }
    }
}

/// LINK 막힘 이유를 사람이 읽는 한 문장으로(무엇을 하면 되는지까지)
enum LinkText {
    static func problem(_ problem: LinkProblem) -> String {
        switch problem {
        case .rekordboxRunning: String(ui: "rekordbox가 같은 LINK 포트를 쓰고 있습니다. rekordbox를 끈 뒤 쓰세요")
        case .noDevice: String(ui: "네트워크에 CDJ가 보이지 않습니다. CDJ를 같은 네트워크에 연결한 뒤 켜세요")
        case .noInterface: String(ui: "CDJ로 가는 네트워크 연결을 찾지 못했습니다. 케이블·네트워크 설정을 확인한 뒤 다시 켜세요")
        case let .portInUse(why): String(ui: "LINK 포트를 열지 못했습니다(\(why)). 그 포트를 쓰는 앱을 끈 뒤 다시 켜세요")
        case .notConnected: String(ui: "LINK를 누른 뒤 곡을 놓으세요")
        case .notJoined: String(ui: "아직 LINK에 참여하는 중입니다. 잠시 뒤 다시 놓으세요")
        case .trackNotShared: String(ui: "이 곡은 LINK로 내어 주지 않습니다. rekordbox 컬렉션에 있고 파일이 있는 MP3·WAV·AIFF·M4A·FLAC 곡만 실을 수 있습니다")
        case let .playerMissing(number): String(ui: "\(number)번 플레이어가 네트워크에 없습니다. 플레이어를 확인한 뒤 다시 놓으세요")
        case let .notMounted(number): String(ui: "\(number)번 플레이어가 아직 DJCrate 라이브러리를 열지 않았습니다. 잠시 뒤 다시 놓으세요")
        case .cancelled: String(ui: "LINK 연결을 껐습니다")
        case let .failed(why): String(ui: "LINK 일이 실패했습니다: \(why)")
        }
    }
}
