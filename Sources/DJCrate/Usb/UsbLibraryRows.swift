import DJCDomain
import Foundation
import RekordboxKit

/// USB 곡 → 목록 줄(읽기 전용). 곡 ID는 로컬 곡과 겹치지 않게 `usb:<볼륨키>:<content_id>`로 짓는다.
/// 분석·아트워크 경로는 비운다: 목록의 미리 보기·썸네일은 로컬 share를 기준으로 찾아서, USB 경로를 넣으면 로컬의 다른 파일을 읽는다.
enum UsbLibraryRows {
    static let idPrefix = "usb:"

    static func trackID(volumeKey: String, contentID: Int) -> String { "\(idPrefix)\(volumeKey):\(contentID)" }

    /// 컬렉션: content_id 순
    static func collection(library: UsbLibrary, volumeKey: String, mountPoint: String, badges: [Int: UsbSyncStatus]) -> [TrackRow] {
        let names = Names(library)
        return library.tracks.map { row($0, names: names, volumeKey: volumeKey, mountPoint: mountPoint, badge: badges[$0.id]) }
    }

    /// 재생 목록: 항목 순서 그대로. 같은 곡이 여러 번 들어 있어도 줄마다 따로 고르게 줄 ID를 곡과 그 곡의 몇 번째 출현으로 짓는다
    /// (로컬 목록과 같다). 자리로 지으면 순서를 바꿔도 ID가 그대로라 선택이 옮긴 곡을 따라가지 않고 표가 줄을 다시 놓지 않는다(#240)
    static func playlist(_ id: Int, library: UsbLibrary, volumeKey: String, mountPoint: String,
                         badges: [Int: UsbSyncStatus]) -> [TrackRow] {
        guard let playlist = library.playlists.first(where: { $0.id == id }) else { return [] }
        let names = Names(library)
        let tracks = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var occurrences: [Int: Int] = [:]
        return entries(of: playlist).enumerated().compactMap { position, contentID in
            guard let track = tracks[contentID] else { return nil }
            let occurrence = occurrences[contentID, default: 0]
            occurrences[contentID] = occurrence + 1
            var row = row(track, names: names, volumeKey: volumeKey, mountPoint: mountPoint, badge: badges[contentID])
            row.playlistOccurrence = .init(id: "\(idPrefix)\(volumeKey):pl\(id):\(contentID):\(occurrence)", number: position + 1)
            return row
        }
    }

    /// 보일 항목: OneLibrary에 있으면 그 순서(합친 모델이 앞세우는 쪽), 없으면 Device Library
    static func entries(of playlist: UsbPlaylist) -> [Int] {
        playlist.presentIn.contains(.oneLibrary) ? playlist.entries[.oneLibrary] ?? [] : playlist.entries[.deviceLibrary] ?? []
    }

    /// 이름 표(아티스트·앨범·장르·키)
    struct Names {
        var artists: [Int: String]
        var albums: [Int: UsbAlbum]
        var genres: [Int: String]
        var keys: [Int: String]

        init(_ library: UsbLibrary) {
            func table(_ rows: [UsbNamedRow]) -> [Int: String] {
                Dictionary(rows.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            }
            artists = table(library.artists)
            albums = Dictionary(library.albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            genres = table(library.genres)
            keys = table(library.keys)
        }
    }

    static func row(_ track: UsbTrack, names: Names, volumeKey: String, mountPoint: String, badge: UsbSyncStatus?) -> TrackRow {
        let id = trackID(volumeKey: volumeKey, contentID: track.id)
        let album = track.albumID.flatMap { names.albums[$0] }
        let model = Track(
            id: id, uuid: id, title: track.title, artist: track.artistID.flatMap { names.artists[$0] }, album: album?.name,
            albumArtist: album?.artistID.flatMap { names.artists[$0] }, genre: track.genreID.flatMap { names.genres[$0] },
            composer: track.composerID.flatMap { names.artists[$0] }, releaseYear: track.releaseYear > 0 ? track.releaseYear : nil,
            trackNumber: track.trackNo > 0 ? track.trackNo : nil, key: track.keyID.flatMap { names.keys[$0] },
            bpm: track.bpmx100 > 0 ? Double(track.bpmx100) / 100 : nil, lengthSeconds: track.lengthSeconds,
            folderPath: mountPoint + track.path, comment: track.comment, importedOn: track.dateAdded.isEmpty ? nil : track.dateAdded,
            analysisDataPath: nil, imagePath: nil, isDeleted: false, bitrateKbps: track.bitrate,
            // 거르기(평점·곡 색)도 로컬 곡과 같게 한다. USB 색 번호 1~8은 rekordbox 색과 같은 순서다(읽기 전용)
            rating: track.rating, colorID: track.colorID > 0 ? String(track.colorID) : nil)
        var row = TrackRow(track: model, cues: [], playCount: track.djPlayCount)
        row.usbSync = badge
        return row
    }
}

/// 곡마다 로컬 곡과 견준 갱신 상태
enum UsbSyncBadges {
    /// 로컬 키를 모르면(스냅샷을 아직 읽지 않음) 배지를 달지 않는다
    static func compute(library: UsbLibrary, local: LocalLibraryKeys?) -> [Int: UsbSyncStatus] {
        evaluate(library: library, local: local).badges
    }

    /// 배지와 로컬 짝(USB content_id → 로컬 ContentID, 짝이 하나인 곡만). 동기화·큐 가져오기가 짝을 쓴다
    static func evaluate(library: UsbLibrary, local: LocalLibraryKeys?) -> (badges: [Int: UsbSyncStatus], matches: [Int: String]) {
        guard let local else { return ([:], [:]) }
        // 쓰기 계획(`UsbEditPlanner.localPairs`)과 같은 규칙: 로컬 행의 MasterDBID·MasterSongID가 USB 곡의 값과 같은 행 중에서
        // 고른다. 이 라이브러리 DBID로 고르면 다른 라이브러리에서 가져온 곡을 계획은 잇고 고아 판정은 빼서 더하기·빼기가 번갈아 생긴다.
        struct Identity: Hashable { var database: Int64; var song: Int64 }
        let byIdentity = Dictionary(grouping: local.tracks) {
            Identity(database: local.masterDBID(of: $0.contentID), song: UsbLibraryBuilder.sqliteInteger($0.masterSongID) ?? 0)
        }
        var result: [Int: UsbSyncStatus] = [:]
        var matches: [Int: String] = [:]
        for track in library.tracks {
            let key = UsbTrackKey(masterDbId: track.masterDbId, masterContentId: track.masterContentId, fileName: track.fileName)
            let family = byIdentity[Identity(database: track.masterDbId, song: track.masterContentId)] ?? []
            guard let contentID = UsbTrackMatch.match(key, localDBID: track.masterDbId, local: family) else {
                result[track.id] = .missingLocal
                continue
            }
            matches[track.id] = contentID
            let counters = local.counters[contentID]
            let modified = max(track.hasModified, track.deviceFields.values.compactMap(\.hasModified).max() ?? 0)
            result[track.id] = UsbSyncStatus.compare(localInfo: counters?.information, localAnalysis: counters?.analysis,
                                                     localCue: counters?.cue, usbInfo: track.informationUpdateCount,
                                                     usbAnalysis: track.analysisDataUpdateCount, usbCue: track.cueUpdateCount,
                                                     hasModified: modified, hasCueRows: false)
        }
        return (result, matches)
    }
}

/// 갱신 상태 칸 글자
enum UsbSyncText {
    static func text(_ status: UsbSyncStatus?) -> String {
        switch status {
        case nil: ""
        case .upToDate: String(ui: "최신")
        case .localNewer: String(ui: "갱신 가능")
        case .deviceModified: String(ui: "기기에서 고침")
        case .missingLocal: String(ui: "로컬에 없음")
        }
    }
}

extension TrackRow {
    /// USB에서 읽은 곡(읽기 전용: 편집·쓰기·덱 불러오기를 막는다)
    var isUsb: Bool { track.id.hasPrefix(UsbLibraryRows.idPrefix) }
    var usbSyncText: String { UsbSyncText.text(usbSync) }
}
