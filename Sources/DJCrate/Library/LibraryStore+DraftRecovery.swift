import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

enum DraftRecoveryKind: CaseIterable, Sendable {
    case tags, cues, grid
    var label: String { switch self { case .tags: String(ui: "태그"); case .cues: String(ui: "큐"); case .grid: String(ui: "그리드") } }
    /// 목록·태그 인스펙터·편집 창이 같은 문구를 쓴다(번역에서 단수·복수가 갈리지 않게 종류마다 한 문장).
    var recoveryButtonTitle: String {
        switch self {
        case .tags: String(ui: "태그 현재값 가져오기…")
        case .cues: String(ui: "큐 현재값 가져오기…")
        case .grid: String(ui: "그리드 현재값 가져오기…")
        }
    }
}

enum RecoveryDraft: Equatable, Sendable {
    case tags(TagDraft), cues(CueDraft), grid(GridDraft)
    var uuid: String { switch self { case let .tags(d): d.trackUUID; case let .cues(d): d.trackUUID; case let .grid(d): d.trackUUID } }
    var kind: DraftRecoveryKind { switch self { case .tags: .tags; case .cues: .cues; case .grid: .grid } }
    var hasChanges: Bool { switch self { case let .tags(d): d.hasChanges; case let .cues(d): d.hasChanges; case let .grid(d): d.hasChanges } }
    func resolved(onto current: Self, choice: DraftRecoveryChoice, sourceMappings: [String: String] = [:]) throws -> Self {
        switch (self, current) {
        case let (.tags(d), .tags(c)): .tags(TagDraftRecovery(draft: d, current: c.base).resolve(choice))
        case let (.cues(d), .cues(c)): .cues(try CueDraftRecovery(draft: d, current: c.base, sourceMappings: sourceMappings).resolve(choice))
        case let (.grid(d), .grid(c)): .grid(try GridDraftRecovery(draft: d, current: c.base).resolve(choice))
        default: throw DraftRecoveryError.ambiguousIdentity
        }
    }
}

struct DraftRecoveryReview: Sendable {
    var original: RecoveryDraft
    var current: RecoveryDraft
    var title: String
    var currentRow: TrackRow?
    var currentGrid: BeatGrid?
    var cueSourceMappings: [String: String] = [:]

    /// 비교 창에서 "내 편집 유지"를 고를 수 없는 이유(미리 알 수 있는 것만)
    var keepRefusal: String? {
        guard let resolved = try? original.resolved(onto: current, choice: .keepEditing, sourceMappings: cueSourceMappings) else { return nil }
        return Self.gridKeepRefusal(original: original, resolved: resolved, currentGrid: currentGrid, lengthSeconds: currentRow?.track.lengthSeconds)
    }

    /// 구간으로 다시 만들 수 없는 현재 그리드에 승인 없는 구간 편집을 얹으면 rekordbox의 박을 통째로 덮으므로 막는다(덱 편집 제한과 같게).
    static func gridKeepRefusal(original: RecoveryDraft, resolved: RecoveryDraft, currentGrid: BeatGrid?, lengthSeconds: Int?) -> String? {
        guard case let .grid(input) = original, input.replacementSource == nil,
              case let .grid(draft) = resolved, draft.hasChanges, let currentGrid,
              GridEditEligibility.reconstructionErrorMilliseconds(of: currentGrid, duration: Double(lengthSeconds ?? 0)) > 2 else { return nil }
        return String(ui: "rekordbox의 현재 그리드는 템포 구간으로 정확히 재현되지 않아 내 그리드 편집을 다시 적용할 수 없으니 현재값을 사용하세요.")
    }
}

extension LibraryStore {
    func recoveryInput(uuid: String, kind: DraftRecoveryKind, home: URL = DJCPaths.userData) -> RecoveryDraft? {
        if kind == .tags { return tagDrafts[uuid].map(RecoveryDraft.tags) }
        if let memory = recoveryMemoryInput?(uuid, kind) { return memory }
        switch kind {
        case .tags: return nil
        case .cues: return (DraftWriter.pendingCue(trackUUID: uuid, directory: home.appending(path: "cue-drafts"))
                ?? CueDraftStore.load(trackUUID: uuid, directory: home.appending(path: "cue-drafts"))).map(RecoveryDraft.cues)
        case .grid: return (DraftWriter.pendingGrid(trackUUID: uuid, directory: home.appending(path: "grid-drafts"))
                ?? GridDraftStore.load(trackUUID: uuid, directory: home.appending(path: "grid-drafts"))).map(RecoveryDraft.grid)
        }
    }

    func prepareDraftRecovery(row: TrackRow, kind: DraftRecoveryKind, home: URL = DJCPaths.userData,
                              readCurrent: ((RecoveryDraft) async throws -> RecoveryDraft)? = nil) async throws -> DraftRecoveryReview {
        guard !isRecoveringDraft, !isWritingRekordbox, !isLoading, allowsLibrarySync?() ?? true,
              !row.isUsb, !row.isStaged, !row.track.isStreaming,
              rowsByUUID[row.track.uuid] != nil,
              let original = recoveryInput(uuid: row.track.uuid, kind: kind, home: home), original.hasChanges else {
            throw DJCError.writeRefused(String(ui: "복구할 초안을 확인하지 못했으니 편집을 저장하고 곡을 다시 선택하세요."))
        }
        isRecoveringDraft = true
        defer { isRecoveringDraft = false }
        DraftWriter.flush()
        let read = try await recoveryCurrent(original, reader: readCurrent)
        try Task.checkCancellation()
        try checkRecoveryInput(original, home: home)
        return DraftRecoveryReview(original: original, current: read.draft, title: read.row?.title ?? row.title,
                                   currentRow: read.row, currentGrid: read.grid)
    }

    func applyDraftRecovery(_ review: DraftRecoveryReview, choice: DraftRecoveryChoice, home: URL = DJCPaths.userData,
                            readCurrent: ((RecoveryDraft) async throws -> RecoveryDraft)? = nil,
                            save: ((RecoveryDraft) throws -> Void)? = nil) async throws {
        guard !isRecoveringDraft else { throw recoveryChangedError() }
        isRecoveringDraft = true
        defer { isRecoveringDraft = false }
        try checkRecoveryInput(review.original, home: home)
        let latest = try await recoveryCurrent(review.original, reader: readCurrent)
        try Task.checkCancellation()
        try checkRecoveryInput(review.original, home: home)
        guard sameRecoveryCurrent(latest.draft, review.current), latest.grid == review.currentGrid else { throw recoveryChangedError() }
        var resolved = try review.original.resolved(onto: latest.draft, choice: choice, sourceMappings: review.cueSourceMappings)
        if case .keepEditing = choice, let refusal = DraftRecoveryReview.gridKeepRefusal(
            original: review.original, resolved: resolved, currentGrid: latest.grid, lengthSeconds: latest.row?.track.lengthSeconds) {
            throw DJCError.writeRefused(refusal)
        }
        if case .keepEditing = choice, case let .grid(original) = review.original, original.replacementSource != nil {
            guard case let .grid(draft) = resolved, let currentGrid = latest.grid,
                  let duration = latest.row?.track.lengthSeconds else { throw recoveryChangedError() }
            // 구간의 실측 BPM이 달라도 전체 저장 박이 이미 원하는 결과면 다시 쓰지 않는다.
            if draft.grid(duration: Double(duration)) == currentGrid {
                resolved = .grid(GridDraft(trackUUID: draft.trackUUID, base: draft.base, segments: draft.base))
            } else if let approved = draft.approvingReplacement(of: currentGrid, duration: Double(duration)) {
                resolved = .grid(approved)
            } else {
                throw DJCError.writeRefused(String(ui: "현재 원본에 대체 그리드를 재적용할 수 없으니 초안을 남기고 그리드 구간을 다시 지정하세요."))
            }
        }
        // 저장과 메모리 갱신 사이에는 양보하지 않는다. 먼저 걸린 비동기 저장부터 끝낸다.
        DraftWriter.flush()
        try checkRecoveryInput(review.original, home: home)
        if let save { try save(resolved) } else {
            do { try Self.saveRecoveryDraft(resolved, home: home) }
            catch {
                // 실패한 새 base가 pending에 남지 않게 기존 입력을 직렬 큐에 돌려놓는다.
                switch review.original {
                case .tags: break
                case let .cues(d): DraftWriter.save(d, directory: home.appending(path: "cue-drafts"))
                case let .grid(d): DraftWriter.save(d, directory: home.appending(path: "grid-drafts"))
                }
                DraftWriter.flush()
                throw error
            }
        }
        undoManager?.removeAllActions(withTarget: self)
        switch resolved {
        case let .tags(draft):
            tagDrafts[draft.trackUUID] = draft.hasChanges ? draft : nil
            tagRevision += 1
            updateEdited(draft.trackUUID)
        case let .cues(draft):
            cueDraftChanged(draft)
            draftChanged(trackUUID: draft.trackUUID, kind: .cue, exists: draft.hasChanges)
        case let .grid(draft): draftChanged(trackUUID: draft.trackUUID, kind: .grid, exists: draft.hasChanges)
        }
        if let row = latest.row { updateRecoveryRow(row) }
        onDraftRecovered?(resolved, latest.row.flatMap { rowsByUUID[$0.track.uuid] }, latest.grid)
        refreshBase()
    }

    private func checkRecoveryInput(_ original: RecoveryDraft, home: URL) throws {
        guard !isWritingRekordbox, !isLoading, allowsLibrarySync?() ?? true,
              rowsByUUID[original.uuid] != nil,
              recoveryInput(uuid: original.uuid, kind: original.kind, home: home) == original else {
            throw recoveryChangedError()
        }
    }

    private func recoveryChangedError() -> DJCError {
        .writeRefused(String(ui: "비교 중 입력이나 현재값이 바뀌어 초안을 그대로 남겼으니 현재값을 다시 가져오세요."))
    }

    private func sameRecoveryCurrent(_ a: RecoveryDraft, _ b: RecoveryDraft) -> Bool {
        switch (a, b) {
        case let (.tags(a), .tags(b)): return a.base == b.base
        case let (.grid(a), .grid(b)): return a.base == b.base
        case let (.cues(a), .cues(b)):
            let lhs = a.base.sorted { ($0.sourceID ?? "") < ($1.sourceID ?? "") }
            let rhs = b.base.sorted { ($0.sourceID ?? "") < ($1.sourceID ?? "") }
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
                $0.sourceID == $1.sourceID && $0.kind == $1.kind && $0.time == $1.time && $0.name == $1.name && $0.loop == $1.loop
            }
        default: return false
        }
    }

    private struct RecoveryRead {
        var draft: RecoveryDraft
        var row: TrackRow?
        var grid: BeatGrid?
    }

    private func recoveryCurrent(_ original: RecoveryDraft, reader: ((RecoveryDraft) async throws -> RecoveryDraft)?) async throws -> RecoveryRead {
        if let reader { return RecoveryRead(draft: try await reader(original), row: nil, grid: nil) }
        let source: URL
        if Self.explicitDatabaseRequested(arguments: launchArguments, environment: launchEnvironment) {
            guard let snapshotURL else { throw recoveryChangedError() }
            source = snapshotURL
        } else { source = LibrarySnapshot.rekordboxDirectory(in: launchEnvironment).appending(path: "master.db") }
        let share = LibrarySnapshot.rekordboxDirectory(in: launchEnvironment).appending(path: "share")
        let grids: [GridDraft]
        if case let .grid(draft) = original { grids = [draft] } else { grids = [] }
        let task = Task.detached(priority: .userInitiated) {
            try await WritePreviewSnapshot.withCopy(from: source, shareRoot: share, grids: grids) { database, copiedShare in
                let library = try RekordboxLibrary.load(snapshot: database)
                let tracks = library.tracks.filter { $0.uuid == original.uuid }
                guard tracks.count == 1, let track = tracks.first, !track.isStreaming else {
                    throw DJCError.writeRefused(String(ui: "현재 라이브러리에서 이 곡을 확인하지 못했으니 곡을 다시 선택하세요. 초안은 그대로 남겼습니다."))
                }
                let row = TrackRow(track: track, cues: library.cues(for: track), playCount: library.playCounts[track.id] ?? 0)
                let current: RecoveryDraft
                var grid: BeatGrid?
                switch original {
                case .tags: current = .tags(TagDraft(track: track))
                case let .cues(draft):
                    let cues = CueDraft(trackUUID: track.uuid, rekordboxCues: row.cues)
                    current = .cues(try CueDraftRecovery(draft: draft, current: cues.base).resolve(.useCurrent))
                case .grid:
                    if let path = track.analysisDataPath, !path.isEmpty {
                        grid = try BeatGrid.load(anlz: copiedShare.appending(path: String(path.drop(while: { $0 == "/" }))))
                    }
                    let segments = grid.map(GridDraft.segments(from:)) ?? []
                    current = .grid(GridDraft(trackUUID: track.uuid, base: segments, segments: segments))
                }
                return RecoveryRead(draft: current, row: row, grid: grid)
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func saveRecoveryDraft(_ draft: RecoveryDraft, home: URL) throws {
        let cueDirectory = home.appending(path: "cue-drafts"), gridDirectory = home.appending(path: "grid-drafts")
        switch draft {
        case let .tags(d):
            let directory = home.appending(path: "tag-drafts")
            DraftWriter.save([d], directory: directory)
            DraftWriter.flush()
            guard !DraftWriter.failedTagSaveUUIDs(in: directory).contains(d.trackUUID) else {
                throw DJCError.writeRefused(DraftWriter.tagSaveFailureMessage)
            }
        case let .cues(d): DraftWriter.save(d, directory: cueDirectory)
        case let .grid(d): DraftWriter.save(d, directory: gridDirectory)
        }
        DraftWriter.flush()
        let failures = DraftWriter.failures(cueDirectory: cueDirectory, gridDirectory: gridDirectory)
        let kind: DraftWriter.Kind?
        switch draft { case .tags: kind = nil; case .cues: kind = .cue; case .grid: kind = .grid }
        if let kind, let failure = failures.first(where: { $0.kind == kind && $0.trackUUID == draft.uuid }) {
            throw DJCError.writeRefused(failure.message)
        }
    }
}
