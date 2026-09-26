import DJCDomain
import DJCStorage
import Foundation

/// 덱이 쓰는 저장소: 곡 초안(큐·그리드·게인)과 설정. 시험에서는 메모리 저장소로 바꾼다.
struct DeckStorage: Sendable {
    var loadCueDraft: @Sendable (String) -> CueDraft?
    var saveCueDraft: @Sendable (CueDraft) -> Void
    var loadGridDraft: @Sendable (String) -> GridDraft?
    var saveGridDraft: @Sendable (GridDraft) -> Void
    var loadGain: @Sendable (String) -> Double?
    var saveGain: @Sendable (Double?, String) -> Void
    var removeGridDraft: @Sendable (String) -> Void
    var settings: SettingsStore

    /// 실제 파일(`~/Library/Application Support/DJCrate`)과 UserDefaults
    static let live = DeckStorage(
        loadCueDraft: { CueDraftStore.load(trackUUID: $0) },
        saveCueDraft: { DraftWriter.save($0) },
        loadGridDraft: { GridDraftStore.load(trackUUID: $0) },
        saveGridDraft: { DraftWriter.save($0) },
        loadGain: { GainDraftStore.load(trackUUID: $0) },
        saveGain: { GainDraftStore.save($0, trackUUID: $1) },
        removeGridDraft: { DraftWriter.removeGrid(trackUUID: $0) },
        settings: SettingsStore()
    )
}
