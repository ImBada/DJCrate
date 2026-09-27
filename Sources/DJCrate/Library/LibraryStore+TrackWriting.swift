import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// rekordbox 컬렉션에 곡을 바로 넣고 뺀다(rekordbox를 켜지 않고). 흐름은 `ReflectionCoordinator`.
/// 넣기: 추가한 곡의 태그 초안·그리드 초안·음량으로 곡 행과 분석 파일(파형·그리드·오토게인)을 만들고, 큐 초안도 같은 트랜잭션에서 쓴다.
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

    // MARK: - 넣기

    func trackAddTargets(_ rows: [TrackRow]) -> [TrackRow] { rows.filter(\.isStaged) }

    /// 곡마다 계획(파일 태그 + 태그 초안)을 만들고, 새 스냅샷 사본으로 DB 쓰기를 시험한다.
    func previewTrackAdd(rows: [TrackRow]) async throws -> TrackAddPreview {
        DraftWriter.flush()
        let tracks = trackAddTargets(rows).compactMap { row in staged.first { $0.id == row.id } }
        var plans: [TrackAddPlan] = [], uuids: [String: String] = [:], without: [String: String] = [:], unreadable: [String] = []
        var cues: [String: [EditableCue]] = [:]
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
        let report = try await Task.detached(priority: .userInitiated) { [plans, cues] in
            let snapshot = try LibrarySnapshot.take()
            await MainActor.run { self.writeStage = WriteStage(String(ui: "미리 보기 2/2단계 · 바꿀 내용을 검사하는 중…"), completed: 1, total: 2, cancellable: true) }
            return try RekordboxTrackWriter.add(plans, cues: cues, to: snapshot, dryRun: true, backups: DJCPaths.rekordboxBackups)
        }.value
        return TrackAddPreview(report: report, plans: plans, stagedUUIDs: uuids, withoutAnalysis: without, cues: cues, unreadable: unreadable)
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

    /// rekordbox 라이브러리에 넣는다(큐 초안도 함께). 넣은 곡은 추가 목록에서 빼고(백업에 남긴다),
    /// 큐가 막힌 곡의 큐 초안과 분석을 못 붙인 곡의 그리드 초안은 새 곡으로 옮긴다.
    func addTracksToRekordbox(_ preview: TrackAddPreview) async throws -> RekordboxTrackWriter.Report {
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
        let report = try await Task.detached(priority: .userInitiated) { [plans, analyses, cues] in
            try RekordboxTrackWriter.add(plans, analyses: analyses, cues: cues, dryRun: false, backups: DJCPaths.rekordboxBackups)
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
        writeStage = WriteStage(String(ui: "넣은 곡을 읽는 중…"))
        await takeSnapshot(quiet: true)
        if let first = report.added.first(where: \.written), let id = first.contentID {
            sidebar = .filter(.all)
            search = ""
            selection = [id]
        }
        lastWriteBackup = report.backup.map { URL(filePath: $0) }
        return report
    }

    // MARK: - 빼기

    func trackDeleteTargets(_ rows: [TrackRow]) -> [TrackRow] { isITunesSelection ? [] : rows.filter { !$0.isStaged && !$0.track.isStreaming } }

    func previewTrackDelete(rows: [TrackRow]) async throws -> TrackDeletePreview {
        let ids = trackDeleteTargets(rows).map(\.track.id)
        try Task.checkCancellation()
        writeStage = WriteStage(String(ui: "미리 보기 1/2단계 · 사본을 만드는 중…"), completed: 0, total: 2, cancellable: true)
        let report = try await Task.detached(priority: .userInitiated) {
            let snapshot = try LibrarySnapshot.take()
            await MainActor.run { self.writeStage = WriteStage(String(ui: "미리 보기 2/2단계 · 바꿀 내용을 검사하는 중…"), completed: 1, total: 2, cancellable: true) }
            return try RekordboxTrackWriter.delete(contentIDs: ids, from: snapshot, dryRun: true, backups: DJCPaths.rekordboxBackups)
        }.value
        try Task.checkCancellation()
        return TrackDeletePreview(report: report, contentIDs: ids)
    }

    func deleteTracksFromRekordbox(_ preview: TrackDeletePreview) async throws -> RekordboxTrackWriter.Report {
        guard !isITunesSelection else { throw DJCError.writeRefused(String(ui: "iTunes 동기화 목록의 곡은 Music에서 빼세요.")) }
        let ids = preview.report.deleted.filter(\.written).compactMap(\.contentID)
        try Task.checkCancellation()
        writeStage = WriteStage(String(ui: "rekordbox에서 곡을 빼는 중…"))
        defer { writeStage = nil }
        let report = try await Task.detached(priority: .userInitiated) {
            try RekordboxTrackWriter.delete(contentIDs: ids, dryRun: false, backups: DJCPaths.rekordboxBackups)
        }.value
        selection.subtract(Set(report.deleted.filter(\.written).compactMap(\.contentID)))
        writeStage = WriteStage(String(ui: "라이브러리를 다시 읽는 중…"))
        await takeSnapshot(quiet: true)
        lastWriteBackup = report.backup.map { URL(filePath: $0) }
        return report
    }

    // MARK: - 되돌린 뒤

    /// 곡 추가를 되돌렸으면 그 곡들을 추가 목록에 다시 넣고, 새 곡으로 옮겼던 초안을 지운다. 되살린 곡 수.
    func restoreStaged(from backup: RekordboxWriter.Backup) -> Int {
        resetPlaylistImports(contentIDs: Set(backup.trackReport?.added.filter(\.written).compactMap(\.contentID) ?? []))
        for uuid in backup.trackReport?.added.compactMap(\.uuid) ?? [] {
            CueDraftStore.remove(trackUUID: uuid)
            GridDraftStore.remove(trackUUID: uuid)
            draftChanged(trackUUID: uuid, kind: .cue, exists: false)
            draftChanged(trackUUID: uuid, kind: .grid, exists: false)
        }
        guard let data = try? Data(contentsOf: backup.url.appending(path: Self.stagedBackupName)),
              let tracks = try? JSONDecoder().decode([StagedTrack].self, from: data) else { return 0 }
        return restage(tracks)
    }
}
