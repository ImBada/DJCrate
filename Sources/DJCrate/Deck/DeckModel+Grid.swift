import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import Foundation
import RekordboxKit

/// 그리드 편집·추정 제안(초안만 바뀐다)
extension DeckModel {
    // MARK: - 그리드 편집 (초안만 바뀐다)

    var canEditGrid: Bool { !isWriteLocked && gridDraft != nil && gridEditBlockedReason == nil }

    /// 그리드 초안 버리기: 편집 중이거나, 편집이 막힌 초안(막히면 편집 잠금을 풀 수 없어도 버릴 수는 있어야 한다)
    var canDiscardGridDraft: Bool {
        guard !isWriteLocked, gridDraft?.hasChanges == true else { return false }
        return gridEditBlockedReason != nil || (canEditGrid && gridEditing)
    }

    /// rekordbox 그리드도, 적용한 추정 그리드도 없는 로컬 곡.
    var needsGrid: Bool { row != nil && row?.track.isStreaming == false && !hasRekordboxGrid && gridDraft == nil }

    func shiftGrid(ms: Double) { mutateGrid(name: String(ui: "그리드 옮기기")) { $0.shift(by: ms / 1000) } }

    func setGridBPM(_ bpm: Double) { mutateGrid(name: String(ui: "BPM 변경")) { $0.setBPM(bpm, at: playhead) } }

    func scaleGridBPM(_ factor: Double) {
        guard let bpm = gridBPM else { return }
        setGridBPM(bpm * factor)
    }

    func nudgeGridBPM(_ delta: Double) {
        guard let bpm = gridBPM else { return }
        setGridBPM(bpm + delta)
    }

    func setGridAnchorAtPlayhead() { mutateGrid { $0.setAnchor(at: playhead) } }

    func addTempoChangeAtPlayhead() { mutateGrid { $0.addTempoChange(nearest: playhead, duration: duration) } }

    func removeTempoChange(at index: Int) { mutateGrid { $0.removeTempoChange(at: index) } }

    func revertGrid() {
        guard canDiscardGridDraft || canEditGrid else { return }
        mutateGrid(name: String(ui: "그리드 초안 버리기"), allowingBlocked: true) { $0.revert() }
    }

    /// 그리드 편집 막대의 ‹ › 버튼을 누르고 있는 동안 그리드 전체를 옮긴다(한 번의 편집으로 저장).
    func beginGridDrag() {
        guard canEditGrid else { return }
        pendingDraftUndo = draftSnapshot
        gridDragBase = gridDraft
        cueDragBase = carryCues ? draft?.cues : nil
    }

    func dragGrid(by seconds: Double) {
        guard !isWriteLocked, var base = gridDragBase, base.trackUUID == row?.track.uuid else { return }
        let from = base.segments
        base.shift(by: seconds)
        gridDraft = base
        if let cues = cueDragBase { moveCuesWithGrid(cues, from: from, to: base.segments, save: false) }
        refreshGrid()
        // 끄는 동안에도 메트로놈이 새 그리드를 따라가게 한다(너무 잦지 않게).
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastClickReset > 0.25 {
            lastClickReset = now
            audio.resetClicks()
        }
    }

    func endGridDrag() {
        guard gridDragBase != nil else { return }
        guard !isWriteLocked else { return }
        gridDragBase = nil
        cueDragBase = nil
        if let draft { persist(draft) }
        saveGridEdit()
        registerDraftUndo(from: pendingDraftUndo, name: String(ui: "그리드 옮기기"))
        pendingDraftUndo = nil
    }

    /// 그리드가 `from` → `to`로 바뀐 만큼 큐(핫큐·메모리 큐·루프 끝)를 따라 옮긴다.
    func moveCuesWithGrid(_ cues: [EditableCue]? = nil, from: [GridSegment], to: [GridSegment], save: Bool = true) {
        guard carryCues, let current = draft else { return }
        let length = max(duration, Double(row?.track.lengthSeconds ?? 0))
        // 지금 초안 값과 같은 큐는 건드리지 않는다(끄는 동안은 출발 위치에서 옮긴다).
        let moved = GridDraft.carried(cues ?? current.cues, from: from, to: to, duration: length).filter { cue in
            guard let now = current.cues.first(where: { $0.id == cue.id }) else { return false }
            return abs(now.time - cue.time) >= 0.0005 || abs((now.loop?.end ?? 0) - (cue.loop?.end ?? 0)) >= 0.0005
        }
        guard !moved.isEmpty else { return }
        mutate(save: save, recordingUndo: false) { draft in for cue in moved { draft.place(cue) } }
    }

    /// 탭 템포: 2초 넘게 쉬면 새로 센다. 최근 8번 간격의 평균.
    func tapTempo() {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = taps.last, now - last > 2 { taps = [] }
        taps.append(now)
        taps = Array(taps.suffix(9))
        guard taps.count >= 3 else { tapBPM = nil; return }
        let interval = (taps.last! - taps.first!) / Double(taps.count - 1)
        tapBPM = 60 / interval
    }

    func resetTapTempo() {
        taps = []
        tapBPM = nil
    }

    func mutateGrid(name: String = String(ui: "그리드 편집"), allowingBlocked: Bool = false, _ change: (inout GridDraft) -> Void) {
        guard canEditGrid || (allowingBlocked && !isWriteLocked), var gridDraft, gridDraft.trackUUID == row?.track.uuid else { return }
        let snapshot = draftSnapshot
        let before = gridDraft.segments
        change(&gridDraft)
        guard self.gridDraft != gridDraft else { return }
        // 복잡한 원본을 대체한 초안은 승인한 모양(템포 구간 하나)을 벗어나는 편집을 받지 않는다(받으면 편집 전체가 막힌다).
        if gridDraft.replacementSource != nil, let originalGrid, !gridDraft.isVerifiedReplacement(of: originalGrid, duration: duration) {
            showToast(String(ui: "복잡한 rekordbox 그리드를 대체한 초안은 템포 구간을 하나로만 둘 수 있으니 변속 지점은 rekordbox에서 편집하세요"), kind: .failure)
            return
        }
        self.gridDraft = gridDraft
        moveCuesWithGrid(from: before, to: gridDraft.segments)
        saveGridEdit()
        registerDraftUndo(from: snapshot, name: name)
    }

    func saveGridEdit() {
        guard let gridDraft else { return }
        refreshGridEditEligibility()
        refreshGrid()
        persistGrid(gridDraft)
        onDraftChange?(gridDraft.trackUUID, .grid, gridDraft.hasChanges)
        if row?.isStaged == true { onStagedGridChange?(gridDraft.trackUUID, gridDraft.segments.first?.bpm) }
        audio.resetClicks()
        refreshSuggestionNote()
    }

    private func refreshGridEditEligibility() {
        guard let originalGrid else { return }
        let fresh = GridDraft(trackUUID: row?.track.uuid ?? "", grid: originalGrid)
        let rebuilt = fresh.grid(duration: max(duration + 1, (originalGrid.beats.last?.time ?? 0) + 0.01))
        let worst = GridEditEligibility.reconstructionErrorMilliseconds(original: originalGrid, rebuilt: rebuilt)
        let replacement = gridDraft?.isVerifiedReplacement(of: originalGrid, duration: duration) == true
        if gridDraft?.replacementSource != nil, !replacement {
            gridEditBlockedReason = String(ui: "초안을 만든 뒤 rekordbox에서 그리드가 바뀌었으니 그리드 현재값 가져오기로 비교하세요")
        } else if worst > 2, !replacement {
            gridEditBlockedReason = String(ui: "이 곡의 그리드는 템포 구간 \(fresh.segments.count)개로 복잡해 정확히 재현되지 않습니다(최대 \(worst, specifier: "%.0f")ms). 편집을 막았습니다.")
        } else {
            gridEditBlockedReason = nil
        }
    }

    // MARK: - 그리드 추정·제안

    /// MU 분석 결과와 어택 곡선으로 그리드를 추정한다. 추가한 곡(아직 rekordbox에 없음)은 그리드가 없으면 바로 적용한다.
    func startGridSuggestion(analysis: PartAnalysis, url: URL, id: String) {
        suggestionTask?.cancel()
        suggestionTask = Task {
            let key = self.row?.track.uuid ?? id
            let estimate = try? await Task.detached(priority: .utility) {
                if let cached = AnalysisCache.gridEstimate(key: key, file: url) { return cached }
                let onset = try OnsetEnvelope.compute(url: url)
                try Task.checkCancellation()
                let estimate = GridEstimator.estimate(beats: analysis.beats, bars: analysis.bars, duration: analysis.duration, onset: onset)
                if let estimate { AnalysisCache.store(estimate, key: key, file: url) }
                return estimate
            }.value
            guard !Task.isCancelled, self.row?.id == id, var estimate else { return }
            // 추정은 음원(AVFoundation) 시간축 → rekordbox 시간축으로 옮긴다.
            for i in estimate.segments.indices { estimate.segments[i].start += self.timelineOffset }
            self.gridSuggestion = estimate
            self.suggestedGrid = GridDraft(trackUUID: "", base: [], segments: estimate.segments).grid(duration: self.duration)
            if self.gridDraft == nil, self.row?.isStaged == true {
                self.applyGridSuggestion(recordingUndo: false)
            } else {
                self.refreshSuggestionNote()
            }
        }
    }

    /// 재분석: 이 곡의 섹션·그리드 추정·조성 캐시와 제안 무시 표시를 지우고 다시 불러온다.
    func reanalyze() {
        guard let uuid = row?.track.uuid else { return }
        AnalysisCache.removeAll(key: uuid)
        var dismissed = storage.settings.strings(SettingKeys.dismissedGridSuggestions)
        dismissed.remove(uuid)
        storage.settings.setStrings(SettingKeys.dismissedGridSuggestions, dismissed)
        reload()
        showToast(String(ui: "다시 분석합니다"), kind: .success)
    }

    /// 무시한 제안을 다시 보인다.
    func restoreGridSuggestion() {
        guard let uuid = row?.track.uuid else { return }
        var dismissed = storage.settings.strings(SettingKeys.dismissedGridSuggestions)
        dismissed.remove(uuid)
        storage.settings.setStrings(SettingKeys.dismissedGridSuggestions, dismissed)
        refreshSuggestionNote()
    }

    /// 이 곡의 그리드 제안을 더는 보이지 않게 한다(곡마다 기억).
    func dismissGridSuggestion() {
        guard let uuid = row?.track.uuid else { return }
        var dismissed = storage.settings.strings(SettingKeys.dismissedGridSuggestions)
        dismissed.insert(uuid)
        storage.settings.setStrings(SettingKeys.dismissedGridSuggestions, dismissed)
        dismissedRevision += 1
    }


    var isGridSuggestionDismissed: Bool {
        guard let uuid = row?.track.uuid else { return false }
        return storage.settings.strings(SettingKeys.dismissedGridSuggestions).contains(uuid)
    }


    // MARK: 알림(잠깐 떴다 사라진다)


    /// 떠 있는 시간(nil이면 닫을 때까지). 경고는 문장이 길어 읽을 시간을 더 준다(#146).
    static func toastDuration(_ kind: AppToast.Kind) -> Duration? {
        switch kind {
        case .success: .seconds(2.5)
        case .warning: .seconds(5)
        case .failure: nil
        }
    }

    func showToast(_ text: String, kind: AppToast.Kind = .warning) {
        toastTask?.cancel()
        toastTask = nil
        let message = AppMessage(kind: kind, text: text)
        toast = message
        feedback.announce(message)
        guard let duration = Self.toastDuration(kind), !feedback.isVoiceOverEnabled() else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, !self.feedback.isVoiceOverEnabled() else { return }
            self.toast = nil
        }
    }

    /// 추정 그리드를 초안으로 적용한다(원본이 있으면 원본은 그대로 두고 구간만 바꾼다).
    func applyGridSuggestion(recordingUndo: Bool = true) {
        guard !isWriteLocked, let suggestion = gridSuggestion, let uuid = row?.track.uuid else { return }
        let base = gridDraft?.base ?? []
        let before = gridDraft?.segments ?? originalGrid.map(GridDraft.segments(from:)) ?? []
        var draft = GridDraft(trackUUID: uuid, base: base, segments: suggestion.segments)
        if let originalGrid, !originalGrid.beats.isEmpty {
            // 초안을 만든 뒤 rekordbox 그리드가 바뀌었으면 어느 쪽도 덮지 않는다.
            guard base == GridDraft.segments(from: originalGrid) else {
                showToast(String(ui: "초안을 만든 뒤 rekordbox에서 그리드가 바뀌었으니 그리드 현재값 가져오기로 비교하세요"), kind: .failure)
                return
            }
            // 템포 구간으로 다시 만들 수 없는 원본만 명시 대체로 승인한다(단순한 원본은 보통 초안이다).
            if GridEditEligibility.reconstructionErrorMilliseconds(of: originalGrid, duration: duration) > 2 {
                guard let approved = draft.approvingReplacement(of: originalGrid, duration: duration) else {
                    showToast(String(ui: "rekordbox 그리드가 복잡한 곡은 템포 구간이 하나인 추정 그리드로만 바꿀 수 있습니다"), kind: .failure)
                    return
                }
                draft = approved
            }
        }
        // 자동 분석은 새 편집이 아니라 초안의 기준을 바꾸는 로드다.
        if !recordingUndo { clearDraftUndo() }
        let snapshot = draftSnapshot
        gridDraft = draft
        moveCuesWithGrid(from: before, to: draft.segments)
        // 복잡한 원본이라 막아 둔 곡도, 추정 그리드로 바꾸면 편집할 수 있다.
        gridEditBlockedReason = nil
        refreshGridEditEligibility()
        refreshGrid()
        persistGrid(draft)
        onDraftChange?(uuid, .grid, draft.hasChanges)
        if row?.isStaged == true { onStagedGridChange?(uuid, draft.segments.first?.bpm) }
        audio.resetClicks()
        refreshSuggestionNote()
        if recordingUndo { registerDraftUndo(from: snapshot, name: String(ui: "추정 그리드 적용")) }
    }

    /// 백그라운드 추정이 이 곡의 초안을 저장했으면 다시 읽는다.
    func gridDraftSavedExternally(_ uuid: String) {
        guard row?.track.uuid == uuid, gridDraft == nil, let saved = storage.loadGridDraft(uuid) else { return }
        clearDraftUndo()
        gridDraft = saved
        refreshGrid()
        refreshSuggestionNote()
    }

    /// 추정과 현재 그리드의 차이를 한 줄로(없거나 작으면 nil).
    func refreshSuggestionNote() {
        guard let suggestion = gridSuggestion else { gridSuggestionNote = nil; return }
        // 신뢰도가 낮을 때만 덧붙인다.
        let confidence = suggestion.isConfident ? "" : " · " + String(ui: "확인 필요")
        guard let grid, !grid.beats.isEmpty else {
            gridSuggestionNote = String(ui: "추정 \(suggestion.bpm, specifier: "%.2f") BPM") + confidence
            return
        }
        let suggested = GridDraft(trackUUID: "", base: [], segments: suggestion.segments).grid(duration: duration)
        let bpmDelta = suggestion.bpm - (grid.beats.first?.bpm ?? suggestion.bpm)
        // 곡 가운데 80%에서 현재 박과 추정 박의 차이(반 박 안으로 접은 값)의 중앙값
        let period = 60 / max(suggestion.bpm, 1)
        var deltas: [Double] = []
        for beat in grid.beats where beat.time > duration * 0.1 && beat.time < duration * 0.9 {
            let i = suggested.firstIndex(atOrAfter: beat.time)
            let near = [i - 1, i].filter { suggested.beats.indices.contains($0) }.map { suggested.beats[$0].time }
            guard let nearest = near.min(by: { abs($0 - beat.time) < abs($1 - beat.time) }) else { continue }
            var d = (nearest - beat.time).truncatingRemainder(dividingBy: period)
            if d > period / 2 { d -= period } else if d < -period / 2 { d += period }
            deltas.append(d)
        }
        deltas.sort()
        let phase = deltas.isEmpty ? 0 : deltas[deltas.count / 2]
        if abs(bpmDelta) < 0.05, abs(phase) < 0.010 {
            gridSuggestionNote = nil  // 사실상 같다
        } else {
            gridSuggestionNote = String(ui: "추정 \(suggestion.bpm, specifier: "%.2f") BPM(\(bpmDelta, specifier: "%+.2f")) · 위상 \(phase * 1000, specifier: "%+.0f")ms")
                + confidence
        }
        if suggestion.segments.count > 1, let note = gridSuggestionNote {
            let flow = suggestion.segments.map { String(format: "%.0f", $0.bpm) }.joined(separator: "→")
            gridSuggestionNote = note + " · " + String(ui: "변속 추정 \(flow)")
        }
    }
}
