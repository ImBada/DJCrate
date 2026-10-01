import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation

/// 이미 rekordbox에 있는 곡에 DJCrate 초안(큐·그리드)을 반영: 계획 → XML → (사용자가 rekordbox에서 가져옴) → 검증.
extension LibraryStore {
    /// 툴바 버튼의 대상: 선택한 곡 중 초안이 있는 곡, 없으면 반영 대기 곡 전체.
    var reflectionTargets: [TrackRow] {
        let pending = pendingUUIDs
        let selected = selectedRows.filter { !$0.isStaged && pending.contains($0.track.uuid) }
        if !selected.isEmpty { return selected }
        return rows.filter { pending.contains($0.track.uuid) }
    }

    /// 곡마다 반영 계획을 만든다(초안이 없는 곡은 대상이 아니다).
    func reflectionPlans(for rows: [TrackRow]) -> [Reflection.Plan] {
        let pending = pendingUUIDs
        return rows.filter { !$0.isStaged && pending.contains($0.track.uuid) }.map { row in
            Reflection.plan(track: row.track, rawCues: row.cues,
                            cueDraft: CueDraftStore.load(trackUUID: row.track.uuid),
                            gridDraft: GridDraftStore.load(trackUUID: row.track.uuid))
        }
    }

    /// 반영 XML을 쓴다. 막힌 곡은 빼고 이유를 돌려준다.
    func exportReflection(rows: [TrackRow], to url: URL) throws -> (exported: [Reflection.Plan], blocked: [Reflection.Plan]) {
        // 저장에 실패한 초안이 있으면 디스크의 옛 초안을 XML로 내보내지 않는다(#170).
        try requireDraftSaves(for: Set(rows.map(\.track.uuid)))
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
    /// 새 스냅샷에 없는 곡은 확인하지 못한 것으로 남긴다(묶음을 다 확인한 것으로 비우지 않는다, #175).
    func verifyReflection() {
        guard var batch = reflectionBatch ?? ReflectionStore.load() else { return }
        var matched = 0, notYet = 0, mismatched: [String] = [], unverified: [String] = []
        var cleared: Set<String> = []
        for plan in batch.plans {
            guard let row = rowsByID[plan.trackID] else {
                unverified.append(plan.title)
                continue
            }
            let grid = RekordboxShare.analysisURL(row.track.analysisDataPath).flatMap { try? BeatGrid.load(anlz: $0) }
            let check = Reflection.verify(plan, track: row.track, cues: row.cues, grid: grid)
            batch.checks[plan.trackID] = check
            switch check.result {
            case .matched:
                matched += 1
                // 저장 실패로 DraftWriter에 남은 기록까지 같이 비우려고 파일을 직접 지우지 않는다(#172).
                DraftWriter.removeCue(trackUUID: plan.uuid)
                DraftWriter.removeGrid(trackUUID: plan.uuid)
                cleared.insert(plan.uuid)
                draftCueCounts[plan.uuid] = nil
                draftChanged(trackUUID: plan.uuid, kind: .cue, exists: false)
                draftChanged(trackUUID: plan.uuid, kind: .grid, exists: false)
            case .notYet:
                notYet += 1
            case .mismatched:
                mismatched.append("\(plan.title): \(check.problems.joined(separator: " / "))")
            }
        }
        let finished = notYet == 0 && mismatched.isEmpty && unverified.isEmpty
        var storeWarning: String?
        do {
            // 모두 확인됐으면 다음 묶음을 위해 비운다.
            try ReflectionStore.save(finished ? nil : batch)
        } catch {
            AppErrorMessage.log(error)
            storeWarning = String(ui: "반영 확인 기록을 저장하지 못했으니 DJCrate 데이터 폴더의 쓰기 권한을 확인한 뒤 rekordbox와 동기화하세요.")
        }
        reflectionBatch = finished ? nil : batch
        // 초안을 지우지 못했으면 알린다(반영은 확인됐지만 덱·쓰기 전 확인이 옛 초안을 계속 볼 수 있다).
        let cleanupWarning = cleared.isEmpty ? nil : draftSaveWarning(for: cleared)
        var parts = [String(ui: "rekordbox XML 가져오기 확인(\(batch.createdAt) 묶음): 일치 \(matched)")]
        if notYet > 0 { parts.append(String(ui: "아직 가져오지 않음 \(notYet)")) }
        if !mismatched.isEmpty { parts.append(String(ui: "불일치 \(mismatched.count) — \(mismatched.prefix(2).joined(separator: " · "))")) }
        if !unverified.isEmpty {
            parts.append(String(ui: "확인하지 못함 \(unverified.count) — 라이브러리에 없는 곡: \(unverified.prefix(2).joined(separator: " · "))"))
        }
        if let cleanupWarning { parts.append(cleanupWarning) }
        if let storeWarning { parts.append(storeWarning) }
        reflectionMessage = AppMessage(kind: finished && cleanupWarning == nil && storeWarning == nil ? .success : .warning,
                                       text: parts.joined(separator: " · "))
        FileHandle.standardError.write(Data("[반영 검증] \(reflectionMessage?.text ?? "")\n".utf8))
    }
}
