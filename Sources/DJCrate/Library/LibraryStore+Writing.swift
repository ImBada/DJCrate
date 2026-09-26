import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation

/// 큐·그리드·게인 초안을 rekordbox DB에 직접 쓴다. rekordbox가 꺼져 있을 때만 쓴다.
/// 흐름: 새 스냅샷 사본으로 미리 보기 → 사용자 확인 → 쓰기(백업·검증은 `RekordboxWriter`) → 새 스냅샷으로 다시 읽기.
/// 분석 전 곡(분석 파일 없음)의 그리드 초안은 분석 파일(파형·그리드·오토게인)을 만들어 붙인다(`RekordboxWriter.attachesAnalysis`가 열렸을 때).
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
        // 미리 보기는 길이만 잰다(음량은 쓸 때 잰다. 막히는지 보는 데는 필요 없다).
        let inputs = await analysisInputs(for: grids, measuringLoudness: false)
        let report = try await Task.detached(priority: .userInitiated) {
            let snapshot = try LibrarySnapshot.take()
            // 미리 보기: 사본 DB + 실제 분석 파일을 읽기만 한다(dryRun이라 파일을 쓰지 않는다).
            return try RekordboxWriter.write(drafts: drafts, grids: grids, gains: gains, analysisInputs: inputs, to: snapshot, dryRun: true,
                                             backups: DJCPaths.rekordboxBackups, shareRoot: RekordboxShare.directory)
        }.value
        return WritePreview(report: report, drafts: drafts, grids: grids, gains: gains)
    }

    /// rekordbox master.db에 쓴다. 쓴 곡의 큐 초안은 지우고(백업 폴더에 남는다) 새 스냅샷을 읽는다.
    func writeToRekordbox(_ drafts: [CueDraft], grids: [GridDraft] = [], gains: [String: Double] = [:]) async throws -> RekordboxWriter.Report {
        defer { writeStage = nil }
        let inputs = await analysisInputs(for: grids, measuringLoudness: true)
        writeStage = "rekordbox에 쓰는 중…"
        let report = try await Task.detached(priority: .userInitiated) {
            try RekordboxWriter.write(drafts: drafts, grids: grids, gains: gains, analysisInputs: inputs, dryRun: false,
                                      backups: DJCPaths.rekordboxBackups)
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
        // 분석을 붙인 곡도 그리드 초안이 분석 파일에 들어갔다.
        for outcome in report.gridWritten + report.analysisWritten {
            DraftWriter.removeGrid(trackUUID: outcome.trackUUID)
            draftChanged(trackUUID: outcome.trackUUID, kind: .grid, exists: false)
        }
        DraftWriter.flush()
        // 화면을 처음부터 다시 불러오지 않고 뒤에서 조용히 다시 읽는다.
        writeStage = "반영 확인 중…"
        await takeSnapshot(quiet: true)
        // 그리드만 바뀐 곡은 DB가 그대로라 목록 줄이 같다. 덱이 그 곡을 보고 있으면 초안·그리드만 다시 읽게 한다.
        onRekordboxWritten?(Set(report.written.map(\.trackUUID)).union(report.gridWritten.map(\.trackUUID)).union(report.gainWritten.map(\.trackUUID))
            .union(report.analysisWritten.map(\.trackUUID)))
        var parts: [String] = []
        if !report.written.isEmpty { parts.append("큐 \(report.written.count)곡") }
        if !report.gridWritten.isEmpty { parts.append("그리드 \(report.gridWritten.count)곡") }
        if !report.analysisWritten.isEmpty { parts.append("분석 \(report.analysisWritten.count)곡") }
        if !report.gainWritten.isEmpty { parts.append("게인 \(report.gainWritten.count)곡") }
        let titles = Array(Set((report.written + report.gridWritten + report.analysisWritten + report.gainWritten).map(\.title))).sorted()
        var detail = titles.prefix(3).joined(separator: ", ") + (titles.count > 3 ? " 외 \(titles.count - 3)곡" : "")
        let blocked = report.blocked + report.gridBlocked + report.analysisBlocked + report.gainBlocked
        if !blocked.isEmpty {
            detail += (detail.isEmpty ? "" : "\n") + "쓰지 않은 것 \(blocked.count): "
                + blocked.prefix(2).map { "\($0.title)(\($0.reason ?? ""))" }.joined(separator: ", ")
        }
        lastWriteBackup = report.backup.map { URL(filePath: $0) }
        toast = AppToast(kind: blocked.isEmpty ? .success : .warning,
                         title: parts.isEmpty ? "rekordbox에 쓴 것이 없습니다" : "rekordbox에 반영했습니다 · " + parts.joined(separator: " · "),
                         detail: detail.isEmpty ? nil : detail,
                         undoBackup: parts.isEmpty ? nil : lastWriteBackup)
        return report
    }

    /// 백업으로 되돌린다: DB를 쓰기 전으로 돌리고, 그때 쓴 초안을 DJCrate에 다시 살린다.
    func restoreRekordbox(_ backup: RekordboxWriter.Backup) async throws {
        writeStage = "rekordbox를 되돌리는 중…"
        defer { writeStage = nil }
        try await Task.detached(priority: .userInitiated) {
            _ = try RekordboxWriter.restore(backup.url, backups: DJCPaths.rekordboxBackups)
        }.value
        let drafts = RekordboxWriter.contents(of: backup.url).drafts
        for draft in drafts { DraftWriter.save(draft) }
        let grids = RekordboxWriter.gridDrafts(in: backup.url)
        for grid in grids { DraftWriter.save(grid) }
        for (uuid, gain) in RekordboxWriter.gainDrafts(in: backup.url) { GainDraftStore.save(gain, trackUUID: uuid) }
        DraftWriter.flush()
        writeStage = "되돌린 라이브러리를 읽는 중…"
        await takeSnapshot(quiet: true)
        let gainUUIDs = Set(RekordboxWriter.gainDrafts(in: backup.url).keys)
        onRekordboxWritten?(Set(drafts.map(\.trackUUID)).union(grids.map(\.trackUUID)).union(gainUUIDs))
        let revived = Set(drafts.map(\.trackUUID)).union(grids.map(\.trackUUID)).union(gainUUIDs).count
        let restaged = restoreStaged(from: backup)
        let revivedTracks = backup.trackReport?.deleted.filter(\.written).count ?? 0
        var detail: [String] = []
        if revived > 0 { detail.append("초안 \(revived)곡을 다시 살렸습니다") }
        if restaged > 0 { detail.append("넣었던 \(restaged)곡을 추가 목록으로 되돌렸습니다") }
        if revivedTracks > 0 { detail.append("뺐던 \(revivedTracks)곡을 되살렸습니다") }
        toast = AppToast(title: "rekordbox를 \(backup.createdAt.formatted(date: .omitted, time: .shortened)) 쓰기 전으로 되돌렸습니다",
                         detail: detail.isEmpty ? nil : detail.joined(separator: " · "))
        lastWriteBackup = nil
    }

    /// 분석 전 곡(분석 파일 없음)의 그리드 초안에 붙일 음원 길이·음량(곡 UUID별). 분석 붙이기가 닫혀 있으면 비운다.
    /// 길이는 곡 넣기와 같은 값(AVFoundation), 음량은 캐시가 없으면 잰다.
    func analysisInputs(for grids: [GridDraft], measuringLoudness: Bool) async -> [String: RekordboxWriter.AnalysisInput] {
        guard RekordboxWriter.attachesAnalysis else { return [:] }
        var inputs: [String: RekordboxWriter.AnalysisInput] = [:]
        for grid in grids {
            guard let row = rowsByUUID[grid.trackUUID], !row.isStaged, !row.track.isStreaming,
                  RekordboxWriter.needsAnalysis(row.track.analysisDataPath) else { continue }
            let url = URL(filePath: row.track.folderPath)
            guard let duration = try? await AudioTags.read(url: url).duration, duration > 0 else { continue }
            var loudness: Loudness?
            if measuringLoudness {
                writeStage = "음량을 재는 중…"
                loudness = LoudnessCache.shared.value(for: url)
                if loudness == nil {
                    loudness = try? await Task.detached(priority: .userInitiated) { try Loudness.measure(fileAt: url) }.value
                    if let loudness { LoudnessCache.shared.store(loudness, for: url) }
                }
            }
            inputs[grid.trackUUID] = .init(duration: duration, loudness: loudness?.integrated, peak: loudness.map { pow(10, $0.peak / 20) } ?? 1)
        }
        return inputs
    }

    /// 백업 뒤 rekordbox에서 라이브러리가 바뀌었는지(되돌리면 그 변경도 사라진다).
    func libraryChangedSince(_ backup: RekordboxWriter.Backup) async -> Bool? {
        guard let expected = backup.finalUpdateCount else { return nil }
        return try? await Task.detached {
            let snapshot = try LibrarySnapshot.take()
            return try RekordboxWriter.updateCount(of: snapshot) != expected
        }.value
    }
}
