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

    enum Kind: Hashable, Sendable { case cue, grid, gain }

    struct Failure: Equatable, Sendable {
        var kind: Kind
        var trackUUID: String
        var revision: UInt64
        var reason: String

        var message: String {
            let title = switch kind {
            case .cue: String(ui: "큐 초안을 저장하지 못했습니다.")
            case .grid: String(ui: "그리드 초안을 저장하지 못했습니다.")
            case .gain: String(ui: "게인 초안을 저장하지 못했습니다.")
            }
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
        /// 게인은 nil이 초안 지우기다.
        case cue(CueDraft), grid(GridDraft), gain(Double?)
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

    /// 종류마다 저장하는 곳(큐·그리드는 폴더, 게인은 모든 곡을 담은 파일 하나)
    struct Locations: Sendable {
        var cue = CueDraftStore.directory
        var grid = GridDraftStore.directory
        var gain = GainDraftStore.url

        func url(_ kind: Kind) -> URL {
            switch kind {
            case .cue: cue
            case .grid: grid
            case .gain: gain
            }
        }
    }

    private static func located(_ key: Key, in locations: Locations) -> Bool {
        key.directory == Self.key(key.kind, "", locations.url(key.kind)).directory
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

    /// 저장하지 못한 게인 입력(바깥 nil은 기록 없음, 안쪽 nil은 초안 지우기)
    static func pendingGain(trackUUID: String, url: URL = GainDraftStore.url) -> Double?? {
        records.withLock {
            guard let record = $0.values[key(.gain, trackUUID, url)], record.state.revision != record.state.savedRevision,
                  case .gain(let gain) = record.input else { return nil }
            return .some(gain)
        }
    }

    static func failures(cueDirectory: URL = CueDraftStore.directory, gridDirectory: URL = GridDraftStore.directory,
                         gainURL: URL = GainDraftStore.url) -> [Failure] {
        let locations = Locations(cue: cueDirectory, grid: gridDirectory, gain: gainURL)
        return records.withLock { records in
            records.values.compactMap { key, record in located(key, in: locations) ? record.state.failure : nil }
        }
    }

    static func unsavedUUIDs(cueDirectory: URL = CueDraftStore.directory, gridDirectory: URL = GridDraftStore.directory,
                             gainURL: URL = GainDraftStore.url) -> Set<String> {
        let locations = Locations(cue: cueDirectory, grid: gridDirectory, gain: gainURL)
        return records.withLock { records in
            Set(records.values.compactMap { key, record in
                located(key, in: locations) && record.state.revision != record.state.savedRevision ? key.uuid : nil
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

    static func retry(trackUUID: String, cueDirectory: URL = CueDraftStore.directory, gridDirectory: URL = GridDraftStore.directory,
                      gainURL: URL = GainDraftStore.url) {
        retry(.cue, trackUUID: trackUUID, directory: cueDirectory)
        retry(.grid, trackUUID: trackUUID, directory: gridDirectory)
        retry(.gain, trackUUID: trackUUID, directory: gainURL)
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
    /// 게인 초안(nil이면 지우기). 모든 곡이 한 파일이라 다른 곡의 저장과 같은 큐에서 차례로 읽고 쓴다.
    static func save(gain: Double?, trackUUID: String, url: URL = GainDraftStore.url,
                     write: @escaping @Sendable (Double?, String, URL) throws -> Void = { try GainDraftStore.save($0, trackUUID: $1, url: $2) },
                     completion: @escaping @Sendable (Failure?) -> Void = { _ in }) {
        enqueue(.gain(gain), key: key(.gain, trackUUID, url), write: { try write(gain, trackUUID, url) }, completion: completion)
    }
    static func removeGain(trackUUID: String) { save(gain: nil, trackUUID: trackUUID) }

    /// 데이터 폴더의 손상된 초안 파일을 옮겨 보관하고 그 목록을 받는다(저장과 같은 큐에서, 막 쓴 파일을 옮기지 않게).
    static func preserveDamagedDrafts(home: URL = DJCPaths.userData) -> [DamagedDrafts.Entry] {
        queue.sync {
            DamagedDrafts.preserveAll(home: home)
            return DamagedDrafts.take(home: home)
        }
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
