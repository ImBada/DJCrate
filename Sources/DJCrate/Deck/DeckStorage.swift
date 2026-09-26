import DJCDomain
import DJCStorage
import Foundation

/// 덱이 쓰는 저장소: 곡 초안(큐·그리드·게인)과 덱 설정. 시험에서는 메모리 저장소로 바꾼다.
struct DeckStorage: Sendable {
    var loadCueDraft: @Sendable (String) -> CueDraft?
    var saveCueDraft: @Sendable (CueDraft) -> Void
    var loadGridDraft: @Sendable (String) -> GridDraft?
    var saveGridDraft: @Sendable (GridDraft) -> Void
    var loadGain: @Sendable (String) -> Double?
    var saveGain: @Sendable (Double?, String) -> Void
    var settings: DeckSettings

    /// 실제 파일(`~/Library/Application Support/DJCrate`)과 UserDefaults
    static let live = DeckStorage(
        loadCueDraft: { CueDraftStore.load(trackUUID: $0) },
        saveCueDraft: { DraftWriter.save($0) },
        loadGridDraft: { GridDraftStore.load(trackUUID: $0) },
        saveGridDraft: { DraftWriter.save($0) },
        loadGain: { GainDraftStore.load(trackUUID: $0) },
        saveGain: { GainDraftStore.save($0, trackUUID: $1) },
        settings: DeckSettings()
    )
}

/// 덱 설정(볼륨·키 락·퀀타이즈·제안 표시·확대 배율·무시한 제안)을 앱을 다시 켜도 유지한다.
/// 개발용 자가 테스트(음량을 −70dB로 바꾼다)는 저장하지 않는다.
final class DeckSettings: @unchecked Sendable {
    let defaults: UserDefaults
    let persist: Bool

    init(defaults: UserDefaults = .standard,
         persist: Bool = !ProcessInfo.processInfo.arguments.contains { $0.hasSuffix("-selftest") || $0 == "--autoplay" }) {
        self.defaults = defaults
        self.persist = persist
    }

    private func key(_ name: String) -> String { "deck.\(name)" }

    func double(_ name: String, _ fallback: Double) -> Double {
        guard persist, let value = defaults.object(forKey: key(name)) as? Double, value.isFinite else { return fallback }
        return value
    }

    func bool(_ name: String, _ fallback: Bool) -> Bool {
        guard persist, let value = defaults.object(forKey: key(name)) as? Bool else { return fallback }
        return value
    }

    func set(_ name: String, _ value: Any) {
        guard persist else { return }
        defaults.set(value, forKey: key(name))
    }

    /// 곡 UUID 모음(무시한 제안 등). 자가 테스트 중에도 읽기·쓰기는 한다(화면 상태라서).
    func strings(_ name: String) -> Set<String> { Set(defaults.stringArray(forKey: key(name)) ?? []) }

    func setStrings(_ name: String, _ value: Set<String>) { defaults.set(Array(value), forKey: key(name)) }
}
