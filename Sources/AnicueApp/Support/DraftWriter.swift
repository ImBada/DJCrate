import AnicueAnalysis
import AnicueDomain
import AnicueStorage
import AppKit
import Foundation
import RekordboxKit

/// 초안 저장은 직렬 큐에서 메인 스레드 밖으로(순서 보장).
enum DraftWriter {
    private static let queue = DispatchQueue(label: "anicue.draft-writer", qos: .utility)

    static func save(_ draft: CueDraft) { queue.async { try? CueDraftStore.save(draft) } }
    /// 반영이 끝난 곡의 큐 초안을 지운다(앞서 걸린 저장 뒤에).
    static func removeCue(trackUUID: String) { queue.async { CueDraftStore.remove(trackUUID: trackUUID) } }
    /// 걸려 있는 저장을 모두 끝낸다(디스크의 초안을 읽기 전에).
    static func flush() { queue.sync {} }
    static func save(_ draft: GridDraft) { queue.async { try? GridDraftStore.save(draft) } }
    static func removeGrid(trackUUID: String) { queue.async { GridDraftStore.remove(trackUUID: trackUUID) } }
    static func save(_ drafts: [TagDraft]) { queue.async { for draft in drafts { try? TagDraftStore.save(draft) } } }
}
