import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 선택한 로컬 트리를 USB 편집으로 만든다. rekordbox처럼 선택에서 뺀 USB 목록은 지우지 않고 연결만 끊는다.
struct UsbSyncPlan: Sendable {
    var edits: [UsbLibraryEdit]
    var layout: PlaylistLayout
    var trackIDs: [String]
    /// 동기화에 잇지 않고 USB에 그대로 남는 목록·폴더 수(rekordbox 장치 트리에서 회색)
    var unlinkedPlaylistCount: Int
    /// 동기화 뒤 USB의 어느 목록에도 없는 곡. rekordbox처럼 확인을 받은 뒤에만 USB에서 뺀다.
    var orphanTrackIDs: [Int] = []
    /// 원본 목록 ID → 기존 USB 목록 또는 같은 묶음에서 만든 목록
    var playlistRefs: [String: PlaylistRef] = [:]

    static func nodes(_ layout: PlaylistLayout) -> [ITunesSyncSelection.Node] {
        UsbSyncSource.nodes(layout)
    }

    /// 미반영 목록과 인텔리전트 목록은 기존 USB 내보내기와 같은 범위로 뺀다.
    static func source(_ layout: PlaylistLayout) -> PlaylistLayout {
        let items = layout.outline.filter { !$0.isNew && !$0.isSmart }
        let ids = Set(items.map(\.id))
        return PlaylistLayout(items.filter { $0.parentID == PlaylistLayout.root || ids.contains($0.parentID) }.map { item in
            (item: item, seq: layout.childIDs(of: item.parentID).firstIndex(of: item.id) ?? 0)
        })
    }

    static func selectedLayout(_ source: PlaylistLayout, selection: ITunesSyncSelection) -> PlaylistLayout {
        let selected = selection.expandedIDs(in: nodes(source))
        var included = selected
        for id in selected { included.formUnion(source.ancestors(of: id).map(\.id)) }
        return PlaylistLayout(source.outline.filter { included.contains($0.id) }.map { item in
            (item: item, seq: source.childIDs(of: item.parentID).firstIndex(of: item.id) ?? 0)
        })
    }

    static func usbLayout(_ library: UsbLibrary) -> PlaylistLayout {
        PlaylistLayout(library.playlists.map { playlist in
            let entries = UsbLibraryRows.entries(of: playlist).enumerated().map {
                PlaylistEntry(trackNo: $0.offset + 1, contentID: String($0.element))
            }
            let item = PlaylistLayout.Item(id: String(playlist.id), name: playlist.name,
                                           parentID: playlist.parentID == 0 ? PlaylistLayout.root : String(playlist.parentID),
                                           isFolder: playlist.attribute == 1, isSmart: playlist.attribute == 4, entries: entries)
            return (item: item, seq: playlist.sortOrder[.oneLibrary] ?? playlist.sortOrder[.deviceLibrary] ?? 0)
        })
    }

    static func path(_ item: PlaylistLayout.Item, in layout: PlaylistLayout) -> [String] {
        (layout.ancestors(of: item.id).map(\.name) + [item.name]).map(UsbLayout.nfc)
    }

    static func initialSelection(source: PlaylistLayout, library: UsbLibrary) -> ITunesSyncSelection {
        let usb = usbLayout(library)
        let paths = Set(usb.outline.filter { !$0.isFolder && !$0.isSmart }.map { path($0, in: usb) })
        return ITunesSyncSelection(selectedIDs: Set(source.outline.filter { !$0.isFolder && paths.contains(path($0, in: source)) }.map(\.id)))
    }

    /// 쓴 뒤 새 목록 ID도 경로로 찾는다. 같은 경로가 여럿이면 짝을 저장하지 않는다.
    static func bindings(source: PlaylistLayout, target: PlaylistLayout, library: UsbLibrary) -> [String: UsbSyncPlaylistBinding] {
        let usb = usbLayout(library)
        let byPath = Dictionary(grouping: usb.outline, by: { path($0, in: usb) })
        var result: [String: UsbSyncPlaylistBinding] = [:]
        for item in target.outline {
            let components = path(item, in: source)
            guard let candidates = byPath[components], candidates.count == 1,
                  let match = candidates.first, match.isFolder == item.isFolder, !match.isSmart, let id = Int(match.id) else { continue }
            result[item.id] = UsbSyncPlaylistBinding(usbID: id, path: components, isFolder: item.isFolder)
        }
        return result
    }

    /// 읽기 실패를 정상적인 빈 선택으로 계획하기 전에 막는다.
    static func build(source: UsbSyncSource, selection: ITunesSyncSelection, library: UsbLibrary,
                      matches: [Int: String], badges: [Int: UsbSyncStatus], bindings: [String: UsbSyncPlaylistBinding],
                      newKey: () -> String = { "sync-" + UUID().uuidString.lowercased() }) throws -> UsbSyncPlan {
        if let reason = source.blockReason(selection: selection) { throw PlaylistLayout.Blocked(reason) }
        return try build(source: source.layout, selection: selection, library: library, matches: matches,
                         badges: badges, bindings: bindings, newKey: newKey)
    }

    static func build(source: PlaylistLayout, selection: ITunesSyncSelection, library: UsbLibrary,
                      matches: [Int: String], badges: [Int: UsbSyncStatus], bindings: [String: UsbSyncPlaylistBinding],
                      newKey: () -> String = { "sync-" + UUID().uuidString.lowercased() }) throws -> UsbSyncPlan {
        let desired = selectedLayout(source, selection: selection)
        let desiredPaths = Dictionary(grouping: desired.outline, by: { path($0, in: desired) })
        guard !desiredPaths.values.contains(where: { $0.count > 1 }) else {
            throw PlaylistLayout.Blocked(String(ui: "같은 폴더에 이름이 같은 재생 목록이 있습니다. 이름을 다르게 바꾼 뒤 동기화하세요"))
        }
        var working = usbLayout(library)
        guard working.outline.count == working.items.count else {
            throw PlaylistLayout.Blocked(String(ui: "USB 재생 목록의 부모 관계가 맞지 않습니다. rekordbox에서 USB를 확인한 뒤 다시 동기화하세요"))
        }
        // 선택에서 뺀 목록이 남으므로 USB에는 이름이 같은 목록이 있을 수 있다. 이름으로 이어야 할 때만 모호함을 막는다.
        let byPath = Dictionary(grouping: working.outline, by: { path($0, in: working) })
        var refs: [String: PlaylistRef] = [:], retained = Set<String>()
        // 다른 원본에 이어진 USB 목록은 이름이 같아도 이 원본에 잇지 않는다.
        let linked = Set(bindings.map { String($0.value.usbID) })
        for item in desired.outline {
            var match: PlaylistLayout.Item?
            let wanted = path(item, in: desired)
            if let bound = bindings[item.id], let old = working.item(String(bound.usbID)),
               old.isFolder == bound.isFolder, !old.isSmart, path(old, in: working) == wanted {
                match = old
            } else if let candidates = byPath[wanted]?.filter({ bindings[item.id]?.usbID == Int($0.id) || !linked.contains($0.id) }),
                      !candidates.isEmpty {
                // 이름·위치가 바뀐 원본은 rekordbox처럼 새 USB 목록으로 만든다(옛 목록은 남는다).
                // 바뀐 자리에 잇지 않은 USB 목록이 이미 있을 때만 그 목록에 잇는다(rekordbox 동작은 확인하지 않음).
                guard candidates.count == 1 else {
                    throw PlaylistLayout.Blocked(String(ui: "USB의 같은 폴더에 이름이 같은 재생 목록이 있습니다. 이름을 다르게 바꾼 뒤 동기화하세요"))
                }
                match = candidates.first
            }
            if let match {
                guard match.isFolder == item.isFolder, !match.isSmart, retained.insert(match.id).inserted else {
                    throw PlaylistLayout.Blocked(String(ui: "USB에서 같은 이름의 폴더와 재생 목록을 구분할 수 없습니다. 이름을 다르게 바꾼 뒤 동기화하세요"))
                }
                refs[item.id] = .id(match.id)
            } else {
                refs[item.id] = .new(newKey())
            }
        }
        var edits: [UsbLibraryEdit] = []
        func append(_ edit: PlaylistEdit) throws {
            let previousCount = edit.destination.map { working.childIDs(of: $0 == .root ? PlaylistLayout.root : $0.description).count }
            try working.apply(edit)
            // USB는 새 목록을 부모의 맨 끝에 만든다. 로컬 초안 트리의 맨 위 규칙과 다르다.
            if case let .create(key, _, _, _) = edit, let previousCount {
                try working.apply(.reorder(playlist: .new(key), index: previousCount))
            }
            edits.append(.playlist(edit: edit))
        }
        // 옮길 항목을 먼저 맨 위로 꺼내 두면 폴더의 부모·자식을 바꾸어도 순환하지 않는다.
        for item in desired.outline {
            guard let ref = refs[item.id], case .id = ref, let old = working.item(ref.description) else { continue }
            let parent = item.parentID == PlaylistLayout.root ? PlaylistRef.root : refs[item.parentID] ?? .root
            let parentID = parent == .root ? PlaylistLayout.root : parent.description
            if old.parentID != parentID, old.parentID != PlaylistLayout.root { try append(.move(playlist: ref, into: .root)) }
        }
        for item in desired.outline {
            guard let ref = refs[item.id] else { continue }
            let parent = item.parentID == PlaylistLayout.root ? PlaylistRef.root : refs[item.parentID] ?? .root
            switch ref {
            case let .new(key): try append(.create(key: key, name: item.name, isFolder: item.isFolder, parent: parent))
            case .id:
                if working.item(ref.description)?.name != item.name { try append(.rename(playlist: ref, name: item.name)) }
                let parentID = parent == .root ? PlaylistLayout.root : parent.description
                if working.item(ref.description)?.parentID != parentID { try append(.move(playlist: ref, into: parent)) }
            case .root: break
            }
        }
        // 선택에서 뺀 USB 목록은 지우지 않는다(rekordbox는 선택 파일의 행만 빼고 장치 목록은 남긴다, 2026-10-08 실험).
        let keep = Set(refs.values.map(\.description))
        let unlinked = working.outline.filter { !keep.contains($0.id) }
        // 이은 목록끼리만 원본 순서로 맞추고, 남은 목록은 그 자리에 둔다.
        let parents = [PlaylistLayout.root] + desired.outline.filter(\.isFolder).map(\.id)
        for parent in parents {
            let usbParent = parent == PlaylistLayout.root ? PlaylistLayout.root : refs[parent]?.description ?? PlaylistLayout.root
            let ordered = desired.childIDs(of: parent).compactMap { refs[$0]?.description }
            let current = working.childIDs(of: usbParent)
            let slots = current.indices.filter { ordered.contains(current[$0]) }
            guard slots.count == ordered.count else { continue }
            var target = current
            for (slot, id) in zip(slots, ordered) { target[slot] = id }
            for (index, id) in target.enumerated() where working.childIDs(of: usbParent).firstIndex(of: id) != index {
                let ref: PlaylistRef = refs.values.first { $0.description == id } ?? .id(id)
                try append(.reorder(playlist: ref, index: index))
            }
        }
        var seen = Set<String>()
        let trackIDs = desired.outline.filter(\.holdsTracks).flatMap(\.trackIDs).filter { seen.insert($0).inserted }
        let usbByLocal = Dictionary(grouping: matches.keys, by: { matches[$0]! })
        guard !trackIDs.contains(where: { (usbByLocal[$0]?.count ?? 0) > 1 }) else {
            throw PlaylistLayout.Blocked(String(ui: "같은 로컬 곡의 USB 사본이 여러 개라 동기화할 수 없습니다. USB의 중복 곡을 정리한 뒤 다시 시도하세요"))
        }
        let missing = trackIDs.filter { usbByLocal[$0] == nil }
        if !missing.isEmpty { edits.append(.addTracks(localContentIDs: missing, playlist: nil)) }
        var refresh: [(parts: Set<UsbRefreshPart>, ids: [Int])] = []
        for id in trackIDs {
            guard let usbID = usbByLocal[id]?.first, case let .localNewer(fields)? = badges[usbID] else { continue }
            var parts = Set<UsbRefreshPart>()
            if fields.contains(.information) { parts.formUnion([.info, .artwork]) }
            if fields.contains(.analysis) { parts.insert(.grid) }
            if fields.contains(.cue) { parts.insert(.cues) }
            guard !parts.isEmpty else { continue }
            if let index = refresh.firstIndex(where: { $0.parts == parts }) { refresh[index].ids.append(usbID) }
            else { refresh.append((parts: parts, ids: [usbID])) }
        }
        edits += refresh.map { .refreshTracks(usbContentIDs: $0.ids, parts: $0.parts) }
        // 동기화 뒤에도 곡을 가리키는 USB 목록: 이은 목록은 원본 곡, 남은 목록은 지금 곡
        var referenced = Set<String>()
        for item in desired.outline where item.holdsTracks {
            guard let ref = refs[item.id] else { continue }
            let expected = item.trackIDs.compactMap { usbByLocal[$0]?.first }.map(String.init)
            referenced.formUnion(expected)
            if expected.count != item.trackIDs.count || working.item(ref.description)?.trackIDs != expected {
                edits.append(.syncPlaylist(playlist: ref, localContentIDs: item.trackIDs))
            }
        }
        for item in unlinked { referenced.formUnion(item.trackIDs) }
        // 재생 기록에 남은 곡은 곡 빼기가 막으므로 지울 곡에 넣지 않는다.
        let history = Set(library.histories.flatMap(\.entries))
        let orphans = library.tracks.map(\.id).filter { !referenced.contains(String($0)) && !history.contains($0) }.sorted()
        return UsbSyncPlan(edits: edits, layout: desired, trackIDs: trackIDs, unlinkedPlaylistCount: unlinked.count,
                           orphanTrackIDs: orphans, playlistRefs: refs)
    }
}
