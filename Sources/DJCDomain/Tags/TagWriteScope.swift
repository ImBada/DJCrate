import Foundation

/// 태그 칸마다 rekordbox 쓰기 규칙을 확인한 범위(#65). 확인하지 않은 곡에서 그 칸을 고친 초안은 막는다: 앱은 초안을 만들 때, 쓰기 모듈은
/// 백업 전 확인과 트랜잭션 안에서(반영 미리 보기에 이유가 보인다). 실험으로 범위를 넓힐 때는 `byKey` 한 곳만 고친다.
/// 표에 없는 칸은 태그 쓰기 공통 범위(`common`: 곡 상태 0·256·257, 재생 목록 XML Timestamp, #171·#173·S5)다.
public struct TagWriteScope: Sendable, Equatable {
    /// 쓰기를 확인한 곡 상태(`rb_data_status`)
    public var states: Set<Int>
    /// 그 곡이 든 재생 목록의 `masterPlaylists6.xml` Timestamp를 rekordbox가 어떻게 고치는지 확인했는지. 아니면 살아 있는 목록에 든 곡을 막는다.
    public var playlistXML: Bool
    /// 그 칸을 조건으로 쓰는 인텔리전트 재생 목록이 있을 때 써도 되는지. 아니면 그런 목록(조건을 못 읽은 목록 포함)이 라이브러리에 있을 때 막는다.
    /// 공통 칸은 예전처럼 보지 않는다.
    public var smartPlaylists: Bool

    public init(states: Set<Int>, playlistXML: Bool, smartPlaylists: Bool = true) {
        self.states = states
        self.playlistXML = playlistXML
        self.smartPlaylists = smartPlaylists
    }

    /// 정보 패널 아홉 칸과 키(#171·#173 S1~S4·S5 K1)
    public static let common = TagWriteScope(states: [0, 256, 257], playlistXML: true)

    /// 공통 범위보다 좁게 확인한 칸.
    /// - 평점·곡 색(2026-10-04 묶음 2 S1~S3, rekordbox 7.2.18): 상태 0 곡의 넣기·바꾸기·지우기만 칸 단위로 확인했다. 실험 곡은 살아 있는 재생 목록에
    ///   들어 있지 않아 XML Timestamp를 고치는지 보지 못했다[미확인]. 동기화 곡(#173 S1 T11·T12: 256 → 257)은 사본 재현 전이라 열지 않는다.
    ///   실험 라이브러리에는 인텔리전트 목록이 없어, 평점·곡 색 조건을 가진 목록의 Timestamp·결과를 rekordbox가 바꾸는지도 보지 못했다[미확인].
    public static let byKey: [TagFields.Key: TagWriteScope] = [
        .rating: TagWriteScope(states: [0], playlistXML: false, smartPlaylists: false),
        .color: TagWriteScope(states: [0], playlistXML: false, smartPlaylists: false),
    ]

    public static func scope(for key: TagFields.Key, in scopes: [TagFields.Key: TagWriteScope] = byKey) -> TagWriteScope {
        scopes[key] ?? common
    }

    /// 고친 칸 가운데 이 곡(상태 `state`, 살아 있는 재생 목록에 들었는지 `inPlaylist`)에서 확인하지 않은 칸이 있으면 막을 이유.
    /// 공통 범위 밖의 곡 상태는 태그 쓰기가 따로 막는다(여기서는 칸별로 좁힌 것만 본다).
    public static func blockReason(keys: [TagFields.Key], state: Int?, inPlaylist: Bool,
                                   scopes: [TagFields.Key: TagWriteScope] = byKey) -> String? {
        let narrowed = TagFields.Key.allCases.filter { keys.contains($0) && scopes[$0] != nil }
        let unsynced = narrowed.filter { key in !(state.map { scope(for: key, in: scopes).states.contains($0) } ?? false) }
        if !unsynced.isEmpty {
            let labels = unsynced.map(\.label).joined(separator: "·")
            return String(ui: "동기화된 곡의 \(labels)은 rekordbox에 쓰는 규칙을 아직 확인하지 않았으니 rekordbox에서 직접 고치거나 이 칸 초안을 버리세요")
        }
        let listed = inPlaylist ? narrowed.filter { !scope(for: $0, in: scopes).playlistXML } : []
        if !listed.isEmpty {
            let labels = listed.map(\.label).joined(separator: "·")
            return String(ui: "재생 목록에 든 곡의 \(labels)은 rekordbox에 쓰는 규칙을 아직 확인하지 않았으니 rekordbox에서 직접 고치거나 이 칸 초안을 버리세요")
        }
        return nil
    }

    /// 인텔리전트 목록 조건(#68의 `SmartPlaylistSource`)이 걸릴 수 있는 태그 칸. 조건을 못 읽었거나 모르는 항목 이름(곡 색일 수 있다)이 있으면 모든 칸이다.
    /// 쓰기 범위를 가르는 데만 쓰므로 좁게 확인한 칸(평점)만 정확히 짝짓는다.
    public static func smartPlaylistKeys(_ source: SmartPlaylistSource) -> Set<TagFields.Key> {
        guard let definition = source.definition else { return Set(TagFields.Key.allCases) }
        var keys = Set<TagFields.Key>()
        for condition in definition.conditions {
            switch condition.property {
            case nil: return Set(TagFields.Key.allCases)
            case .rating: keys.insert(.rating)
            default: break
            }
        }
        return keys
    }

    /// 고친 칸 가운데 인텔리전트 목록(`smartPlaylists`: 이름과 조건)이 걸릴 수 있어 확인하지 않은 칸이 있으면 막을 이유. 이유에는 첫 목록 이름을 적는다.
    public static func smartPlaylistBlockReason(keys: [TagFields.Key], smartPlaylists: [(name: String, source: SmartPlaylistSource)],
                                                scopes: [TagFields.Key: TagWriteScope] = byKey) -> String? {
        let unverified = TagFields.Key.allCases.filter { keys.contains($0) && !scope(for: $0, in: scopes).smartPlaylists }
        guard !unverified.isEmpty else { return nil }
        for playlist in smartPlaylists {
            let hit = unverified.filter(smartPlaylistKeys(playlist.source).contains)
            guard !hit.isEmpty else { continue }
            let labels = hit.map(\.label).joined(separator: "·")
            return String(ui: "인텔리전트 재생 목록 ‘\(playlist.name)’의 조건이 \(labels)에 걸릴 수 있어 아직 쓰지 않으니 rekordbox에서 직접 고치거나 이 칸 초안을 버리세요")
        }
        return nil
    }
}
