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
            let alert = NSAlert()
            alert.messageText = "반영할 수 있는 곡이 없습니다"
            alert.informativeText = blocked.isEmpty
                ? "고른 곡에 rekordbox와 다른 큐·그리드 초안이 없습니다."
                : blocked.prefix(5).map { "• \($0.title): \($0.blockers.joined(separator: " / "))" }.joined(separator: "\n")
            alert.addButton(withTitle: "확인")
            alert.runModal()
            return
        }
        do {
            let url = try RekordboxLink.prepare()
            _ = try store.exportReflection(rows: rows, to: url)
        } catch {
            store.reflectionMessage = "반영 XML을 쓰지 못했습니다: \(error.localizedDescription)"
            return
        }
        var text = "\(eligible.count)곡을 연동 XML에 썼습니다 · rekordbox: rekordbox xml 새로고침 › \"DJCrate 반영\" › 곡 모두 선택 › Import To Collection → DJCrate 새 스냅샷(⟳)"
        if !blocked.isEmpty {
            text += " · 막혀서 뺀 곡 \(blocked.count): " + blocked.prefix(2).map { "\($0.title)(\($0.blockers.first ?? ""))" }.joined(separator: ", ")
        }
        store.reflectionMessage = text
        RekordboxLink.showSetupIfNeeded()
    }
}
