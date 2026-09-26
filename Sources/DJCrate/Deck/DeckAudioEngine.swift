import DJCAnalysis
import DJCDomain
import Foundation

/// 덱이 쓰는 재생 엔진. 실제는 `DeckAudio`(AVAudioEngine), 시험에서는 가짜로 바꾼다.
@MainActor
protocol DeckAudioEngine: AnyObject {
    var volume: Float { get set }
    var metronome: Bool { get set }
    var metronomeVolume: Float { get set }
    /// 멈춘 뒤 엔진을 끄기까지(초)
    var idleSeconds: Double { get set }
    var rate: Double { get set }
    var keyLock: Bool { get set }
    var gainDB: Float { get set }
    var meter: LevelMeter { get }
    var needsChroma: Bool { get set }
    var onChroma: ((KeyAnalyzer.Chroma) -> Void)? { get set }
    var onLoudness: ((Loudness) -> Void)? { get set }
    var onRecovered: (() -> Void)? { get set }
    var onInterrupted: ((Double) -> Void)? { get set }

    var isLoaded: Bool { get }
    var isPlaying: Bool { get }
    /// rekordbox 시간축 길이
    var duration: Double { get }
    /// 지금 들리는 곡 위치(rekordbox 시간축)
    var position: Double { get }
    /// 오디오가 루프를 샘플 단위로 되풀이하고 있는지
    var handlesLoop: Bool { get }

    func load(url: URL, timelineOffset: Double) throws
    func unload()
    @discardableResult func play(from position: Double) -> Bool
    func pause()
    func stop()
    func seekWhilePaused(_ position: Double)
    func recoverIfStalled()
    func scheduleClicks(_ grid: BeatGrid?)
    func resetClicks()
    @discardableResult func setLoop(_ range: ClosedRange<Double>?, reschedule: Bool) -> Bool

    // 진단(자가 테스트)
    func debugStopEngine()
    func debugConfigurationChange()
}

extension DeckAudioEngine {
    /// 루프를 걸거나 푼다(재생 중이면 지금 흐름에 이어 붙인다).
    @discardableResult func setLoop(_ range: ClosedRange<Double>?) -> Bool { setLoop(range, reschedule: true) }
}

extension DeckAudio: DeckAudioEngine {}
