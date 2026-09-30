import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import Foundation
import RekordboxKit
import Synchronization

/// 초안 저장은 직렬 큐에서 메인 스레드 밖으로(순서 보장).
enum DraftWriter {
    private static let queue = DispatchQueue(label: "djc.draft-writer", qos: .utility)
    private static let tagFailures = Mutex<[String: Set<String>]>([:])

    static var tagSaveFailureMessage: String {
        String(ui: "태그 초안을 저장하지 못했으니 초안 폴더의 접근 권한을 확인한 뒤 동기화하거나 쓰기를 다시 시도하세요.")
    }

    static func failedTagSaveUUIDs(in directory: URL = TagDraftStore.directory) -> Set<String> {
        let key = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return tagFailures.withLock { $0[key] ?? [] }
    }

    static func save(_ draft: CueDraft) { queue.async { try? CueDraftStore.save(draft) } }
    /// 반영이 끝난 곡의 큐 초안을 지운다(앞서 걸린 저장 뒤에).
    static func removeCue(trackUUID: String) { queue.async { CueDraftStore.remove(trackUUID: trackUUID) } }
    /// 걸려 있는 저장을 모두 끝낸다(디스크의 초안을 읽기 전에).
    static func flush() { queue.sync {} }
    static func save(_ draft: GridDraft) { queue.async { try? GridDraftStore.save(draft) } }
    static func removeGrid(trackUUID: String) { queue.async { GridDraftStore.remove(trackUUID: trackUUID) } }
    static func save(_ drafts: [TagDraft], directory: URL = TagDraftStore.directory) {
        let key = directory.resolvingSymlinksInPath().standardizedFileURL.path
        queue.async {
            for draft in drafts {
                do {
                    try TagDraftStore.save(draft, directory: directory)
                    _ = tagFailures.withLock { $0[key]?.remove(draft.trackUUID) }
                } catch {
                    _ = tagFailures.withLock { $0[key, default: []].insert(draft.trackUUID) }
                }
            }
        }
    }
}
