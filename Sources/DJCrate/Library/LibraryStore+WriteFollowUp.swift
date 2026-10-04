import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 복원이 되살릴 백업 초안과 지금 초안이 다른 곳(#175). 지금 초안은 쓴 뒤 새로 만든 편집이다.
struct RestoreDraftConflict: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case cue, grid, gain, tag, artwork, merge }
    var kind: Kind
    /// 곡 UUID(합치기는 합치기 초안 ID)
    var uuid: String

    var label: String {
        switch kind {
        case .cue: String(ui: "큐")
        case .grid: String(ui: "그리드")
        case .gain: String(ui: "게인")
        case .tag: String(ui: "태그")
        case .artwork: String(ui: "앨범아트")
        case .merge: String(ui: "합치기")
        }
    }
}

/// 쓰기·복원 뒤에 따르는 일(#175): 다시 읽기의 성공 여부, 초안 정리 실패, 복원 충돌을 쓰기 결과와 나눠 알린다.
extension LibraryStore {
    /// 쓰기·복원 뒤 조용히 다시 읽는다. 새 스냅샷을 실제로 읽었는지 돌려준다(거절·실패·밀린 읽기는 거짓).
    func reloadAfterWrite() async -> Bool {
        let before = completedLoadCount
        await takeSnapshot(quiet: true, refreshITunes: false)
        return completedLoadCount > before
    }

    /// 새 스냅샷을 읽은 뒤: 쓰거나 되돌린 곡을 덱에 알린다(옛 스냅샷을 새것으로 보지 않게 읽기가 성공한 뒤에만).
    func deliverWrittenAfterReload() {
        guard !writtenAwaitingReload.isEmpty else { return }
        let uuids = writtenAwaitingReload
        writtenAwaitingReload = []
        onRekordboxWritten?(uuids)
    }

    /// 새 스냅샷을 읽은 뒤: 복원한 재생 목록 편집을 되돌린 rekordbox 상태에 다시 쌓는다(쌓지 못한 편집은 알린다).
    func restoreAwaitingPlaylistEdits() {
        guard !playlistEditsAwaitingReload.isEmpty else { return }
        let edits = playlistEditsAwaitingReload
        playlistEditsAwaitingReload = []
        let unrestored = restorePlaylistEdits(edits)
        if unrestored > 0 {
            playlistMessage = AppMessage(kind: .warning, text: String(ui: "재생 목록 편집 \(unrestored)건은 초안으로 되살리지 못했습니다."))
        }
    }

    static func reloadFailureText(restoring: Bool) -> String {
        restoring ? String(ui: "rekordbox는 복원했지만 라이브러리를 다시 읽지 못했으니 ‘rekordbox와 동기화’(⌘R)로 다시 읽은 뒤 편집을 이어 가세요.")
            : String(ui: "rekordbox에는 썼지만 라이브러리를 다시 읽지 못했으니 ‘rekordbox와 동기화’(⌘R)로 다시 읽은 뒤 편집을 이어 가세요.")
    }

    static func keptDraftsText(_ count: Int) -> String {
        String(ui: "쓴 뒤 새로 만든 초안이 있는 \(count)곡은 지금 초안을 남겼고, 백업의 초안은 ‘마지막 쓰기 결과…’의 백업 폴더에 남아 있습니다.")
    }

    /// 쓰기·복원 결과와 나눠 알릴 경고를 정리한다. 목록 위 경고 줄에도 남긴다(다시 읽기 실패 이유는 그 뒤에 잇는다).
    func finishWriteFollowUp(_ notes: [String?], reloaded: Bool, restoring: Bool) {
        let reloadError = reloaded ? nil : lastError
        writeFollowUp = notes.compactMap { $0 } + (reloaded ? [] : [Self.reloadFailureText(restoring: restoring)])
        let line = (writeFollowUp + [reloadError].compactMap { $0 }).joined(separator: " ")
        if !line.isEmpty { reportLibraryError(line) }
    }

    // MARK: - 복원 충돌

    /// 백업이 되살릴 초안 중 같은 곡의 지금 초안과 다른 것. 지금 초안이 백업과 같거나 변경이 없으면 충돌이 아니다.
    /// 태그는 저장에 실패했을 수 있어 메모리 초안과 비교한다.
    func restoreDraftConflicts(_ backup: RekordboxWriter.Backup) -> [RestoreDraftConflict] {
        DraftWriter.flush()
        var conflicts: [RestoreDraftConflict] = []
        for draft in RekordboxWriter.contents(of: backup.url).drafts {
            let current = DraftWriter.pendingCue(trackUUID: draft.trackUUID) ?? CueDraftStore.load(trackUUID: draft.trackUUID)
            if let current, current.hasChanges, current != draft { conflicts.append(.init(kind: .cue, uuid: draft.trackUUID)) }
        }
        for grid in RekordboxWriter.gridDrafts(in: backup.url) {
            let current = DraftWriter.pendingGrid(trackUUID: grid.trackUUID) ?? GridDraftStore.load(trackUUID: grid.trackUUID)
            if let current, current.hasChanges, current != grid { conflicts.append(.init(kind: .grid, uuid: grid.trackUUID)) }
        }
        for (uuid, gain) in RekordboxWriter.gainDrafts(in: backup.url).sorted(by: { $0.key < $1.key }) {
            let current = DraftWriter.pendingGain(trackUUID: uuid) ?? GainDraftStore.load(trackUUID: uuid)
            if let current, current != gain { conflicts.append(.init(kind: .gain, uuid: uuid)) }
        }
        for tag in RekordboxWriter.tagDrafts(in: backup.url) {
            if let current = tagDrafts[tag.trackUUID], current.hasChanges, current != tag { conflicts.append(.init(kind: .tag, uuid: tag.trackUUID)) }
        }
        for edit in RekordboxWriter.artworkDrafts(in: backup.url) {
            if let current = artworkDrafts[edit.trackUUID], current != edit.draft { conflicts.append(.init(kind: .artwork, uuid: edit.trackUUID)) }
        }
        let restored = RekordboxWriter.mergeDrafts(in: backup.url)
        let restoredIDs = Set(restored.flatMap { $0.members.map(\.trackUUID) })
        for current in mergeDrafts where !restored.contains(current)
            && !Set(current.members.map(\.trackUUID)).isDisjoint(with: restoredIDs) {
            conflicts.append(.init(kind: .merge, uuid: current.id))
        }
        return conflicts
    }

    /// 충돌한 곡(합치기는 묶인 곡 모두)
    func conflictTrackUUIDs(_ conflicts: [RestoreDraftConflict]) -> [String: [RestoreDraftConflict]] {
        var byTrack: [String: [RestoreDraftConflict]] = [:]
        for conflict in conflicts {
            let uuids = conflict.kind == .merge
                ? mergeDrafts.first { $0.id == conflict.uuid }?.members.map(\.trackUUID) ?? [] : [conflict.uuid]
            for uuid in uuids { byTrack[uuid, default: []].append(conflict) }
        }
        return byTrack
    }

    /// 복원 확인 창에 보일 충돌 목록("• 곡 — 큐·태그")
    func restoreDraftConflictDetails(_ backup: RekordboxWriter.Backup) -> [String] {
        var outcomes: [RekordboxWriter.Outcome] = []
        if let report = backup.report {
            outcomes = report.outcomes + (report.gridOutcomes ?? []) + (report.gainOutcomes ?? [])
            outcomes += (report.tagOutcomes ?? []) + (report.artworkOutcomes ?? [])
        }
        let titles = Dictionary(outcomes.map { ($0.trackUUID, $0.title) }, uniquingKeysWith: { first, _ in first })
        return conflictTrackUUIDs(restoreDraftConflicts(backup))
            .map { uuid, conflicts in (rowsByUUID[uuid]?.title ?? titles[uuid] ?? uuid, conflicts) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            .map { title, conflicts in "• \(title) — \(conflicts.map(\.label).joined(separator: "·"))" }
    }
}
