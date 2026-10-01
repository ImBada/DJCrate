import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import SwiftUI

/// 기존 곡의 XML 미리 보기 → 연동 파일에 쓰기.
@MainActor
enum ReflectionPanels {
    static func export(store: LibraryStore, rows: [TrackRow]) {
        let plans = store.reflectionPlans(for: rows)
        let eligible = plans.filter(\.isEligible), blocked = plans.filter { !$0.blockers.isEmpty }
        guard !eligible.isEmpty else {
            _ = AlertPrompter().show(blockedPrompt(blocked))
            return
        }
        let exclusions = store.draftExclusionReasons(for: rows, xml: true)
        guard AlertPrompter().show(previewPrompt(plans, exclusions: exclusions)) else { return }
        guard store.reflectionPlans(for: rows) == plans else {
            store.reflectionMessage = AppMessage(kind: .warning, text: String(ui: "미리 보기 뒤 초안이 바뀌었으니 XML 미리 보기를 다시 확인하세요"))
            return
        }
        do {
            let url = try RekordboxLink.prepare()
            _ = try store.exportReflection(rows: rows, to: url)
        } catch {
            store.reflectionMessage = AppMessage(kind: .failure, text: String(ui: "XML을 만들지 못했습니다. 저장 위치와 권한을 확인하세요: \(error.localizedDescription)"))
            return
        }
        // 재생 목록 이름 "DJCrate 반영"은 XML에 쓰는 이름 그대로다(번역하지 않음).
        var text = String(ui: "\(eligible.count)곡을 연동 XML에 썼습니다 · rekordbox: rekordbox xml 새로고침 › \"DJCrate 반영\" › 곡 모두 선택 › Import To Collection → DJCrate rekordbox와 동기화(⟳)")
        if !blocked.isEmpty {
            let names = blocked.prefix(2).map { "\($0.title)(\($0.blockers.first ?? ""))" }.joined(separator: ", ")
            text += " · " + String(ui: "막혀서 뺀 곡 \(blocked.count): \(names)")
        }
        store.reflectionMessage = AppMessage(kind: blocked.isEmpty && exclusions.isEmpty ? .success : .warning, text: text)
        RekordboxLink.showSetupIfNeeded()
    }

    static func blockedPrompt(_ blocked: [Reflection.Plan]) -> ReflectionPrompt {
        ReflectionPrompt(title: String(ui: "XML로 만들 곡이 없습니다"),
                         text: blocked.isEmpty ? String(ui: "고른 곡에 rekordbox와 다른 큐·그리드 초안이 없습니다.") : "",
                         details: blocked.map { "• \($0.title): \($0.blockers.joined(separator: " / "))" })
    }

    static func previewPrompt(_ plans: [Reflection.Plan], exclusions: [String]) -> ReflectionPrompt {
        let eligible = plans.filter(\.isEligible)
        var details = eligible.map { plan in
            "• \(plan.title) — " + [plan.cueChanged ? String(ui: "큐") : nil, plan.gridChanged ? String(ui: "그리드") : nil].compactMap { $0 }.joined(separator: " · ")
        }
        var seen = Set<String>()
        let omitted = (plans.filter { !$0.isEligible }.flatMap { plan in
            plan.blockers.map { "• \(plan.title): \($0)" }
        } + exclusions).filter { seen.insert($0).inserted }
        if !omitted.isEmpty { details += ["", String(ui: "XML에 넣지 않는 것:")] + omitted }
        return ReflectionPrompt(title: String(ui: "XML 미리 보기"),
                                text: String(ui: "기존 곡 \(eligible.count)개의 큐·그리드 초안을 XML로 만드니 대상과 제외 이유를 확인하세요"),
                                confirm: String(ui: "XML 만들기"), details: details)
    }
}
