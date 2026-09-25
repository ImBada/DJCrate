import AnicueCore
import AppKit
import AVFoundation
import ImageIO
import Observation

/// 위쪽 덱: 선택한 곡의 파형·그리드·분석·재생·큐/그리드 초안.
@MainActor
@Observable
final class DeckModel {
    enum DraftKind { case cue, grid }

    private(set) var row: TrackRow?
    private(set) var waveform: Waveform?
    private(set) var waveformError: String?
    private(set) var analysis: PartAnalysis?
    private(set) var analysisError: String?
    private(set) var artwork: NSImage?
    private(set) var draft: CueDraft?
    var selectedCueID: EditableCue.ID?
    private(set) var playhead: Double = 0
    private(set) var isPlaying = false
    var zoomSeconds: Double = 16
    var quantize = true
    var showSuggestions = true { didSet { refreshSuggestions() } }

    // 재생 설정
    var volume: Double = 0.9 { didSet { audio.volume = Float(volume) } }
    var metronome = false { didSet { audio.metronome = metronome } }
    /// 재생 속도(%). rekordbox 템포 슬라이더와 같은 의미.
    var tempoPercent: Double = 0 { didSet { audio.rate = 1 + tempoPercent / 100 } }
    var keyLock = true { didSet { audio.keyLock = keyLock } }

    // 그리드
    private(set) var originalGrid: BeatGrid?
    private(set) var gridDraft: GridDraft?
    /// 화면·스냅·메트로놈이 쓰는 그리드. 편집하지 않았으면 rekordbox 원본 그대로다.
    private(set) var grid: BeatGrid?
    var gridEditing = false
    /// 편집 전 재생성 오차가 크면(다이내믹 그리드 등) 그리드 편집을 막는다.
    private(set) var gridEditBlockedReason: String?
    private(set) var tapBPM: Double?
    private var taps: [Double] = []
    private var gridDragBase: GridDraft?
    private var lastClickReset: Double = 0

    /// 초안 존재 여부가 바뀌면 알린다(목록의 편집 표시용). 디스크를 다시 읽지 않도록 상태를 함께 넘긴다.
    var onDraftChange: ((String, DraftKind, Bool) -> Void)?

    /// 곡 길이와 재생 가능 여부는 관찰되는 저장값이다(오디오 엔진 값은 관찰되지 않는다).
    private(set) var duration: Double = 0
    private(set) var canPlay = false
    var currentTime: Double { playhead }
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

    /// 곡 ID가 같아도 내용(새 스냅샷의 큐·메타데이터)이 다르면 다시 불러온다.
    func load(_ row: TrackRow?) {
        guard row != self.row else { return }
        let sameTrack = row != nil && row?.id == self.row?.id
        stopPlayback()
        loadTask?.cancel()
        waveformTask?.cancel()
        seekRestartTask?.cancel()
        audio.unload()
        self.row = row
        waveform = nil; waveformError = nil; analysis = nil; analysisError = nil; artwork = nil
        suggestions = []; sectionEnergies = []; draft = nil
        originalGrid = nil; gridDraft = nil; grid = nil; gridBPM = nil; gridEditBlockedReason = nil
        gridDragBase = nil; tapBPM = nil; taps = []; resumeAfterScrub = false
        if !sameTrack { selectedCueID = nil; playhead = 0 }
        duration = Double(row?.track.lengthSeconds ?? 0)
        canPlay = false
        guard let row else { return }

        let url = URL(filePath: row.track.folderPath)
        let exists = !row.track.isStreaming && FileManager.default.fileExists(atPath: url.path)
        if exists {
            try? audio.load(url: url)
            canPlay = audio.isLoaded
            if canPlay { duration = audio.duration }
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
            guard self.canPlay else { return }
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
                self.analysis = analysis
                self.analysisError = nil
                self.sectionEnergies = PartLabeler.energies(analysis)
                self.refreshSuggestions()
            } catch {
                guard !Task.isCancelled, self.row?.id == id else { return }
                self.analysisError = String(describing: error)
            }
        }
    }

    private func apply(_ payload: DeckPayload) {
        draft = payload.draft
        originalGrid = payload.originalGrid
        gridDraft = payload.gridDraft
        gridEditBlockedReason = payload.gridBlockedReason
        if let image = payload.artwork?.image {
            artwork = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        refreshGrid()
    }

    /// 개발용: `--grid-edit`, `--autoplay [--muted] [--metronome]`
    private func applyLaunchFlags() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--grid-edit") { gridEditing = true }
        if args.contains("--autoplay"), !isPlaying {
            if args.contains("--muted") { volume = 0 }
            if args.contains("--metronome") { metronome = true }
            togglePlay()
        }
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

    private func tick() {
        guard isPlaying else { return }
        playhead = audio.position
        updateGridBPM()
        audio.scheduleClicks(grid)
        if !audio.isPlaying || playhead >= duration - 0.01 {
            audio.stop()
            isPlaying = false
            ticker.stop()
            playhead = min(playhead, duration)
        }
    }

    /// 한 번의 이동(패드·목록 클릭 등). 재생 중이면 그 위치에서 다시 재생한다.
    func seek(_ time: Double) {
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
        guard isPlaying else { return }
        resumeAfterScrub = true
        audio.pause()
        isPlaying = false
        ticker.stop()
    }

    func scrub(to time: Double) {
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
        let cue = EditableCue(kind: .memory, time: snapped(time))
        mutate { $0.place(cue) }
        selectedCueID = cue.id
    }

    func pressHotCue(slot: Int) {
        if let cue = hotCue(slot: slot) {
            seek(cue.time)
            selectedCueID = cue.id
        } else {
            guard canPlay || grid != nil else { return }  // 소리·그리드 없이 0초에 박히지 않게
            let cue = EditableCue(kind: .hot(slot), time: snapped(currentTime))
            mutate { $0.place(cue) }
            selectedCueID = cue.id
        }
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
        cue.time = target
        mutate(save: save) { $0.place(cue) }
    }

    func nudge(_ id: EditableCue.ID, beats: Int) {
        guard var cue = cue(id) else { return }
        cue.time = grid?.nudge(cue.time, beats: beats) ?? min(max(cue.time + Double(beats) * 0.5, 0), duration)
        mutate { $0.place(cue) }
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
        if let draft { persist(draft) }
    }

    private func mutate(save: Bool = true, _ change: (inout CueDraft) -> Void) {
        guard var draft, draft.trackUUID == row?.track.uuid else { return }
        change(&draft)
        self.draft = draft
        refreshSuggestions()
        if save { persist(draft) }
    }

    private func persist(_ draft: CueDraft) {
        DraftWriter.save(draft)
        onDraftChange?(draft.trackUUID, .cue, draft.hasChanges)
    }

    // MARK: - 그리드 편집 (초안만 바뀐다)

    var canEditGrid: Bool { gridDraft != nil && gridEditBlockedReason == nil }

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
    }

    func dragGrid(by seconds: Double) {
        guard var base = gridDragBase, base.trackUUID == row?.track.uuid else { return }
        base.shift(by: seconds)
        gridDraft = base
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
        mutateGrid { _ in }
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
        change(&gridDraft)
        self.gridDraft = gridDraft
        refreshGrid()
        DraftWriter.save(gridDraft)
        onDraftChange?(gridDraft.trackUUID, .grid, gridDraft.hasChanges)
        audio.resetClicks()
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
        let draft = CueDraftStore.load(trackUUID: track.uuid) ?? CueDraft(trackUUID: track.uuid, rekordboxCues: cues)
        var payload = DeckPayload(draft: draft)
        payload.artwork = ArtworkCache.downsampled(imagePath: track.imagePath, maxPixels: 360)

        guard let url = RekordboxShare.analysisURL(track.analysisDataPath),
              let original = try? BeatGrid.load(anlz: url), !original.beats.isEmpty
        else {
            payload.gridBlockedReason = "rekordbox 비트 그리드가 없습니다(분석되지 않은 곡)."
            return payload
        }
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
    static func save(_ draft: GridDraft) { queue.async { try? GridDraftStore.save(draft) } }
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
