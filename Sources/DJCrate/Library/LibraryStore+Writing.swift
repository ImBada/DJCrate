import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation

/// 큐·그리드·게인·태그·그림·재생 목록 초안을 rekordbox DB에 직접 쓴다. rekordbox가 꺼져 있을 때만 쓴다(태그·그림은 음원 파일이 아니라 rekordbox 라이브러리만).
/// 흐름: 새 스냅샷 사본으로 미리 보기 → 사용자 확인 → 쓰기(백업·검증은 `RekordboxWriter`) → 새 스냅샷으로 다시 읽기.
/// 분석 전 곡(분석 파일 없음)의 그리드 초안은 분석 파일(파형·그리드·오토게인)을 만들어 붙인다(`RekordboxWriter.attachesAnalysis`가 열렸을 때).
extension LibraryStore {
    struct WritePreview {
        var report: RekordboxWriter.Report
        var drafts: [CueDraft]
        var grids: [GridDraft]
        var gains: [String: Double]
        var tags: [TagDraft] = []
        var artworks: [ArtworkEdit] = []
        /// 함께 쓸 재생 목록 초안(없으면 nil). 결과(`report.playlistOutcomes`)가 편집 순서와 같다.
        var playlists: PlaylistDraft?
        var merges: [DuplicateMergeDraft] = []
        var exclusions: [String] = []
    }

    /// 대상 곡 중 반영 대기 초안이 있는 곡(추가한 곡 제외)
    func writeTargets(_ rows: [TrackRow]) -> [TrackRow] {
        let pending = pendingUUIDs.union(DraftWriter.unsavedUUIDs())
        return rows.filter { !$0.isStaged && pending.contains($0.track.uuid) }
    }

    func requireDraftSaves(for uuids: Set<String>) throws {
        DraftWriter.flush()
        if let failure = DraftWriter.failures().first(where: { uuids.contains($0.trackUUID) }) {
            throw DJCError.writeRefused(failure.message)
        }
        guard DraftWriter.unsavedUUIDs().isDisjoint(with: uuids) else {
            throw DJCError.writeRefused(String(ui: "초안 저장이 끝나지 않았으니 저장을 마친 뒤 쓰기를 다시 시도하세요."))
        }
    }

    func draftSaveWarning(for uuids: Set<String>, restoring: Bool = false) -> String? {
        DraftWriter.flush()
        guard let failure = DraftWriter.failures().first(where: { uuids.contains($0.trackUUID) }) else { return nil }
        let result = restoring ? String(ui: "rekordbox는 복원했지만 초안을 저장하지 못했습니다.")
            : String(ui: "rekordbox에는 썼지만 초안을 정리하지 못했습니다.")
        return result + " " + failure.message
    }

    /// 새 스냅샷을 떠서 그 사본으로 쓰기를 끝까지 해 보고 되돌린다(rekordbox는 건드리지 않는다).
    /// - Parameter playlists: 재생 목록 초안도 함께 볼지(곡 초안과 달리 곡을 골라 나누지 않는다)
    func previewWrite(rows: [TrackRow], playlists: Bool) async throws -> WritePreview {
        DraftWriter.flush()
        retryFailedTagSaves()
        let targets = writeTargets(rows)
        let uuids = Set(targets.map { $0.track.uuid })
        // 읽지 못한 초안 파일이 미리 보기에서 조용히 빠지지 않게 먼저 옮기고 알린다(#174).
        try requireReadableDrafts(for: uuids, playlists: playlists)
        try requireDraftSaves(for: uuids)
        guard failedTagSaves().isDisjoint(with: uuids) else {
            throw DJCError.writeRefused(DraftWriter.tagSaveFailureMessage)
        }
        if playlists { try requirePlaylistDraftSaved() }
        let merges = mergeDrafts.filter { $0.members.contains { uuids.contains($0.trackUUID) } }
        // 자동 큐를 빼고 만든 옛 초안에는 곡의 자동 큐를 채운다(#145, 쓰기도 같은 일을 한다).
        let drafts = targets.compactMap { row in CueDraftStore.load(trackUUID: row.track.uuid)?.includingAutoCues(from: row.cues) }
            .filter(\.hasChanges)
        let grids = targets.compactMap { GridDraftStore.load(trackUUID: $0.track.uuid) }.filter(\.hasChanges)
        let allGains = try readGainDrafts()
        let gains = Dictionary(uniqueKeysWithValues: targets.compactMap { row in allGains[row.track.uuid].map { (row.track.uuid, $0) } })
        let tags = targets.compactMap { TagDraftStore.load(trackUUID: $0.track.uuid) }.filter(\.hasChanges)
        let artworks = try artworkEdits(for: targets)
        let playlistDraft = playlists && !self.playlistDraft.isEmpty ? self.playlistDraft : nil
        // 미리 보기는 길이만 잰다(음량은 쓸 때 잰다. 막히는지 보는 데는 필요 없다).
        let inputs = try await analysisInputs(for: grids, measuringLoudness: false)
        try requireDraftSaves(for: uuids)
        writeStage = WriteStage(String(ui: "미리 보기 1/2단계 · 사본을 만드는 중…"), completed: 0, total: 2, cancellable: true)
        let source = rekordboxDatabase, sourceShare = rekordboxShareRoot ?? RekordboxShare.directory
        let task = Task.detached(priority: .userInitiated) {
            try await WritePreviewSnapshot.withCopy(from: source, shareRoot: sourceShare, grids: grids, merges: merges,
                                                    artworks: artworks.map(\.trackUUID)) { snapshot, share in
                await MainActor.run { self.writeStage = WriteStage(String(ui: "미리 보기 2/2단계 · 바꿀 내용을 검사하는 중…"), completed: 1, total: 2, cancellable: true) }
                try Task.checkCancellation()
                return try RekordboxWriter.write(drafts: drafts, grids: grids, gains: gains, tags: tags, artworks: artworks, analysisInputs: inputs,
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
        return WritePreview(report: report, drafts: drafts, grids: grids, gains: gains, tags: tags, artworks: artworks, playlists: playlistDraft,
                            merges: merges, exclusions: draftExclusionReasons(for: rows))
    }

    /// rekordbox master.db에 쓴다. 쓴 곡의 초안과 쓴 재생 목록 편집은 지우고(백업 폴더에 남는다) 새 스냅샷을 읽는다. 태그는 반영한 값이 새 base가 된다.
    func writeToRekordbox(_ drafts: [CueDraft], grids: [GridDraft] = [], gains: [String: Double] = [:],
                          tags: [TagDraft] = [], artworks: [ArtworkEdit] = [], playlists: PlaylistDraft? = nil,
                          merges: [DuplicateMergeDraft] = []) async throws -> RekordboxWriter.Report {
        try await writeToRekordbox(drafts, grids: grids, gains: gains, tags: tags, artworks: artworks, playlists: playlists, merges: merges,
                                  to: rekordboxDatabase, shareRoot: rekordboxShareRoot)
    }

    /// 같은 앱 쓰기 흐름을 합성 사본에서 확인할 때도 쓰기 관문을 그대로 지난다.
    func writeToRekordbox(_ drafts: [CueDraft], grids: [GridDraft] = [], gains: [String: Double] = [:],
                          tags: [TagDraft] = [], artworks: [ArtworkEdit] = [], playlists: PlaylistDraft? = nil, merges: [DuplicateMergeDraft] = [],
                          to database: URL, shareRoot: URL?) async throws -> RekordboxWriter.Report {
        try Task.checkCancellation()
        defer { writeStage = nil }
        writeFollowUp = []
        let uuids = Set(drafts.map(\.trackUUID)).union(grids.map(\.trackUUID)).union(gains.keys).union(tags.map(\.trackUUID))
            .union(artworks.map(\.trackUUID)).union(merges.flatMap { $0.members.map(\.trackUUID) })
        try requireDraftSaves(for: uuids)
        if playlists != nil { try requirePlaylistDraftSaved() }
        let inputs = try await analysisInputs(for: grids, measuringLoudness: true)
        try Task.checkCancellation()
        try requireDraftSaves(for: uuids)
        writeStage = WriteStage(String(ui: "rekordbox에 쓰는 중…"))
        // 백업은 이 저장소의 백업 폴더에 둔다(합성 사본 시험이 사용자 백업을 밀어내지 않게).
        let backups = backupDirectory
        let report = try await Task.detached(priority: .userInitiated) {
            try RekordboxWriter.write(drafts: drafts, grids: grids, gains: gains, tags: tags, artworks: artworks, analysisInputs: inputs,
                                      playlistDraft: playlists, merges: merges, to: database, dryRun: false,
                                      backups: backups, shareRoot: shareRoot)
        }.value
        // 스냅샷을 다시 읽으면 초안도 파일에서 다시 읽으므로 그 전에 쓴 편집을 뺀다.
        let merged = Set(report.mergeWritten.map(\.trackUUID))
        if !merged.isEmpty {
            let remaining = mergeDrafts.filter { !merged.contains($0.id) }
            saveMergeDraftsAfterWrite(remaining)
        }
        if let playlists { finishPlaylistWrite(playlists, outcomes: report.playlistOutcomes ?? []) }
        for outcome in report.gainWritten {
            // 저장 실패로 DraftWriter에 남은 기록까지 같이 비우려고 파일을 직접 고치지 않는다(#174).
            DraftWriter.removeGain(trackUUID: outcome.trackUUID)
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
        // 쓴 그림 초안을 지우고 목록·덱이 그 곡의 그림을 새로 읽게 한다(바꾸기는 ImagePath가 그대로라 캐시 열쇠를 바꾼다).
        finishArtworkWrite(report)
        let saveWarning = draftSaveWarning(for: uuids)
        // 쓴 재생 목록 편집을 초안에서 빼지 못하면 다음에 같은 편집을 또 쓸 수 있으니 따로 알린다(#174·#175).
        let playlistWarning = playlists != nil && playlistDraftUnsaved
            ? String(ui: "rekordbox에는 썼지만 재생 목록 초안을 정리하지 못했습니다.") + " " + Self.playlistSaveFailureText : nil
        // 화면을 처음부터 다시 불러오지 않고 뒤에서 조용히 다시 읽는다.
        // 덱은 새 스냅샷을 읽은 뒤에만 그 곡을 다시 읽는다(그리드만 바뀐 곡도 초안·그리드를 맞춘다). 읽지 못하면 다음 읽기까지 미룬다.
        writeStage = .reloadingLibrary
        writtenAwaitingReload.formUnion(Set(report.written.map(\.trackUUID)).union(report.gridWritten.map(\.trackUUID))
            .union(report.gainWritten.map(\.trackUUID)).union(report.analysisWritten.map(\.trackUUID)).union(tagWritten)
            .union(report.artworkWritten.map(\.trackUUID))
            .union(merges.filter { merged.contains($0.id) }.flatMap { $0.members.map(\.trackUUID) }))
        let reloaded = await reloadAfterWrite()
        lastWriteBackup = report.backup.map { URL(filePath: $0) }
        finishWriteFollowUp([saveWarning, playlistWarning] + (report.warnings ?? []), reloaded: reloaded, restoring: false)
        return report
    }

    /// 백업으로 되돌린다: DB를 쓰기 전으로 돌리고, 그때 쓴 초안을 DJCrate에 다시 살린다.
    /// 쓴 뒤 같은 곡에 새로 만든 초안은 덮지 않는다(`keepingCurrentDrafts`가 거짓일 때만 백업 초안으로 바꾼다, #175).
    @discardableResult
    func restoreRekordbox(_ backup: RekordboxWriter.Backup) async throws -> URL {
        try await restoreRekordbox(backup, keepingCurrentDrafts: true)
    }

    @discardableResult
    func restoreRekordbox(_ backup: RekordboxWriter.Backup, keepingCurrentDrafts: Bool) async throws -> URL {
        writeFollowUp = []
        writeStage = WriteStage(String(ui: "rekordbox를 복원하는 중…"))
        defer { writeStage = nil }
        // 복원 전에 지금 초안을 정해 둔다(복원 뒤 덱이 다시 저장하는 값과 섞지 않게).
        let kept = keepingCurrentDrafts ? restoreDraftConflicts(backup) : []
        let backups = backupDirectory, database = rekordboxDatabase, shareRoot = rekordboxShareRoot
        let saved = try await Task.detached(priority: .userInitiated) {
            try RekordboxWriter.restore(backup.url, to: database, backups: backups, shareRoot: shareRoot)
        }.value
        func keeps(_ kind: RestoreDraftConflict.Kind, _ uuid: String) -> Bool { kept.contains(RestoreDraftConflict(kind: kind, uuid: uuid)) }
        let restoredMerges = RekordboxWriter.mergeDrafts(in: backup.url)
        if !restoredMerges.isEmpty {
            let keptMerges = mergeDrafts.filter { keeps(.merge, $0.id) }
            let keptIDs = Set(keptMerges.flatMap { $0.members.map(\.trackUUID) })
            let revived = restoredMerges.filter { Set($0.members.map(\.trackUUID)).isDisjoint(with: keptIDs) }
            let restoredIDs = Set(revived.flatMap { $0.members.map(\.trackUUID) })
            let combined = mergeDrafts.filter { Set($0.members.map(\.trackUUID)).isDisjoint(with: restoredIDs) } + revived
            saveMergeDraftsAfterWrite(combined)
        }
        let drafts = RekordboxWriter.contents(of: backup.url).drafts
        for draft in drafts where !keeps(.cue, draft.trackUUID) { DraftWriter.save(draft) }
        let grids = RekordboxWriter.gridDrafts(in: backup.url)
        for grid in grids where !keeps(.grid, grid.trackUUID) { DraftWriter.save(grid) }
        let gains = RekordboxWriter.gainDrafts(in: backup.url)
        for (uuid, gain) in gains where !keeps(.gain, uuid) { DraftWriter.save(gain: gain, trackUUID: uuid) }
        let tags = RekordboxWriter.tagDrafts(in: backup.url)
        replaceTagDrafts(tags.filter { !keeps(.tag, $0.trackUUID) })
        // 그림 초안·사본도 되살리고, 옛 그림으로 돌아온 곡은 목록·덱이 새로 읽게 한다.
        let artwork = restoreArtworkDrafts(from: backup) { keeps(.artwork, $0) }
        let artworkTracks = artwork.tracks
        let artworkWarning = artwork.failed == 0 ? nil : Self.artworkRestoreFailureText(artwork.failed)
        let saveWarning = draftSaveWarning(for: Set(drafts.map(\.trackUUID)).union(grids.map(\.trackUUID)).union(gains.keys), restoring: true)
        let keptWarning = kept.isEmpty ? nil : Self.keptDraftsText(conflictTrackUUIDs(kept).count)
        writeStage = WriteStage(String(ui: "복원한 라이브러리를 읽는 중…"))
        writtenAwaitingReload.formUnion(Set(drafts.map(\.trackUUID)).union(grids.map(\.trackUUID)).union(gains.keys).union(tags.map(\.trackUUID))
            .union(artworkTracks))
        // 재생 목록 편집은 되돌린 rekordbox 상태에 다시 쌓는다. 다시 읽지 못하면 옛 목록 상태에 쌓지 않고 다음 읽기 뒤에 쌓는다.
        playlistEditsAwaitingReload += RekordboxWriter.playlistEdits(in: backup.url)
        let reloaded = await reloadAfterWrite()
        let restoredStaged = restoreStaged(from: backup)
        lastWriteBackup = nil
        finishWriteFollowUp([saveWarning, artworkWarning, keptWarning, Self.keptNewTrackDraftsText(restoredStaged.keptDrafts, kinds: restoredStaged.keptKinds)],
                            reloaded: reloaded, restoring: true)
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
        persistTagDrafts(drafts)
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
    /// 명시한 사본으로 연 창은 스냅샷을 뜨지 않으므로 모른다(nil).
    func libraryChangedSince(_ backup: RekordboxWriter.Backup) async -> Bool? {
        guard Self.snapshotTakeAllowed(arguments: launchArguments, environment: launchEnvironment),
              let expected = backup.finalUpdateCount else { return nil }
        let take = takeLiveSnapshot
        return try? await Task.detached {
            let snapshot = try take(false)
            return try RekordboxWriter.updateCount(of: snapshot) != expected
        }.value
    }
}
