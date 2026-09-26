@testable import AnicueApp
import AnicueAnalysis
import AnicueDomain
import AnicueTestSupport
import Foundation

/// 소리를 내지 않는 재생 엔진. 위치는 시험이 직접 옮긴다.
@MainActor
final class FakeDeckAudio: DeckAudioEngine {
    var volume: Float = 1
    var metronome = false
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
    /// 불러오면 이 길이가 된다
    var trackLength = 180.0
    /// 걸려 있는 루프(오디오 쪽)
    var loop: ClosedRange<Double>?
    var log: [String] = []

    func load(url: URL, timelineOffset: Double) throws { isLoaded = true; duration = trackLength; log.append("load") }
    func unload() { isLoaded = false; isPlaying = false }
    func play(from position: Double) -> Bool {
        self.position = position
        isPlaying = true
        handlesLoop = loop != nil
        log.append(String(format: "play %.3f", position))
        return true
    }
    func pause() { isPlaying = false; log.append("pause") }
    func stop() { isPlaying = false; log.append("stop") }
    func seekWhilePaused(_ position: Double) { self.position = position }
    func recoverIfStalled() {}
    func scheduleClicks(_ grid: BeatGrid?) {}
    func resetClicks() { log.append("resetClicks") }
    func setLoop(_ range: ClosedRange<Double>?, reschedule: Bool) -> Bool {
        loop = range
        handlesLoop = range != nil && isPlaying
        log.append(range.map { String(format: "loop %.3f~%.3f", $0.lowerBound, $0.upperBound) } ?? "loop off")
        return true
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
    func gain(_ uuid: String) -> Double? { lock.withLock { gains[uuid] } }
    func save(_ draft: CueDraft) { lock.withLock { cues[draft.trackUUID] = draft } }
    func save(_ draft: GridDraft) { lock.withLock { grids[draft.trackUUID] = draft } }
    func save(gain: Double?, _ uuid: String) { lock.withLock { gains[uuid] = gain } }
}

extension DeckStorage {
    static func memory(_ drafts: MemoryDrafts) -> DeckStorage {
        DeckStorage(
            loadCueDraft: { drafts.cue($0) }, saveCueDraft: { drafts.save($0) },
            loadGridDraft: { drafts.grid($0) }, saveGridDraft: { drafts.save($0) },
            loadGain: { drafts.gain($0) }, saveGain: { drafts.save(gain: $0, $1) },
            settings: DeckSettings(defaults: UserDefaults(suiteName: "anicue-test-\(UUID().uuidString)")!, persist: true))
    }
}

/// 덱 하나 + 가짜 오디오 + 메모리 저장소 + 합성 WAV 곡
@MainActor
struct DeckHarness {
    let deck: DeckModel
    let audio: FakeDeckAudio
    let drafts: MemoryDrafts
    let fixture: RekordboxFixture

    init(cues: [Cue] = [], grid: [GridSegment]? = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)],
         autoGain: RekordboxAutoGain? = nil) throws {
        fixture = try RekordboxFixture()
        audio = FakeDeckAudio()
        drafts = MemoryDrafts()
        let url = try AudioFixture.wav(seconds: 1, in: fixture.audio)
        let track = Track(id: "1", uuid: "track-1", title: "시험 곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                          composer: nil, releaseYear: nil, trackNumber: nil, key: "8B", bpm: 120, lengthSeconds: 180,
                          folderPath: url.path, comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
        // 그리드는 rekordbox 분석 파일 대신 초안으로 준다(분석 경로가 없는 곡)
        if let grid { drafts.save(GridDraft(trackUUID: track.uuid, base: [], segments: grid)) }
        deck = DeckModel(audio: audio, storage: .memory(drafts), runsAnalysis: false)
        deck.load(TrackRow(track: track, cues: cues, playCount: 0, autoGain: autoGain))
    }

    /// 백그라운드에서 초안·그리드를 다 읽을 때까지
    func loaded() async throws {
        for _ in 0..<200 where deck.draft == nil { try await Task.sleep(for: .milliseconds(10)) }
        if deck.draft == nil { throw FixtureError("덱이 곡을 다 읽지 못함") }
    }
}
