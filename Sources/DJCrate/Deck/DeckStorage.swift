import DJCDomain
import DJCStorage
import Foundation

/// 덱이 쓰는 저장소: 곡 초안(큐·그리드·게인)과 설정. 시험에서는 메모리 저장소로 바꾼다.
struct DeckStorage: Sendable {
    var loadCueDraft: @Sendable (String) -> CueDraft?
    var saveCueDraft: @Sendable (CueDraft, @escaping @Sendable (DraftWriter.Failure?) -> Void) -> Void
    var loadGridDraft: @Sendable (String) -> GridDraft?
    var saveGridDraft: @Sendable (GridDraft, @escaping @Sendable (DraftWriter.Failure?) -> Void) -> Void
    var loadGain: @Sendable (String) -> Double?
    var saveGain: @Sendable (Double?, String) -> Void
    var removeGridDraft: @Sendable (String, @escaping @Sendable (DraftWriter.Failure?) -> Void) -> Void
    var settings: SettingsStore
    var flushDrafts: @Sendable () -> [DraftWriter.Failure] = { [] }
    var draftSaveFailures: @Sendable (String) -> [DraftWriter.Failure] = { _ in [] }
    /// 저장에 실패한 마지막 입력을 다시 저장한다(덱이 곡을 읽는 중이어도).
    var retryDraftSave: @Sendable (DraftWriter.Kind, String, @escaping @Sendable (DraftWriter.Failure?) -> Void) -> Void = { _, _, _ in }
    /// 덱이 받은 저장 실패가 그 뒤 해소됐는지
    var draftSaveResolved: @Sendable (DraftWriter.Failure) -> Bool = { _ in false }

    /// 실제 파일(`~/Library/Application Support/DJCrate`)과 UserDefaults
    static let live = DeckStorage(
        loadCueDraft: { uuid in
            if let pending = DraftWriter.pendingCue(trackUUID: uuid) { return pending.hasChanges ? pending : nil }
            return CueDraftStore.load(trackUUID: uuid)
        },
        saveCueDraft: { DraftWriter.save($0, completion: $1) },
        loadGridDraft: { uuid in
            if let pending = DraftWriter.pendingGrid(trackUUID: uuid) { return pending.hasChanges ? pending : nil }
            return GridDraftStore.load(trackUUID: uuid)
        },
        saveGridDraft: { DraftWriter.save($0, completion: $1) },
        loadGain: { GainDraftStore.load(trackUUID: $0) },
        saveGain: { GainDraftStore.save($0, trackUUID: $1) },
        removeGridDraft: { DraftWriter.removeGrid(trackUUID: $0, completion: $1) },
        settings: SettingsStore(),
        flushDrafts: { DraftWriter.flush() },
        draftSaveFailures: { uuid in DraftWriter.failures().filter { $0.trackUUID == uuid } },
        retryDraftSave: { kind, uuid, completion in
            DraftWriter.retry(kind, trackUUID: uuid, directory: kind == .cue ? CueDraftStore.directory : GridDraftStore.directory,
                              completion: completion)
        },
        draftSaveResolved: { failure in
            DraftWriter.isResolved(failure, directory: failure.kind == .cue ? CueDraftStore.directory : GridDraftStore.directory)
        }
    )
}
