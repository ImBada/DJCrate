import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// LINK 연결(#273·#274): 켜기 전 확인, 서버에 넘기는 라이브러리, 곡 싣기 번호. 가짜 서버 포트만 쓰고 소켓을 열지 않는다.
@Suite("LINK 연결")
struct LinkSessionTests {
    static let cdj2 = LinkDevice(number: 2, name: "CDJ-2000nexus", kind: .player, address: "169.254.86.193")
    static let djm = LinkDevice(number: 33, name: "DJM-900NXS2", kind: .mixer, address: "169.254.98.242")

    static func row(_ id: String) -> TrackRow {
        TrackRow(track: Track(id: id, uuid: "u\(id)", title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil, genre: nil,
                              composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 60,
                              folderPath: "/Users/dj/Music/\(id).mp3", comment: "", importedOn: nil, analysisDataPath: nil,
                              imagePath: nil, isDeleted: false),
                 cues: [], playCount: 0)
    }

    /// 서버 포트가 받은 것을 적는다
    final class Fake: Sendable {
        let rekordbox = Mutex(false)
        let started = Mutex<[(library: LinkLibrary, shareRoot: String, peer: String)]>([])
        let stopped = Mutex(0)
        let loaded = Mutex<[(player: Int, id: UInt32)]>([])
        let loadProblem = Mutex<LinkProblem?>(nil)
        /// 켜면 서버 띄우기를 시험이 풀어 줄 때까지 멈춘다(그 사이 끄기를 끼워 넣는다)
        let holdsStart = Mutex(false)
        let held = Mutex<CheckedContinuation<Void, Never>?>(nil)

        func releaseStart() { held.withLock { $0?.resume(); $0 = nil } }
        var isHolding: Bool { held.withLock { $0 != nil } }

        var source: LinkServerSource {
            LinkServerSource(
                start: { [self] library, root, peer throws(LinkProblem) in
                    if holdsStart.withLock({ $0 }) {
                        await withCheckedContinuation { continuation in held.withLock { $0 = continuation } }
                    }
                    started.withLock { $0.append((library, root, peer)) }
                },
                stop: { [self] in stopped.withLock { $0 += 1 } },
                status: { LinkServerStatus(deviceNumber: 17) },
                load: { [self] player, id throws(LinkProblem) in
                    if let problem = loadProblem.withLock({ $0 }) { throw problem }
                    loaded.withLock { $0.append((player, id)) }
                },
                isRekordboxRunning: { [self] in rekordbox.withLock { $0 } })
        }
    }

    @Test func 켜면_컬렉션으로_만든_라이브러리를_플레이어_쪽으로_띄운다() async throws {
        let fake = Fake()
        let session = LinkSession(source: fake.source)
        let count = try await session.connect(rows: [Self.row("10"), Self.row("djc-1")], playlists: PlaylistLayout(), shareRoot: "/share",
                                              peers: [Self.djm, Self.cdj2])
        #expect(count == 1)
        let start = try #require(fake.started.withLock { $0.first })
        #expect(start.library.tracks.map(\.contentID) == ["10"])
        #expect(start.shareRoot == "/share")
        #expect(start.peer == Self.cdj2.address)
        #expect(await session.isConnected)
    }

    @Test func rekordbox가_켜져_있으면_서버를_띄우지_않는다() async {
        let fake = Fake()
        fake.rekordbox.withLock { $0 = true }
        let session = LinkSession(source: fake.source)
        await #expect(throws: LinkProblem.rekordboxRunning) {
            try await session.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        }
        #expect(fake.started.withLock { $0.isEmpty })
        #expect(!(await session.isConnected))
    }

    @Test func 보이는_장치가_없으면_켜지_않는다() async {
        let session = LinkSession(source: Fake().source)
        await #expect(throws: LinkProblem.noDevice) {
            try await session.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [])
        }
    }

    @Test func 곡은_rekordbox_ID가_아니라_내어_준_번호로_싣는다() async throws {
        let fake = Fake()
        let session = LinkSession(source: fake.source)
        try await session.connect(rows: [Self.row("10"), Self.row("20")], playlists: PlaylistLayout(), shareRoot: "/share",
                                  peers: [Self.cdj2])
        try await session.load(contentID: "20", player: 2)
        #expect(fake.loaded.withLock { $0.map(\.player) } == [2])
        #expect(fake.loaded.withLock { $0.map(\.id) } == [2])
    }

    @Test func 내어_주지_않은_곡과_꺼진_연결은_싣지_않는다() async throws {
        let fake = Fake()
        let session = LinkSession(source: fake.source)
        await #expect(throws: LinkProblem.notConnected) { try await session.load(contentID: "10", player: 2) }
        try await session.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        await #expect(throws: LinkProblem.trackNotShared) { try await session.load(contentID: "djc-1", player: 2) }
        #expect(fake.loaded.withLock { $0.isEmpty })
    }

    @Test func 서버가_막은_이유를_그대로_넘긴다() async throws {
        let fake = Fake()
        fake.loadProblem.withLock { $0 = .notMounted(2) }
        let session = LinkSession(source: fake.source)
        try await session.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        await #expect(throws: LinkProblem.notMounted(2)) { try await session.load(contentID: "10", player: 2) }
    }

    @Test func 끄면_서버를_내리고_다시_싣지_않는다() async throws {
        let fake = Fake()
        let session = LinkSession(source: fake.source)
        try await session.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        await session.disconnect()
        await session.disconnect()
        #expect(fake.stopped.withLock { $0 } == 1)
        #expect(await session.status() == nil)
        await #expect(throws: LinkProblem.notConnected) { try await session.load(contentID: "10", player: 2) }
    }

    @Test func 켜는_도중에_끄면_띄운_서버를_바로_내리고_켜지지_않는다() async throws {
        let fake = Fake()
        fake.holdsStart.withLock { $0 = true }
        let session = LinkSession(source: fake.source)
        let connecting = Task {
            try await session.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        }
        // 띄우기가 멈출 때까지 기다린다(안전망 300초, TEST-32)
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while !fake.isHolding, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(fake.isHolding)
        await session.disconnect()
        fake.releaseStart()
        await #expect(throws: LinkProblem.cancelled) { try await connecting.value }
        #expect(fake.stopped.withLock { $0 } == 2)
        #expect(!(await session.isConnected))
    }
}
