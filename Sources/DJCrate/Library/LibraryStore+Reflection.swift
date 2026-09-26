import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation

/// 이미 rekordbox에 있는 곡에 DJCrate 초안(큐·그리드)을 반영: 계획 → XML → (사용자가 rekordbox에서 가져옴) → 검증.
extension LibraryStore {
    /// 툴바 버튼의 대상: 선택한 곡 중 초안이 있는 곡, 없으면 반영 대기 곡 전체.
    var reflectionTargets: [TrackRow] {
        let selected = selectedRows.filter { !$0.isStaged && pendingUUIDs.contains($0.track.uuid) }
        if !selected.isEmpty { return selected }
        return rows.filter { pendingUUIDs.contains($0.track.uuid) }
    }

    /// 곡마다 반영 계획을 만든다(초안이 없는 곡은 대상이 아니다).
    func reflectionPlans(for rows: [TrackRow]) -> [Reflection.Plan] {
        rows.filter { !$0.isStaged && pendingUUIDs.contains($0.track.uuid) }.map { row in
            Reflection.plan(track: row.track, rawCues: row.cues,
                            cueDraft: CueDraftStore.load(trackUUID: row.track.uuid),
                            gridDraft: GridDraftStore.load(trackUUID: row.track.uuid))
        }
    }

    /// 반영 XML을 쓴다. 막힌 곡은 빼고 이유를 돌려준다.
    func exportReflection(rows: [TrackRow], to url: URL) throws -> (exported: [Reflection.Plan], blocked: [Reflection.Plan]) {
        let plans = reflectionPlans(for: rows)
        let eligible = plans.filter(\.isEligible)
        let blocked = plans.filter { !$0.blockers.isEmpty }
        guard !eligible.isEmpty else { return ([], blocked) }
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.space))
        // 재생 목록 이름은 늘 같게(rekordbox에서 찾기 쉽게). 만든 시각은 반영 묶음에 남긴다.
        let xml = Reflection.document(plans: eligible, playlistName: "DJCrate 반영")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        let batch = ReflectionStore.Batch(createdAt: stamp, xmlPath: url.path, plans: eligible, checks: [:])
        try ReflectionStore.save(batch)
        reflectionBatch = batch
        return (eligible, blocked)
    }

    /// 새 스냅샷을 읽은 뒤: 반영 묶음의 곡마다 rekordbox에 의도대로 들어갔는지 확인한다.
    /// 일치한 곡의 초안은 지운다(이제 rekordbox 값이 원본이다). 어긋난 곡은 초안을 그대로 두고 알린다.
    func verifyReflection() {
        guard var batch = reflectionBatch ?? ReflectionStore.load() else { return }
        var matched = 0, notYet = 0, mismatched: [String] = []
        for plan in batch.plans {
            guard let row = rowsByID[plan.trackID] else { continue }
            let grid = RekordboxShare.analysisURL(row.track.analysisDataPath).flatMap { try? BeatGrid.load(anlz: $0) }
            let check = Reflection.verify(plan, track: row.track, cues: row.cues, grid: grid)
            batch.checks[plan.trackID] = check
            switch check.result {
            case .matched:
                matched += 1
                CueDraftStore.remove(trackUUID: plan.uuid)
                GridDraftStore.remove(trackUUID: plan.uuid)
                draftCueCounts[plan.uuid] = nil
                draftChanged(trackUUID: plan.uuid, kind: .cue, exists: false)
                draftChanged(trackUUID: plan.uuid, kind: .grid, exists: false)
            case .notYet:
                notYet += 1
            case .mismatched:
                mismatched.append("\(plan.title): \(check.problems.joined(separator: " / "))")
            }
        }
        if notYet == 0 && mismatched.isEmpty {
            // 모두 확인됐다. 다음 묶음을 위해 비운다.
            try? ReflectionStore.save(nil)
            reflectionBatch = nil
        } else {
            try? ReflectionStore.save(batch)
            reflectionBatch = batch
        }
        var parts = ["rekordbox 반영 확인(\(batch.createdAt) 묶음): 일치 \(matched)"]
        if notYet > 0 { parts.append("아직 가져오지 않음 \(notYet)") }
        if !mismatched.isEmpty { parts.append("불일치 \(mismatched.count) — " + mismatched.prefix(2).joined(separator: " · ")) }
        reflectionMessage = AppMessage(kind: mismatched.isEmpty && notYet == 0 ? .success : .warning, text: parts.joined(separator: " · "))
        FileHandle.standardError.write(Data("[반영 검증] \(reflectionMessage?.text ?? "")\n".utf8))
    }
}
