import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import Foundation
import RekordboxKit

/// 그리드 편집·추정 제안(초안만 바뀐다)
extension DeckModel {
    // MARK: - 그리드 편집 (초안만 바뀐다)

    var canEditGrid: Bool { gridDraft != nil && gridEditBlockedReason == nil }

    /// rekordbox 그리드도, 적용한 추정 그리드도 없는 로컬 곡.
    var needsGrid: Bool { row != nil && row?.track.isStreaming == false && !hasRekordboxGrid && gridDraft == nil }

    func shiftGrid(ms: Double) { mutateGrid { $0.shift(by: ms / 1000) } }

    func setGridBPM(_ bpm: Double) { mutateGrid { $0.setBPM(bpm, at: playhead) } }

    func scaleGridBPM(_ factor: Double) {
        guard let bpm = gridBPM else { return }
        setGridBPM(bpm * factor)
    }

    func nudgeGridBPM(_ delta: Double) {
        guard let bpm = gridBPM else { return }
        setGridBPM(bpm + delta)
    }

    func setDownbeatAtPlayhead() { mutateGrid { $0.setDownbeat(nearest: playhead, duration: duration) } }

    func setGridAnchorAtPlayhead() { mutateGrid { $0.setAnchor(at: playhead) } }

    func addTempoChangeAtPlayhead() { mutateGrid { $0.addTempoChange(nearest: playhead, duration: duration) } }

    func removeTempoChange(at index: Int) { mutateGrid { $0.removeTempoChange(at: index) } }

    func revertGrid() { mutateGrid { $0.revert() } }

    /// 확대 파형을 끌어 그리드 전체를 옮긴다(그리드 편집 모드).
    func beginGridDrag() {
        guard canEditGrid else { return }
        gridDragBase = gridDraft
        cueDragBase = carryCues ? draft?.cues : nil
    }

    func dragGrid(by seconds: Double) {
        guard var base = gridDragBase, base.trackUUID == row?.track.uuid else { return }
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
        gridDragBase = nil
        if cueDragBase != nil {
            cueDragBase = nil
            commitDraft()
        }
        mutateGrid { _ in }
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
        mutate(save: save) { draft in for cue in moved { draft.place(cue) } }
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

    func mutateGrid(_ change: (inout GridDraft) -> Void) {
        guard canEditGrid, var gridDraft, gridDraft.trackUUID == row?.track.uuid else { return }
        let before = gridDraft.segments
        change(&gridDraft)
        self.gridDraft = gridDraft
        moveCuesWithGrid(from: before, to: gridDraft.segments)
        refreshGrid()
        storage.saveGridDraft(gridDraft)
        onDraftChange?(gridDraft.trackUUID, .grid, gridDraft.hasChanges)
        if row?.isStaged == true { onStagedGridChange?(gridDraft.trackUUID, gridDraft.segments.first?.bpm) }
        audio.resetClicks()
        refreshSuggestionNote()
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
                self.applyGridSuggestion()
            } else {
                self.refreshSuggestionNote()
            }
        }
    }

    /// 재분석: 이 곡의 섹션·그리드 추정·조성 캐시와 제안 무시 표시를 지우고 다시 불러온다.
    func reanalyze() {
        guard let uuid = row?.track.uuid else { return }
        AnalysisCache.removeAll(key: uuid)
        var dismissed = storage.settings.strings("dismissedGridSuggestions")
        dismissed.remove(uuid)
        storage.settings.setStrings("dismissedGridSuggestions", dismissed)
        reload()
        showToast("다시 분석합니다")
    }

    /// 무시한 제안을 다시 보인다.
    func restoreGridSuggestion() {
        guard let uuid = row?.track.uuid else { return }
        var dismissed = storage.settings.strings("dismissedGridSuggestions")
        dismissed.remove(uuid)
        storage.settings.setStrings("dismissedGridSuggestions", dismissed)
        refreshSuggestionNote()
    }

    /// 이 곡의 그리드 제안을 더는 보이지 않게 한다(곡마다 기억).
    func dismissGridSuggestion() {
        guard let uuid = row?.track.uuid else { return }
        var dismissed = storage.settings.strings("dismissedGridSuggestions")
        dismissed.insert(uuid)
        storage.settings.setStrings("dismissedGridSuggestions", dismissed)
        dismissedRevision += 1
    }


    var isGridSuggestionDismissed: Bool {
        guard let uuid = row?.track.uuid else { return false }
        return storage.settings.strings("dismissedGridSuggestions").contains(uuid)
    }


    // MARK: 알림(잠깐 떴다 사라진다)


    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// 추정 그리드를 초안으로 적용한다(원본이 있으면 원본은 그대로 두고 구간만 바꾼다).
    func applyGridSuggestion() {
        guard let suggestion = gridSuggestion, let uuid = row?.track.uuid else { return }
        let base = gridDraft?.base ?? []
        let before = gridDraft?.segments ?? originalGrid.map(GridDraft.segments(from:)) ?? []
        let draft = GridDraft(trackUUID: uuid, base: base, segments: suggestion.segments)
        gridDraft = draft
        moveCuesWithGrid(from: before, to: draft.segments)
        // 복잡한 원본이라 막아 둔 곡도, 추정 그리드로 바꾸면 편집할 수 있다.
        gridEditBlockedReason = nil
        refreshGrid()
        storage.saveGridDraft(draft)
        onDraftChange?(uuid, .grid, draft.hasChanges)
        if row?.isStaged == true { onStagedGridChange?(uuid, draft.segments.first?.bpm) }
        audio.resetClicks()
        refreshSuggestionNote()
    }

    /// 반 박 옮긴다(추정이 뒷박을 잡았을 때 한 번에 고친다).
    func shiftGridHalfBeat() {
        mutateGrid { draft in
            let segment = draft.segments[draft.segmentIndex(at: playhead)]
            draft.shift(by: 30 / segment.bpm)
        }
    }

    /// 백그라운드 추정이 이 곡의 초안을 저장했으면 다시 읽는다.
    func gridDraftSavedExternally(_ uuid: String) {
        guard row?.track.uuid == uuid, gridDraft == nil, let saved = storage.loadGridDraft(uuid) else { return }
        gridDraft = saved
        refreshGrid()
        refreshSuggestionNote()
    }

    /// 추정과 현재 그리드의 차이를 한 줄로(없거나 작으면 nil).
    func refreshSuggestionNote() {
        guard let suggestion = gridSuggestion else { gridSuggestionNote = nil; return }
        // 신뢰도가 낮을 때만 덧붙인다.
        let confidence = suggestion.isConfident ? "" : " · 확인 필요"
        guard let grid, !grid.beats.isEmpty else {
            gridSuggestionNote = String(format: "추정 %.2f BPM", suggestion.bpm) + confidence
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
            gridSuggestionNote = String(format: "추정 %.2f BPM(%+.2f) · 위상 %+.0fms", suggestion.bpm, bpmDelta, phase * 1000) + confidence
        }
        if suggestion.segments.count > 1, let note = gridSuggestionNote {
            let flow = suggestion.segments.map { String(format: "%.0f", $0.bpm) }.joined(separator: "→")
            gridSuggestionNote = note + " · 변속 추정 \(flow)"
        }
    }
}
