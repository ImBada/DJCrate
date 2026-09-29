import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import Observation
import Foundation
import RekordboxKit

/// 위쪽 덱: 선택한 곡의 파형·그리드·분석·재생·큐/그리드 초안.
@MainActor
@Observable
final class DeckModel {
    enum DraftKind { case cue, grid, gain }

    @ObservationIgnored weak var undoManager: UndoManager? {
        didSet { if oldValue !== undoManager { oldValue?.removeAllActions(withTarget: self) } }
    }
    @ObservationIgnored var pendingDraftUndo: DeckDraftSnapshot?

    var row: TrackRow?
    var waveform: Waveform? { didSet { refreshColorWaveform() } }
    var colorWaveform: ColorWaveformRaster?
    @ObservationIgnored var colorWaveformTask: Task<Void, Never>?
    var waveformColorMode = WaveformColorMode.threeBand {
        didSet {
            guard waveformColorMode != oldValue else { return }
            storage.settings.set(SettingKeys.waveformColorMode, waveformColorMode.rawValue)
            refreshColorWaveform()
        }
    }
    var waveformError: String?
    var analysis: PartAnalysis?
    var analysisError: String?
    /// 섹션(MU) 분석이 끝나기를 기다리는 중(섹션 칸에 로딩 막대)
    var isAnalyzingSections = false
    var artwork: NSImage?
    var draft: CueDraft?
    var hasUncommittedCueEdits = false
    var selectedCueID: EditableCue.ID?
    var playhead: Double = 0 {
        didSet { updateDisplayTime() }
    }
    var isPlaying = false {
        didSet { if !isPlaying, displayTime != playhead { displayTime = playhead } }
    }
    var zoomSeconds: Double = 16 { didSet { storage.settings.set(SettingKeys.zoomSeconds, zoomSeconds) } }
    /// CDJ식 메인 CUE 지점. 곡을 불러오면 첫 메모리 큐(없으면 0초)에 놓인다. 초안·rekordbox에는 쓰지 않는다.
    var cuePoint: Double = 0
    /// CUE를 누르고 있는 동안의 미리 듣기.
    var isCuePreviewing = false
    var placeAtFirstMemoryCue = false
    /// 큐·루프 등록도 Q와 같은 상태를 읽는다. 기존 편집 호출부는 이 이름을 유지한다.
    var quantize: Bool {
        get { playQuantize }
        set { playQuantize = newValue }
    }
    /// Q 하나로 큐·루프 등록 스냅과 재생 중 핫큐 점프 퀀타이즈를 함께 켠다.
    var playQuantize = true {
        didSet {
            storage.settings.set(SettingKeys.playQuantize, playQuantize)
            storage.settings.set(SettingKeys.quantize, playQuantize)
        }
    }
    /// 이전 박 간격 저장값의 호환용. 재생 경계는 이 값과 관계없이 다음 한 박이다.
    var playQuantizeBeats = PlayQuantize.defaultBeats {
        didSet { storage.settings.set(SettingKeys.playQuantizeBeats, playQuantizeBeats) }
    }
    /// 오디오가 샘플 단위로 예약하지 못한 점프(곡을 메모리에 풀기 전). 화면 틱이 경계를 지나면 넘긴다.
    var pendingJump: PendingJump?
    /// 오디오가 경계에서 넘길 점프. 화면 틱이 넘어간 순간을 알아본다(건너뛴 구간을 지나간 것으로 보지 않게).
    @ObservationIgnored var scheduledJump: PlayQuantize.Jump?
    /// 경계 전에 일시정지하면 아직 도착하지 않은 루프 상태도 함께 취소한다.
    @ObservationIgnored var scheduledJumpSourceLoop: (instant: InstantLoop?, cueID: EditableCue.ID?)?
    /// 그리드를 고칠 때 큐(핫큐·메모리 큐·루프)도 같은 박을 따라 옮긴다.
    var carryCues = true { didSet { storage.settings.set(SettingKeys.carryCues, carryCues) } }
    var showSuggestions = true {
        didSet { storage.settings.set(SettingKeys.showSuggestions, showSuggestions); refreshSuggestions() }
    }

    // 재생 설정
    var volume: Double = 0.9 {
        didSet {
            audio.volume = Float(volume)
            guard volume != oldValue else { return }
            storage.settings.set(SettingKeys.volume, volume)
        }
    }
    @ObservationIgnored private var lastVolumePreviewTime: Double = 0
    /// 슬라이더를 끄는 동안에는 소리에만 바로 반영하고 저장은 손을 놓을 때 한다.
    func previewVolume(_ value: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastVolumePreviewTime >= 1.0 / 30 else { return }
        lastVolumePreviewTime = now
        audio.volume = Float(value)
    }
    var metronome = false { didSet { audio.metronome = metronome } }
    /// 메트로놈 소리 크기(0~1). 설정 창 컨트롤이 같은 값을 다시 넣을 때는 저장하지 않는다.
    var metronomeVolume = SettingKeys.metronomeVolume.defaultValue {
        didSet {
            guard metronomeVolume != oldValue else { return }
            audio.metronomeVolume = Float(metronomeVolume)
            storage.settings.set(SettingKeys.metronomeVolume, metronomeVolume)
        }
    }
    /// 재생을 멈춘 뒤 오디오 엔진을 끄기까지(초)
    var idleSeconds = SettingKeys.idleSeconds.defaultValue {
        didSet {
            guard idleSeconds != oldValue else { return }
            audio.idleSeconds = idleSeconds
            storage.settings.set(SettingKeys.idleSeconds, idleSeconds)
        }
    }
    /// 덱 단축키(키 위치 → 동작). 설정 창에서 바꾸고 KeyRouter가 읽는다.
    var shortcuts = DeckShortcuts.standard { didSet { storage.settings.shortcuts = shortcuts } }
    /// 재생 속도(%). rekordbox 템포 슬라이더와 같은 의미.
    var tempoPercent: Double = 0 { didSet { audio.rate = 1 + tempoPercent / 100 } }
    var keyLock = true { didSet { audio.keyLock = keyLock; storage.settings.set(SettingKeys.keyLock, keyLock) } }

    // MARK: 상태(역할별 파일에서 쓰는 저장값)

    /// 곡마다 통합 음량을 목표에 맞춘다.
    var autoGain = true { didSet { storage.settings.set(SettingKeys.autoGain, autoGain); applyGain() } }

    /// 오토게인 목표(LUFS)
    var gainTarget: Double = -10 { didSet { storage.settings.set(SettingKeys.gainTarget, gainTarget); applyGain() } }

    /// 피크가 0dBFS를 넘지 않을 만큼만 올린다.
    var peakProtection = true {
        didSet { storage.settings.set(SettingKeys.peakProtection, peakProtection); applyGain() }
    }

    /// 수동 트림(dB). 오토게인 위에 더한다.
    var gainTrim: Double = 0 { didSet { storage.settings.set(SettingKeys.gainTrim, gainTrim); applyGain() } }

    /// 지금 곡의 음량(메모리 디코딩 뒤 측정, 다음부터는 캐시)
    var loudness: Loudness?

    /// rekordbox 오토게인을 그대로 쓴다(없으면 DJCrate 측정으로 계산).
    var useRekordboxGain = true {
        didSet { storage.settings.set(SettingKeys.useRekordboxGain, useRekordboxGain); applyGain() }
    }

    /// 이 곡의 오토게인 초안(dB). rekordbox에 반영하면 rekordbox 오토게인이 이 값이 된다.
    var gainDraft: Double?

    var dismissedGainSuggestions: Set<String> = [] {
        didSet { storage.settings.setStrings(SettingKeys.dismissedGainSuggestions, dismissedGainSuggestions) }
    }

    /// 곡 안의 조표 구간(rekordbox 시간축). 주 조표는 rekordbox 키에 맞춘다.
    var keySegments: [KeyAnalyzer.Segment] = []

    /// 장·단(A/B)은 rekordbox 키를 따른다(없으면 크로마로 정한다).
    var keyMinor = false

    @ObservationIgnored var keyChroma: KeyAnalyzer.Chroma?

    /// 레벨 미터 다시 그리기 신호(재생 틱에 맞춰 초당 30번). 미터가 따로 타이머를 돌리면 창 갱신이 그만큼 더 생긴다.
    var meterFrame = 0

    @ObservationIgnored var meterStamp: Double = 0

    /// 지금 반복 중인 루프(큐 ID)
    var engagedLoopID: EditableCue.ID?

    var instantLoop: InstantLoop?

    /// 즉석 루프 길이(박). ½ · ×2로 바꾼다.
    var loopSize: Double = 4

    /// 무시 표시가 바뀌면 화면을 다시 그리게 한다.
    var dismissedRevision = 0

    var toast: AppMessage?
    @ObservationIgnored var feedback = AppFeedback()

    @ObservationIgnored var toastTask: Task<Void, Never>?

    // 그리드
    var originalGrid: BeatGrid?
    var gridDraft: GridDraft?
    /// 화면·스냅·메트로놈이 쓰는 그리드. 편집하지 않았으면 rekordbox 원본 그대로다.
    var grid: BeatGrid? { didSet { if grid?.downbeats != oldValue?.downbeats { refreshKeySegments() } } }
    var gridEditing = false
    /// rekordbox에 쓰는 동안 큐 편집을 막는다(쓰는 초안과 덱 초안이 어긋나지 않게).
    /// rekordbox에 쓰는 동안: 재생을 잠시 멈추고(끝나면 이어서) 편집을 막는다.
    var isWriteLocked = false {
        didSet {
            guard isWriteLocked != oldValue else { return }
            if isWriteLocked {
                clearDraftUndo()
                resumeAfterWrite = isPlaying
                if isPlaying { togglePlay() }
            } else if resumeAfterWrite {
                resumeAfterWrite = false
                if canPlay, !isPlaying { togglePlay() }
            }
        }
    }
    var resumeAfterWrite = false
    var softReloadTask: Task<Void, Never>?
    /// 편집 전 재생성 오차가 크면(다이내믹 그리드 등) 그리드 편집을 막는다.
    var gridEditBlockedReason: String?
    /// rekordbox 비트 그리드가 있는 곡인지(없으면 추정 그리드를 권한다)
    var hasRekordboxGrid = false
    /// rekordbox 시간축 − 음원(AVFoundation) 시간축(초). 덱은 rekordbox 시간축을 쓰고,
    /// 음원 재생·파형·MU 분석만 이만큼 밀어 맞춘다(압축 음원의 인코더 지연을 rekordbox처럼 남긴다).
    var timelineOffset: Double = 0
    /// DJCrate가 추정한 그리드(DJCrate 시간축)와 현재 그리드와의 차이 설명
    var gridSuggestion: GridEstimator.Estimate?
    var gridSuggestionNote: String?
    /// 그리드가 없는 곡에서 파형 위에 미리 보여 줄 추정 박(적용 전)
    var suggestedGrid: BeatGrid?
    var suggestionTask: Task<Void, Never>?
    /// 추가한 곡의 그리드가 바뀌면 목록 BPM을 맞춘다.
    var onStagedGridChange: ((String, Double?) -> Void)?
    /// 큐 초안이 바뀔 때(목록의 핫큐·메모리 숫자용)
    var onCueDraftChange: ((CueDraft) -> Void)?
    var tapBPM: Double?
    var taps: [Double] = []
    var gridDragBase: GridDraft?
    /// 그리드를 끄는 동안 핫큐의 출발 위치(끄는 동안 오차가 쌓이지 않게 늘 여기서 옮긴다)
    var cueDragBase: [EditableCue]?
    var lastClickReset: Double = 0

    /// 초안 존재 여부가 바뀌면 알린다(목록의 편집 표시용). 디스크를 다시 읽지 않도록 상태를 함께 넘긴다.
    var onDraftChange: ((String, DraftKind, Bool) -> Void)?

    /// 곡 길이와 재생 가능 여부는 관찰되는 저장값이다(오디오 엔진 값은 관찰되지 않는다).
    var duration: Double = 0
    var canPlay = false
    var currentTime: Double { playhead }
    /// 글자·전체 파형용 재생 위치. 재생 중에는 초당 15번만 바뀐다(멈춰 있을 땐 바로 따라간다).
    var displayTime: Double = 0
    @ObservationIgnored var displayTimeStamp: Double = 0

    func updateDisplayTime() {
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
    var gridBPM: Double?

    /// 메모리 큐 제안과 섹션 에너지는 분석·큐·그리드가 바뀔 때만 다시 계산한다.
    var suggestions: [Double] = []
    var sectionEnergies: [PartLabeler.SectionEnergy] = []

    let audio: any DeckAudioEngine
    let storage: DeckStorage
    /// 곡을 올린 뒤 파형·음악 분석·그리드 추정을 돌릴지(시험에서는 끈다: 캐시 폴더에 쓰지 않게)
    let runsAnalysis: Bool
    @ObservationIgnored lazy var ticker = DisplayTicker { [weak self] in self?.tick() }
    var loadTask: Task<Void, Never>?
    var waveformTask: Task<Waveform, Error>?
    var resumeAfterScrub = false
    /// 확대 파형을 끄는 동안의 기준점(놓으면 nil). 끄는 도중 핫큐로 옮기면 기준도 옮긴다(#133).
    @ObservationIgnored var scrubAnchor: ScrubAnchor?
    var seekRestartTask: Task<Void, Never>?

    init(audio: any DeckAudioEngine = DeckAudio(), storage: DeckStorage = .live, runsAnalysis: Bool = true) {
        self.audio = audio
        self.storage = storage
        self.runsAnalysis = runsAnalysis
        // 설정은 저장소에서 읽는다.
        let settings = storage.settings
        zoomSeconds = settings.value(SettingKeys.zoomSeconds)
        waveformColorMode = WaveformColorMode(rawValue: settings.value(SettingKeys.waveformColorMode)) ?? .threeBand
        // 관찰 프로퍼티의 setter를 거치지 않아 초기화 때 기존 두 저장값을 덮어쓰지 않는다.
        _playQuantize = settings.quantize
        playQuantizeBeats = settings.value(SettingKeys.playQuantizeBeats)
        carryCues = settings.value(SettingKeys.carryCues)
        showSuggestions = settings.value(SettingKeys.showSuggestions)
        volume = settings.value(SettingKeys.volume)
        keyLock = settings.value(SettingKeys.keyLock)
        metronomeVolume = settings.value(SettingKeys.metronomeVolume)
        idleSeconds = settings.value(SettingKeys.idleSeconds)
        shortcuts = settings.shortcuts
        autoGain = settings.value(SettingKeys.autoGain)
        gainTarget = settings.value(SettingKeys.gainTarget)
        peakProtection = settings.value(SettingKeys.peakProtection)
        gainTrim = settings.value(SettingKeys.gainTrim)
        useRekordboxGain = settings.value(SettingKeys.useRekordboxGain)
        dismissedGainSuggestions = settings.strings(SettingKeys.dismissedGainSuggestions)
        audio.volume = Float(volume)
        audio.keyLock = keyLock
        audio.metronomeVolume = Float(metronomeVolume)
        audio.idleSeconds = idleSeconds
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
    func softReload(_ newRow: TrackRow) {
        clearDraftUndo()
        row = newRow
        gainDraft = storage.loadGain(newRow.track.uuid)
        applyGain()
        let selected = cue(selectedCueID), engaged = cue(engagedLoopID)
        let track = newRow.track, cues = newRow.cues, id = newRow.id, length = duration, storage = storage
        softReloadTask?.cancel()
        softReloadTask = Task {
            let payload = await Task.detached(priority: .userInitiated) {
                DeckPayload.load(track: track, cues: cues, duration: length, storage: storage)
            }.value
            guard !Task.isCancelled, self.row?.id == id else { return }
            self.clearDraftUndo()
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
        clearDraftUndo()
        hasUncommittedCueEdits = false
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
        gridDragBase = nil; tapBPM = nil; taps = []; resumeAfterScrub = false; scrubAnchor = nil; isCuePreviewing = false
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
            gainDraft = storage.loadGain(row.track.uuid)
            applyGain()
            canPlay = audio.isLoaded
            if canPlay { duration = audio.duration }
            if let cachedChroma {
                keyChroma = cachedChroma
                refreshKeySegments()
            }
            if !canPlay { waveformError = String(ui: "이 파일 형식은 재생·파형을 지원하지 않습니다.") }
        } else if !row.track.isStreaming {
            waveformError = String(ui: "파일을 찾을 수 없습니다. 외장 드라이브가 연결됐는지 확인하세요.")
        }
        playhead = min(playhead, duration)

        let track = row.track, cues = row.cues, id = row.id, key = track.uuid, length = duration, storage = storage
        loadTask = Task {
            // 1) 초안·그리드·아트워크는 백그라운드에서 읽고, 아직 이 곡일 때만 적용한다.
            let payload = await Task.detached(priority: .userInitiated) {
                DeckPayload.load(track: track, cues: cues, duration: length, storage: storage)
            }.value
            guard !Task.isCancelled, self.row?.id == id else { return }
            self.apply(payload)
            if self.artwork == nil, exists, self.runsAnalysis {
                let embedded = await ArtworkCache.embeddedArtwork(url: url)
                guard !Task.isCancelled, self.row?.id == id, self.artwork == nil else { return }
                self.artwork = embedded
            }

            // 2) 파형: 곡을 넘기면 바로 취소된다(조각 단위로 취소를 확인한다).
            guard self.canPlay, self.runsAnalysis else { self.isAnalyzingSections = false; return }
            let job = Task.detached(priority: .userInitiated) { try WaveformCache.load(fileAt: url, key: key) }
            self.waveformTask = job
            do {
                let waveform = try await job.value
                guard !Task.isCancelled, self.row?.id == id else { return }
                self.waveform = waveform
            } catch {
                guard !Task.isCancelled, self.row?.id == id else { return }
                self.waveformError = String(ui: "파형을 만들지 못했습니다: \(error.localizedDescription)")
            }
            #if DEBUG
            self.applyLaunchFlags()
            #endif

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

    func apply(_ payload: DeckPayload) {
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

    func refreshGrid() {
        if let gridDraft, gridDraft.hasChanges {
            grid = gridDraft.grid(duration: max(duration, Double(row?.track.lengthSeconds ?? 0)))
        } else {
            grid = originalGrid
        }
        updateGridBPM()
        refreshSuggestions()
    }

    func refreshSuggestions() {
        guard showSuggestions, let analysis, let draft else {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        let raw = MemoryCueSuggester.suggestions(analysis, existing: draft.cues.map(\.time))
        suggestions = raw.map { grid?.snap($0) ?? $0 }
    }

    func updateGridBPM() {
        guard let grid, !grid.beats.isEmpty else {
            if gridBPM != nil { gridBPM = nil }
            return
        }
        let index = grid.firstIndex(atOrAfter: playhead + 0.001)
        let bpm = index > 0 ? grid.beats[index - 1].bpm : grid.beats[0].bpm
        if bpm != gridBPM { gridBPM = bpm }
    }

}
