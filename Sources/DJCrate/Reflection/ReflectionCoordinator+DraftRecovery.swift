import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

extension ReflectionCoordinator {
    func chooseRecoveryTarget(store: LibraryStore, rows: [TrackRow]) async {
        let choices = rows.flatMap { row in store.recoveryKinds(for: row).map { (row, $0) } }
        for (index, target) in choices.enumerated() {
            let prompt = ReflectionPrompt(title: String(ui: "\(target.0.title)의 \(target.1.label) 현재값을 가져올까요?"),
                                          text: String(ui: "이 곡의 선택한 종류만 비교합니다. 가져오기 자체는 초안을 바꾸지 않습니다."),
                                          confirm: String(ui: "현재값 가져오기"),
                                          alternate: index + 1 < choices.count ? String(ui: "다음 초안") : nil)
            switch prompter.choose(prompt) {
            case .cancel: return
            case .alternate: continue
            case .confirm:
                await recoverDraft(store: store, row: target.0, kind: target.1)
                return
            }
        }
    }

    /// 반영 경고와 편집 화면이 같은 비교·선택·저장 흐름을 쓴다.
    func recoverDraft(store: LibraryStore, row: TrackRow, kind: DraftRecoveryKind) async {
        do {
            var review = try await store.prepareDraftRecovery(row: row, kind: kind)
            let refusal = review.keepRefusal
            let keep = refusal == nil ? try? review.original.resolved(onto: review.current, choice: .keepEditing) : nil
            var prompt = Self.recoveryConfirmation(review, canKeep: keep != nil, keepRefusal: refusal)
            let missing = Self.missingCueMappings(review)
            if keep == nil, !missing.isEmpty {
                prompt.confirm = String(ui: "큐 대상 다시 지정…")
                prompt.alternate = String(ui: "현재값 사용")
                prompt.destructive = false
            }
            var choice = prompter.choose(prompt)
            if choice == .cancel { return }
            let action: DraftRecoveryChoice
            if keep == nil, !missing.isEmpty, choice == .confirm {
                guard let mappings = chooseCueMappings(review, missing: missing) else { return }
                review.cueSourceMappings = mappings
                _ = try review.original.resolved(onto: review.current, choice: .keepEditing, sourceMappings: mappings)
                choice = prompter.choose(Self.recoveryConfirmation(review, canKeep: true))
                if choice == .cancel { return }
                action = choice == .confirm ? .keepEditing : .useCurrent
            } else {
                action = keep != nil && choice == .confirm ? .keepEditing : .useCurrent
            }
            try await store.applyDraftRecovery(review, choice: action)
            let details = String(ui: "선택한 종류의 초안을 저장했습니다. 쓰기 미리 보기에서 지원 제한과 최신 상태를 다시 확인하세요.")
            store.toast = AppToast(kind: .success, title: String(ui: "초안을 복구했습니다"), detail: details)
        } catch is CancellationError { return }
        catch {
            let text = error is DraftRecoveryError
                ? String(ui: "큐 ID나 그리드 구간의 대응이 모호하므로 내 편집을 그대로 남겼습니다. 현재값을 사용하거나 편집 대상을 다시 지정하세요.")
                : AppErrorMessage.message(for: error)
            _ = prompter.show(ReflectionPrompt(title: String(ui: "초안을 복구하지 못했습니다"), text: text))
        }
    }

    static func recoveryConfirmation(_ review: DraftRecoveryReview, canKeep: Bool, keepRefusal: String? = nil) -> ReflectionPrompt {
        let kind = review.original.kind.label
        let text = String(ui: "현재값 사용을 선택하면 이 곡의 \(kind) 편집을 버립니다. 다른 곡과 다른 종류의 초안은 그대로 남깁니다. 저장 뒤 쓰기 미리 보기에서 재검사하며 지원 제한은 유지됩니다.")
        var details = recoveryDetails(review)
        if case let .grid(draft) = review.original, draft.replacementSource != nil {
            details.append(String(ui: "내 편집 유지를 선택하면 표시한 현재 원본의 전체 박을 기준으로 단일 템포 대체 그리드를 새로 승인합니다."))
        }
        if !canKeep { details.append(keepRefusal ?? String(ui: "큐 ID나 그리드 구간의 대응이 모호해 자동으로 재적용할 수 없습니다. 내 편집을 남기려면 취소하고 대상을 다시 지정하세요.")) }
        return ReflectionPrompt(title: String(ui: "\(review.title)의 \(kind) 현재값을 비교하세요"), text: text,
                                confirm: canKeep ? String(ui: "내 편집 유지·재적용") : String(ui: "현재값 사용"),
                                destructive: !canKeep, details: details,
                                alternate: canKeep ? String(ui: "현재값 사용") : nil)
    }

    static func recoveryDetails(_ review: DraftRecoveryReview) -> [String] {
        switch (review.original, review.current) {
        case let (.tags(d), .tags(c)):
            let recovery = TagDraftRecovery(draft: d, current: c.base)
            // 독립 칸(키·평점·곡 색)은 고친 초안만 비교에 올린다(그 칸이 없던 옛 초안의 빈 기준이 현재 값과 달라 보이는 것은 차이가 아니다)
            return TagFields.Key.allCases.filter {
                (!TagFields.Key.independent.contains($0) && d.base[$0] != c.base[$0]) || d.base[$0] != d.fields[$0]
            }.flatMap { key in
                [key.label + (recovery.conflictingKeys.contains(key) ? " ⚠︎" : ""),
                 String(ui: "기준: \(d.base[key])"), String(ui: "현재: \(c.base[key])"), String(ui: "내 편집: \(d.fields[key])")]
            }
        case let (.cues(d), .cues(c)):
            var lines = [String(ui: "기준:")] + d.base.map(cueDescription)
                + [String(ui: "현재:")] + c.base.map(cueDescription)
                + [String(ui: "내 편집:")] + d.cues.map(cueDescription)
            if case let .cues(merged)? = try? review.original.resolved(onto: review.current, choice: .keepEditing, sourceMappings: review.cueSourceMappings) {
                let removed = c.base.filter { old in !merged.cues.contains { $0.sourceID == old.sourceID } }
                if !removed.isEmpty { lines += [String(ui: "내 편집 유지 때 없어질 현재 큐:")] + removed.map(cueDescription) }
            }
            for (oldSource, currentSource) in review.cueSourceMappings.sorted(by: { $0.key < $1.key }) {
                if let old = d.base.first(where: { $0.sourceID == oldSource }), let current = c.base.first(where: { $0.sourceID == currentSource }) {
                    lines += [String(ui: "직접 지정한 큐 대응:"), cueDescription(old), "→ " + cueDescription(current)]
                }
            }
            return lines
        case let (.grid(d), .grid(c)):
            return [String(ui: "기준:")] + d.base.map(gridDescription)
                + [String(ui: "현재:")] + c.base.map(gridDescription)
                + [String(ui: "내 편집:")] + d.segments.map(gridDescription)
        default: return []
        }
    }

    static func missingCueMappings(_ review: DraftRecoveryReview) -> [EditableCue] {
        guard case let .cues(draft) = review.original, case let .cues(current) = review.current else { return [] }
        let sources = Set(current.base.compactMap(\.sourceID))
        return draft.changes.compactMap {
            if case let .modified(old, _) = $0, let source = old.sourceID, !sources.contains(source) { return old }
            return nil
        }
    }

    private func chooseCueMappings(_ review: DraftRecoveryReview, missing: [EditableCue]) -> [String: String]? {
        guard case let .cues(draft) = review.original, case let .cues(current) = review.current else { return nil }
        let known = Set(draft.base.compactMap(\.sourceID))
        var mappings: [String: String] = [:]
        for old in missing {
            guard let oldSource = old.sourceID else { return nil }
            let candidates = current.base.filter { cue in
                cue.sourceID.map { !known.contains($0) && !mappings.values.contains($0) } ?? false
            }
            var selected = false
            for (index, candidate) in candidates.enumerated() {
                let prompt = ReflectionPrompt(title: String(ui: "내 큐 편집을 이 현재 큐에 연결할까요?"),
                                              text: String(ui: "시각이나 이름으로 자동 대응하지 않습니다. 아래 두 큐가 같은 대상인지 확인하고 직접 선택하세요."),
                                              confirm: String(ui: "이 현재 큐에 연결"),
                                              details: [String(ui: "기준 큐:"), Self.cueDescription(old), String(ui: "현재 큐:"), Self.cueDescription(candidate)],
                                              alternate: index + 1 < candidates.count ? String(ui: "다음 큐") : nil)
                switch prompter.choose(prompt) {
                case .cancel: return nil
                case .alternate: continue
                case .confirm:
                    mappings[oldSource] = candidate.sourceID
                    selected = true
                }
                if selected { break }
            }
            if !selected { return nil }
        }
        return mappings
    }

    private static func cueDescription(_ cue: EditableCue) -> String {
        let kind = cue.kind.slotLetter ?? String(ui: "메모리 큐")
        let loop = cue.loop.map { String(ui: "루프 끝 \($0.end, specifier: "%.3f")초 · 활성 \($0.active ? 1 : 0) · 박 \($0.beats ?? 0)") } ?? ""
        return String(ui: "\(kind) · \(cue.time, specifier: "%.3f")초 · \(cue.name) \(loop)")
    }
    private static func gridDescription(_ segment: GridSegment) -> String {
        String(ui: "\(segment.start, specifier: "%.3f")초 · \(segment.bpm, specifier: "%.4f") BPM · 박 \(segment.firstBeatNumber)")
    }
}

@MainActor
enum DraftRecoveryPanels {
    static func recover(store: LibraryStore, row: TrackRow, kind: DraftRecoveryKind) {
        guard !store.isRecoveringDraft, !store.isWritingRekordbox, store.writeTask == nil else { return }
        store.writeTask = Task {
            defer { store.writeTask = nil }
            await ReflectionCoordinator(host: store).recoverDraft(store: store, row: row, kind: kind)
        }
    }
}
