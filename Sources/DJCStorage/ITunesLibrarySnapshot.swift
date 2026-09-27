import DJCDomain
import Foundation
import RekordboxKit

/// DB 스냅샷 옆에 보관하는 iTunes 목록 사본. Music·rekordbox에는 쓰지 않는다.
public struct ITunesLibrarySnapshot: Codable, Sendable {
    public struct Playlist: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var parentID: String?
        public var isFolder: Bool
        /// 로컬 위치가 없는 곡도 nil로 남겨 누락 개수를 알린다.
        public var paths: [String?]

        public init(id: String, name: String, parentID: String? = nil, isFolder: Bool = false, paths: [String?] = []) {
            self.id = id; self.name = name; self.parentID = parentID; self.isFolder = isFolder; self.paths = paths
        }
    }

    public enum Status: String, Codable, Sendable {
        case ready, stale, notCaptured, unavailable
        public var message: String? {
            switch self {
            case .ready: nil
            case .stale: String(ui: "iTunes 목록 갱신에 실패해 이전 사본을 표시합니다. Music 접근 권한과 rekordbox의 iTunes 읽기 설정을 확인한 뒤 새로고침하세요.")
            case .notCaptured: String(ui: "새 스냅샷을 뜨고 있습니다")
            case .unavailable: String(ui: "iTunes 목록을 읽지 못했으니 Music 접근 권한과 rekordbox의 iTunes 읽기 설정을 확인한 뒤 새로고침하세요.")
            }
        }
    }

    public var version = 1
    public var playlists: [Playlist]
    public var status: Status
    public var unavailablePlaylistCount: Int
    /// 선택 창과 이후 선택 변경에 쓰는 전체 보관함. 옛 사본에는 없다.
    public var sourcePlaylists: [Playlist]?
    public var selectedIDs: Set<String>?
    /// 선택 창을 연 뒤 외부에서 동기화 선택을 바꿨는지 검사할 원문.
    public var syncData: Data?
    public var availablePlaylists: [Playlist] { sourcePlaylists ?? playlists }
    public var selectionNodes: [ITunesSyncSelection.Node] {
        availablePlaylists.map { .init(id: $0.id, parentID: $0.parentID, isFolder: $0.isFolder) }
    }
    public var initialSelection: ITunesSyncSelection {
        // 옛 사본의 조상 폴더를 전체 선택으로 오해하지 않는다.
        var ids = selectedIDs ?? Set(playlists.filter { !$0.isFolder }.map(\.id))
        if let syncData, let parsed = try? RekordboxITunesSelection.parse(syncData),
           parsed.nodes.contains(where: { $0.id == "0" && $0.isSelected }) { ids.insert("0") }
        return ITunesSyncSelection(selectedIDs: ids)
    }

    public init(playlists: [Playlist] = [], status: Status = .ready, unavailablePlaylistCount: Int = 0,
                sourcePlaylists: [Playlist]? = nil, selectedIDs: Set<String>? = nil) {
        self.playlists = playlists; self.status = status; self.unavailablePlaylistCount = unavailablePlaylistCount
        self.sourcePlaylists = sourcePlaylists; self.selectedIDs = selectedIDs
    }

    public static func url(for database: URL) -> URL { database.appendingPathExtension("itunes.json") }

    public func save(for database: URL) throws {
        let destination = Self.url(for: database)
        let pending = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).itunes.part")
        defer { try? FileManager.default.removeItem(at: pending) }
        try JSONEncoder().encode(self).write(to: pending, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard (try FileManager.default.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType) == .typeRegular else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: pending)
        } else {
            try FileManager.default.moveItem(at: pending, to: destination)
        }
    }

    public static func load(for database: URL) -> Self {
        let file = url(for: database)
        guard FileManager.default.fileExists(atPath: file.path) else { return Self(status: .notCaptured) }
        do {
            let snapshot = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            guard snapshot.version == 1 else { return Self(status: .unavailable) }
            try validate(snapshot.playlists)
            if let source = snapshot.sourcePlaylists { try validate(source) }
            return snapshot
        } catch { return Self(status: .unavailable) }
    }

    /// 동기화 ID로만 고르고, 그 목록을 찾아갈 수 있도록 현재 조상 폴더를 함께 남긴다.
    public static func select(_ selection: RekordboxITunesSelection, from source: [Playlist]) throws -> Self {
        try select(ids: selection.selectedIDs, from: source)
    }

    public func applying(_ selection: ITunesSyncSelection) throws -> Self {
        var result = try Self.select(ids: selection.expandedIDs(in: selectionNodes), from: availablePlaylists)
        result.status = status
        result.selectedIDs = selection.selectedIDs
        result.syncData = syncData
        return result
    }

    public func applyingRekordboxSelection(_ data: Data) throws -> Self {
        var result = try Self.select(RekordboxITunesSelection.parse(data), from: availablePlaylists)
        result.status = status
        result.syncData = data
        return result
    }

    private static func select(ids: Set<String>, from source: [Playlist]) throws -> Self {
        let normalized = try source.map { playlist -> Playlist in
            guard let id = RekordboxITunesSelection.normalizedID(playlist.id) else { throw RekordboxITunesSelection.ParseError.invalidFile }
            var result = playlist
            result.id = id
            if let parent = playlist.parentID, parent != "0" {
                guard let normalizedParent = RekordboxITunesSelection.normalizedID(parent) else { throw RekordboxITunesSelection.ParseError.invalidFile }
                result.parentID = normalizedParent
            } else { result.parentID = nil }
            return result
        }
        try validate(normalized)
        let byID = Dictionary(uniqueKeysWithValues: normalized.map { ($0.id, $0) })
        var included = ids.intersection(byID.keys)
        for id in Array(included) {
            var parent = byID[id]?.parentID
            while let ancestor = parent {
                included.insert(ancestor)
                parent = byID[ancestor]?.parentID
            }
        }
        return Self(playlists: normalized.filter { included.contains($0.id) },
                    unavailablePlaylistCount: ids.subtracting(byID.keys).count,
                    sourcePlaylists: normalized, selectedIDs: ids)
    }

    static func validate(_ playlists: [Playlist]) throws {
        let byID = Dictionary(grouping: playlists, by: \.id)
        guard byID.values.allSatisfy({ $0.count == 1 }), playlists.allSatisfy({
            $0.id != "0" && RekordboxITunesSelection.normalizedID($0.id) == $0.id
        }) else { throw RekordboxITunesSelection.ParseError.invalidFile }
        for playlist in playlists {
            var seen: Set<String> = [playlist.id]
            var parent = playlist.parentID
            while let id = parent {
                guard seen.insert(id).inserted, let ancestor = byID[id]?.first, ancestor.isFolder else {
                    throw RekordboxITunesSelection.ParseError.invalidFile
                }
                parent = ancestor.parentID
            }
        }
    }

    /// rekordbox가 XML 읽기로 설정된 경우 같은 보관함 XML에서 폴더·순서를 읽는다.
    public static func parseLibraryXML(_ data: Data) throws -> [Playlist] {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let root = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any], format == .xml,
              let tracks = root["Tracks"] as? [String: [String: Any]], let lists = root["Playlists"] as? [[String: Any]] else {
            throw RekordboxITunesSelection.ParseError.invalidFile
        }
        return try lists.filter { $0["Master"] as? Bool != true }.map { raw in
            guard let id = raw["Playlist Persistent ID"] as? String, let name = raw["Name"] as? String,
                  raw["Playlist Items"] == nil || raw["Playlist Items"] is [[String: Any]] else {
                throw RekordboxITunesSelection.ParseError.invalidFile
            }
            let paths = try (raw["Playlist Items"] as? [[String: Any]] ?? []).map { item -> String? in
                guard let trackID = item["Track ID"] as? Int else { throw RekordboxITunesSelection.ParseError.invalidFile }
                guard let location = tracks[String(trackID)]?["Location"] as? String,
                      let url = URL(string: location), url.isFileURL,
                      url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { return nil }
                return url.path
            }
            return Playlist(id: id, name: name, parentID: raw["Parent Persistent ID"] as? String,
                            isFolder: raw["Folder"] as? Bool == true, paths: paths)
        }
    }
}
