import AnicueCore
import AppKit
import AVFoundation
import ImageIO
import Observation

/// 위쪽 덱: 선택한 곡의 파형·그리드·분석·재생·큐/그리드 초안.
@MainActor
@Observable
final class DeckModel {
    enum DraftKind { case cue, grid, gain }

    private(set) var row: TrackRow?
    private(set) var waveform: Waveform?
    private(set) var waveformError: String?
    private(set) var analysis: PartAnalysis?
    private(set) var analysisError: String?
    /// 섹션(MU) 분석이 끝나기를 기다리는 중(섹션 칸에 로딩 막대)
    private(set) var isAnalyzingSections = false
    private(set) var artwork: NSImage?
    private(set) var draft: CueDraft?
    var selectedCueID: EditableCue.ID?
    private(set) var playhead: Double = 0 {
        didSet { updateDisplayTime() }
    }
    private(set) var isPlaying = false {
        didSet { if !isPlaying, displayTime != playhead { displayTime = playhead } }
    }
    var zoomSeconds: Double = DeckSettings.double("zoomSeconds", 16) { didSet { DeckSettings.set("zoomSeconds", zoomSeconds) } }
    /// CDJ식 메인 CUE 지점. 곡을 불러오면 첫 메모리 큐(없으면 0초)에 놓인다. 초안·rekordbox에는 쓰지 않는다.
    private(set) var cuePoint: Double = 0
    /// CUE를 누르고 있는 동안의 미리 듣기.
    private(set) var isCuePreviewing = false
    private var placeAtFirstMemoryCue = false
    var quantize = DeckSettings.bool("quantize", true) { didSet { DeckSettings.set("quantize", quantize) } }
    /// 그리드를 고칠 때 핫큐(루프 포함)도 같은 박을 따라 옮긴다.
    var carryHotCues = DeckSettings.bool("carryHotCues", true) { didSet { DeckSettings.set("carryHotCues", carryHotCues) } }
    var showSuggestions = DeckSettings.bool("showSuggestions", true) {
        didSet { DeckSettings.set("showSuggestions", showSuggestions); refreshSuggestions() }
    }

    // 재생 설정
    var volume: Double = DeckSettings.double("volume", 0.9) {
        didSet { audio.volume = Float(volume); DeckSettings.set("volume", volume) }
    }
    var metronome = false { didSet { audio.metronome = metronome } }
    /// 재생 속도(%). rekordbox 템포 슬라이더와 같은 의미.
    var tempoPercent: Double = 0 { didSet { audio.rate = 1 + tempoPercent / 100 } }
    var keyLock = DeckSettings.bool("keyLock", true) { didSet { audio.keyLock = keyLock; DeckSettings.set("keyLock", keyLock) } }

    // MARK: 게인 (볼륨 페이더 앞)

    /// 곡마다 통합 음량을 목표에 맞춘다.
    var autoGain = DeckSettings.bool("autoGain", true) { didSet { DeckSettings.set("autoGain", autoGain); applyGain() } }
    /// 오토게인 목표(LUFS)
    var gainTarget: Double = DeckSettings.double("gainTarget", -10) { didSet { DeckSettings.set("gainTarget", gainTarget); applyGain() } }
    /// 피크가 0dBFS를 넘지 않을 만큼만 올린다.
    var peakProtection = DeckSettings.bool("peakProtection", true) {
        didSet { DeckSettings.set("peakProtection", peakProtection); applyGain() }
    }
    /// 수동 트림(dB). 오토게인 위에 더한다.
    var gainTrim: Double = DeckSettings.double("gainTrim", 0) { didSet { DeckSettings.set("gainTrim", gainTrim); applyGain() } }
    /// 지금 곡의 음량(메모리 디코딩 뒤 측정, 다음부터는 캐시)
    private(set) var loudness: Loudness?

    /// rekordbox 오토게인을 그대로 쓴다(없으면 anicue 측정으로 계산).
    var useRekordboxGain = DeckSettings.bool("useRekordboxGain", true) {
        didSet { DeckSettings.set("useRekordboxGain", useRekordboxGain); applyGain() }
    }

    /// 이 곡의 rekordbox 오토게인(dB)
    var rekordboxGainDB: Double? { row?.autoGain?.gainDB }

    /// anicue 측정으로 계산한 오토게인(dB)
    var measuredGainDB: Double? {
        loudness.map { $0.autoGain(target: gainTarget, peakProtection: peakProtection) }
    }

    /// rekordbox 오토게인과 anicue 계산(같은 −10 LUFS 기준)의 차이. 1.5dB 넘으면 이상한 값으로 본다.
    var gainMismatchDB: Double? {
        guard let rekordbox = rekordboxGainDB, let integrated = loudness?.integrated else { return nil }
        return rekordbox - (RekordboxAutoGain.targetLoudness - integrated)
    }

    var isGainSuspicious: Bool { abs(gainMismatchDB ?? 0) > 1.5 }

    var autoGainDB: Double {
        guard autoGain else { return 0 }
        if let gainDraft { return gainDraft }
        if useRekordboxGain, let rekordbox = rekordboxGainDB { return rekordbox }
        return measuredGainDB ?? 0
    }

    // MARK: 곡 오토게인 초안(rekordbox에 반영한다)

    /// 이 곡의 오토게인 초안(dB). rekordbox에 반영하면 rekordbox 오토게인이 이 값이 된다.
    private(set) var gainDraft: Double?

    /// 지금 이 곡에 쓰는 오토게인 값(초안 > rekordbox)
    var trackGainDB: Double? { gainDraft ?? rekordboxGainDB }

    private(set) var dismissedGainSuggestions: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "deck.dismissedGainSuggestions") ?? []) {
        didSet { UserDefaults.standard.set(Array(dismissedGainSuggestions), forKey: "deck.dismissedGainSuggestions") }
    }

    /// 제안할 게인(dB): rekordbox 오토게인이 anicue 측정과 1.5dB 넘게 다를 때 anicue 계산값
    var gainSuggestion: Double? {
        guard autoGain, useRekordboxGain, isGainSuspicious, gainDraft == nil, let uuid = row?.track.uuid,
              !dismissedGainSuggestions.contains(uuid) else { return nil }
        return measuredGainDB
    }

    func acceptGainSuggestion() {
        guard let value = measuredGainDB else { return }
        setTrackGain((value * 10).rounded() / 10)
    }

    func dismissGainSuggestion() {
        guard let uuid = row?.track.uuid else { return }
        dismissedGainSuggestions.insert(uuid)
    }

    /// 곡 오토게인을 정한다(초안). rekordbox 값과 같으면 초안을 지운다.
    func setTrackGain(_ value: Double) {
        guard let uuid = row?.track.uuid, rekordboxGainDB != nil else { return }
        let clamped = min(max(value, -24), 24)
        if let rekordbox = rekordboxGainDB, abs(clamped - rekordbox) < 0.05 {
            gainDraft = nil
        } else {
            gainDraft = clamped
        }
        GainDraftStore.save(gainDraft, trackUUID: uuid)
        onDraftChange?(uuid, .gain, gainDraft != nil)
        applyGain()
    }

    func adjustTrackGain(by delta: Double) {
        guard let current = trackGainDB else { return }
        setTrackGain(((current + delta) * 10).rounded() / 10)
    }

    /// 초안을 지우고 rekordbox 오토게인으로 돌아간다.
    func clearGainDraft() {
        guard let uuid = row?.track.uuid else { return }
        gainDraft = nil
        dismissedGainSuggestions.remove(uuid)
        GainDraftStore.remove(trackUUID: uuid)
        onDraftChange?(uuid, .gain, false)
        applyGain()
    }

    var hasGainOverride: Bool { gainDraft != nil }

    /// 실제로 걸린 게인(dB)
    var appliedGain: Double { min(max(autoGainDB + gainTrim, -24), 24) }

    /// 게인 뒤·볼륨 앞 레벨
    var meter: LevelMeter { audio.meter }

    private func applyGain() { audio.gainDB = Float(appliedGain) }

    // MARK: 조성 흐름(추정)

    /// 곡 안의 조표 구간(rekordbox 시간축). 주 조표는 rekordbox 키에 맞춘다.
    private(set) var keySegments: [KeyAnalyzer.Segment] = []
    /// 장·단(A/B)은 rekordbox 키를 따른다(없으면 장조로 본다).
    private(set) var keyMinor = false
    @ObservationIgnored private var keyChroma: KeyAnalyzer.Chroma?

    func keyName(for segment: KeyAnalyzer.Segment) -> String { KeyAnalyzer.camelot(signature: segment.signature, minor: keyMinor) }

    /// 재생 위치의 조성(Camelot)
    func key(at time: Double) -> String? {
        guard let segment = keySegments.first(where: { time >= $0.start && time < $0.end }) ?? keySegments.last(where: { time >= $0.start })
        else { return row?.track.key }
        return keyName(for: segment)
    }

    /// 크로마·그리드가 바뀌면 다시 계산한다(마디 창, 벌점 5, 최소 16마디).
    private func refreshKeySegments() {
        guard let chroma = keyChroma, !chroma.frames.isEmpty else { keySegments = []; return }
        let offset = timelineOffset
        let rekordbox = row.flatMap { KeyAnalyzer.signature(camelot: $0.track.key ?? "") }
        keyMinor = rekordbox?.minor ?? false
        // 창은 rekordbox 시간축(그리드 기준) → 크로마(음원 시간축)로 옮겨 계산하고 되돌린다.
        let windows = KeyAnalyzer.windows(grid: grid, duration: duration).map { ($0.0 - offset, $0.1 - offset) }
        let result = KeyAnalyzer.segments(chroma: chroma, windows: windows, switchPenalty: 5, minWindows: 16)
        var segments = result.segments.map { KeyAnalyzer.Segment(start: $0.start + offset, end: $0.end + offset, signature: $0.signature) }
        // 주 조표를 rekordbox 키에 맞춘다(전조는 같은 간격으로 옮긴다).
        if let main = result.main, let rekordbox, main != rekordbox.signature {
            let shift = rekordbox.signature - main
            segments = segments.map { var s = $0; s.signature = (($0.signature + shift) % 12 + 12) % 12; return s }
        }
        if let first = segments.first, first.start > 0 { segments[0].start = 0 }
        keySegments = segments
    }

    // 그리드
    private(set) var originalGrid: BeatGrid?
    private(set) var gridDraft: GridDraft?
    /// 화면·스냅·메트로놈이 쓰는 그리드. 편집하지 않았으면 rekordbox 원본 그대로다.
    private(set) var grid: BeatGrid? { didSet { if grid?.downbeats != oldValue?.downbeats { refreshKeySegments() } } }
    var gridEditing = false
    /// rekordbox에 쓰는 동안 큐 편집을 막는다(쓰는 초안과 덱 초안이 어긋나지 않게).
    /// rekordbox에 쓰는 동안: 재생을 잠시 멈추고(끝나면 이어서) 편집을 막는다.
    var isWriteLocked = false {
        didSet {
            guard isWriteLocked != oldValue else { return }
            if isWriteLocked {
                resumeAfterWrite = isPlaying
                if isPlaying { togglePlay() }
            } else if resumeAfterWrite {
                resumeAfterWrite = false
                if canPlay, !isPlaying { togglePlay() }
            }
        }
    }
    private var resumeAfterWrite = false
    private var softReloadTask: Task<Void, Never>?
    /// 편집 전 재생성 오차가 크면(다이내믹 그리드 등) 그리드 편집을 막는다.
    private(set) var gridEditBlockedReason: String?
    /// rekordbox 비트 그리드가 있는 곡인지(없으면 추정 그리드를 권한다)
    private(set) var hasRekordboxGrid = false
    /// rekordbox 시간축 − 음원(AVFoundation) 시간축(초). 덱은 rekordbox 시간축을 쓰고,
    /// 음원 재생·파형·MU 분석만 이만큼 밀어 맞춘다(압축 음원의 인코더 지연을 rekordbox처럼 남긴다).
    private(set) var timelineOffset: Double = 0
    /// anicue가 추정한 그리드(anicue 시간축)와 현재 그리드와의 차이 설명
    private(set) var gridSuggestion: GridEstimator.Estimate?
    private(set) var gridSuggestionNote: String?
    /// 그리드가 없는 곡에서 파형 위에 미리 보여 줄 추정 박(적용 전)
    private(set) var suggestedGrid: BeatGrid?
    private var suggestionTask: Task<Void, Never>?
    /// 추가한 곡의 그리드가 바뀌면 목록 BPM을 맞춘다.
    var onStagedGridChange: ((String, Double?) -> Void)?
    /// 큐 초안이 바뀔 때(목록의 핫큐·메모리 숫자용)
    var onCueDraftChange: ((CueDraft) -> Void)?
    /// 지금 곡의 초안을 rekordbox 반영 XML로 만들기(덱 큐 목록의 버튼)
    var onRequestReflection: ((TrackRow) -> Void)?
    private(set) var tapBPM: Double?
    private var taps: [Double] = []
    private var gridDragBase: GridDraft?
    /// 그리드를 끄는 동안 핫큐의 출발 위치(끄는 동안 오차가 쌓이지 않게 늘 여기서 옮긴다)
    private var cueDragBase: [EditableCue]?
    private var lastClickReset: Double = 0

    /// 초안 존재 여부가 바뀌면 알린다(목록의 편집 표시용). 디스크를 다시 읽지 않도록 상태를 함께 넘긴다.
    var onDraftChange: ((String, DraftKind, Bool) -> Void)?

    /// 곡 길이와 재생 가능 여부는 관찰되는 저장값이다(오디오 엔진 값은 관찰되지 않는다).
    private(set) var duration: Double = 0
    private(set) var canPlay = false
    var currentTime: Double { playhead }
    /// 글자·전체 파형용 재생 위치. 재생 중에는 초당 15번만 바뀐다(멈춰 있을 땐 바로 따라간다).
    private(set) var displayTime: Double = 0
    @ObservationIgnored private var displayTimeStamp: Double = 0

    private func updateDisplayTime() {
        guard displayTime != playhead else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // 재생 중이 아니거나(탐색·끌기) 크게 뛰면 바로, 재생 중에는 1/15초마다
        if !isPlaying || now - displayTimeStamp >= 1.0 / 15 || abs(playhead - displayTime) > 0.5 {
            displayTime = playhead
            displayTimeStamp = now
        }
    }
    var rate: Double { 1 + tempoPercent / 100 }

    /// 플레이헤드가 있는 템포 구간의 BPM. 바뀔 때만 갱신되는 저장값이다.
    private(set) var gridBPM: Double?

    /// 메모리 큐 제안과 섹션 에너지는 분석·큐·그리드가 바뀔 때만 다시 계산한다.
    private(set) var suggestions: [Double] = []
    private(set) var sectionEnergies: [PartLabeler.SectionEnergy] = []

    private let audio = DeckAudio()
    @ObservationIgnored private lazy var ticker = DisplayTicker { [weak self] in self?.tick() }
    private var loadTask: Task<Void, Never>?
    private var waveformTask: Task<Waveform, Error>?
    private var resumeAfterScrub = false
    private var seekRestartTask: Task<Void, Never>?

    init() {
        audio.volume = Float(volume)
        audio.keyLock = keyLock
        audio.onChroma = { [weak self] chroma in
            guard let self, let row = self.row, !row.track.isStreaming else { return }
            AnalysisCache.store(chroma, key: row.track.uuid, file: URL(filePath: row.track.folderPath))
            self.keyChroma = chroma
            self.refreshKeySegments()
        }
        audio.onLoudness = { [weak self] measured in
            guard let self, let row = self.row, !row.track.isStreaming else { return }
            LoudnessCache.shared.store(measured, for: URL(filePath: row.track.folderPath))
            self.loudness = measured
            self.applyGain()
        }
        audio.onRecovered = { [weak self] in
            guard let self else { return }
            self.isPlaying = true
            self.ticker.start()
        }
        audio.onInterrupted = { [weak self] position in
            guard let self else { return }
            self.ticker.stop()
            self.isPlaying = false
            self.playhead = position
        }
    }

    func setZoom(_ seconds: Double) {
        zoomSeconds = min(max(seconds, 2), 64)
    }

    func zoom(by factor: Double) {
        setZoom(zoomSeconds * factor)
    }

    // MARK: - 로드

    /// 지금 곡을 처음부터 다시 읽는다(분석 파일·초안이 밖에서 바뀌었을 때).
    func reload() {
        let current = row
        load(nil)
        load(current)
    }

    /// rekordbox에 쓰거나 되돌린 뒤: 소리·파형·분석은 그대로 두고 초안·그리드·게인만 새 rekordbox 값으로 맞춘다.
    func refreshAfterWrite(_ newRow: TrackRow?) {
        guard let current = row else { return }
        let target = newRow ?? current
        guard target.id == current.id else { return }
        softReload(target)
    }

    /// 같은 곡·같은 파일인데 내용(큐·그리드·게인·메타데이터)만 바뀌었을 때.
    private func softReload(_ newRow: TrackRow) {
        row = newRow
        gainDraft = GainDraftStore.load(trackUUID: newRow.track.uuid)
        applyGain()
        let selected = cue(selectedCueID), engaged = cue(engagedLoopID)
        let track = newRow.track, cues = newRow.cues, id = newRow.id, length = duration
        softReloadTask?.cancel()
        softReloadTask = Task {
            let payload = await Task.detached(priority: .userInitiated) {
                DeckPayload.load(track: track, cues: cues, duration: length)
            }.value
            guard !Task.isCancelled, self.row?.id == id else { return }
            self.draft = payload.draft
            self.originalGrid = payload.originalGrid
            self.gridDraft = payload.gridDraft
            self.gridEditBlockedReason = payload.gridBlockedReason
            self.hasRekordboxGrid = payload.originalGrid != nil
            self.refreshGrid()
            self.refreshSuggestions()
            self.refreshSuggestionNote()
            // 고른 큐·걸린 루프는 같은 자리·종류의 새 큐로 잇는다(반영하면 rekordbox 큐로 바뀌어 ID가 새로 생긴다).
            func match(_ old: EditableCue?) -> EditableCue.ID? {
                old.flatMap { o in payload.draft.cues.first { $0.kind == o.kind && abs($0.time - o.time) < 0.002 }?.id }
            }
            self.selectedCueID = match(selected)
            if self.engagedLoopID != nil { self.engagedLoopID = match(engaged) }
        }
    }

    /// 곡 ID가 같아도 내용(새 스냅샷의 큐·메타데이터)이 다르면 다시 불러온다.
    /// 같은 파일이고 이미 소리를 불러 둔 상태면 처음부터 다시 부르지 않고 초안·그리드만 맞춘다.
    func load(_ row: TrackRow?) {
        guard row != self.row else { return }
        let sameTrack = row != nil && row?.id == self.row?.id
        if sameTrack, let row, let current = self.row, canPlay,
           row.track.folderPath == current.track.folderPath, row.track.imagePath == current.track.imagePath {
            softReload(row)
            return
        }
        stopPlayback()
        loadTask?.cancel()
        waveformTask?.cancel()
        seekRestartTask?.cancel()
        audio.unload()
        self.row = row
        waveform = nil; waveformError = nil; analysis = nil; analysisError = nil; artwork = nil
        isAnalyzingSections = row.map { !$0.track.isStreaming } ?? false
        suggestions = []; sectionEnergies = []; draft = nil; loudness = nil; keySegments = []; keyChroma = nil; gainDraft = nil
        engagedLoopID = nil; instantLoop = nil
        originalGrid = nil; gridDraft = nil; grid = nil; gridBPM = nil; gridEditBlockedReason = nil
        hasRekordboxGrid = false; timelineOffset = 0; gridSuggestion = nil; gridSuggestionNote = nil; suggestedGrid = nil
        suggestionTask?.cancel()
        gridDragBase = nil; tapBPM = nil; taps = []; resumeAfterScrub = false; isCuePreviewing = false
        if !sameTrack { selectedCueID = nil; playhead = 0; cuePoint = 0; placeAtFirstMemoryCue = true }
        duration = Double(row?.track.lengthSeconds ?? 0)
        canPlay = false
        guard let row else { return }

        let url = URL(filePath: row.track.folderPath)
        let exists = !row.track.isStreaming && FileManager.default.fileExists(atPath: url.path)
        if exists {
            // 인코더 지연은 rekordbox 쪽에 맞춘다: 덱의 모든 시각은 rekordbox 시간축이다.
            timelineOffset = RekordboxTimeline.predictedOffset(url: url)
            // 조성 크로마 캐시가 있으면 디코딩 때 다시 계산하지 않는다(불러오기 전에 정해야 한다).
            let cachedChroma = AnalysisCache.chroma(key: row.track.uuid, file: url)
            audio.needsChroma = cachedChroma == nil
            try? audio.load(url: url, timelineOffset: timelineOffset)
            // 전에 잰 곡이면 디코딩을 기다리지 않고 바로 오토게인을 건다.
            loudness = LoudnessCache.shared.value(for: url)
            gainDraft = GainDraftStore.load(trackUUID: row.track.uuid)
            applyGain()
            canPlay = audio.isLoaded
            if canPlay { duration = audio.duration }
            if let cachedChroma {
                keyChroma = cachedChroma
                refreshKeySegments()
            }
            if !canPlay { waveformError = "이 파일 형식은 재생·파형을 지원하지 않습니다." }
        } else if !row.track.isStreaming {
            waveformError = "파일을 찾을 수 없습니다. 외장 드라이브가 연결됐는지 확인하세요."
        }
        playhead = min(playhead, duration)

        let track = row.track, cues = row.cues, id = row.id, key = track.uuid, length = duration
        loadTask = Task {
            // 1) 초안·그리드·아트워크는 백그라운드에서 읽고, 아직 이 곡일 때만 적용한다.
            let payload = await Task.detached(priority: .userInitiated) {
                DeckPayload.load(track: track, cues: cues, duration: length)
            }.value
            guard !Task.isCancelled, self.row?.id == id else { return }
            self.apply(payload)
            if self.artwork == nil, exists {
                let embedded = await ArtworkCache.embeddedArtwork(url: url)
                guard !Task.isCancelled, self.row?.id == id, self.artwork == nil else { return }
                self.artwork = embedded
            }

            // 2) 파형: 곡을 넘기면 바로 취소된다(조각 단위로 취소를 확인한다).
            guard self.canPlay else { self.isAnalyzingSections = false; return }
            let job = Task.detached(priority: .userInitiated) { try WaveformCache.load(fileAt: url, key: key) }
            self.waveformTask = job
            do {
                let waveform = try await job.value
                guard !Task.isCancelled, self.row?.id == id else { return }
                self.waveform = waveform
            } catch {
                guard !Task.isCancelled, self.row?.id == id else { return }
                self.waveformError = "파형을 만들지 못했습니다: \(error.localizedDescription)"
            }
            self.applyLaunchFlags()

            // 3) 음악 분석(약 5초): 같은 곡에 1초 머문 뒤에만 시작하고, 곡을 넘기면 취소된다.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self.row?.id == id else { return }
            do {
                let analysis = try await PartAnalyzer.analyze(fileAt: url, cacheKey: key)
                guard !Task.isCancelled, self.row?.id == id else { return }
                let shifted = analysis.shifted(by: self.timelineOffset)
                self.analysis = shifted
                self.analysisError = nil
                self.isAnalyzingSections = false
                self.sectionEnergies = PartLabeler.energies(shifted)
                self.refreshSuggestions()
                self.startGridSuggestion(analysis: analysis, url: url, id: id)
            } catch {
                guard !Task.isCancelled, self.row?.id == id else { return }
                self.analysisError = String(describing: error)
                self.isAnalyzingSections = false
            }
        }
    }

    private func apply(_ payload: DeckPayload) {
        draft = payload.draft
        originalGrid = payload.originalGrid
        gridDraft = payload.gridDraft
        gridEditBlockedReason = payload.gridBlockedReason
        hasRekordboxGrid = payload.originalGrid != nil
        if let image = payload.artwork?.image {
            artwork = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        refreshGrid()
        // CDJ처럼 첫 메모리 큐에서 대기한다. 그사이 사용자가 위치를 옮겼으면 건드리지 않는다.
        if placeAtFirstMemoryCue {
            placeAtFirstMemoryCue = false
            let first = draft?.cues.filter { $0.kind == .memory }.map(\.time).min() ?? 0
            if !isPlaying, playhead == cuePoint {
                cuePoint = min(max(first, 0), duration)
                playhead = cuePoint
                audio.seekWhilePaused(cuePoint)
                updateGridBPM()
            }
        }
    }

    /// 개발용: `--grid-edit`, `--autoplay [--muted|--quiet] [--metronome]`
    private func applyLaunchFlags() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--grid-edit") { gridEditing = true }
        if args.contains("--autoplay"), !isPlaying {
            if args.contains("--muted") { volume = 0 }
            if args.contains("--quiet") { volume = 0.0003 }   // 진단용 −70dB
            if args.contains("--metronome") { metronome = true }
            togglePlay()
        }
        if args.contains("--audio-selftest"), !Self.selfTestStarted {
            Self.selfTestStarted = true
            runAudioSelfTest()
        }
        if args.contains("--stale-cue-selftest"), !Self.selfTestStarted {
            Self.selfTestStarted = true
            runStaleCueSelfTest()
        }
        if args.contains("--analysis-play-selftest"), !Self.selfTestStarted {
            Self.selfTestStarted = true
            runAnalysisPlaySelfTest()
        }
        if args.contains("--grid-selftest"), !Self.selfTestStarted {
            Self.selfTestStarted = true
            runGridSelfTest()
        }
        if args.contains("--key-selftest"), !Self.selfTestStarted {
            Self.selfTestStarted = true
            runKeySelfTest()
        }
    }

    private static var selfTestStarted = false

    /// 진단: 실제 조작 순서를 흉내 내며 단계마다 표시를 남긴다(`ANICUE_AUDIO_DEBUG=1`과 함께 쓴다).
    private func runAudioSelfTest() {
        volume = 0.0003
        Task {
            await selfTestStep("재생") { togglePlay() }
            await selfTestStep("일시정지", 1) { togglePlay() }
            await selfTestStep("재개") { togglePlay() }
            await selfTestStep("탐색 60초") { seek(60) }
            await selfTestStep("0초로 탐색(지연 구간 안쪽)") { seek(0.01) }
            await selfTestStep("스크럽(끌기)") { beginScrub(); scrub(to: 80); scrub(to: 90); endScrub() }
            await selfTestStep("가로 스크롤 스크럽") { scrubCoalesced(to: 100); scrubCoalesced(to: 101) }
            await selfTestStep("템포 +8%") { tempoPercent = 8 }
            await selfTestStep("템포 +8% 탐색 30초") { seek(30) }
            await selfTestStep("키락 끔") { keyLock = false }
            await selfTestStep("키락 끔 탐색 40초") { seek(40) }
            await selfTestStep("템포 0%·키락 켬") { tempoPercent = 0; keyLock = true }
            await selfTestStep("탐색 50초") { seek(50) }
            await selfTestStep("메트로놈 켬") { metronome = true }
            await selfTestStep("일시정지 후 재개", 0.3) { togglePlay() }
            await selfTestStep("재개") { togglePlay() }
            await selfTestStep("재생 중 CUE → 큐 지점 정지", 1) { cueDown(); cueUp() }
            await selfTestStep("탐색 70초(멈춤)", 0.5) { seek(70) }
            await selfTestStep("CUE → 70초를 새 큐 지점으로", 0.5) { cueDown(); cueUp() }
            await selfTestStep("CUE 누르고 있기(미리 듣기)", 1.5) { cueDown() }
            await selfTestStep("CUE 뗌 → 큐 지점 복귀", 1) { cueUp() }
            await selfTestStep("CUE 누른 채 재생 → 계속 재생", 0.5) { cueDown(); togglePlay() }
            await selfTestStep("CUE 뗌(계속 재생)", 1.5) { cueUp() }
            await selfTestStep("재생(복구 시험)") { if !isPlaying { togglePlay() } }
            await selfTestStep("엔진이 알림 없이 멈춤", 3) { audio.debugStopEngine() }
            await selfTestStep("출력 구성 변경", 3) { audio.debugConfigurationChange() }
            await selfTestStep("끝", 0.5) { togglePlay() }
        }
    }

    /// 진단: CUE를 뗀 신호를 놓친 상황(미리 듣기 상태만 남음)에서 스스로 풀리는지, 재생이 되는지 본다.
    private func runStaleCueSelfTest() {
        volume = 0.0003
        Task {
            await selfTestStep("큐 지점으로", 0.5) { seek(cuePoint) }
            await selfTestStep("재생", 1.5) { togglePlay() }
            await selfTestStep("정지 후 오래 쉼(엔진 꺼짐)", 4) { togglePlay() }
            await selfTestStep("오래 쉰 뒤 재생", 2) { togglePlay() }
            await selfTestStep("정지", 0.5) { togglePlay() }
            await selfTestStep("큐 지점으로 다시", 0.5) { seek(cuePoint) }
            await selfTestStep("CUE 누름(뗌 신호 없음)", 1.5) { cueDown() }
            await selfTestStep("재생 누름", 2) { togglePlay() }
            await selfTestStep("정지", 0.5) { togglePlay() }
            await selfTestStep("다시 재생", 2) { togglePlay() }
            await selfTestStep("끝", 0.5) { if isPlaying { togglePlay() } }
        }
    }

    /// 진단: 분석이 도는 동안 재생·일시정지·재개를 반복한다(곡을 고르자마자 재생하는 실제 사용과 같게).
    private func runAnalysisPlaySelfTest() {
        volume = 0.0003
        Task {
            await selfTestStep("곡 로드 직후 재생", 3) { togglePlay() }
            for round in 1...8 {
                await selfTestStep("일시정지 \(round)", 1.2) { togglePlay() }
                await selfTestStep("재개 \(round)", 2.5) { togglePlay() }
            }
            await selfTestStep("끝", 0.5) { if isPlaying { togglePlay() } }
        }
    }

    /// 진단: 그리드 편집 중·후에 소리가 끊기는지 본다.
    private func runGridSelfTest() {
        volume = 0.0003
        Task {
            await selfTestStep("재생") { togglePlay() }
            await selfTestStep("그리드 편집 켬") { gridEditing = true }
            await selfTestStep("그리드 10ms 이동") { shiftGrid(ms: 10) }
            await selfTestStep("BPM +0.01") { nudgeGridBPM(0.01) }
            await selfTestStep("여기를 1박으로") { setDownbeatAtPlayhead() }
            await selfTestStep("그리드 끌기") { beginGridDrag(); dragGrid(by: 0.02); dragGrid(by: 0.03); endGridDrag() }
            await selfTestStep("여기서 BPM 변경") { addTempoChangeAtPlayhead() }
            await selfTestStep("메트로놈 켬") { metronome = true }
            await selfTestStep("메트로놈 켠 채 10ms 이동") { shiftGrid(ms: 10) }
            await selfTestStep("일시정지", 0.5) { togglePlay() }
            await selfTestStep("재개") { togglePlay() }
            await selfTestStep("탐색 60초") { seek(60) }
            await selfTestStep("그리드 되돌리기") { revertGrid() }
            await selfTestStep("그리드 편집 끔") { gridEditing = false }
            await selfTestStep("끝", 0.5) { togglePlay() }
        }
    }

    /// 진단: 앱 안으로 키 이벤트를 흘려보내 단축키·포커스 경로를 확인한다(다른 앱에는 가지 않는다).
    private func runKeySelfTest() {
        volume = 0.0003
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            @MainActor func key(_ characters: String, _ code: UInt16) async {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: characters, charactersIgnoringModifiers: characters,
                                                    isARepeat: false, keyCode: code) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            @MainActor func shiftKey(_ characters: String, _ code: UInt16) async {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.shift],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: characters, charactersIgnoringModifiers: characters,
                                                    isARepeat: false, keyCode: code) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            @MainActor func mark(_ name: String) {
                let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "없음"
                let line = "── \(name) · 재생=\(isPlaying) · 포커스=\(responder)"
                AudioDebug.log(line)
            }
            @MainActor func field(_ view: NSView?, placeholder: String) -> NSTextField? {
                guard let view else { return nil }
                if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
                for sub in view.subviews { if let found = field(sub, placeholder: placeholder) { return found } }
                return nil
            }
            mark("시작")
            await key(" ", 49); mark("스페이스(재생 기대)")
            await key(" ", 49); mark("스페이스(정지 기대)")
            gridEditing = true
            try? await Task.sleep(for: .milliseconds(400))
            if let bpm = field(window.contentView, placeholder: "BPM") { window.makeFirstResponder(bpm) }
            mark("BPM 칸 클릭")
            await key("\r", 36); mark("Return")
            await key(" ", 49); mark("스페이스(재생 기대)")
            await key(" ", 49); mark("스페이스(정지 기대)")
            await key("ㅊ", 8); mark("C 자리 키를 한글 입력으로(ㅊ) · 큐 \(String(format: "%.2f", cuePoint))")
            await key("ㄷ", 14); mark("E 자리(ㄷ) 다음 큐 · 위치 \(String(format: "%.2f", playhead))")
            await key("ㄷ", 14); mark("E 자리(ㄷ) 다음 큐 · 위치 \(String(format: "%.2f", playhead))")
            let hotA = hotCue(slot: 0).map { String(format: "%.2f", $0.time) } ?? "없음"
            await key("1", 18); mark("1 → 핫큐 A(\(hotA)) · 위치 \(String(format: "%.2f", playhead))")
            await key("5", 23); mark("5 → 핫큐 E · 위치 \(String(format: "%.2f", playhead))")
            let memoriesBefore = draft?.cues.filter { $0.kind == .memory }.count ?? 0
            await key("₩", 50); mark("` 자리(₩) → 메모리 큐 \(memoriesBefore) → \(draft?.cues.filter { $0.kind == .memory }.count ?? 0)")
            seek(playhead + 5)
            await key("ㅡ", 46); mark("M 자리(ㅡ) → 메모리 큐 \(draft?.cues.filter { $0.kind == .memory }.count ?? 0)")
            await shiftKey("M", 46); mark("Shift+M → 이 자리 메모리 큐 지움 → \(draft?.cues.filter { $0.kind == .memory }.count ?? 0)")
            await shiftKey("M", 46); mark("다시 Shift+M(이 자리에 없음) → \(draft?.cues.filter { $0.kind == .memory }.count ?? 0)")
            let hotB = hotCue(slot: 1).map { String(format: "%.2f", $0.time) } ?? "없음"
            await shiftKey("@", 19); mark("Shift+2 → 핫큐 B 지움(전 \(hotB)) · 지금 \(hotCue(slot: 1).map { String(format: "%.2f", $0.time) } ?? "없음")")
            await key("8", 91); mark("숫자 패드 8 → 핫큐 H · 위치 \(String(format: "%.2f", playhead)) · H=\(hotCue(slot: 7).map { String(format: "%.2f", $0.time) } ?? "없음")")
            await key("q", 12); mark("Q 이전 큐 · 위치 \(String(format: "%.2f", playhead))")
            await key(" ", 49); mark("스페이스(재생 기대)")
            await key("e", 14); mark("재생 중 E · 위치 \(String(format: "%.2f", playhead))")
            await key("q", 12); mark("재생 중 Q · 위치 \(String(format: "%.2f", playhead))")
            await key(" ", 49); mark("스페이스(정지 기대)")
        }
    }

    private func selfTestStep(_ name: String, _ seconds: Double = 2.5, _ action: () -> Void) async {
        AudioDebug.log("── \(name)")
        action()
        let state = "   상태 재생=\(isPlaying) 위치=\(String(format: "%.2f", playhead)) 큐=\(String(format: "%.2f", cuePoint)) 미리듣기=\(isCuePreviewing)"
        AudioDebug.log(state)
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func refreshGrid() {
        if let gridDraft, gridDraft.hasChanges {
            grid = gridDraft.grid(duration: max(duration, Double(row?.track.lengthSeconds ?? 0)))
        } else {
            grid = originalGrid
        }
        updateGridBPM()
        refreshSuggestions()
    }

    private func refreshSuggestions() {
        guard showSuggestions, let analysis, let draft else {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        let raw = MemoryCueSuggester.suggestions(analysis, existing: draft.cues.map(\.time))
        suggestions = raw.map { grid?.snap($0) ?? $0 }
    }

    private func updateGridBPM() {
        guard let grid, !grid.beats.isEmpty else {
            if gridBPM != nil { gridBPM = nil }
            return
        }
        let index = grid.firstIndex(atOrAfter: playhead + 0.001)
        let bpm = index > 0 ? grid.beats[index - 1].bpm : grid.beats[0].bpm
        if bpm != gridBPM { gridBPM = bpm }
    }

    // MARK: - 재생

    func togglePlay() {
        guard canPlay else { return }
        AudioEvents.record("조작 재생/정지 · 재생 중=\(isPlaying) · 미리듣기=\(isCuePreviewing) · 위치 \(String(format: "%.2f", playhead))")
        if isCuePreviewing {
            if Self.isCueHeld {
                // CUE를 누른 채 재생을 누르면 손을 떼도 계속 재생한다(CDJ와 같다).
                isCuePreviewing = false
                return
            }
            // CUE를 뗀 신호를 놓쳐 미리 듣기 상태만 남은 경우: 평소처럼 재생/정지한다.
            AudioEvents.record("남아 있던 미리 듣기 상태를 풀었음")
            isCuePreviewing = false
        }
        if isPlaying {
            audio.pause()
            playhead = audio.position
            isPlaying = false
            ticker.stop()
        } else {
            if playhead >= duration - 0.05 { playhead = 0 }
            startPlayback(from: playhead)
        }
    }

    private func startPlayback(from time: Double) {
        if audio.play(from: time) {
            isPlaying = true
            ticker.start()
        } else {
            isPlaying = false
            ticker.stop()
            playhead = min(time, duration)
        }
    }

    /// 레벨 미터 다시 그리기 신호(재생 틱에 맞춰 초당 30번). 미터가 따로 타이머를 돌리면 창 갱신이 그만큼 더 생긴다.
    private(set) var meterFrame = 0
    @ObservationIgnored private var meterStamp: Double = 0

    private func tick() {
        guard isPlaying else { return }
        PerfProbe.tick()
        let now = ProcessInfo.processInfo.systemUptime
        if now - meterStamp >= 1.0 / 30 {
            meterStamp = now
            meterFrame &+= 1
        }
        // CUE를 뗀 신호(키·마우스)를 놓치면 미리 듣기가 끝나지 않는다. 실제로 누르고 있지 않으면 뗀 것으로 본다.
        if isCuePreviewing, !Self.isCueHeld {
            AudioEvents.record("CUE를 뗀 신호를 놓쳐 미리 듣기를 끝냄")
            cueUp()
            return
        }
        audio.recoverIfStalled()
        let previous = playhead
        playhead = audio.position
        if handleLoops(previous: previous) { return }
        updateGridBPM()
        audio.scheduleClicks(grid)
        if !audio.isPlaying || playhead >= duration - 0.01 {
            audio.stop()
            isPlaying = false
            isCuePreviewing = false
            ticker.stop()
            playhead = min(playhead, duration)
        }
    }

    // MARK: 루프 재생

    /// 지금 반복 중인 루프(큐 ID)
    private(set) var engagedLoopID: EditableCue.ID?

    /// 즉석 루프(큐에 저장하지 않은 루프). CDJ의 오토 비트 루프와 같다. 이 상태로 빈 핫큐 칸을 누르면 루프 핫큐로 저장된다.
    struct InstantLoop: Equatable {
        var start: Double
        var end: Double
        /// 박 수(루프 큐로 저장할 때 rekordbox BeatLoopSize로 적는다)
        var beats: Double?
    }

    private(set) var instantLoop: InstantLoop?

    /// 즉석 루프 길이(박). ½ · ×2로 바꾼다.
    private(set) var loopSize: Double = 4
    static let loopSizes: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16, 32]

    var loopSizeText: String { Self.beatsText(loopSize) }

    static func beatsText(_ beats: Double) -> String {
        switch beats {
        case 0.25: "¼"
        case 0.5: "½"
        default: String(Int(beats))
        }
    }

    /// 지금 반복 중인 구간(즉석 루프 또는 루프 큐)
    var engagedLoopRange: InstantLoop? {
        if let instantLoop { return instantLoop }
        guard let cue = cue(engagedLoopID), let loop = cue.loop else { return nil }
        return InstantLoop(start: cue.time, end: loop.end, beats: loop.beats)
    }

    var isLooping: Bool { engagedLoopRange != nil }

    /// 걸린 루프를 오디오에 알린다. 오디오가 곡을 메모리에 풀어 두었으면 샘플 단위로 이어 붙여 끊김 없이 되풀이한다.
    private func syncAudioLoop() {
        audio.setLoop(engagedLoopRange.map { $0.start...$0.end })
    }

    /// 재생 중 루프 처리. 반복으로 되돌렸으면 true.
    private func handleLoops(previous: Double) -> Bool {
        let cues = draft?.cues ?? []
        // 활성 루프: 재생이 그 시작을 지나가면 자동으로 건다.
        if engagedLoopID == nil, instantLoop == nil,
           let active = cues.first(where: { $0.loop?.active == true && previous < $0.time && playhead >= $0.time }) {
            engagedLoopID = active.id
        }
        if engagedLoopID != nil, cue(engagedLoopID)?.loop == nil { engagedLoopID = nil }
        syncAudioLoop()
        guard let range = engagedLoopRange else { return false }
        // 오디오가 샘플 단위로 되풀이하고 있으면 화면은 따라가기만 한다.
        if audio.handlesLoop { return false }
        // 곡을 아직 메모리에 풀지 못했으면(막 불러온 직후) 예전처럼 끝에서 되돌린다.
        if playhead >= range.end - 0.004 {
            startPlayback(from: range.start)
            playhead = range.start
            return true
        }
        return false
    }

    /// 루프에서 빠져나온다(재생 중이면 지금 바퀴 끝에서 그대로 이어 간다).
    func exitLoop() {
        engagedLoopID = nil
        instantLoop = nil
        syncAudioLoop()
    }

    /// LOOP 버튼·L: 반복 중이면 빠져나오고, 아니면 플레이헤드(퀀타이즈면 가까운 박)에서 `loopSize`박 루프를 건다.
    func toggleLoop() {
        if isLooping {
            exitLoop()
            return
        }
        guard canPlay else { return }
        let start = snapped(currentTime)
        guard let end = loopEnd(from: start, beats: loopSize) else { return }
        instantLoop = InstantLoop(start: start, end: end, beats: loopSize)
        syncAudioLoop()
    }

    /// 루프 길이를 반으로(-1) · 두 배로(+1). 반복 중이면 시작점은 두고 끝만 바꾼다(루프 큐는 그대로 두고 즉석 루프로 바뀐다).
    func resizeLoop(_ direction: Int) {
        let current = engagedLoopRange
        var size = loopSize
        if instantLoop == nil, let cue = cue(engagedLoopID) {
            if let beats = cue.loop?.beats { size = beats } else if let beats = loopBeats(cue), beats > 0 { size = Double(beats) }
        }
        guard let index = Self.loopSizes.firstIndex(where: { $0 >= size - 0.001 }) ?? Self.loopSizes.indices.last,
              Self.loopSizes.indices.contains(index + direction) else { return }
        let next = Self.loopSizes[index + direction]
        if let current {
            guard let end = loopEnd(from: current.start, beats: next) else { return }
            engagedLoopID = nil
            instantLoop = InstantLoop(start: current.start, end: end, beats: next)
            if playhead >= end {
                // 줄어든 루프 밖에 있으면 바로 시작점으로(새 루프로 다시 예약된다)
                audio.setLoop(current.start...end, reschedule: false)
                jump(to: current.start)
            } else {
                syncAudioLoop()
            }
        }
        loopSize = next
    }

    /// `start`에서 `beats`박 뒤. 그리드가 있으면 박에 맞추고(1박 이상), 1박 미만이면 그 자리 BPM으로 나눈다.
    private func loopEnd(from start: Double, beats: Double) -> Double? {
        let end: Double
        if let grid, !grid.beats.isEmpty, beats >= 1, beats == beats.rounded() {
            end = grid.nudge(start, beats: Int(beats))
        } else {
            let index = grid.map { max(0, $0.firstIndex(atOrAfter: start + 0.001) - 1) }
            let bpm = index.flatMap { grid?.beats.indices.contains($0) == true ? grid?.beats[$0].bpm : nil } ?? gridBPM ?? 120
            end = start + beats * 60 / max(bpm, 1)
        }
        guard end > start + 0.01, end <= duration + 0.01 else {
            showToast("곡 끝을 넘는 루프는 만들 수 없습니다")
            return nil
        }
        return end
    }

    /// 한 번의 이동(패드·목록 클릭 등). 재생 중이면 그 위치에서 다시 재생한다.
    func seek(_ time: Double) {
        // 루프 중에 다른 자리로 옮기면 루프에서 빠져나온다(루프 핫큐를 누른 경우는 부른 쪽이 다시 건다).
        if isLooping, abs(time - playhead) > 0.005 { exitLoop() }
        jump(to: time)
    }

    /// 루프 상태를 건드리지 않고 옮긴다(루프 길이를 줄여 끝 밖에 있게 됐을 때 등).
    private func jump(to time: Double) {
        isCuePreviewing = false
        playhead = min(max(time, 0), duration)
        updateGridBPM()
        if isPlaying {
            startPlayback(from: playhead)
        } else {
            audio.seekWhilePaused(playhead)
        }
    }

    /// 끌기 시작: 재생 중이면 소리를 멈추고, 놓을 때 한 번만 다시 재생한다.
    func beginScrub() {
        isCuePreviewing = false
        guard isPlaying else { return }
        resumeAfterScrub = true
        audio.pause()
        isPlaying = false
        ticker.stop()
    }

    func scrub(to time: Double) {
        if isLooping, abs(time - playhead) > 0.005 { exitLoop() }
        playhead = min(max(time, 0), duration)
        audio.seekWhilePaused(playhead)
        updateGridBPM()
    }

    func endScrub() {
        guard resumeAfterScrub else { return }
        resumeAfterScrub = false
        startPlayback(from: playhead)
    }

    /// 휠·트랙패드 가로 스크롤처럼 짧은 간격으로 이어지는 이동. 150ms 멈추면 그때 재생을 이어 간다.
    func scrubCoalesced(to time: Double) {
        if isPlaying { beginScrub() }
        scrub(to: time)
        guard resumeAfterScrub else { return }
        seekRestartTask?.cancel()
        seekRestartTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self.endScrub()
        }
    }

    private func stopPlayback() {
        ticker.stop()
        audio.stop()
        isPlaying = false
        isCuePreviewing = false
    }

    // MARK: - CUE (CDJ 방식)

    /// CUE를 누름.
    /// - 재생 중: 큐 지점으로 돌아가 멈춘다.
    /// - 멈춤 + 큐 지점이 아닌 곳: 그 자리를 새 큐 지점으로 정한다(퀀타이즈가 켜져 있으면 박에 맞춘다).
    /// - 멈춤 + 큐 지점: 누르고 있는 동안 재생한다. 떼면 큐 지점으로 돌아간다.
    func cueDown() {
        guard canPlay, !isCuePreviewing else { return }
        AudioEvents.record("조작 CUE 누름 · 재생 중=\(isPlaying) · 위치 \(String(format: "%.2f", playhead)) · 큐 \(String(format: "%.2f", cuePoint))")
        if isPlaying {
            returnToCue()
        } else if abs(playhead - cuePoint) > Self.cueTolerance {
            cuePoint = snapped(playhead)
            playhead = cuePoint
            audio.seekWhilePaused(cuePoint)
            updateGridBPM()
        } else {
            isCuePreviewing = true
            startPlayback(from: cuePoint)
            if !isPlaying { isCuePreviewing = false }
        }
    }

    /// CUE를 뗌: 미리 듣던 중이면 큐 지점으로 돌아가 멈춘다.
    func cueUp() {
        guard isCuePreviewing else { return }
        AudioEvents.record("조작 CUE 뗌(미리 듣기 끝)")
        isCuePreviewing = false
        if isPlaying { returnToCue() }
    }

    /// CUE를 지금 실제로 누르고 있는지(C 키 또는 마우스 왼쪽 버튼). 미리 듣기 상태가 남지 않게 확인한다.
    static var isCueHeld: Bool {
        CGEventSource.keyState(.combinedSessionState, key: 8) || (NSEvent.pressedMouseButtons & 1) != 0
    }

    /// 멈춘 채 큐 지점에 있는지(CUE 버튼 불빛).
    var isAtCue: Bool { !isPlaying && abs(playhead - cuePoint) <= Self.cueTolerance }

    private static let cueTolerance = 0.01

    private func returnToCue() {
        exitLoop()
        audio.pause()
        ticker.stop()
        isPlaying = false
        playhead = cuePoint
        audio.seekWhilePaused(cuePoint)
        updateGridBPM()
    }

    /// Q/E: 이전·다음 큐(메모리·핫큐)로 간다. 부른 큐는 CUE 지점이 된다(CDJ의 메모리 큐 호출과 같다).
    /// 재생 중이면 거기서 계속 재생하고, 멈춰 있으면 그 자리에서 대기한다(C로 바로 미리 듣기).
    func jumpToCue(forward: Bool) {
        guard canPlay, let cues = draft?.cues, !cues.isEmpty else { return }
        let times = cues.sorted { $0.time < $1.time }
        let target: EditableCue?
        if forward {
            target = times.first { $0.time > playhead + Self.cueTolerance }
        } else {
            // 재생 중에는 방금 부른 큐에서 0.25초 안이면 그 앞 큐로 간다(아니면 지금 구간의 시작으로).
            let slack = isPlaying ? 0.25 : Self.cueTolerance
            target = times.last { $0.time < playhead - slack }
        }
        guard let target else { return }
        selectedCueID = target.id
        cuePoint = target.time
        seek(target.time)
    }

    /// 선택한 큐를 박 단위로 민다. 선택이 없으면 false(키를 다른 곳에 넘긴다).
    func nudgeSelectedCue(beats: Int) -> Bool {
        guard let id = selectedCueID, cue(id) != nil else { return false }
        nudge(id, beats: beats)
        return true
    }

    func deleteSelectedCue() -> Bool {
        guard let id = selectedCueID, cue(id) != nil else { return false }
        delete(id)
        return true
    }

    // MARK: - 큐 편집 (초안만 바뀐다)

    func snapped(_ time: Double) -> Double {
        let clamped = min(max(time, 0), duration)
        return quantize ? (grid?.snap(clamped) ?? clamped) : clamped
    }

    func cue(_ id: EditableCue.ID?) -> EditableCue? {
        draft?.cues.first { $0.id == id }
    }

    func hotCue(slot: Int) -> EditableCue? {
        draft?.cues.first { $0.kind == .hot(slot) }
    }

    func addMemoryCue(at time: Double) {
        let target = snapped(time)
        // 같은 자리(±30ms)에 메모리 큐가 이미 있으면 새로 만들지 않고 그 큐를 고른다.
        if let existing = draft?.cues.first(where: { $0.kind == .memory && abs($0.time - target) <= 0.03 }) {
            selectedCueID = existing.id
            return
        }
        guard memoryCueCount < Self.memoryCueLimit else {
            showToast("메모리 큐는 곡당 \(Self.memoryCueLimit)개까지입니다(rekordbox 제한, 자동 큐 포함)")
            return
        }
        let cue = EditableCue(kind: .memory, time: target)
        mutate { $0.place(cue) }
        selectedCueID = cue.id
    }

    /// + 메모리 큐 · M: 즉석 루프 중이면 그 루프를 메모리 루프로 저장하고, 아니면 플레이헤드에 메모리 큐를 찍는다.
    func addMemoryCueAtPlayhead() {
        guard let loop = instantLoop else {
            addMemoryCue(at: currentTime)
            return
        }
        if let existing = draft?.cues.first(where: { $0.kind == .memory && abs($0.time - loop.start) <= 0.03 && $0.loop != nil }) {
            selectedCueID = existing.id
            return
        }
        guard memoryCueCount < Self.memoryCueLimit else {
            showToast("메모리 큐는 곡당 \(Self.memoryCueLimit)개까지입니다(rekordbox 제한, 자동 큐 포함)")
            return
        }
        var cue = EditableCue(kind: .memory, time: loop.start)
        cue.loop = EditableCue.Loop(end: loop.end, active: false, beats: loop.beats)
        mutate { $0.place(cue) }
        instantLoop = nil
        engagedLoopID = cue.id
        selectedCueID = cue.id
    }

    /// 재생 위치(±30ms, 퀀타이즈 위치 포함)에 있는 메모리 큐를 지운다. CDJ에서 메모리 큐를 불러온 자리에서 DELETE를 누르는 것과 같다.
    @discardableResult
    func deleteMemoryCue(at time: Double) -> Bool {
        let targets = [time, snapped(time)]
        let candidates = (draft?.cues ?? []).filter { cue in
            cue.kind == .memory && targets.contains { abs(cue.time - $0) <= 0.03 }
        }
        guard let cue = candidates.min(by: { abs($0.time - time) < abs($1.time - time) }) else { return false }
        delete(cue.id)
        return true
    }

    func pressHotCue(slot: Int) {
        if let cue = hotCue(slot: slot) {
            // 루프 핫큐: 누르면 그 루프를 반복하고, 반복 중에 다시 누르면 빠져나온다.
            if cue.loop != nil, engagedLoopID == cue.id {
                engagedLoopID = nil
                return
            }
            seek(cue.time)
            if cue.loop != nil { instantLoop = nil; engagedLoopID = cue.id; syncAudioLoop() }
            selectedCueID = cue.id
        } else if let loop = instantLoop {
            // 즉석 루프 중에 빈 칸을 누르면 그 루프를 루프 핫큐로 저장하고 계속 반복한다(CDJ와 같다).
            var cue = EditableCue(kind: .hot(slot), time: loop.start)
            cue.loop = EditableCue.Loop(end: loop.end, active: false, beats: loop.beats)
            mutate { $0.place(cue) }
            instantLoop = nil
            engagedLoopID = cue.id
            selectedCueID = cue.id
        } else {
            guard canPlay || grid != nil else { return }  // 소리·그리드 없이 0초에 박히지 않게
            let cue = EditableCue(kind: .hot(slot), time: snapped(currentTime))
            mutate { $0.place(cue) }
            selectedCueID = cue.id
        }
    }

    /// 그 칸의 핫큐를 지운다(초안만, 되돌리기 가능).
    func deleteHotCue(slot: Int) {
        guard let cue = hotCue(slot: slot) else { return }
        delete(cue.id)
    }

    func moveHotCueToPlayhead(slot: Int) {
        guard var cue = hotCue(slot: slot) else { return }
        cue.time = snapped(currentTime)
        mutate { $0.place(cue) }
    }

    func move(_ id: EditableCue.ID, to time: Double, save: Bool = true) {
        guard var cue = cue(id) else { return }
        let target = snapped(time)
        guard abs(target - cue.time) >= 0.0005 else { return }
        // 루프는 길이를 유지한 채 함께 옮긴다.
        if let length = cue.loopLength { cue.loop?.end = target + length }
        cue.time = target
        mutate(save: save) { $0.place(cue) }
    }

    func nudge(_ id: EditableCue.ID, beats: Int) {
        guard var cue = cue(id) else { return }
        let length = cue.loopLength
        cue.time = grid?.nudge(cue.time, beats: beats) ?? min(max(cue.time + Double(beats) * 0.5, 0), duration)
        if let length { cue.loop?.end = cue.time + length }
        mutate { $0.place(cue) }
    }

    // MARK: 루프

    /// 큐를 박 수만큼의 루프로 만든다(nil이면 루프를 없앤다). 그리드가 있으면 박에 맞춘다.
    func setLoop(_ id: EditableCue.ID, beats: Int?) {
        guard var cue = cue(id) else { return }
        if let beats {
            let end: Double
            if let grid, !grid.beats.isEmpty {
                end = grid.nudge(cue.time, beats: beats)
            } else {
                let bpm = gridBPM ?? 120
                end = cue.time + Double(beats) * 60 / bpm
            }
            guard end > cue.time + 0.01, end <= duration + 0.01 else { showToast("곡 끝을 넘는 루프는 만들 수 없습니다"); return }
            cue.loop = EditableCue.Loop(end: end, active: cue.loop?.active ?? false, beats: Double(beats))
        } else {
            cue.loop = nil
        }
        mutate { $0.place(cue) }
    }

    /// 활성 루프 켜기·끄기(곡을 불러오면 그 루프를 자동으로 반복한다)
    func toggleActiveLoop(_ id: EditableCue.ID) {
        guard var cue = cue(id), cue.loop != nil else { return }
        let turningOn = !(cue.loop?.active ?? false)
        cue.loop?.active = turningOn
        mutate { draft in
            // 활성 루프는 곡에 하나만 둔다.
            if turningOn {
                for i in draft.cues.indices where draft.cues[i].id != cue.id && draft.cues[i].loop?.active == true {
                    draft.cues[i].loop?.active = false
                }
            }
            draft.place(cue)
        }
    }

    /// 루프 박 수(그리드 기준, 대략)
    func loopBeats(_ cue: EditableCue) -> Int? {
        guard let loop = cue.loop else { return nil }
        if let grid, !grid.beats.isEmpty {
            let a = grid.firstIndex(atOrAfter: cue.time - 0.005), b = grid.firstIndex(atOrAfter: loop.end - 0.005)
            return max(b - a, 0)
        }
        return gridBPM.map { Int(((loop.end - cue.time) * $0 / 60).rounded()) }
    }

    func setKind(_ id: EditableCue.ID, _ kind: EditableCue.Kind) {
        guard var cue = cue(id) else { return }
        cue.kind = kind
        mutate { $0.place(cue) }
    }

    func rename(_ id: EditableCue.ID, _ name: String) {
        guard var cue = cue(id) else { return }
        cue.name = name
        mutate { $0.place(cue) }
    }

    func delete(_ id: EditableCue.ID) {
        mutate { $0.remove(id) }
        if selectedCueID == id { selectedCueID = nil }
    }

    func acceptSuggestion(_ time: Double) {
        addMemoryCue(at: time)
    }

    func revertDraft() {
        mutate { $0.revert() }
        selectedCueID = nil
    }

    func commitDraft() {
        if !isWriteLocked, let draft { persist(draft) }
    }

    private func mutate(save: Bool = true, _ change: (inout CueDraft) -> Void) {
        guard !isWriteLocked, var draft, draft.trackUUID == row?.track.uuid else { return }
        change(&draft)
        self.draft = draft
        refreshSuggestions()
        if save { persist(draft) }
    }

    private func persist(_ draft: CueDraft) {
        DraftWriter.save(draft)
        onCueDraftChange?(draft)
        onDraftChange?(draft.trackUUID, .cue, draft.hasChanges)
    }

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
        cueDragBase = carryHotCues ? draft?.cues : nil
    }

    func dragGrid(by seconds: Double) {
        guard var base = gridDragBase, base.trackUUID == row?.track.uuid else { return }
        let from = base.segments
        base.shift(by: seconds)
        gridDraft = base
        if let cues = cueDragBase { moveHotCuesWithGrid(cues, from: from, to: base.segments, save: false) }
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

    /// 그리드가 `from` → `to`로 바뀐 만큼 핫큐(루프 끝 포함)를 따라 옮긴다. 메모리 큐는 그대로 둔다.
    private func moveHotCuesWithGrid(_ cues: [EditableCue]? = nil, from: [GridSegment], to: [GridSegment], save: Bool = true) {
        guard carryHotCues, from != to, let current = draft else { return }
        let source = cues ?? current.cues
        let length = max(duration, Double(row?.track.lengthSeconds ?? 0))
        func carried(_ time: Double) -> Double { min(max(GridDraft.carry(time, from: from, to: to, duration: length), 0), length) }
        let moved: [EditableCue] = source.compactMap { cue in
            guard case .hot = cue.kind else { return nil }
            var copy = cue
            copy.time = carried(cue.time)
            if let end = cue.loop?.end { copy.loop?.end = max(carried(end), copy.time + 0.01) }
            // 지금 초안 값과 같으면 건드리지 않는다.
            guard let now = current.cues.first(where: { $0.id == cue.id }),
                  abs(now.time - copy.time) >= 0.0005 || abs((now.loop?.end ?? 0) - (copy.loop?.end ?? 0)) >= 0.0005 else { return nil }
            return copy
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

    private func mutateGrid(_ change: (inout GridDraft) -> Void) {
        guard canEditGrid, var gridDraft, gridDraft.trackUUID == row?.track.uuid else { return }
        let before = gridDraft.segments
        change(&gridDraft)
        self.gridDraft = gridDraft
        moveHotCuesWithGrid(from: before, to: gridDraft.segments)
        refreshGrid()
        DraftWriter.save(gridDraft)
        onDraftChange?(gridDraft.trackUUID, .grid, gridDraft.hasChanges)
        if row?.isStaged == true { onStagedGridChange?(gridDraft.trackUUID, gridDraft.segments.first?.bpm) }
        audio.resetClicks()
        refreshSuggestionNote()
    }

    // MARK: - 그리드 추정·제안

    /// MU 분석 결과와 어택 곡선으로 그리드를 추정한다. 추가한 곡(아직 rekordbox에 없음)은 그리드가 없으면 바로 적용한다.
    private func startGridSuggestion(analysis: PartAnalysis, url: URL, id: String) {
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
        var dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedSuggestionsKey) ?? [])
        dismissed.remove(uuid)
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedSuggestionsKey)
        reload()
        showToast("다시 분석합니다")
    }

    /// 무시한 제안을 다시 보인다.
    func restoreGridSuggestion() {
        guard let uuid = row?.track.uuid else { return }
        var dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedSuggestionsKey) ?? [])
        dismissed.remove(uuid)
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedSuggestionsKey)
        refreshSuggestionNote()
    }

    /// 이 곡의 그리드 제안을 더는 보이지 않게 한다(곡마다 기억).
    func dismissGridSuggestion() {
        guard let uuid = row?.track.uuid else { return }
        var dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedSuggestionsKey) ?? [])
        dismissed.insert(uuid)
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedSuggestionsKey)
        dismissedRevision += 1
    }

    /// 무시 표시가 바뀌면 화면을 다시 그리게 한다.
    private(set) var dismissedRevision = 0

    static let dismissedSuggestionsKey = "deck.dismissedGridSuggestions"

    var isGridSuggestionDismissed: Bool {
        guard let uuid = row?.track.uuid else { return false }
        return (UserDefaults.standard.stringArray(forKey: Self.dismissedSuggestionsKey) ?? []).contains(uuid)
    }

    // MARK: 알림(잠깐 떴다 사라진다)

    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// rekordbox는 곡당 메모리 큐를 10개까지 둔다(라이브러리 7천 곡 중 최대가 정확히 10개, 자동 큐 포함).
    static let memoryCueLimit = 10

    /// 이 곡의 메모리 큐 수(초안 + 초안에서 빼 둔 rekordbox 자동 큐)
    var memoryCueCount: Int {
        let draftMemory = draft?.cues.filter { $0.kind == .memory }.count ?? 0
        let auto = row?.cues.filter { $0.isMemoryCue && $0.isAutoGenerated }.count ?? 0
        return draftMemory + auto
    }

    /// 추정 그리드를 초안으로 적용한다(원본이 있으면 원본은 그대로 두고 구간만 바꾼다).
    func applyGridSuggestion() {
        guard let suggestion = gridSuggestion, let uuid = row?.track.uuid else { return }
        let base = gridDraft?.base ?? []
        let before = gridDraft?.segments ?? originalGrid.map(GridDraft.segments(from:)) ?? []
        let draft = GridDraft(trackUUID: uuid, base: base, segments: suggestion.segments)
        gridDraft = draft
        moveHotCuesWithGrid(from: before, to: draft.segments)
        // 복잡한 원본이라 막아 둔 곡도, 추정 그리드로 바꾸면 편집할 수 있다.
        gridEditBlockedReason = nil
        refreshGrid()
        DraftWriter.save(draft)
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
        guard row?.track.uuid == uuid, gridDraft == nil, let saved = GridDraftStore.load(trackUUID: uuid) else { return }
        gridDraft = saved
        refreshGrid()
        refreshSuggestionNote()
    }

    /// 추정과 현재 그리드의 차이를 한 줄로(없거나 작으면 nil).
    private func refreshSuggestionNote() {
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

/// 덱에 올릴 곡의 무거운 부분(초안·그리드·아트워크). 백그라운드에서 만든다.
struct DeckPayload: Sendable {
    var draft: CueDraft
    var originalGrid: BeatGrid?
    var gridDraft: GridDraft?
    var gridBlockedReason: String?
    var artwork: Thumbnails.Box?

    static func load(track: Track, cues: [Cue], duration: Double) -> DeckPayload {
        // 덱의 시각은 모두 rekordbox 시간축이다(초안·rekordbox 큐·그리드를 그대로 쓴다).
        let draft = CueDraftStore.load(trackUUID: track.uuid) ?? CueDraft(trackUUID: track.uuid, rekordboxCues: cues)
        var payload = DeckPayload(draft: draft)
        payload.artwork = ArtworkCache.downsampled(imagePath: track.imagePath, maxPixels: 360)

        guard let url = RekordboxShare.analysisURL(track.analysisDataPath),
              let rekordboxGrid = try? BeatGrid.load(anlz: url), !rekordboxGrid.beats.isEmpty
        else {
            // 그리드가 없는 곡: 앞서 적용해 둔 추정 그리드 초안이 있으면 그것을 쓴다.
            payload.gridDraft = GridDraftStore.load(trackUUID: track.uuid)
            return payload
        }
        let original = rekordboxGrid
        payload.originalGrid = original
        let fresh = GridDraft(trackUUID: track.uuid, grid: original)
        // 재생성 오차 확인: 편집하지 않은 상태에서 2ms 넘게 다르면 편집을 막는다.
        let rebuilt = fresh.grid(duration: max(duration + 1, original.beats.last!.time + 0.01))
        let worst = original.beats.map { abs(rebuilt.snap($0.time) - $0.time) }.max() ?? 0
        if worst > 0.002 {
            payload.gridBlockedReason = String(format: "이 곡의 그리드는 템포 구간 %d개로 복잡해 정확히 재현되지 않습니다(최대 %.0fms). 편집을 막았습니다.",
                                               fresh.segments.count, worst * 1000)
        }
        payload.gridDraft = GridDraftStore.load(trackUUID: track.uuid) ?? fresh
        return payload
    }
}

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

/// rekordbox가 만들어 둔 아트워크(`share/PIONEER/Artwork`)를 우선 쓰고, 없으면 파일 내장 이미지를 읽는다.
enum ArtworkCache {
    /// 덱 커버: 전체 크기 JPEG를 그대로 쓰지 않고 작게 디코딩한다(메모리·메인 스레드 절약).
    nonisolated static func downsampled(imagePath: String?, maxPixels: Int) -> Thumbnails.Box? {
        for size in [RekordboxShare.ArtworkSize.full, .medium] {
            guard let url = RekordboxShare.artworkURL(imagePath, size: size),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  ] as CFDictionary)
            else { continue }
            return Thumbnails.Box(image: image)
        }
        return nil
    }

    static func embeddedArtwork(url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first,
              let data = try? await item.load(.dataValue)
        else { return nil }
        return NSImage(data: data)
    }
}

/// 목록 썸네일: 메인 스레드 밖에서 작게 디코딩해 캐시한다. 스크롤로 지나친 요청은 건너뛴다.
actor Thumbnails {
    static let shared = Thumbnails()

    struct Box: @unchecked Sendable { let image: CGImage }
    private final class Entry { let box: Box?; init(_ box: Box?) { self.box = box } }
    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 3000
        return cache
    }()

    func image(imagePath: String?, key: String) -> Box? {
        if let hit = cache.object(forKey: key as NSString) { return hit.box }
        guard !Task.isCancelled else { return nil }
        var box: Box?
        if let url = RekordboxShare.artworkURL(imagePath, size: .small),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 64,
           ] as CFDictionary) {
            box = Box(image: image)
        }
        // 아트워크가 없는 곡도 기억해 파일을 다시 열지 않는다.
        cache.setObject(Entry(box), forKey: key as NSString)
        return box
    }
}

/// 덱 설정(볼륨·키 락·퀀타이즈·제안 표시·확대 배율)을 앱을 다시 켜도 유지한다.
/// 개발용 자가 테스트(음량을 −70dB로 바꾼다)는 저장하지 않는다.
enum DeckSettings {
    private static let persist = !ProcessInfo.processInfo.arguments.contains { $0.hasSuffix("-selftest") || $0 == "--autoplay" }
    private static func key(_ name: String) -> String { "deck.\(name)" }

    static func double(_ name: String, _ fallback: Double) -> Double {
        guard persist, let value = UserDefaults.standard.object(forKey: key(name)) as? Double, value.isFinite else { return fallback }
        return value
    }

    static func bool(_ name: String, _ fallback: Bool) -> Bool {
        guard persist, let value = UserDefaults.standard.object(forKey: key(name)) as? Bool else { return fallback }
        return value
    }

    static func set(_ name: String, _ value: Any) {
        guard persist else { return }
        UserDefaults.standard.set(value, forKey: key(name))
    }
}
