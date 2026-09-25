import AnicueCore
import AppKit
import AVFoundation
import QuartzCore

/// 덱 재생 엔진.
///
/// 곡(trackNode)과 메트로놈(clickNode)을 같은 서브믹서에 넣고 속도 변환(varispeed·timePitch)을
/// 함께 통과시킨다. 두 노드의 시간축이 모두 "곡 시간"이라 템포를 바꿔도 클릭이 박에 붙어 있다.
/// 클릭은 노드 시간(샘플 단위)으로 예약하므로 화면 갱신 주기와 무관하게 정확하다.
@MainActor
final class DeckAudio {
    private let engine = AVAudioEngine()
    private let trackNode = AVAudioPlayerNode()
    private let clickNode = AVAudioPlayerNode()
    private let subMixer = AVAudioMixerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let timePitch = AVAudioUnitTimePitch()
    private let clickFormat: AVAudioFormat
    private let downbeatClick: AVAudioPCMBuffer?
    private let beatClick: AVAudioPCMBuffer?
    private var file: AVAudioFile?

    private(set) var isPlaying = false
    private var pausedPosition: Double = 0
    /// 재생 시작(또는 속도 변경) 시점의 곡 위치와 호스트 시각.
    private var anchorPosition: Double = 0
    private var anchorHost: Double = 0
    /// clickNode 샘플 0이 가리키는 곡 위치.
    private var clickEpochPosition: Double = 0
    private var clickScheduledUntil: Double = 0
    /// 출력·변환 지연. 매 프레임 Core Audio에 묻지 않도록 재생 시작·경로 변경 때만 갱신한다.
    private var latency: Double = 0
    private var configObserver: NSObjectProtocol?
    /// 출력 장치가 바뀌어 엔진이 멈췄을 때 알린다(재생 상태 정리용).
    var onInterrupted: ((Double) -> Void)?

    var rate: Double = 1 { didSet { if rate != oldValue { applyRate() } } }
    var keyLock = true { didSet { if keyLock != oldValue { applyRate() } } }
    var volume: Float = 0.9 { didSet { trackNode.volume = volume } }
    var metronomeVolume: Float = 0.8 { didSet { clickNode.volume = metronomeVolume } }
    var metronome = false { didSet { if metronome != oldValue { resetClicks() } } }

    var isLoaded: Bool { file != nil }
    var duration: Double { file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0 }

    init() {
        clickFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        downbeatClick = Self.makeClick(format: clickFormat, frequency: 1_760)
        beatClick = Self.makeClick(format: clickFormat, frequency: 1_175)
        for node in [trackNode, clickNode, subMixer, varispeed, timePitch] as [AVAudioNode] { engine.attach(node) }
        engine.connect(clickNode, to: subMixer, format: clickFormat)
        engine.connect(subMixer, to: varispeed, format: nil)
        engine.connect(varispeed, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        trackNode.volume = volume
        clickNode.volume = metronomeVolume
        // 헤드폰·에어팟 연결 등으로 출력 구성이 바뀌면 엔진이 멈춘다. 위치를 기억하고 정지 상태로 정리한다.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    private func handleConfigurationChange() {
        let wasPlaying = isPlaying
        let position = self.position
        trackNode.stop()
        clickNode.stop()
        isPlaying = false
        pausedPosition = position
        if wasPlaying { onInterrupted?(position) }
    }

    func load(url: URL) throws {
        stop()
        let file = try AVAudioFile(forReading: url)
        engine.disconnectNodeOutput(trackNode)
        engine.connect(trackNode, to: subMixer, format: file.processingFormat)
        self.file = file
        fileDuration = Double(file.length) / file.processingFormat.sampleRate
        pausedPosition = 0
        engine.prepare()
    }

    func unload() {
        stop()
        file = nil
        fileDuration = 0
    }

    // MARK: - 재생

    /// 지금 들리는 곡 위치. 출력·변환 지연만큼 빼서 화면이 소리와 맞게 한다.
    var position: Double {
        guard isPlaying else { return pausedPosition }
        let elapsed = max(0, Self.now() - anchorHost - latency)
        return min(fileDuration, anchorPosition + elapsed * rate)
    }

    private var fileDuration: Double = 0

    /// 지금 렌더링 중인 곡 위치(지연 보정 없음). 클릭 예약·재앵커에 쓴다.
    private var renderPosition: Double {
        anchorPosition + max(0, Self.now() - anchorHost) * rate
    }

    /// 재생을 시작한다. 곡 끝이거나 엔진을 켤 수 없으면 false(재생 상태로 두지 않는다).
    @discardableResult
    func play(from position: Double) -> Bool {
        guard let file else { return false }
        trackNode.stop()
        clickNode.stop()
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, position) * sampleRate)
        guard startFrame < file.length else {
            isPlaying = false
            pausedPosition = fileDuration
            return false
        }
        if !engine.isRunning {
            do { try engine.start() } catch {
                isPlaying = false
                pausedPosition = position
                return false
            }
        }
        latency = timePitch.latency + varispeed.latency + engine.outputNode.presentationLatency
        trackNode.scheduleSegment(file, startingFrame: startFrame,
                                  frameCount: AVAudioFrameCount(file.length - startFrame), at: nil)
        let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.03)
        let when = AVAudioTime(hostTime: startHost)
        trackNode.play(at: when)
        clickNode.play(at: when)
        anchorPosition = position
        anchorHost = AVAudioTime.seconds(forHostTime: startHost)
        clickEpochPosition = position
        clickScheduledUntil = position - 0.001
        isPlaying = true
        return true
    }

    func pause() {
        guard isPlaying else { return }
        pausedPosition = position
        trackNode.stop()
        clickNode.stop()
        isPlaying = false
        // 멈춰 있는 동안 렌더 스레드와 타임피치가 CPU를 쓰지 않게 한다.
        engine.pause()
    }

    func stop() {
        trackNode.stop()
        clickNode.stop()
        isPlaying = false
        if engine.isRunning { engine.pause() }
    }

    func seekWhilePaused(_ position: Double) {
        pausedPosition = position
    }

    private func applyRate() {
        if isPlaying {
            anchorPosition = renderPosition
            anchorHost = Self.now()
        }
        timePitch.rate = Float(keyLock ? rate : 1)
        varispeed.rate = Float(keyLock ? 1 : rate)
    }

    // MARK: - 메트로놈

    /// 1.5초 앞까지 클릭을 예약한다. 디스플레이 갱신마다 부른다.
    func scheduleClicks(_ grid: BeatGrid?) {
        guard isPlaying, metronome, let grid, let down = downbeatClick, let beat = beatClick else { return }
        let horizon = renderPosition + 1.5 * rate
        var index = grid.firstIndex(atOrAfter: clickScheduledUntil + 0.0005)
        while index < grid.beats.count, grid.beats[index].time <= horizon {
            let b = grid.beats[index]
            index += 1
            let offset = b.time - clickEpochPosition
            guard offset >= 0 else { continue }
            let when = AVAudioTime(sampleTime: AVAudioFramePosition(offset * clickFormat.sampleRate), atRate: clickFormat.sampleRate)
            clickNode.scheduleBuffer(b.isDownbeat ? down : beat, at: when, options: [], completionHandler: nil)
            clickScheduledUntil = b.time
        }
    }

    /// 예약된 클릭을 버리고 새 시간축에서 다시 시작한다(메트로놈 토글·그리드 편집 후).
    func resetClicks() {
        guard isPlaying else { return }
        clickNode.stop()
        let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.02)
        clickNode.play(at: AVAudioTime(hostTime: startHost))
        clickEpochPosition = anchorPosition + (AVAudioTime.seconds(forHostTime: startHost) - anchorHost) * rate
        clickScheduledUntil = clickEpochPosition - 0.001
    }

    private static func now() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    private static func makeClick(format: AVAudioFormat, frequency: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * 0.03)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            for i in 0..<Int(frames) {
                let t = Double(i) / format.sampleRate
                channels[channel][i] = Float(sin(2 * .pi * frequency * t) * exp(-t * 120) * 0.6)
            }
        }
        return buffer
    }
}

/// 디스플레이 주사율에 맞춘 갱신(CADisplayLink). 16ms 타이머보다 움직임이 고르다.
@MainActor
final class DisplayTicker: NSObject {
    private var link: CADisplayLink?
    private let onTick: @MainActor () -> Void

    init(onTick: @escaping @MainActor () -> Void) {
        self.onTick = onTick
    }

    func start() {
        guard link == nil, let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        // 파형 갱신은 60Hz면 충분하다(ProMotion 120Hz에서 CPU를 반으로 줄인다).
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    private var pending = false

    /// 디스플레이 링크는 AppKit 레이아웃 패스 도중에 불린다. 여기서 바로 상태를 바꾸면
    /// 레이아웃이 다시 무효화되어 무한 갱신(NSGenericException)이 난다. 다음 런루프로 미룬다.
    @objc private func step(_ link: CADisplayLink) {
        guard !pending else { return }
        pending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pending = false
            self.onTick()
        }
    }
}
