import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// rekordbox 컬렉션에 곡을 바로 넣고 뺀다(rekordbox를 켜지 않고). 흐름은 `ReflectionCoordinator`.
/// 넣기: 추가한 곡의 태그 초안·그리드 초안·음량으로 곡 행과 분석 파일(파형·그리드·오토게인)을 만들고, 큐 초안과 고른 키(#5)도 같은 트랜잭션에서 쓴다.
/// 분석까지 붙이는 곡은 음원의 아트워크로 아트워크 파일도 만든다(rekordbox가 분석할 때 뽑는 것처럼, `RekordboxTrackWriter.writesArtwork`).
/// 빼기: 곡 행과 딸린 큐·재생 목록 항목·재생 기록·분석 파일·아트워크 파일을 지운다(음원 파일은 그대로).
/// 둘 다 쓰기 직전 백업을 떠서 "되돌리기"로 무를 수 있다.
extension LibraryStore {
    struct TrackAddPreview {
        /// 사본에서 DB만 시험해 본 결과(분석 없이)
        var report: RekordboxTrackWriter.Report
        var plans: [TrackAddPlan]
        /// 경로 → 추가한 곡 UUID
        var stagedUUIDs: [String: String]
        /// 경로 → 분석을 붙이지 못하는 이유(곡은 분석 전 상태로 넣는다)
        var withoutAnalysis: [String: String]
        /// 경로 → 함께 넣을 큐(추가한 곡의 큐 초안)
        var cues: [String: [EditableCue]] = [:]
        /// 경로 → 함께 쓸 키(사용자가 고른 Camelot 이름, #5)
        var keys: [String: String] = [:]
        /// 계획을 만들지 못한 곡(이름: 이유)
        var unreadable: [String]
    }

    struct TrackDeletePreview {
        /// 사본에서 시험해 본 결과
        var report: RekordboxTrackWriter.Report
        var contentIDs: [String]
    }

    /// 백업 폴더에 남겨 두는 추가 목록(되돌리면 추가 목록으로 돌아온다)
    nonisolated static let stagedBackupName = "djc-staged.json"

    /// 백업 폴더에 남긴 추가 목록. 옛 백업이거나 저장에 실패했거나 읽지 못하면 nil이다.
    nonisolated static func stagedTracks(in backup: URL) -> [StagedTrack]? {
        guard let data = try? Data(contentsOf: backup.appending(path: stagedBackupName)) else { return nil }
        return try? JSONDecoder().decode([StagedTrack].self, from: data)
    }

    // MARK: - 넣기

    func trackAddTargets(_ rows: [TrackRow]) -> [TrackRow] { rows.filter(\.isStaged) }

    /// 곡마다 계획(파일 태그 + 태그 초안)을 만들고, 새 스냅샷 사본으로 DB 쓰기를 시험한다.
    func previewTrackAdd(rows: [TrackRow]) async throws -> TrackAddPreview {
        // 저장에 실패한 큐·그리드 초안이 있으면 디스크의 옛 초안을 넣지 않는다(#170).
        try requireDraftSaves(for: Set(trackAddTargets(rows).map(\.track.uuid)))
        // 미리 보기는 라이브에서 스냅샷을 뜬다: 명시한 사본으로 연 창은 사용자 스냅샷 폴더를 바꾸지 않게 막는다
        guard Self.snapshotTakeAllowed(arguments: launchArguments, environment: launchEnvironment) else {
            throw DJCError.writeRefused(Self.snapshotRefusedMessage)
        }
        let tracks = trackAddTargets(rows).compactMap { row in staged.first { $0.id == row.id } }
        var plans: [TrackAddPlan] = [], uuids: [String: String] = [:], without: [String: String] = [:], unreadable: [String] = []
        var cues: [String: [EditableCue]] = [:], keys: [String: String] = [:]
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            writeStage = WriteStage(String(ui: "넣을 곡을 확인하는 중…"), completed: index, total: tracks.count, cancellable: true)
            let url = URL(filePath: track.path)
            do {
                var tags = try await AudioTags.read(url: url)
                if let fields = tagDrafts[track.uuid]?.fields { Self.apply(fields, to: &tags) }
                let plan = try TrackAddPlan.make(url: url, tags: tags)
                plans.append(plan)
                uuids[plan.path] = track.uuid
                if let draft = CueDraftStore.load(trackUUID: track.uuid), !draft.cues.isEmpty { cues[plan.path] = draft.cues }
                // 고른 키는 곡을 넣은 뒤 같은 쓰기에서 쓴다(넣을 때 `KeyID` '0' → 키 저장). 음원 파일의 키 태그는 그대로다.
                if let key = confirmedStagedKey(uuid: track.uuid) { keys[plan.path] = key }
                if GridDraftStore.load(trackUUID: track.uuid)?.segments.first.map({ $0.bpm > 0 }) != true {
                    without[plan.path] = gridJob != nil ? String(ui: "그리드를 아직 추정하는 중") : String(ui: "그리드가 없음")
                } else if let reason = AudioFacts.read(url: url).unsupported {
                    without[plan.path] = reason
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                unreadable.append("\(track.title): \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()
        writeStage = WriteStage(String(ui: "미리 보기 1/2단계 · 사본을 만드는 중…"), completed: 0, total: 2, cancellable: true)
        // 사본으로 DB만 시험한다(분석 파일은 만들지 않지만 큐는 함께 시험해 막히는 이유를 미리 본다).
        let take = takeLiveSnapshot
        // 백업은 이 저장소의 백업 폴더에 둔다(시험 쓰기가 사용자 백업을 밀어내지 않게).
        let backups = backupDirectory
        let report = try await Task.detached(priority: .userInitiated) { [plans, cues, keys] in
            let snapshot = try take(false)
            await MainActor.run { self.writeStage = WriteStage(String(ui: "미리 보기 2/2단계 · 바꿀 내용을 검사하는 중…"), completed: 1, total: 2, cancellable: true) }
            return try RekordboxTrackWriter.add(plans, cues: cues, keys: keys, to: snapshot, dryRun: true, backups: backups)
        }.value
        return TrackAddPreview(report: report, plans: plans, stagedUUIDs: uuids, withoutAnalysis: without, cues: cues, keys: keys,
                               unreadable: unreadable)
    }

    /// 태그 초안(시트·인스펙터에서 고친 값)을 파일 태그 위에 얹는다. 빈 칸은 태그 없음.
    nonisolated static func apply(_ fields: TagFields, to tags: inout AudioTags) {
        func text(_ value: String) -> String? { value.isEmpty ? nil : value }
        tags.title = text(fields.title) ?? tags.title
        tags.artist = text(fields.artist)
        tags.album = text(fields.album)
        tags.albumArtist = text(fields.albumArtist)
        tags.genre = text(fields.genre)
        tags.composer = text(fields.composer)
        tags.year = Int(fields.year)
        tags.trackNumber = Int(fields.trackNumber)
        tags.comment = text(fields.comment)
    }

    /// rekordbox 라이브러리에 넣는다(큐 초안·고른 키도 함께). 넣은 곡은 추가 목록에서 빼고(백업에 남긴다),
    /// 큐가 막힌 곡의 큐 초안, 분석을 못 붙인 곡의 그리드 초안, 키가 막힌 곡의 키는 새 곡의 초안으로 옮긴다.
    func addTracksToRekordbox(_ preview: TrackAddPreview) async throws -> RekordboxTrackWriter.Report {
        try await addTracksToRekordbox(preview, to: rekordboxDatabase, shareRoot: rekordboxShareRoot)
    }

    /// - Parameters:
    ///   - database: 쓸 DB. 합성 사본 시험이 아니면 라이브 DB.
    ///   - shareRoot: 사본일 때 분석 파일 뿌리(`RekordboxTrackWriter.add`와 같다)
    func addTracksToRekordbox(_ preview: TrackAddPreview, to database: URL, shareRoot: URL?) async throws -> RekordboxTrackWriter.Report {
        // 미리 본 뒤 저장이 실패했을 수도 있다(그러면 디스크의 초안은 옛것이다).
        try requireDraftSaves(for: Set(preview.stagedUUIDs.values))
        let accepted = Set(preview.report.added.filter(\.written).map(\.path))
        let plans = preview.plans.filter { accepted.contains($0.path) }
        let analysisPlans = plans.filter { preview.withoutAnalysis[$0.path] == nil }
        writeStage = WriteStage(String(ui: "음량을 재는 중…"), completed: 0, total: analysisPlans.count, cancellable: true)
        defer { writeStage = nil }
        var analyses: [String: RekordboxTrackWriter.Analysis] = [:]
        for (index, plan) in analysisPlans.enumerated() {
            try Task.checkCancellation()
            writeStage = WriteStage(String(ui: "음량을 재는 중…"), completed: index, total: analysisPlans.count, cancellable: true)
            guard let uuid = preview.stagedUUIDs[plan.path], let grid = GridDraftStore.load(trackUUID: uuid) else { continue }
            let url = URL(filePath: plan.path)
            var loudness = LoudnessCache.shared.value(for: url)
            if loudness == nil {
                loudness = try? await Task.detached(priority: .userInitiated) { try Loudness.measure(fileAt: url) }.value
                if let loudness { LoudnessCache.shared.store(loudness, for: url) }
            }
            try Task.checkCancellation()
            analyses[plan.path] = .init(segments: grid.segments, loudness: loudness?.integrated,
                                        peak: loudness.map { pow(10, $0.peak / 20) } ?? 1)
        }
        try Task.checkCancellation()
        writeStage = WriteStage(String(ui: "rekordbox에 곡과 분석 파일을 넣는 중…"))
        let cues = preview.cues.filter { accepted.contains($0.key) }
        let keys = preview.keys.filter { accepted.contains($0.key) }
        let backups = backupDirectory
        let report = try await Task.detached(priority: .userInitiated) { [plans, analyses, cues, keys] in
            try RekordboxTrackWriter.add(plans, analyses: analyses, cues: cues, keys: keys, to: database, shareRoot: shareRoot,
                                         dryRun: false, backups: backups)
        }.value
        // 초안 옮기기: 큐가 막힌 곡은 새 곡의 반영 대기로, 그리드는 분석 파일에 들어갔으면 끝(못 붙였으면 새 곡 초안으로).
        var unstaged: Set<String> = []
        for outcome in report.added where outcome.written {
            guard let old = preview.stagedUUIDs[outcome.path], let new = outcome.uuid else { continue }
            unstaged.insert(old)
            if outcome.cuesWritten == nil, let cues = CueDraftStore.load(trackUUID: old), !cues.cues.isEmpty {
                var draft = CueDraft(trackUUID: new, rekordboxCues: [])
                for var cue in cues.cues {
                    cue.sourceID = nil
                    draft.place(cue)
                }
                DraftWriter.save(draft)
            }
            if analyses[outcome.path] == nil, var grid = GridDraftStore.load(trackUUID: old) {
                grid.trackUUID = new
                grid.base = []
                DraftWriter.save(grid)
            }
        }
        // 키가 막힌 곡의 키도 같은 자리에서(다시 읽기 전에) 새 곡의 초안으로 옮긴다: 읽기가 실패해도 결과 창이 알린 "쓰기 대기"가 사실이 되게.
        moveBlockedKeys(report, keys: keys)
        DraftWriter.flush()
        // 덱에 올린 추가한 곡을 넣었으면 새로 읽을 때 새 rekordbox 곡으로 바꿔 올린다(덱을 비우지 않게).
        if let deckUUID = deckTrackID.flatMap({ rowsByID[$0] }).flatMap({ $0.isStaged ? $0.track.uuid : nil }),
           let moved = report.added.first(where: { $0.written && preview.stagedUUIDs[$0.path] == deckUUID })?.contentID {
            moveDeckTrack(to: moved)
        }
        let removed = unstage(uuids: unstaged)
        if let backup = report.backup, !removed.isEmpty, let data = try? JSONEncoder().encode(removed) {
            try? data.write(to: URL(filePath: backup).appending(path: Self.stagedBackupName))
        }
        if let backup = report.backup { saveStagedDrafts(uuids: unstaged, in: URL(filePath: backup)) }
        writeStage = WriteStage(String(ui: "넣은 곡을 읽는 중…"))
        await takeSnapshot(quiet: true, refreshITunes: false)
        if let first = report.added.first(where: \.written), let id = first.contentID {
            sidebar = .filter(.all)
            search = ""
            selection = [id]
        }
        lastWriteBackup = report.backup.map { URL(filePath: $0) }
        return report
    }

    /// 넣은 추가 목록 곡의 태그·큐·그리드 초안을 백업에 둔다. 넣은 뒤 그 곡 UUID의 초안은 어느 곡에도 이어지지 않아(연결 안 된 초안, #175)
    /// 쓰기 대기 목록에서 버릴 수 있다. 백업에 있으면 "쓰기 전으로 복원…"이 곡을 추가 목록으로 되돌리며 이 초안도 되살린다(#197).
    /// 백업 폴더의 초안 모양은 큐·그리드·태그 쓰기와 같아 복원 흐름(`restoreRekordbox`)이 그대로 읽는다.
    private func saveStagedDrafts(uuids: Set<String>, in backup: URL) {
        func put<T: Encodable>(_ draft: T, folder: String, uuid: String) {
            let directory = backup.appending(path: folder)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(draft).write(to: directory.appending(path: "\(uuid).json"), options: .atomic)
        }
        for uuid in uuids.sorted() {
            if let draft = CueDraftStore.load(trackUUID: uuid), draft.hasChanges { put(draft, folder: "cue-drafts", uuid: uuid) }
            if let grid = GridDraftStore.load(trackUUID: uuid), !grid.segments.isEmpty { put(grid, folder: "grid-drafts", uuid: uuid) }
            if let tag = tagDrafts[uuid], tag.hasChanges { put(tag, folder: "tag-drafts", uuid: uuid) }
        }
    }

    /// 키가 막혀 키 없이 넣은 곡은 고른 키를 새 곡의 키 초안으로 남긴다(막힌 큐를 옮기는 것과 같다: 고른 키가 조용히 사라지지 않게).
    /// 기준은 쓰기 결과(`keyBase`, 넣은 곡의 태그 값)에서 만들어 다시 읽기보다 먼저 저장한다. 읽기가 실패해 새 곡 행이 아직 없어도 초안이 남고,
    /// 나중에 읽으면 곡 행의 값과 같아 기준 어긋남으로 막히지 않는다(#197).
    private func moveBlockedKeys(_ report: RekordboxTrackWriter.Report, keys: [String: String]) {
        var moved: [TagDraft] = []
        for outcome in report.added where outcome.written && outcome.keyReason != nil {
            guard let uuid = outcome.uuid, let key = keys[outcome.path], let base = outcome.keyBase else { continue }
            var draft = TagDraft(trackUUID: uuid, base: base)
            draft.fields.musicalKey = key
            moved.append(draft)
        }
        replaceTagDrafts(moved)
    }

    // MARK: - 빼기

    func trackDeleteTargets(_ rows: [TrackRow]) -> [TrackRow] { isITunesSelection ? [] : rows.filter { !$0.isStaged && !$0.track.isStreaming } }

    func previewTrackDelete(rows: [TrackRow]) async throws -> TrackDeletePreview {
        guard Self.snapshotTakeAllowed(arguments: launchArguments, environment: launchEnvironment) else {
            throw DJCError.writeRefused(Self.snapshotRefusedMessage)
        }
        let ids = trackDeleteTargets(rows).map(\.track.id)
        try Task.checkCancellation()
        writeStage = WriteStage(String(ui: "미리 보기 1/2단계 · 사본을 만드는 중…"), completed: 0, total: 2, cancellable: true)
        let take = takeLiveSnapshot
        let backups = backupDirectory
        let report = try await Task.detached(priority: .userInitiated) {
            let snapshot = try take(false)
            await MainActor.run { self.writeStage = WriteStage(String(ui: "미리 보기 2/2단계 · 바꿀 내용을 검사하는 중…"), completed: 1, total: 2, cancellable: true) }
            return try RekordboxTrackWriter.delete(contentIDs: ids, from: snapshot, dryRun: true, backups: backups)
        }.value
        try Task.checkCancellation()
        return TrackDeletePreview(report: report, contentIDs: ids)
    }

    func deleteTracksFromRekordbox(_ preview: TrackDeletePreview) async throws -> RekordboxTrackWriter.Report {
        try await deleteTracksFromRekordbox(preview, from: rekordboxDatabase, shareRoot: rekordboxShareRoot)
    }

    func deleteTracksFromRekordbox(_ preview: TrackDeletePreview, from database: URL, shareRoot: URL?) async throws -> RekordboxTrackWriter.Report {
        guard !isITunesSelection else { throw DJCError.writeRefused(String(ui: "iTunes 동기화 목록의 곡은 Music에서 빼세요.")) }
        let ids = preview.report.deleted.filter(\.written).compactMap(\.contentID)
        try Task.checkCancellation()
        writeStage = WriteStage(String(ui: "rekordbox에서 곡을 빼는 중…"))
        defer { writeStage = nil }
        let backups = backupDirectory
        let report = try await Task.detached(priority: .userInitiated) {
            try RekordboxTrackWriter.delete(contentIDs: ids, from: database, shareRoot: shareRoot,
                                            dryRun: false, backups: backups)
        }.value
        selection.subtract(Set(report.deleted.filter(\.written).compactMap(\.contentID)))
        writeStage = WriteStage(String(ui: "라이브러리를 다시 읽는 중…"))
        await takeSnapshot(quiet: true, refreshITunes: false)
        lastWriteBackup = report.backup.map { URL(filePath: $0) }
        return report
    }

    // MARK: - 되돌린 뒤

    struct RestoredStaged {
        /// 추가 목록에 다시 넣은 곡 수
        var restaged = 0
        /// 되돌린 새 곡에 넣은 뒤 만든 태그 초안 가운데 지우지 않고 연결 안 된 초안으로 남긴 곡 수
        var keptTagDrafts = 0
    }

    /// 곡 추가를 되돌렸으면 그 곡들을 추가 목록에 다시 넣고, 새 곡으로 옮겼던 초안을 지운다.
    /// 새 곡에 사용자가 넣은 뒤 만든 태그 초안은 지우지 않고 연결 안 된 초안으로 남긴다(쓰기 대기 목록에서 버릴 수 있다, #197).
    /// 키가 막혀 새 곡으로 옮겨 둔 키만 있는 초안은 지운다(추가 목록 곡에 돌아온 키 초안이 같은 값을 들고 있어 다시 넣으면 함께 쓴다).
    @discardableResult
    func restoreStaged(from backup: RekordboxWriter.Backup) -> RestoredStaged {
        resetPlaylistImports(contentIDs: Set(backup.trackReport?.added.filter(\.written).compactMap(\.contentID) ?? []))
        let outcomes = backup.trackReport?.added.filter { $0.written && $0.uuid != nil } ?? []
        let added = Set(outcomes.compactMap(\.uuid))
        for uuid in added {
            // 저장 실패로 DraftWriter에 남은 기록까지 같이 비우려고 파일을 직접 지우지 않는다(#172).
            DraftWriter.removeCue(trackUUID: uuid)
            DraftWriter.removeGrid(trackUUID: uuid)
            draftChanged(trackUUID: uuid, kind: .cue, exists: false)
            draftChanged(trackUUID: uuid, kind: .grid, exists: false)
        }
        let tracks = Self.stagedTracks(in: backup.url)
        var result = RestoredStaged()
        var cleared: [TagDraft] = []
        for outcome in outcomes {
            guard let uuid = outcome.uuid, let draft = tagDrafts[uuid] else { continue }
            let stagedUUID = tracks?.first { URL(filePath: $0.path).path.precomposedStringWithCanonicalMapping == outcome.path }?.uuid
            // 옮겨 둔 키 그대로인지: 키 막힘 기록이 있고, 키만 고친 초안이며, 그 키가 추가 목록 곡의 고른 키와 같다. 모르면 사용자 초안으로 본다.
            let isMovedKey = outcome.keyReason != nil && draft.changedKeys == [.musicalKey]
                && stagedUUID.flatMap { confirmedStagedKey(uuid: $0) } == draft.fields.musicalKey
            if isMovedKey { cleared.append(TagDraft(trackUUID: uuid, base: TagFields())) } else { result.keptTagDrafts += 1 }
        }
        replaceTagDrafts(cleared)
        if !added.isEmpty, let warning = draftSaveWarning(for: added, restoring: true) { reportLibraryError(warning) }
        if let tracks { result.restaged = restage(tracks) }
        // 되돌린 곡을 추가 목록에 다시 넣었으니 그 곡의 초안은 더는 연결 안 된 초안이 아니고, 남긴 새 곡 초안은 연결 안 된 초안이다.
        refreshUnlinkedDrafts()
        return result
    }

    static func keptNewTrackDraftsText(_ count: Int) -> String? {
        count == 0 ? nil : String(ui: "넣은 뒤 새 곡에 만든 태그 초안 \(count)곡은 지우지 않고 연결되지 않은 초안으로 남겼습니다. 필요 없으면 ‘연결되지 않은 초안 보기…’에서 버리세요.")
    }
}
