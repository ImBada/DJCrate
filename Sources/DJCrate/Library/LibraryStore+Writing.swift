import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation

/// 큐·그리드·게인·태그·재생 목록 초안을 rekordbox DB에 직접 쓴다. rekordbox가 꺼져 있을 때만 쓴다(태그는 음원 파일이 아니라 rekordbox 곡 정보만).
/// 흐름: 새 스냅샷 사본으로 미리 보기 → 사용자 확인 → 쓰기(백업·검증은 `RekordboxWriter`) → 새 스냅샷으로 다시 읽기.
/// 분석 전 곡(분석 파일 없음)의 그리드 초안은 분석 파일(파형·그리드·오토게인)을 만들어 붙인다(`RekordboxWriter.attachesAnalysis`가 열렸을 때).
extension LibraryStore {
    struct WritePreview {
        var report: RekordboxWriter.Report
        var drafts: [CueDraft]
        var grids: [GridDraft]
        var gains: [String: Double]
        var tags: [TagDraft] = []
        /// 함께 쓸 재생 목록 초안(없으면 nil). 결과(`report.playlistOutcomes`)가 편집 순서와 같다.
        var playlists: PlaylistDraft?
        var merges: [DuplicateMergeDraft] = []
    }

    /// 대상 곡 중 반영 대기 초안이 있는 곡(추가한 곡 제외)
    func writeTargets(_ rows: [TrackRow]) -> [TrackRow] {
        rows.filter { !$0.isStaged && pendingUUIDs.contains($0.track.uuid) }
    }

    /// 새 스냅샷을 떠서 그 사본으로 쓰기를 끝까지 해 보고 되돌린다(rekordbox는 건드리지 않는다).
    /// - Parameter playlists: 재생 목록 초안도 함께 볼지(곡 초안과 달리 곡을 골라 나누지 않는다)
    func previewWrite(rows: [TrackRow], playlists: Bool) async throws -> WritePreview {
        DraftWriter.flush()
        let targets = writeTargets(rows)
        let uuids = Set(targets.map { $0.track.uuid })
        let merges = mergeDrafts.filter { $0.members.contains { uuids.contains($0.trackUUID) } }
        let drafts = targets.compactMap { CueDraftStore.load(trackUUID: $0.track.uuid) }.filter(\.hasChanges)
        let grids = targets.compactMap { GridDraftStore.load(trackUUID: $0.track.uuid) }.filter(\.hasChanges)
        let allGains = GainDraftStore.all()
        let gains = Dictionary(uniqueKeysWithValues: targets.compactMap { row in allGains[row.track.uuid].map { (row.track.uuid, $0) } })
        let tags = targets.compactMap { TagDraftStore.load(trackUUID: $0.track.uuid) }.filter(\.hasChanges)
        let playlistDraft = playlists && !self.playlistDraft.isEmpty ? self.playlistDraft : nil
        // 미리 보기는 길이만 잰다(음량은 쓸 때 잰다. 막히는지 보는 데는 필요 없다).
        let inputs = try await analysisInputs(for: grids, measuringLoudness: false)
        writeStage = WriteStage(String(ui: "미리 보기 1/2단계 · 사본을 만드는 중…"), completed: 0, total: 2, cancellable: true)
        let task = Task.detached(priority: .userInitiated) {
            try await WritePreviewSnapshot.withCopy(grids: grids, merges: merges) { snapshot, share in
                await MainActor.run { self.writeStage = WriteStage(String(ui: "미리 보기 2/2단계 · 바꿀 내용을 검사하는 중…"), completed: 1, total: 2, cancellable: true) }
                try Task.checkCancellation()
                return try RekordboxWriter.write(drafts: drafts, grids: grids, gains: gains, tags: tags, analysisInputs: inputs,
                                                 playlistDraft: playlistDraft, merges: merges, to: snapshot, dryRun: true,
                                                 backups: snapshot.deletingLastPathComponent().appending(path: "backups"), shareRoot: share)
            }
        }
        let report = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return WritePreview(report: report, drafts: drafts, grids: grids, gains: gains, tags: tags, playlists: playlistDraft, merges: merges)
    }

    /// rekordbox master.db에 쓴다. 쓴 곡의 초안과 쓴 재생 목록 편집은 지우고(백업 폴더에 남는다) 새 스냅샷을 읽는다. 태그는 반영한 값이 새 base가 된다.
    func writeToRekordbox(_ drafts: [CueDraft], grids: [GridDraft] = [], gains: [String: Double] = [:],
                          tags: [TagDraft] = [], playlists: PlaylistDraft? = nil, merges: [DuplicateMergeDraft] = []) async throws -> RekordboxWriter.Report {
        try Task.checkCancellation()
        defer { writeStage = nil }
        let inputs = try await analysisInputs(for: grids, measuringLoudness: true)
        try Task.checkCancellation()
        writeStage = WriteStage(String(ui: "rekordbox에 쓰는 중…"))
        let report = try await Task.detached(priority: .userInitiated) {
            try RekordboxWriter.write(drafts: drafts, grids: grids, gains: gains, tags: tags, analysisInputs: inputs, playlistDraft: playlists, merges: merges,
                                      dryRun: false,
                                      backups: DJCPaths.rekordboxBackups)
        }.value
        // 스냅샷을 다시 읽으면 초안도 파일에서 다시 읽으므로 그 전에 쓴 편집을 뺀다.
        let merged = Set(report.mergeWritten.map(\.trackUUID))
        if !merged.isEmpty {
            let remaining = mergeDrafts.filter { !merged.contains($0.id) }
            saveMergeDraftsAfterWrite(remaining)
        }
        if let playlists { finishPlaylistWrite(playlists, outcomes: report.playlistOutcomes ?? []) }
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
        let tagWritten = Set(report.tagWritten.map(\.trackUUID))
        replaceTagDrafts(tags.filter { tagWritten.contains($0.trackUUID) }.map { draft in
            var cleared = draft
            cleared.fields = cleared.base
            return cleared
        })
        DraftWriter.flush()
        // 화면을 처음부터 다시 불러오지 않고 뒤에서 조용히 다시 읽는다.
        writeStage = .reloadingLibrary
        await takeSnapshot(quiet: true, refreshITunes: false)
        // 그리드만 바뀐 곡은 DB가 그대로라 목록 줄이 같다. 덱이 그 곡을 보고 있으면 초안·그리드만 다시 읽게 한다.
        onRekordboxWritten?(Set(report.written.map(\.trackUUID)).union(report.gridWritten.map(\.trackUUID)).union(report.gainWritten.map(\.trackUUID))
            .union(report.analysisWritten.map(\.trackUUID)).union(tagWritten).union(merges.filter { merged.contains($0.id) }.flatMap { $0.members.map(\.trackUUID) }))
        lastWriteBackup = report.backup.map { URL(filePath: $0) }
        return report
    }

    /// 백업으로 되돌린다: DB를 쓰기 전으로 돌리고, 그때 쓴 초안을 DJCrate에 다시 살린다.
    @discardableResult
    func restoreRekordbox(_ backup: RekordboxWriter.Backup) async throws -> URL {
        writeStage = WriteStage(String(ui: "rekordbox를 복원하는 중…"))
        defer { writeStage = nil }
        let saved = try await Task.detached(priority: .userInitiated) {
            try RekordboxWriter.restore(backup.url, backups: DJCPaths.rekordboxBackups)
        }.value
        let restoredMerges = RekordboxWriter.mergeDrafts(in: backup.url)
        if !restoredMerges.isEmpty {
            let restoredIDs = Set(restoredMerges.flatMap { $0.members.map(\.trackUUID) })
            let combined = mergeDrafts.filter { Set($0.members.map(\.trackUUID)).isDisjoint(with: restoredIDs) } + restoredMerges
            saveMergeDraftsAfterWrite(combined)
        }
        let drafts = RekordboxWriter.contents(of: backup.url).drafts
        for draft in drafts { DraftWriter.save(draft) }
        let grids = RekordboxWriter.gridDrafts(in: backup.url)
        for grid in grids { DraftWriter.save(grid) }
        for (uuid, gain) in RekordboxWriter.gainDrafts(in: backup.url) { GainDraftStore.save(gain, trackUUID: uuid) }
        let tags = RekordboxWriter.tagDrafts(in: backup.url)
        replaceTagDrafts(tags)
        DraftWriter.flush()
        writeStage = WriteStage(String(ui: "복원한 라이브러리를 읽는 중…"))
        await takeSnapshot(quiet: true, refreshITunes: false)
        // 재생 목록 편집은 되돌린 rekordbox 상태에 다시 쌓는다(쌓지 못한 편집은 알린다).
        let unrestored = restorePlaylistEdits(RekordboxWriter.playlistEdits(in: backup.url))
        if unrestored > 0 {
            playlistMessage = AppMessage(kind: .warning, text: String(ui: "재생 목록 편집 \(unrestored)건은 초안으로 되살리지 못했습니다."))
        }
        let gainUUIDs = Set(RekordboxWriter.gainDrafts(in: backup.url).keys)
        onRekordboxWritten?(Set(drafts.map(\.trackUUID)).union(grids.map(\.trackUUID)).union(gainUUIDs).union(tags.map(\.trackUUID)))
        _ = restoreStaged(from: backup)
        lastWriteBackup = nil
        return saved
    }

    /// 태그 초안을 통째로 바꾼다(쓴 뒤 비운 초안, 되돌린 뒤 백업의 초안). 변경이 없는 초안은 파일째 지운다.
    /// 쓰는 동안은 잠겨 있고 되돌리기 목록도 비어 있어 되돌리기 단위로 남기지 않는다.
    func replaceTagDrafts(_ drafts: [TagDraft]) {
        guard !drafts.isEmpty else { return }
        for draft in drafts {
            tagDrafts[draft.trackUUID] = draft.hasChanges ? draft : nil
            updateEdited(draft.trackUUID)
        }
        saveTagDrafts(drafts)
        tagRevision += 1
        if case .pending = sidebar { refreshBase() }
    }

    /// 분석 전 곡(분석 파일 없음)의 그리드 초안에 붙일 음원 길이·음량·내장 그림(곡 UUID별). 분석 붙이기가 닫혀 있으면 비운다.
    /// 길이는 곡 넣기와 같은 값(AVFoundation), 음량은 캐시가 없으면 잰다. 내장 그림이 있으면 쓰기 모듈이 아트워크도 넣는다(#87).
    func analysisInputs(for grids: [GridDraft], measuringLoudness: Bool) async throws -> [String: RekordboxWriter.AnalysisInput] {
        guard RekordboxWriter.attachesAnalysis else { return [:] }
        var inputs: [String: RekordboxWriter.AnalysisInput] = [:]
        for (index, grid) in grids.enumerated() {
            try Task.checkCancellation()
            writeStage = WriteStage(measuringLoudness ? String(ui: "음량을 재는 중…") : String(ui: "분석할 곡을 확인하는 중…"),
                                    completed: index, total: grids.count, cancellable: true)
            guard let row = rowsByUUID[grid.trackUUID], !row.isStaged, !row.track.isStreaming,
                  RekordboxWriter.needsAnalysis(row.track.analysisDataPath) else { continue }
            let url = URL(filePath: row.track.folderPath)
            guard let tags = try? await AudioTags.read(url: url), tags.duration > 0 else { continue }
            var loudness: Loudness?
            if measuringLoudness {
                loudness = LoudnessCache.shared.value(for: url)
                if loudness == nil {
                    loudness = try? await Task.detached(priority: .userInitiated) { try Loudness.measure(fileAt: url) }.value
                    if let loudness { LoudnessCache.shared.store(loudness, for: url) }
                }
            }
            try Task.checkCancellation()
            inputs[grid.trackUUID] = .init(duration: tags.duration, loudness: loudness?.integrated, peak: loudness.map { pow(10, $0.peak / 20) } ?? 1,
                                           artwork: tags.artwork)
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
