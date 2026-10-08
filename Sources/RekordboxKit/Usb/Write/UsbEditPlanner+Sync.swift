import DJCDomain
import Foundation

extension UsbEditPlanner {
    struct LocalPairs {
        var matches: [String: [Int]] = [:]
        var ambiguous: Set<String> = []
        var present: Set<String> = []
    }

    /// 같은 곡 ID를 가진 로컬 행을 모두 읽어야 선택하지 않은 행 때문에 생기는 모호함도 알아낼 수 있다
    mutating func localKeys(database: CipherDatabase) throws -> [LocalIdentity: [UsbLocalTrackKey]] {
        if let localTrackKeys { return localTrackKeys }
        var keys: [LocalIdentity: [UsbLocalTrackKey]] = [:]
        try database.query("""
            SELECT ID, MasterSongID, MasterDBID, FileNameL FROM djmdContent WHERE rb_local_deleted = 0
            """) { row in
            guard let id = row.string(0) else { return }
            let song = row.string(1) ?? "", db = row.string(2) ?? ""
            let identity = LocalIdentity(database: UsbLibraryBuilder.sqliteInteger(db) ?? 0,
                                         song: UsbLibraryBuilder.sqliteInteger(song) ?? 0)
            keys[identity, default: []].append(UsbLocalTrackKey(contentID: id, masterSongID: song, fileNameL: row.string(3) ?? ""))
        }
        localTrackKeys = keys
        return keys
    }

    /// 내보내기에서 정제·줄임·번호 꼬리가 붙은 파일 이름도 기존 짝짓기 규칙으로 찾는다
    mutating func localPairs(for localIDs: [String], database: CipherDatabase) throws -> LocalPairs {
        let wanted = Set(localIDs), keys = try localKeys(database: database)
        var result = LocalPairs()
        result.present = Set(keys.values.flatMap { $0.map(\.contentID) })
        for track in working.tracks {
            let identity = LocalIdentity(database: track.masterDbId, song: track.masterContentId)
            let family = keys[identity] ?? []
            guard family.contains(where: { wanted.contains($0.contentID) }) else { continue }
            let usb = UsbTrackKey(masterDbId: track.masterDbId, masterContentId: track.masterContentId, fileName: track.fileName)
            if let id = UsbTrackMatch.match(usb, localDBID: track.masterDbId, local: family) {
                if wanted.contains(id) { result.matches[id, default: []].append(track.id) }
            } else {
                // 한 행만 보면 맞지만 전체 행에서는 짝을 정할 수 없는 곡을 없는 곡과 구분한다
                for key in family where wanted.contains(key.contentID) {
                    if UsbTrackMatch.match(usb, localDBID: track.masterDbId, local: [key]) != nil {
                        result.ambiguous.insert(key.contentID)
                    }
                }
            }
        }
        // 같은 묶음의 새 곡은 원래 로컬 ID를 알고 있다. 파일 이름이 다른 로컬 행과 겹쳐도 추측하지 않는다
        for (localID, usbID) in addedLocalTracks where wanted.contains(localID) && working.tracks.contains(where: { $0.id == usbID }) {
            result.matches[localID] = [usbID]
            result.ambiguous.remove(localID)
        }
        return result
    }

    /// 모든 짝을 확인한 뒤 목록을 통째로 맞춘다. 일부 곡만 들어간 목록으로 덮어쓰거나 조용히 비우지 않는다
    mutating func planSyncPlaylist(_ ref: PlaylistRef, localIDs: [String], into planned: inout UsbPlannedEdit) throws {
        let (playlist, formats, before) = try entryTarget(ref)
        let database = try requireLocalDatabase()
        let pairs = try localPairs(for: localIDs, database: database)
        var resolved: [String: Int] = [:]
        for localID in Self.unique(localIDs) {
            guard pairs.present.contains(localID) else {
                throw UsbEditBlocked(block: UsbBlock(code: "localTrackMissing", scope: .track(localID),
                                                     message: String(ui: "동기화할 곡이 로컬 스냅샷에 없어 목록을 바꾸지 않았습니다. 새 스냅샷을 뜬 뒤 다시 동기화하세요")))
            }
            let matches = pairs.matches[localID] ?? []
            guard !pairs.ambiguous.contains(localID), matches.count <= 1 else {
                throw UsbEditBlocked(block: Self.syncPairingBlock(localID, ambiguous: true))
            }
            guard let id = matches.first else {
                throw UsbEditBlocked(block: Self.syncPairingBlock(localID, ambiguous: false))
            }
            // 항목 편집과 같이 목록이 쓰일 형식마다 그 곡이 있어야 한다
            resolved[localID] = try trackID(String(id), formats: formats)
        }
        let after = localIDs.compactMap { resolved[$0] }
        guard after != before else { return }
        planned.rules = [.editPlaylists]
        planned.op = .playlist(.entries(change(playlist.id, formats: formats, before: before, after: after)))
    }

    static func syncPairingBlock(_ localID: String, ambiguous: Bool) -> UsbBlock {
        UsbBlock(code: ambiguous ? "syncTrackAmbiguous" : "syncTrackMissing", scope: .track(localID),
                 message: ambiguous
                     ? String(ui: "로컬 곡의 USB 짝을 하나로 정할 수 없어 목록을 바꾸지 않았습니다. 로컬과 USB의 중복 곡을 정리한 뒤 다시 동기화하세요")
                     : String(ui: "동기화할 곡이 USB에 없어 목록을 바꾸지 않았습니다. 곡 더하기가 막힌 이유를 푼 뒤 다시 동기화하세요"))
    }
}
