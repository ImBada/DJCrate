import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import SwiftUI

/// 반영 XML 만들기(연동 파일에 바로 쓴다).
@MainActor
enum ReflectionPanels {
    static func export(store: LibraryStore, rows: [TrackRow]) {
        let plans = store.reflectionPlans(for: rows)
        let eligible = plans.filter(\.isEligible), blocked = plans.filter { !$0.blockers.isEmpty }
        guard !eligible.isEmpty else {
            _ = AlertPrompter().show(blockedPrompt(blocked))
            return
        }
        do {
            let url = try RekordboxLink.prepare()
            _ = try store.exportReflection(rows: rows, to: url)
        } catch {
            store.reflectionMessage = AppMessage(kind: .failure, text: String(ui: "반영 XML을 쓰지 못했습니다. 저장 위치와 권한을 확인하세요: \(error.localizedDescription)"))
            return
        }
        // 재생 목록 이름 "DJCrate 반영"은 XML에 쓰는 이름 그대로다(번역하지 않음).
        var text = String(ui: "\(eligible.count)곡을 연동 XML에 썼습니다 · rekordbox: rekordbox xml 새로고침 › \"DJCrate 반영\" › 곡 모두 선택 › Import To Collection → DJCrate 새 스냅샷(⟳)")
        if !blocked.isEmpty {
            let names = blocked.prefix(2).map { "\($0.title)(\($0.blockers.first ?? ""))" }.joined(separator: ", ")
            text += " · " + String(ui: "막혀서 뺀 곡 \(blocked.count): \(names)")
        }
        store.reflectionMessage = AppMessage(kind: blocked.isEmpty ? .success : .warning, text: text)
        RekordboxLink.showSetupIfNeeded()
    }

    static func blockedPrompt(_ blocked: [Reflection.Plan]) -> ReflectionPrompt {
        ReflectionPrompt(title: String(ui: "반영할 수 있는 곡이 없습니다"),
                         text: blocked.isEmpty ? String(ui: "고른 곡에 rekordbox와 다른 큐·그리드 초안이 없습니다.") : "",
                         details: blocked.map { "• \($0.title): \($0.blockers.joined(separator: " / "))" })
    }
}
