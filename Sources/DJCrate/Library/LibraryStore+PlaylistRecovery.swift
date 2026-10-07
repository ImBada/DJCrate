import DJCDomain
import Foundation
import RekordboxKit

struct PlaylistRecoveryCurrent: Equatable, Sendable {
    var layout: PlaylistLayout
    var contentIDs: Set<String>
    var titles: [String: String]
    var rows: [String: TrackRow]
}

struct PlaylistRecoveryReview: Sendable {
    var original: PlaylistDraft
    var current: PlaylistRecoveryCurrent
    var playlistID: String
    var recovery: PlaylistDraft.Recovery

    var blockedOffsets: [Int] {
        let blocked = original.project(onto: current.layout, contentIDs: current.contentIDs).blocked
        return original.steps.indices.filter { original.steps[$0].edit.playlist.layoutID == playlistID && blocked[$0] != nil }
    }
}

extension LibraryStore {
    var blockedPlaylistRecoveryIDs: [String] {
        var seen = Set<String>()
        return zip(playlistDraft.steps, playlistProjection.blocked).compactMap { step, reason in
            let id = step.edit.playlist.layoutID
            return reason != nil && seen.insert(id).inserted ? id : nil
        }
    }

    /// - Parameter prefetched: 복구 시트가 재생 목록 줄 여럿을 위해 한 번 읽어 둔 현재 라이브러리(`readPlaylistRecoveryPrefetch`)
    func preparePlaylistRecovery(playlist id: String, prefetched: PlaylistRecoveryCurrent? = nil) async throws -> PlaylistRecoveryReview {
        guard playlistRecoveryAllowed, !isRecoveringDraft else { throw playlistRecoveryChanged() }
        let original = playlistDraft
        isRecoveringDraft = true
        defer { isRecoveringDraft = false }
        let current: PlaylistRecoveryCurrent
        if let prefetched { current = prefetched } else { current = try await readPlaylistRecoveryCurrent() }
        try Task.checkCancellation()
        guard playlistRecoveryAllowed, playlistDraft == original else { throw playlistRecoveryChanged() }
        let review = PlaylistRecoveryReview(original: original, current: current, playlistID: id,
                                           recovery: original.recovering(playlist: id, rekordbox: current.layout, contentIDs: current.contentIDs))
        guard !review.blockedOffsets.isEmpty else { throw playlistRecoveryChanged() }
        return review
    }

    /// - Parameter latest: 복구 시트가 저장하기 전에 한 번 다시 읽은 현재 라이브러리
    func applyPlaylistRecovery(_ review: PlaylistRecoveryReview, reapply: Bool, latest prefetched: PlaylistRecoveryCurrent? = nil) async throws {
        guard playlistRecoveryAllowed, !isRecoveringDraft, playlistDraft == review.original else { throw playlistRecoveryChanged() }
        isRecoveringDraft = true
        defer { isRecoveringDraft = false }
        let current: PlaylistRecoveryCurrent
        if let prefetched { current = prefetched } else { current = try await readPlaylistRecoveryCurrent() }
        try Task.checkCancellation()
        guard playlistRecoveryAllowed, playlistDraft == review.original, current == review.current else { throw playlistRecoveryChanged() }
        var resolved = review.original
        if reapply {
            guard !review.recovery.reapplied.isEmpty else { throw playlistRecoveryChanged() }
            resolved = review.recovery.draft
        } else { resolved.removeSteps(at: review.blockedOffsets) }
        // 새 기준을 저장하지 못했으면 메모리에도 적용하지 않아 다음 쓰기에서 조용히 풀리지 않는다.
        try playlistDraftSaver(resolved)
        playlistDraft = resolved
        playlistDraftUnsaved = false
        rekordboxPlaylists = current.layout
        let projected = resolved.project(onto: current.layout, contentIDs: current.contentIDs).layout
        let visibleIDs = Set(projected.subtree(of: review.playlistID).flatMap { projected.item($0)?.trackIDs ?? [] })
        for id in visibleIDs {
            if let row = current.rows[id] { updateRecoveryRow(row) }
        }
        undoManager?.removeAllActions(withTarget: self)
        refreshPlaylists()
    }

    private var playlistRecoveryAllowed: Bool {
        !isWritingRekordbox && !isLoading && (allowsLibrarySync?() ?? true)
    }

    private func playlistRecoveryChanged() -> DJCError {
        .writeRefused(String(ui: "비교 중 입력이나 현재값이 바뀌어 초안을 그대로 남겼으니 현재값을 다시 가져오세요."))
    }

    /// 복구 시트가 재생 목록 줄 전체를 위해 현재 라이브러리를 한 번 읽는다(줄마다 사본을 뜨지 않게, #232).
    func readPlaylistRecoveryPrefetch() async throws -> PlaylistRecoveryCurrent {
        guard playlistRecoveryAllowed, !isRecoveringDraft else { throw playlistRecoveryChanged() }
        isRecoveringDraft = true
        defer { isRecoveringDraft = false }
        let current = try await readPlaylistRecoveryCurrent()
        try Task.checkCancellation()
        return current
    }

    private func readPlaylistRecoveryCurrent() async throws -> PlaylistRecoveryCurrent {
        recoverySnapshotReads += 1
        let source: URL
        if Self.explicitDatabaseRequested(arguments: launchArguments, environment: launchEnvironment), let snapshotURL {
            source = snapshotURL
        } else { source = rekordboxDatabase }
        let share = rekordboxShareRoot ?? source.deletingLastPathComponent().appending(path: "share")
        let task = Task.detached(priority: .userInitiated) {
            try await WritePreviewSnapshot.withCopy(from: source, shareRoot: share) { database, _ in
                let library = try RekordboxLibrary.load(snapshot: database)
                return PlaylistRecoveryCurrent(layout: PlaylistLayout(rekordbox: library.playlists),
                                               contentIDs: Set(library.tracks.map(\.id)),
                                               titles: Dictionary(uniqueKeysWithValues: library.tracks.map { ($0.id, $0.title) }),
                                               rows: Dictionary(uniqueKeysWithValues: library.tracks.map { track in
                                                   (track.id, TrackRow(track: track, cues: library.cues(for: track),
                                                                       playCount: library.playCounts[track.id] ?? 0))
                                               }))
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
