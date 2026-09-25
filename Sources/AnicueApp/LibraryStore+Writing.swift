import AnicueCore
import Foundation

/// 큐 초안을 rekordbox DB에 직접 쓴다. rekordbox가 꺼져 있을 때만 쓴다.
/// 흐름: 새 스냅샷 사본으로 미리 보기 → 사용자 확인 → 쓰기(백업·검증은 `RekordboxWriter`) → 새 스냅샷으로 다시 읽기.
/// 그리드 초안은 아직 직접 쓰지 않는다(XML 경로).
extension LibraryStore {
    struct WritePreview {
        var report: RekordboxWriter.Report
        var drafts: [CueDraft]
        var grids: [GridDraft]
        var gains: [String: Double]
    }

    /// 대상 곡 중 반영 대기 초안이 있는 곡(추가한 곡 제외)
    func writeTargets(_ rows: [TrackRow]) -> [TrackRow] {
        rows.filter { !$0.isStaged && pendingUUIDs.contains($0.track.uuid) }
    }

    /// 새 스냅샷을 떠서 그 사본으로 쓰기를 끝까지 해 보고 되돌린다(rekordbox는 건드리지 않는다).
    func previewWrite(rows: [TrackRow]) async throws -> WritePreview {
        DraftWriter.flush()
        let targets = writeTargets(rows)
        let drafts = targets.compactMap { CueDraftStore.load(trackUUID: $0.track.uuid) }.filter(\.hasChanges)
        let grids = targets.compactMap { GridDraftStore.load(trackUUID: $0.track.uuid) }.filter(\.hasChanges)
        let allGains = GainDraftStore.all()
        let gains = Dictionary(uniqueKeysWithValues: targets.compactMap { row in allGains[row.track.uuid].map { (row.track.uuid, $0) } })
        let report = try await Task.detached(priority: .userInitiated) {
            let snapshot = try LibrarySnapshot.take()
            // 미리 보기: 사본 DB + 실제 분석 파일을 읽기만 한다(dryRun이라 파일을 쓰지 않는다).
            return try RekordboxWriter.write(drafts: drafts, grids: grids, gains: gains, to: snapshot, dryRun: true,
                                             shareRoot: RekordboxShare.directory)
        }.value
        return WritePreview(report: report, drafts: drafts, grids: grids, gains: gains)
    }

    /// rekordbox master.db에 쓴다. 쓴 곡의 큐 초안은 지우고(백업 폴더에 남는다) 새 스냅샷을 읽는다.
    func writeToRekordbox(_ drafts: [CueDraft], grids: [GridDraft] = [], gains: [String: Double] = [:]) async throws -> RekordboxWriter.Report {
        let report = try await Task.detached(priority: .userInitiated) {
            try RekordboxWriter.write(drafts: drafts, grids: grids, gains: gains, dryRun: false)
        }.value
        for outcome in report.gainWritten {
            GainDraftStore.remove(trackUUID: outcome.trackUUID)
            draftChanged(trackUUID: outcome.trackUUID, kind: .gain, exists: false)
        }
        for outcome in report.written {
            DraftWriter.removeCue(trackUUID: outcome.trackUUID)
            draftCueCounts[outcome.trackUUID] = nil
            draftChanged(trackUUID: outcome.trackUUID, kind: .cue, exists: false)
        }
        for outcome in report.gridWritten {
            DraftWriter.removeGrid(trackUUID: outcome.trackUUID)
            draftChanged(trackUUID: outcome.trackUUID, kind: .grid, exists: false)
        }
        DraftWriter.flush()
        await takeSnapshot()
        // 그리드만 바뀐 곡은 DB가 그대로라 목록 줄이 같다. 덱이 그 곡을 보고 있으면 분석 파일을 다시 읽게 한다.
        onRekordboxWritten?(Set(report.written.map(\.trackUUID)).union(report.gridWritten.map(\.trackUUID)).union(report.gainWritten.map(\.trackUUID)))
        var parts: [String] = []
        if !report.written.isEmpty { parts.append("큐 \(report.written.count)곡") }
        if !report.gridWritten.isEmpty { parts.append("그리드 \(report.gridWritten.count)곡") }
        if !report.gainWritten.isEmpty { parts.append("게인 \(report.gainWritten.count)곡") }
        var text = "rekordbox에 " + (parts.isEmpty ? "쓴 것이 없습니다" : parts.joined(separator: " · ") + "을 썼습니다")
        let blocked = report.blocked + report.gridBlocked + report.gainBlocked
        if !blocked.isEmpty {
            text += " · 쓰지 않은 것 \(blocked.count): " + blocked.prefix(2).map { "\($0.title)(\($0.reason ?? ""))" }.joined(separator: ", ")
        }
        reflectionMessage = text
        lastWriteBackup = report.backup.map { URL(filePath: $0) }
        return report
    }

    /// 백업으로 되돌린다: DB를 쓰기 전으로 돌리고, 그때 쓴 초안을 anicue에 다시 살린다.
    func restoreRekordbox(_ backup: RekordboxWriter.Backup) async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try RekordboxWriter.restore(backup.url)
        }.value
        let drafts = RekordboxWriter.contents(of: backup.url).drafts
        for draft in drafts { DraftWriter.save(draft) }
        let grids = RekordboxWriter.gridDrafts(in: backup.url)
        for grid in grids { DraftWriter.save(grid) }
        for (uuid, gain) in RekordboxWriter.gainDrafts(in: backup.url) { GainDraftStore.save(gain, trackUUID: uuid) }
        DraftWriter.flush()
        await takeSnapshot()
        onRekordboxWritten?(Set(drafts.map(\.trackUUID)).union(grids.map(\.trackUUID)))
        reflectionMessage = "rekordbox를 \(backup.createdAt.formatted(date: .omitted, time: .shortened)) 쓰기 전으로 되돌렸습니다 · 초안 \(Set(drafts.map(\.trackUUID)).union(grids.map(\.trackUUID)).count)곡을 다시 살렸습니다"
        lastWriteBackup = nil
    }

    /// 백업 뒤 rekordbox에서 라이브러리가 바뀌었는지(되돌리면 그 변경도 사라진다).
    func libraryChangedSince(_ backup: RekordboxWriter.Backup) async -> Bool? {
        guard let expected = backup.report?.finalUpdateCount else { return nil }
        return try? await Task.detached {
            let snapshot = try LibrarySnapshot.take()
            return try RekordboxWriter.updateCount(of: snapshot) != expected
        }.value
    }
}
