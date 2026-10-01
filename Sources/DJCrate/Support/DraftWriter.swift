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

    enum Kind: Hashable, Sendable { case cue, grid }

    struct Failure: Equatable, Sendable {
        var kind: Kind
        var trackUUID: String
        var revision: UInt64
        var reason: String

        var message: String {
            let title = kind == .cue ? String(ui: "큐 초안을 저장하지 못했습니다.") : String(ui: "그리드 초안을 저장하지 못했습니다.")
            return title + " " + reason
        }
    }

    struct SaveState: Sendable {
        var revision: UInt64
        var savedRevision: UInt64?
        var failure: Failure?
    }

    private struct Key: Hashable, Sendable {
        var kind: Kind
        var directory: String
        var uuid: String
    }

    private enum Input: Sendable {
        case cue(CueDraft), grid(GridDraft)
    }

    private struct Record: Sendable {
        var input: Input
        var state: SaveState
        var write: @Sendable () throws -> Void
    }

    private struct Records: Sendable {
        var revision: UInt64 = 0
        var values: [Key: Record] = [:]
    }

    private static let records = Mutex(Records())

    private static func key(_ kind: Kind, _ uuid: String, _ directory: URL) -> Key {
        Key(kind: kind, directory: directory.resolvingSymlinksInPath().standardizedFileURL.path, uuid: uuid)
    }

    static func state(_ kind: Kind, trackUUID: String, directory: URL) -> SaveState? {
        records.withLock { $0.values[key(kind, trackUUID, directory)]?.state }
    }

    static func pendingCue(trackUUID: String, directory: URL = CueDraftStore.directory) -> CueDraft? {
        records.withLock {
            guard let record = $0.values[key(.cue, trackUUID, directory)], record.state.revision != record.state.savedRevision,
                  case .cue(let draft) = record.input else { return nil }
            return draft
        }
    }

    static func pendingGrid(trackUUID: String, directory: URL = GridDraftStore.directory) -> GridDraft? {
        records.withLock {
            guard let record = $0.values[key(.grid, trackUUID, directory)], record.state.revision != record.state.savedRevision,
                  case .grid(let draft) = record.input else { return nil }
            return draft
        }
    }

    static func failures(cueDirectory: URL = CueDraftStore.directory, gridDirectory: URL = GridDraftStore.directory) -> [Failure] {
        let cue = key(.cue, "", cueDirectory).directory, grid = key(.grid, "", gridDirectory).directory
        return records.withLock { records in
            records.values.compactMap { key, record in
                guard key.directory == (key.kind == .cue ? cue : grid) else { return nil }
                return record.state.failure
            }
        }
    }

    static func unsavedUUIDs(cueDirectory: URL = CueDraftStore.directory, gridDirectory: URL = GridDraftStore.directory) -> Set<String> {
        let cue = key(.cue, "", cueDirectory).directory, grid = key(.grid, "", gridDirectory).directory
        return records.withLock { records in
            Set(records.values.compactMap { key, record in
                key.directory == (key.kind == .cue ? cue : grid) && record.state.revision != record.state.savedRevision ? key.uuid : nil
            })
        }
    }

    private static func failureReason(_ error: any Error) -> String {
        // 오류 설명에 개인 경로가 들어갈 수 있어 원인과 조치만 화면에 넘긴다.
        switch (error as NSError).code {
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            String(ui: "초안 폴더의 접근 권한을 확인한 뒤 다시 저장하세요.")
        case NSFileWriteOutOfSpaceError:
            String(ui: "저장 장치의 빈 공간을 확보한 뒤 다시 저장하세요.")
        default:
            String(ui: "초안 폴더와 저장할 파일을 확인한 뒤 다시 저장하세요.")
        }
    }

    private static func enqueue(_ input: Input, key: Key, write: @escaping @Sendable () throws -> Void,
                                completion: @escaping @Sendable (Failure?) -> Void) {
        records.withLock { records in
            records.revision += 1
            let record = Record(input: input, state: SaveState(revision: records.revision,
                                                              savedRevision: records.values[key]?.state.savedRevision,
                                                              failure: records.values[key]?.state.failure), write: write)
            records.values[key] = record
            queue.async { perform(record, key: key, completion: completion) }
        }
    }

    private static func perform(_ record: Record, key: Key, completion: @Sendable (Failure?) -> Void) {
        let failure: Failure?
        do { try record.write(); failure = nil }
        catch { failure = Failure(kind: key.kind, trackUUID: key.uuid, revision: record.state.revision, reason: failureReason(error)) }
        records.withLock { records in
            guard var current = records.values[key] else { return }
            if failure == nil { current.state.savedRevision = record.state.revision }
            // 앞선 완료가 최신 입력의 저장 오류를 지우지 않게 한다.
            if current.state.revision == record.state.revision { current.state.failure = failure }
            records.values[key] = current
        }
        completion(failure)
    }

    static func retry(trackUUID: String, cueDirectory: URL = CueDraftStore.directory, gridDirectory: URL = GridDraftStore.directory) {
        retry(.cue, trackUUID: trackUUID, directory: cueDirectory)
        retry(.grid, trackUUID: trackUUID, directory: gridDirectory)
    }

    /// 마지막으로 맡은 입력(저장이든 지우기든)을 다시 저장한다. 덱이 아직 곡을 읽는 중이어도 그 입력을 쓴다.
    /// - Returns: 다시 저장할 기록이 있었는지(이미 저장된 기록은 건너뛴다)
    @discardableResult
    static func retry(_ kind: Kind, trackUUID: String, directory: URL,
                      completion: @escaping @Sendable (Failure?) -> Void = { _ in }) -> Bool {
        let key = key(kind, trackUUID, directory)
        return records.withLock { records in
            guard let record = records.values[key], record.state.revision != record.state.savedRevision else { return false }
            queue.async { perform(record, key: key, completion: completion) }
            return true
        }
    }

    /// 그 실패가 뒤의 저장으로 해소됐는지(목록 복구·복원·다시 저장처럼 덱 밖에서 해소된 경우 포함)
    static func isResolved(_ failure: Failure, directory: URL) -> Bool {
        state(failure.kind, trackUUID: failure.trackUUID, directory: directory).map { $0.failure == nil } ?? false
    }

    static var tagSaveFailureMessage: String {
        String(ui: "태그 초안을 저장하지 못했으니 초안 폴더의 접근 권한을 확인한 뒤 동기화하거나 쓰기를 다시 시도하세요.")
    }

    static func failedTagSaveUUIDs(in directory: URL = TagDraftStore.directory) -> Set<String> {
        let key = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return tagFailures.withLock { $0[key] ?? [] }
    }

    static func save(_ draft: CueDraft, directory: URL = CueDraftStore.directory,
                     write: @escaping @Sendable (CueDraft, URL) throws -> Void = { try CueDraftStore.save($0, directory: $1) },
                     completion: @escaping @Sendable (Failure?) -> Void = { _ in }) {
        enqueue(.cue(draft), key: key(.cue, draft.trackUUID, directory), write: { try write(draft, directory) }, completion: completion)
    }
    /// 반영이 끝난 곡의 큐 초안을 지운다(앞서 걸린 저장 뒤에).
    static func removeCue(trackUUID: String) { save(CueDraft(trackUUID: trackUUID, rekordboxCues: [])) }
    /// 걸려 있는 저장을 모두 끝낸다(디스크의 초안을 읽기 전에).
    @discardableResult
    static func flush() -> [Failure] {
        queue.sync {}
        return records.withLock { $0.values.values.compactMap { $0.state.failure } }
    }
    static func save(_ draft: GridDraft, directory: URL = GridDraftStore.directory,
                     write: @escaping @Sendable (GridDraft, URL) throws -> Void = { try GridDraftStore.save($0, directory: $1) },
                     completion: @escaping @Sendable (Failure?) -> Void = { _ in }) {
        enqueue(.grid(draft), key: key(.grid, draft.trackUUID, directory), write: { try write(draft, directory) }, completion: completion)
    }
    static func removeGrid(trackUUID: String, completion: @escaping @Sendable (Failure?) -> Void = { _ in }) {
        save(GridDraft(trackUUID: trackUUID, base: [], segments: []), completion: completion)
    }
    static func save(_ drafts: [TagDraft], directory: URL = TagDraftStore.directory) {
        let key = directory.resolvingSymlinksInPath().standardizedFileURL.path
        queue.async {
            for draft in drafts {
                do {
                    try TagDraftStore.save(draft, directory: directory)
                    tagFailures.withLock { $0[key]?.remove(draft.trackUUID) }
                } catch {
                    tagFailures.withLock { $0[key, default: []].insert(draft.trackUUID) }
                }
            }
        }
    }
}
