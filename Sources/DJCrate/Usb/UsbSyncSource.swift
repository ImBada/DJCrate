import CryptoKit
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// USB 동기화 원본만 합치고 iTunes ID는 rekordbox 편집 대상에 넣지 않는다.
struct UsbSyncSource: Sendable, Equatable {
    static let rekordboxSelectionID = UsbSyncSourceNode.rekordboxSelectionID
    static let iTunesSelectionID = UsbSyncSourceNode.iTunesSelectionID

    var layout: PlaylistLayout
    var rekordbox: PlaylistLayout
    var iTunes: PlaylistLayout
    /// 목록 옆에 보일 알림(잇지 못한 곡이 있는 iTunes 목록). 동기화를 막지 않는다
    var notices: [String: String]
    /// iTunes 목록 ID → 잇지 못한 곡. rekordbox처럼 이 곡만 빼고 동기화하고 넣지 못한 곡으로 알린다
    var unlinked: [String: [SyncedITunesLibrary.Unlinked]] = [:]
    /// 행이 없어도 읽기 실패와 정상적인 빈 원본을 구분한다.
    var iTunesStatus: ITunesLibrarySnapshot.Status

    /// 선택 전용 머리는 USB의 실제 폴더가 아니다. 원본 파일에는 실제 목록 ID만 전달한다.
    var nativeNodes: [UsbSyncSourceNode] {
        Self.nativeNodes(layout)
    }

    /// - master: rekordbox 폴더의 masterPlaylists6.xml. 같은 Id·ParentId·Attribute·Lib_Type의 NODE가 있는 목록만
    ///   Timestamp를 싣는다(USB 선택 파일에 그대로 옮긴다). 맞지 않는 목록은 체크해 쓸 때 막힌다.
    static func nativeNodes(_ layout: PlaylistLayout, master: [MasterPlaylistsXML.Node] = []) -> [UsbSyncSourceNode] {
        let byKey = Dictionary(master.map { ("\($0.libType):\($0.id)", $0) }, uniquingKeysWith: { first, _ in first })
        func encoded(_ id: String) -> (library: Int, id: String)? {
            if id == PlaylistLayout.root { return nil }
            if id.hasPrefix("itunes:") {
                return UInt64(id.dropFirst("itunes:".count), radix: 16).map { (1, String($0, radix: 16, uppercase: true)) }
            }
            return MasterPlaylistsXML.hex(id).map { (0, $0) }
        }
        return layout.outline.map { item in
            var timestamp: Int64?
            if let key = encoded(item.id), let node = byKey["\(key.library):\(key.id)"],
               node.parentID == (encoded(item.parentID).map(\.id) ?? "0"), node.attribute == (item.isFolder ? 1 : 0) {
                timestamp = node.timestamp
            }
            return UsbSyncSourceNode(id: item.id, parentID: item.parentID == PlaylistLayout.root ? nil : item.parentID,
                                     isFolder: item.isFolder, timestamp: timestamp)
        }
    }

    /// 체크하거나 부분 체크로 쓸 목록 중 masterPlaylists6.xml에서 찾지 못한 것이 있는지
    static func lacksMasterNode(_ nodes: [UsbSyncSourceNode], selection: ITunesSyncSelection) -> Bool {
        let selectionNodes: [ITunesSyncSelection.Node] = [
            .init(id: rekordboxSelectionID, parentID: "0", isFolder: true), .init(id: iTunesSelectionID, parentID: "0", isFolder: true),
        ] + nodes.map { node in
            .init(id: node.id, parentID: node.parentID ?? (node.id.hasPrefix("itunes:") ? iTunesSelectionID : rekordboxSelectionID),
                  isFolder: node.isFolder)
        }
        let expanded = selection.expandedIDs(in: selectionNodes)
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var written = Set<String>()
        for id in expanded where byID[id] != nil {
            var next: String? = id
            while let current = next, let node = byID[current], written.insert(current).inserted { next = node.parentID }
        }
        return written.contains { byID[$0]?.timestamp == nil }
    }

    static func make(rekordbox raw: PlaylistLayout, iTunes library: SyncedITunesLibrary) -> Self {
        let rekordbox = UsbSyncPlan.source(raw)
        var entries: [(item: PlaylistLayout.Item, seq: Int)] = []
        var notices: [String: String] = [:]
        var unlinked: [String: [SyncedITunesLibrary.Unlinked]] = [:]
        func append(_ nodes: [SyncedITunesLibrary.Node], parent: String) {
            for (position, node) in nodes.enumerated() {
                // 폴더의 곡 모음은 중복을 뺀 값이라 USB 목록의 순서로 쓰지 않는다.
                let tracks: [PlaylistEntry] = node.isFolder ? [] : zip(node.trackNumbers, node.trackIDs).map {
                    PlaylistEntry(trackNo: $0.0, contentID: $0.1)
                }
                let item = PlaylistLayout.Item(id: node.id, name: node.name, parentID: parent,
                                               isFolder: node.isFolder, entries: tracks)
                entries.append((item: item, seq: position))
                if let children = node.children {
                    append(children, parent: node.id)
                } else if !node.unlinked.isEmpty {
                    // rekordbox도 동기화할 수 없는 곡은 내보내기 기록에 남기고 나머지를 동기화했다(2026-10-08 실제 동기화)
                    unlinked[node.id] = node.unlinked
                    notices[node.id] = String(ui: "rekordbox 컬렉션에 잇지 못한 \(node.unlinked.count)곡은 USB에 넣지 않습니다. 컬렉션 등록과 음원 경로를 확인하세요")
                }
            }
        }
        if library.status == .ready || library.status == .stale {
            append(library.tree, parent: PlaylistLayout.root)
        }
        let iTunes = PlaylistLayout(entries)
        let rootOffset = rekordbox.childIDs(of: PlaylistLayout.root).count
        let combined = [rekordbox, iTunes].enumerated().flatMap { sourceIndex, source in
            source.outline.map { item in
                let position = source.childIDs(of: item.parentID).firstIndex(of: item.id) ?? 0
                let offset = item.parentID == PlaylistLayout.root && sourceIndex == 1 ? rootOffset : 0
                return (item: item, seq: position + offset)
            }
        }
        return Self(layout: PlaylistLayout(combined), rekordbox: rekordbox, iTunes: iTunes, notices: notices, unlinked: unlinked,
                    iTunesStatus: library.status)
    }

    /// 선택한 iTunes 목록의 잇지 못한 곡을 곡 단위 막힘으로. 같은 음원은 여러 목록에 있어도 한 번만 센다.
    /// 막힘 대상은 경로를 남기지 않게 음원 경로의 해시로 적는다
    func skippedITunesTracks(selection: ITunesSyncSelection) -> [UsbBlock] {
        var seen = Set<String>(), blocks: [UsbBlock] = []
        for item in UsbSyncPlan.selectedLayout(layout, selection: selection).outline where item.holdsTracks {
            for (position, entry) in (unlinked[item.id] ?? []).enumerated() {
                let target = entry.key.map { "itunes:" + Self.digest($0) } ?? "itunes:\(item.id)#\(position + 1)"
                guard seen.insert(target).inserted else { continue }
                blocks.append(UsbBlock(code: "iTunes." + entry.reason.rawValue, scope: .track(target), message: entry.reason.message))
            }
        }
        return blocks
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// 로컬 곡을 USB에 넣을 수 없는 까닭(앱이 아는 것만. 음원 없음·분석 파일 없음은 USB 쓰기 계획이 곡마다 알린다)
    enum LocalSkip: Sendable {
        case missing, staged, usb, streaming

        var block: (code: String, message: String) {
            switch self {
            case .missing:
                ("syncSourceTrackMissing", String(ui: "로컬 라이브러리에서 찾지 못한 곡이라 USB에 넣지 않았습니다. 라이브러리를 새로고침한 뒤 다시 동기화하세요"))
            case .staged:
                ("syncTrackStaged", String(ui: "아직 rekordbox 컬렉션에 넣지 않은 곡이라 USB에 넣지 않았습니다. rekordbox에 쓴 뒤 다시 동기화하세요"))
            case .usb:
                ("syncTrackOnUsbOnly", String(ui: "USB에만 있는 곡이라 다시 넣지 않았습니다. 로컬 컬렉션의 곡으로 목록을 고친 뒤 다시 동기화하세요"))
            case .streaming:
                ("streamingTrack", String(ui: "스트리밍 곡이라 USB에 넣지 않았습니다. 로컬 음원으로 바꾼 뒤 다시 동기화하세요"))
            }
        }
    }

    /// 선택한 목록 중 USB에 넣을 수 없는 로컬 곡 → 곡 단위 막힘. 동기화는 이 곡을 목록에서 빼고 나머지를 쓴다
    static func skippedLocalTracks(_ selected: PlaylistLayout, kind: (String) -> LocalSkip?) -> [String: UsbBlock] {
        var result: [String: UsbBlock] = [:]
        for id in selected.outline.filter(\.holdsTracks).flatMap(\.trackIDs) where result[id] == nil {
            guard let skip = kind(id) else { continue }
            let block = skip.block
            result[id] = UsbBlock(code: block.code, scope: .track(id), message: block.message)
        }
        return result
    }

    /// 그룹 머리나 사라진 iTunes ID도 선택의 출처이므로 빈 미러로 바꾸지 않는다.
    func blockReason(selection: ITunesSyncSelection) -> String? {
        let expanded = selection.expandedIDs(in: Self.nodes(layout))
        let selectsITunes = expanded.contains(Self.iTunesSelectionID) || expanded.contains { $0.hasPrefix("itunes:") }
        if selectsITunes, iTunesStatus != .ready, iTunesStatus != .stale {
            return String(ui: "선택한 iTunes 원본을 아직 읽지 못했습니다. iTunes 목록을 새로고침한 뒤 동기화하세요")
        }
        let available = Set(Self.nodes(layout).map(\.id)).union(["0"])
        guard selection.selectedIDs.isSubset(of: available) else {
            return String(ui: "USB에서 선택했던 원본 목록을 찾지 못했습니다. iTunes와 rekordbox 목록을 다시 읽거나 rekordbox에서 USB 동기화 선택을 확인하세요")
        }
        // 잇지 못한 곡이 있는 목록은 막지 않는다. 그 곡만 빼고 넣지 못한 곡으로 알린다(rekordbox와 같다, `skippedITunesTracks`)
        return nil
    }

    /// 원본별 전체 선택도 새 하위 목록을 따라가게 한다. 선택용 부모는 실제 USB 폴더에 들어가지 않는다.
    static func nodes(_ layout: PlaylistLayout) -> [ITunesSyncSelection.Node] {
        let groups: [ITunesSyncSelection.Node] = [
            .init(id: rekordboxSelectionID, parentID: "0", isFolder: true),
            .init(id: iTunesSelectionID, parentID: "0", isFolder: true),
        ]
        return groups + layout.outline.map { item in
            let root = item.id.hasPrefix("itunes:") ? iTunesSelectionID : rekordboxSelectionID
            return .init(id: item.id, parentID: item.parentID == PlaylistLayout.root ? root : item.parentID,
                         isFolder: item.isFolder)
        }
    }
}
