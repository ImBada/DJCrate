import DJCDomain
import DJCStorage
import Foundation

extension LibraryStore {
    /// writer에 도착하기 전에 빠진 곡·초안도 요청한 곡과 종류로 설명한다.
    /// - Parameter blockedOnly: 쓰기 확인 목록용. 초안을 읽지 못해 막힌 줄만 남긴다(#211)
    func draftExclusionReasons(for rows: [TrackRow], xml: Bool = false, blockedOnly: Bool = false) -> [String] {
        let gains = try? GainDraftStore.read()
        return rows.flatMap { row -> [String] in
            let uuid = row.track.uuid
            func line(_ reason: String) -> String { "• \(row.title): \(reason)" }
            // 추가한 곡·USB 곡은 이 쓰기의 대상이 아니니 쓰기 확인 목록에 섞지 않는다.
            if blockedOnly, row.isStaged || row.isUsb { return [] }
            if row.isStaged {
                return [line(String(ui: "추가한 곡은 기존 곡의 초안 쓰기에서 제외하니 ‘rekordbox에 넣기’ 또는 추가 목록의 XML 만들기를 사용하세요"))]
            }
            if row.isUsb {
                return [line(String(ui: "USB 곡은 이 라이브러리의 초안 쓰기를 지원하지 않으니 라이브러리에서 곡을 고르세요"))]
            }
            let cue = CueDraftStore.load(trackUUID: uuid)
            let grid = GridDraftStore.load(trackUUID: uuid)
            let tag = TagDraftStore.load(trackUUID: uuid)
            let artwork = artworkDrafts[uuid] == nil ? nil : (try? ArtworkDraftStore.load(trackUUID: uuid, directory: artworkDirectory)).map { _ in true }
            let known = unreadableDraftKinds[uuid] ?? []
            let candidates: [(WriteResult.Part, Bool, Bool?)] = [
                (.cue, hasDraft(.cue, trackUUID: uuid) || known.contains(.cue), cue.flatMap { $0.trackUUID == uuid ? $0.hasChanges : nil }),
                (.grid, hasDraft(.grid, trackUUID: uuid) || known.contains(.grid), grid.flatMap { $0.trackUUID == uuid ? $0.hasChanges : nil }),
                (.gain, gainDraftUUIDs.contains(uuid) || known.contains(.gain), gains?[uuid].map { _ in true }),
                (.tag, tagDrafts[uuid] != nil || known.contains(.tag), tag.flatMap { $0.trackUUID == uuid ? $0.hasChanges : nil }),
                (.artwork, artworkDrafts[uuid] != nil || known.contains(.artwork), artwork),
                (.merge, mergeDrafts.contains { $0.members.contains { $0.trackUUID == uuid } }, true),
            ]
            var reasons: [String] = []
            for (kind, expected, changed) in candidates where expected {
                if changed == nil {
                    reasons.append(line(kind.blocked(String(ui: "초안을 불러오지 못했으니 초안 파일과 접근 권한을 확인한 뒤 다시 불러오세요"))))
                } else if changed == false {
                    if !blockedOnly { reasons.append(line(kind.unchanged)) }
                } else if xml, kind != .cue && kind != .grid {
                    reasons.append(line(kind.blocked(String(ui: "기존 곡의 XML은 큐·그리드만 지원하니 이 종류의 초안은 ‘rekordbox에 쓰기’를 사용하세요"))))
                }
            }
            if !blockedOnly, !candidates.contains(where: { $0.1 }) {
                reasons.append(line(String(ui: "rekordbox와 다른 초안 변경이 없으니 변경할 곡과 초안을 확인하세요")))
            }
            return reasons
        }
    }

    /// 실제 쓰기 대상은 유지하고, 같은 선택에서 빠진 곡을 미리 보기에 함께 넘긴다.
    /// 쓰기 확인 목록은 이 가운데 막힌 초안만 보인다(`blockedOnly`, #211).
    var reflectionPreviewRows: [TrackRow] {
        let targets = reflectionTargets
        var ids = Set(targets.map(\.id))
        return targets + selectedRows.filter { ids.insert($0.id).inserted }
    }
}
