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
        let inputs = try await analysisInputs(for: grids, measuringLoudness: false)
        writeStage = WriteStage("미리 보기 1/2단계 · 사본을 만드는 중…", completed: 0, total: 2, cancellable: true)
        let report = try await Task.detached(priority: .userInitiated) {
            let snapshot = try LibrarySnapshot.take()
            await MainActor.run { self.writeStage = WriteStage("미리 보기 2/2단계 · 바꿀 내용을 검사하는 중…", completed: 1, total: 2, cancellable: true) }
            // 미리 보기: 사본 DB + 실제 분석 파일을 읽기만 한다(dryRun이라 파일을 쓰지 않는다).
            return try RekordboxWriter.write(drafts: drafts, grids: grids, gains: gains, analysisInputs: inputs, to: snapshot, dryRun: true,
                                             backups: DJCPaths.rekordboxBackups, shareRoot: RekordboxShare.directory)
        }.value
        try Task.checkCancellation()
        return WritePreview(report: report, drafts: drafts, grids: grids, gains: gains)
    }

    /// rekordbox master.db에 쓴다. 쓴 곡의 큐 초안은 지우고(백업 폴더에 남는다) 새 스냅샷을 읽는다.
    func writeToRekordbox(_ drafts: [CueDraft], grids: [GridDraft] = [], gains: [String: Double] = [:]) async throws -> RekordboxWriter.Report {
        try Task.checkCancellation()
        defer { writeStage = nil }
        let inputs = try await analysisInputs(for: grids, measuringLoudness: true)
        try Task.checkCancellation()
        writeStage = WriteStage("rekordbox에 쓰는 중…")
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
        writeStage = WriteStage("반영 확인 중…")
        await takeSnapshot(quiet: true)
        // 그리드만 바뀐 곡은 DB가 그대로라 목록 줄이 같다. 덱이 그 곡을 보고 있으면 초안·그리드만 다시 읽게 한다.
        onRekordboxWritten?(Set(report.written.map(\.trackUUID)).union(report.gridWritten.map(\.trackUUID)).union(report.gainWritten.map(\.trackUUID)).union(report.analysisWritten.map(\.trackUUID)))
        lastWriteBackup = report.backup.map { URL(filePath: $0) }
        return report
    }

    /// 백업으로 되돌린다: DB를 쓰기 전으로 돌리고, 그때 쓴 초안을 DJCrate에 다시 살린다.
    @discardableResult
    func restoreRekordbox(_ backup: RekordboxWriter.Backup) async throws -> URL {
        writeStage = WriteStage("rekordbox를 되돌리는 중…")
        defer { writeStage = nil }
        let saved = try await Task.detached(priority: .userInitiated) {
            try RekordboxWriter.restore(backup.url, backups: DJCPaths.rekordboxBackups)
        }.value
        let drafts = RekordboxWriter.contents(of: backup.url).drafts
        for draft in drafts { DraftWriter.save(draft) }
        let grids = RekordboxWriter.gridDrafts(in: backup.url)
        for grid in grids { DraftWriter.save(grid) }
        for (uuid, gain) in RekordboxWriter.gainDrafts(in: backup.url) { GainDraftStore.save(gain, trackUUID: uuid) }
        DraftWriter.flush()
        writeStage = WriteStage("되돌린 라이브러리를 읽는 중…")
        await takeSnapshot(quiet: true)
        let gainUUIDs = Set(RekordboxWriter.gainDrafts(in: backup.url).keys)
        onRekordboxWritten?(Set(drafts.map(\.trackUUID)).union(grids.map(\.trackUUID)).union(gainUUIDs))
        _ = restoreStaged(from: backup)
        lastWriteBackup = nil
        return saved
    }

    /// 분석 전 곡(분석 파일 없음)의 그리드 초안에 붙일 음원 길이·음량(곡 UUID별). 분석 붙이기가 닫혀 있으면 비운다.
    /// 길이는 곡 넣기와 같은 값(AVFoundation), 음량은 캐시가 없으면 잰다.
    func analysisInputs(for grids: [GridDraft], measuringLoudness: Bool) async throws -> [String: RekordboxWriter.AnalysisInput] {
        guard RekordboxWriter.attachesAnalysis else { return [:] }
        var inputs: [String: RekordboxWriter.AnalysisInput] = [:]
        for (index, grid) in grids.enumerated() {
            try Task.checkCancellation()
            writeStage = WriteStage(measuringLoudness ? "음량을 재는 중…" : "분석할 곡을 확인하는 중…",
                                    completed: index, total: grids.count, cancellable: true)
            guard let row = rowsByUUID[grid.trackUUID], !row.isStaged, !row.track.isStreaming,
                  RekordboxWriter.needsAnalysis(row.track.analysisDataPath) else { continue }
            let url = URL(filePath: row.track.folderPath)
            guard let duration = try? await AudioTags.read(url: url).duration, duration > 0 else { continue }
            var loudness: Loudness?
            if measuringLoudness {
                loudness = LoudnessCache.shared.value(for: url)
                if loudness == nil {
                    loudness = try? await Task.detached(priority: .userInitiated) { try Loudness.measure(fileAt: url) }.value
                    if let loudness { LoudnessCache.shared.store(loudness, for: url) }
                }
            }
            try Task.checkCancellation()
            inputs[grid.trackUUID] = .init(duration: duration, loudness: loudness?.integrated, peak: loudness.map { pow(10, $0.peak / 20) } ?? 1)
        }
        try Task.checkCancellation()
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
