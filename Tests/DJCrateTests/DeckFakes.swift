@testable import DJCrate
import DJCAnalysis
import DJCDomain
import DJCTestSupport
import Foundation

/// 소리를 내지 않는 재생 엔진. 위치는 시험이 직접 옮긴다.
@MainActor
final class FakeDeckAudio: DeckAudioEngine {
    var volume: Float = 1
    var metronome = false
    var metronomeVolume: Float = 1
    var idleSeconds = 0.0
    var rate = 1.0
    var keyLock = true
    var gainDB: Float = 0
    let meter = LevelMeter()
    var needsChroma = true
    var onChroma: ((KeyAnalyzer.Chroma) -> Void)?
    var onLoudness: ((Loudness) -> Void)?
    var onRecovered: (() -> Void)?
    var onInterrupted: ((Double) -> Void)?

    var isLoaded = false
    var isPlaying = false
    var duration = 0.0
    var position = 0.0
    var handlesLoop = false
    var hasPendingJump = false
    /// 불러오면 이 길이가 된다
    var trackLength = 180.0
    /// 걸려 있는 루프(오디오 쪽)
    var loop: ClosedRange<Double>?
    var log: [String] = []

    func load(url: URL, timelineOffset: Double) throws { isLoaded = true; duration = trackLength; log.append("load") }
    func unload() { isLoaded = false; isPlaying = false }
    func play(from position: Double) -> Bool {
        self.position = position
        hasPendingJump = false
        isPlaying = true
        handlesLoop = loop != nil
        log.append(String(format: "play %.3f", position))
        return true
    }
    func pause() { isPlaying = false; hasPendingJump = false; log.append("pause") }
    func stop() { isPlaying = false; hasPendingJump = false; log.append("stop") }
    func seekWhilePaused(_ position: Double) { self.position = position }
    func recoverIfStalled() {}
    func scheduleClicks(_ grid: BeatGrid?) {}
    func resetClicks() { log.append("resetClicks") }
    func setLoop(_ range: ClosedRange<Double>?, reschedule: Bool) -> Bool {
        handlesLoop = range != nil && isPlaying
        // 실제 엔진처럼 같은 루프를 다시 걸면 아무 일도 하지 않는다(예약한 점프를 지우지 않게).
        guard range != loop else { return true }
        loop = range
        log.append(range.map { String(format: "loop %.3f~%.3f", $0.lowerBound, $0.upperBound) } ?? "loop off")
        return true
    }
    /// false면 샘플 단위 점프 예약을 못 하는 엔진(곡을 메모리에 풀기 전)처럼 군다.
    var schedulesJumps = true
    func scheduleJump(to cue: Double, loop: ClosedRange<Double>?, quantize: PlayQuantize) -> PlayQuantize.Jump? {
        guard schedulesJumps, isPlaying else { return nil }
        let jump = quantize.jump(earliest: position, to: cue, loopEnd: loop?.upperBound)
        self.loop = loop
        hasPendingJump = true
        handlesLoop = loop != nil
        log.append(String(format: "jump %.3f→%.3f", jump.at, jump.to)
                   + (loop.map { String(format: " loop %.3f~%.3f", $0.lowerBound, $0.upperBound) } ?? ""))
        return jump
    }
    func debugStopEngine() {}
    func debugConfigurationChange() {}
}

/// 메모리 초안 저장소(디스크·UserDefaults 표준 영역을 건드리지 않는다)
final class MemoryDrafts: @unchecked Sendable {
    private let lock = NSLock()
    private var cues: [String: CueDraft] = [:]
    private var grids: [String: GridDraft] = [:]
    private var gains: [String: Double] = [:]
    func cue(_ uuid: String) -> CueDraft? { lock.withLock { cues[uuid] } }
    func grid(_ uuid: String) -> GridDraft? { lock.withLock { grids[uuid] } }
    func removeGrid(_ uuid: String) { lock.withLock { grids[uuid] = nil } }
    func gain(_ uuid: String) -> Double? { lock.withLock { gains[uuid] } }
    func save(_ draft: CueDraft) { lock.withLock { cues[draft.trackUUID] = draft } }
    func save(_ draft: GridDraft) { lock.withLock { grids[draft.trackUUID] = draft } }
    func save(gain: Double?, _ uuid: String) { lock.withLock { gains[uuid] = gain } }
}

extension DeckStorage {
    static func memory(_ drafts: MemoryDrafts,
                       settings: SettingsStore = SettingsStore(defaults: UserDefaults(suiteName: "djc-test-\(UUID().uuidString)")!,
                                                               persist: true)) -> DeckStorage {
        DeckStorage(
            loadCueDraft: { drafts.cue($0) }, saveCueDraft: { drafts.save($0) },
            loadGridDraft: { drafts.grid($0) }, saveGridDraft: { drafts.save($0) },
            loadGain: { drafts.gain($0) }, saveGain: { drafts.save(gain: $0, $1) },
            removeGridDraft: { drafts.removeGrid($0) },
            settings: settings)
    }
}

/// 덱 하나 + 가짜 오디오 + 메모리 저장소 + 합성 WAV 곡
@MainActor
final class DeckHarness {
    let deck: DeckModel
    let audio: FakeDeckAudio
    let drafts: MemoryDrafts
    let root: URL

    /// - Parameter gridBase: 그리드 초안의 "rekordbox 원래 그리드"(되돌리기 대상). 비우면 분석 전 곡처럼 원래 그리드가 없다.
    init(cues: [Cue] = [], grid: [GridSegment]? = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)],
         gridBase: [GridSegment] = [], autoGain: RekordboxAutoGain? = nil, key: String? = "8B") throws {
        root = FileManager.default.temporaryDirectory.appending(path: "djc-deck-\(UUID().uuidString)")
        audio = FakeDeckAudio()
        drafts = MemoryDrafts()
        deck = DeckModel(audio: audio, storage: .memory(drafts), runsAnalysis: false)
        // 메모리 저장소를 쓰는 덱 시험에는 DB 없이 합성 음원 폴더만 필요하다.
        let directory = root.appending(path: "audio")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try AudioFixture.wav(seconds: 1, in: directory)
        let track = Track(id: "1", uuid: "track-1", title: "시험 곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                          composer: nil, releaseYear: nil, trackNumber: nil, key: key, bpm: 120, lengthSeconds: 180,
                          folderPath: url.path, comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
        // 그리드는 rekordbox 분석 파일 대신 초안으로 준다(분석 경로가 없는 곡)
        if let grid { drafts.save(GridDraft(trackUUID: track.uuid, base: gridBase, segments: grid)) }
        deck.load(TrackRow(track: track, cues: cues, playCount: 0, autoGain: autoGain))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// 백그라운드에서 초안·그리드를 다 읽을 때까지
    func loaded() async throws {
        for _ in 0..<200 where deck.draft == nil { try await Task.sleep(for: .milliseconds(10)) }
        if deck.draft == nil { throw FixtureError("덱이 곡을 다 읽지 못함") }
    }
}
