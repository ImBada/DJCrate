import Foundation
import iTunesLibrary
import RekordboxKit

/// rekordbox의 동기화 선택을 기준으로 같은 읽기 방식(Framework 또는 XML)을 사용한다.
public enum RekordboxITunesReader {
    public static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Pioneer/rekordbox6/rekordbox3.settings")
    }

    public static func capture(directory: URL = LibrarySnapshot.rekordboxDirectory, settings: URL = settingsURL) -> ITunesLibrarySnapshot {
        do {
            let sync = directory.appending(path: "playlists3.sync")
            let selectionData = FileManager.default.fileExists(atPath: sync.path) ? try stableRead(sync) : nil
            let selection = try RekordboxITunesSelection.parse(selectionData ?? Data("<SYNC_ITUNES_PLAYLIST><PLAYLISTS/></SYNC_ITUNES_PLAYLIST>".utf8))
            let settingsData = try stableRead(settings)
            let config = try configuration(settingsData)
            let playlists: [ITunesLibrarySnapshot.Playlist]
            switch config.method {
            case "1": playlists = try frameworkPlaylists()
            case "0":
                guard let path = config.xmlPath, !path.isEmpty else { throw RekordboxITunesSelection.ParseError.invalidFile }
                playlists = try ITunesLibrarySnapshot.parseLibraryXML(stableRead(URL(filePath: path)))
            default: throw RekordboxITunesSelection.ParseError.invalidFile
            }
            let snapshot = try ITunesLibrarySnapshot.select(selection, from: playlists)
            // 읽는 동안 동기화 선택·읽기 설정이 바뀌었으면 섞인 결과를 쓰지 않는다.
            let latestSelection = FileManager.default.fileExists(atPath: sync.path) ? try Data(contentsOf: sync) : nil
            guard selectionData == latestSelection, settingsData == (try Data(contentsOf: settings)) else {
                throw RekordboxITunesSelection.ParseError.invalidFile
            }
            return snapshot
        } catch { return ITunesLibrarySnapshot(status: .unavailable) }
    }

    static func stableRead(_ url: URL) throws -> Data {
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let data = try Data(contentsOf: url)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        guard before[.size] as? Int == after[.size] as? Int,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date else {
            throw RekordboxITunesSelection.ParseError.invalidFile
        }
        return data
    }

    static func frameworkPlaylists() throws -> [ITunesLibrarySnapshot.Playlist] {
        let library = try ITLibrary(apiVersion: "1.0")
        return library.allPlaylists.filter { !$0.isPrimary }.map { playlist in
            let id = String(playlist.persistentID.uint64Value, radix: 16, uppercase: true)
            let parent = playlist.parentID.map { String($0.uint64Value, radix: 16, uppercase: true) }
            return ITunesLibrarySnapshot.Playlist(id: id, name: playlist.name, parentID: parent,
                isFolder: playlist.kind == .folder,
                paths: playlist.kind != .folder ? playlist.items.map { item in
                    guard let url = item.location, url.isFileURL else { return nil }
                    return url.path
                } : [])
        }
    }

    static func configuration(_ data: Data) throws -> (method: String, xmlPath: String?) {
        let reader = SettingsReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.hasRoot, let method = reader.values["MusicAppLoadingType"] else {
            throw RekordboxITunesSelection.ParseError.invalidFile
        }
        return (method, reader.values["itunesLibraryFile"])
    }

    private final class SettingsReader: NSObject, XMLParserDelegate {
        var depth = 0
        var hasRoot = false
        var values: [String: String] = [:]
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            defer { depth += 1 }
            if depth == 0 { hasRoot = name == "PROPERTIES" }
            if depth == 1, name == "VALUE", let key = attributes["name"], ["MusicAppLoadingType", "itunesLibraryFile"].contains(key) {
                values[key] = attributes["val"]
            }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { depth -= 1 }
    }
}
