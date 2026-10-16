import DJCApplication
@testable import DJCrate
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 창 아래 LINK 막대(#272): 장치가 보일 때만 단추를 띄우고, 펼치면 장치를 보이며 라이브러리를 내어 준다. rekordbox가 켜져 있으면 이유를 보인다.
/// 장치 찾기 상태는 직접 넣는다(포트를 열지 않는다).
@Suite("LINK 막대")
@MainActor
struct LinkBarModelTests {
    static let cdj1 = LinkDevice(number: 1, name: "CDJ-2000nexus", kind: .player, address: "169.254.86.192")

    static func model() -> LinkBarModel { LinkBarModel(discovery: LinkDiscovery(source: .none)) }

    @Test func 장치가_없으면_단추를_보이지_않는다() {
        let model = Self.model()
        #expect(!model.isVisible)
        model.apply(.listening([]))
        #expect(!model.isVisible)
        model.apply(.unavailable)
        #expect(!model.isVisible)
    }

    @Test func 장치가_보이면_단추를_띄우고_펼쳐야_장치를_보인다() {
        let model = Self.model()
        model.apply(.listening([Self.cdj1]))
        #expect(model.isVisible)
        #expect(!model.showsDevices)
        model.toggle()
        #expect(model.showsDevices)
        #expect(model.devices == [Self.cdj1])
        model.toggle()
        #expect(!model.showsDevices)
    }

    @Test func rekordbox가_켜져_있으면_장치_대신_이유를_보인다() {
        let model = Self.model()
        model.apply(.listening([Self.cdj1]))
        model.toggle()
        model.apply(.blockedByRekordbox)
        #expect(model.isVisible)
        #expect(!model.showsDevices)
        #expect(model.blockReason != nil)
    }

    @Test func 장치가_모두_빠지면_단추를_숨긴다() {
        let model = Self.model()
        model.apply(.listening([Self.cdj1]))
        model.toggle()
        model.apply(.listening([]))
        #expect(!model.isVisible)
        #expect(!model.showsDevices)
    }

    @Test func 플레이어는_반씩_믹서_양쪽에_두고_그_밖의_장치는_오른쪽_끝에_둔다() {
        func device(_ number: Int, _ kind: LinkDevice.Kind) -> LinkDevice {
            LinkDevice(number: number, name: "\(number)", kind: kind, address: "169.254.0.\(number)")
        }
        let devices = [device(33, .mixer), device(4, .player), device(1, .player), device(3, .player), device(2, .player),
                       device(18, .rekordbox)]
        let arrangement = LinkArrangement(devices)
        #expect(arrangement.left.map(\.number) == [1, 2])
        #expect(arrangement.mixers.map(\.number) == [33])
        #expect(arrangement.right.map(\.number) == [3, 4, 18])
        // 홀수면 왼쪽이 하나 더 많다
        #expect(LinkArrangement([device(2, .player), device(1, .player), device(3, .player)]).left.map(\.number) == [1, 2])
    }

    // MARK: - 연결(#273·#274)

    static let own = LinkDevice(number: 17, name: "DJCrate", kind: .rekordbox, address: "169.254.1.2")

    static func connectable(notes: NotesBox, problem: LinkProblem? = nil) -> LinkBarModel {
        let source = LinkServerSource(
            start: { _, _, _, _ throws(LinkProblem) in },
            stop: {},
            status: { LinkServerStatus(deviceNumber: 17, mounted: ["169.254.86.192"]) },
            load: { _, _ throws(LinkProblem) in if let problem { throw problem } },
            isRekordboxRunning: { false })
        let row = TrackRow(track: Track(id: "10", uuid: "u10", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                                        composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 60,
                                        folderPath: "/Users/dj/Music/10.mp3", comment: "", importedOn: nil, analysisDataPath: nil,
                                        imagePath: nil, isDeleted: false),
                           cues: [], playCount: 0)
        return LinkBarModel(discovery: LinkDiscovery(source: .none), session: LinkSession(source: source),
                            library: { .init(rows: [row], playlists: PlaylistLayout(), shareRoot: "/share") },
                            notify: { text, _ in notes.values.append(text) })
    }

    @MainActor final class NotesBox {
        var values: [String] = []
    }

    @Test func 연결을_켜면_내어_준_곡_수와_참여_번호를_보이고_자신은_목록에서_뺀다() async {
        let notes = NotesBox()
        let model = Self.connectable(notes: notes)
        model.apply(.listening([Self.cdj1, Self.own]))
        await model.connect()
        #expect(model.connection == .on(tracks: 1))
        #expect(model.server?.deviceNumber == 17)
        #expect(model.devices == [Self.cdj1])
        #expect(model.isMounted(Self.cdj1))
        #expect(model.acceptsDrop(Self.cdj1))
        #expect(model.connectionText != nil)
        #expect(notes.values.isEmpty)
    }

    @Test func LINK를_펼치면_내어_주고_접으면_내어_주기를_끈다() async throws {
        let model = Self.connectable(notes: NotesBox())
        model.apply(.listening([Self.cdj1]))
        model.toggle()
        #expect(model.isExpanded)
        // 펼치기가 띄운 연결을 기다린다(안전망 300초, TEST-32)
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while !model.isConnected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.connection == .on(tracks: 1))
        model.toggle()
        #expect(!model.isExpanded)
        while model.connection != .off, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.connection == .off)
        #expect(model.server == nil)
    }

    @Test func rekordbox가_켜져_있으면_펼쳐도_내어_주지_않는다() async {
        let model = Self.connectable(notes: NotesBox())
        model.apply(.blockedByRekordbox)
        model.toggle()
        #expect(model.isExpanded)
        #expect(model.connection == .off)
    }

    @Test func 펼친_채_rekordbox가_꺼지면_다시_내어_준다() async throws {
        let notes = NotesBox()
        let model = Self.connectable(notes: notes)
        model.apply(.blockedByRekordbox)
        model.toggle()
        // 포트를 다시 열면 빈 목록이 먼저 온다
        model.apply(.listening([]))
        #expect(model.connection == .off)
        model.apply(.listening([Self.cdj1]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while !model.isConnected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.connection == .on(tracks: 1))
        #expect(notes.values.isEmpty)
    }

    @Test func 켤_때_iTunes_목록을_읽는_중이었으면_다_읽은_뒤_켜_둔_서버에_넣는다() async throws {
        let updated = Mutex<[[LinkLibrary.Playlist]]>([])
        let source = LinkServerSource(
            start: { _, _, _, _ throws(LinkProblem) in }, stop: {}, status: { LinkServerStatus(deviceNumber: 17) },
            load: { _, _ throws(LinkProblem) in }, isRekordboxRunning: { false },
            updatePlaylists: { playlists in updated.withLock { $0.append(playlists) } })
        let row = TrackRow(track: Track(id: "10", uuid: "u10", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                                        composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 60,
                                        folderPath: "/Users/dj/Music/10.mp3", comment: "", importedOn: nil, analysisDataPath: nil,
                                        imagePath: nil, isDeleted: false),
                           cues: [], playCount: 0)
        let ready = ITunesBox()
        let model = LinkBarModel(discovery: LinkDiscovery(source: .none), session: LinkSession(source: source),
                                 library: { .init(rows: [row], playlists: PlaylistLayout(), iTunes: ready.tree, shareRoot: "/share") })
        model.apply(.listening([Self.cdj1]))
        await model.connect()
        await model.addITunesWhenReady()
        #expect(updated.withLock { $0.isEmpty })
        ready.tree = SyncedITunesLibrary(snapshot: ITunesLibrarySnapshot(playlists: [.init(id: "B", name: "Later", paths: ["/Users/dj/Music/10.mp3"])]),
                                         tracks: [row.track]).tree
        await model.addITunesWhenReady()
        await model.addITunesWhenReady()
        #expect(updated.withLock { $0.map { $0.map(\.name) } } == [["iTunes", "Later"]])
    }

    @MainActor final class ITunesBox {
        var tree: [SyncedITunesLibrary.Node]?
    }

    @Test func CDJ가_실은_DJCrate_곡을_바뀔_때만_알리고_끄면_비운다() async {
        let reports = NotesBox()
        let box = LoadedBox()
        let source = LinkServerSource(
            start: { _, _, _, _ throws(LinkProblem) in }, stop: {},
            status: { LinkServerStatus(deviceNumber: 17, players: [2: LinkPlayerState(loadedTrackID: box.id)]) },
            load: { _, _ throws(LinkProblem) in }, isRekordboxRunning: { false })
        let row = TrackRow(track: Track(id: "10", uuid: "u10", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                                        composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 60,
                                        folderPath: "/Users/dj/Music/10.mp3", comment: "", importedOn: nil, analysisDataPath: nil,
                                        imagePath: nil, isDeleted: false),
                           cues: [], playCount: 0)
        let model = LinkBarModel(discovery: LinkDiscovery(source: .none), session: LinkSession(source: source),
                                 library: { .init(rows: [row], playlists: PlaylistLayout(), shareRoot: "/share") },
                                 cdjTracks: { reports.values.append($0.sorted().joined(separator: ",")) })
        model.apply(.listening([Self.cdj1]))
        await model.connect()
        #expect(reports.values == [])
        box.id = 1
        await model.refreshStatus()
        await model.refreshStatus()
        #expect(reports.values == ["10"])
        await model.disconnect()
        #expect(reports.values == ["10", ""])
    }

    final class LoadedBox: @unchecked Sendable {
        var id: UInt32?
    }

    @Test func 장치가_없으면_연결하지_않고_이유를_알린다() async {
        let notes = NotesBox()
        let model = Self.connectable(notes: notes)
        await model.connect()
        #expect(model.connection == .off)
        #expect(notes.values == [LinkText.problem(.noDevice)])
    }

    @Test func 연결을_끄기_전에는_플레이어에_곡을_놓을_수_없다() {
        let model = Self.connectable(notes: NotesBox())
        model.apply(.listening([Self.cdj1]))
        #expect(!model.acceptsDrop(Self.cdj1))
    }

    @Test func 싣기가_막히면_이유를_알린다() async {
        let notes = NotesBox()
        let model = Self.connectable(notes: notes, problem: .notMounted(1))
        model.apply(.listening([Self.cdj1]))
        await model.connect()
        await model.load(contentID: "10", on: Self.cdj1)
        #expect(notes.values == [LinkText.problem(.notMounted(1))])
    }

    @Test func rekordbox가_켜지면_연결을_끄고_알린다() async {
        let notes = NotesBox()
        let model = Self.connectable(notes: notes)
        model.apply(.listening([Self.cdj1]))
        await model.connect()
        model.apply(.blockedByRekordbox)
        #expect(model.connection == .off)
        #expect(model.server == nil)
        #expect(notes.values.count == 1)
    }
}
