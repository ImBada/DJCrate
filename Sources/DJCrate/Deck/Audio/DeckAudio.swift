import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import Accelerate
import AVFoundation
import QuartzCore

/// 덱 재생 엔진.
///
/// 곡(trackNode)과 메트로놈(clickNode)을 같은 서브믹서에 넣고 속도 변환(varispeed·timePitch)을
/// 함께 통과시킨다. 두 노드의 시간축이 모두 "곡 시간"이라 템포를 바꿔도 클릭이 박에 붙어 있다.
/// 클릭은 노드 시간(샘플 단위)으로 예약하므로 화면 갱신 주기와 무관하게 정확하다.
/// 속도가 1.0이면 두 변환 유닛을 우회해 원본 그대로 낸다.
@MainActor
final class DeckAudio {
    private let engine = AVAudioEngine()
    private let trackNode = AVAudioPlayerNode()
    /// 곡 게인(오토게인·트림). 대역은 쓰지 않고 전역 게인만 쓴다(−96…+24dB).
    private let gainUnit = AVAudioUnitEQ(numberOfBands: 1)
    /// 곡 볼륨(페이더). 미터는 이 앞(게인 뒤)에서 읽는다.
    private let trackMixer = AVAudioMixerNode()
    private let clickNode = AVAudioPlayerNode()
    private let subMixer = AVAudioMixerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let timePitch = AVAudioUnitTimePitch()
    private let clickFormat: AVAudioFormat
    private let downbeatClick: AVAudioPCMBuffer?
    private let beatClick: AVAudioPCMBuffer?
    private var file: AVAudioFile?
    private var decoded: DecodedAudio?
    private var decodeTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var idleTask: Task<Void, Never>?

    private(set) var isPlaying = false
    private var pausedPosition: Double = 0
    /// 재생 시작(또는 속도 변경) 시점의 "직선 시간"과 호스트 시각. 직선 시간은 재생을 시작한 곡 위치에서
    /// 곡 속도로 쭉 흘러가는 시간이다(루프가 없으면 곡 위치와 같다). 곡 위치는 조각(`pieces`)으로 바꿔 구한다.
    private var anchorPosition: Double = 0
    private var anchorHost: Double = 0
    /// clickNode 샘플 0이 가리키는 직선 시간.
    private var clickEpochPosition: Double = 0
    /// 여기(직선 시간)까지 클릭을 예약했다.
    private var clickScheduledUntil: Double = 0

    // MARK: 샘플 단위 루프

    /// 재생 조각(노드 샘플 ↔ 곡 프레임) — 시간 변환·클릭 계획은 코어의 `PlaybackSchedule`(단위 테스트 있음).
    /// 재생 노드에 버퍼를 이어 붙여 예약하므로 루프 이음새가 샘플 단위로 맞는다(rekordbox처럼 끊김 없이).
    private var schedule = PlaybackSchedule(sampleRate: 44_100, timelineOffset: 0, startLinear: 0, pieces: [])
    private var pieces: [PlaybackPiece] {
        get { schedule.pieces }
        set { schedule.pieces = newValue }
    }
    /// 걸어 둘 루프(곡 위치, rekordbox 시간축)
    private(set) var loopRange: ClosedRange<Double>?

    /// 메모리에 풀어 둔 곡이 있어 루프를 샘플 단위로 이어 붙일 수 있는지(없으면 화면 틱이 되돌린다)
    var canLoopSampleAccurately: Bool { decoded != nil }
    /// 지금 예약된 재생에 루프가 들어 있어 오디오가 알아서 되풀이하는지
    var handlesLoop: Bool { isPlaying && loopRange != nil && pieces.last?.loop != nil }

    private var sampleRate: Double { file?.processingFormat.sampleRate ?? 44_100 }

    private func linear(ofNode node: Double) -> Double { schedule.linear(ofNode: node) }
    private func node(ofLinear linear: Double) -> Double { schedule.node(ofLinear: linear) }
    /// 재생 노드 샘플 → 곡 위치(초, rekordbox 시간축)
    private func songPosition(atNode node: Double) -> Double { schedule.songPosition(atNode: node) }

    private func frame(of position: Double) -> Int64 {
        Int64(((position - timelineOffset) * sampleRate).rounded())
    }

    /// 재생 노드가 실제로 그려 낸 샘플(없으면 호스트 시각으로 어림)
    private var renderedNode: Double {
        if let time = trackNode.lastRenderTime, let player = trackNode.playerTime(forNodeTime: time) {
            return Double(player.sampleTime)
        }
        return node(ofLinear: renderPosition)
    }

    /// 루프를 건다(nil이면 푼다). 재생 중이면 지금 흐름에 끊김 없이 이어 붙인다.
    /// - Returns: 샘플 단위로 처리했으면 true. false면 부른 쪽이 예전 방식(화면 틱에서 되돌리기)으로 처리한다.
    /// - Parameter reschedule: false면 값만 바꾼다(곧바로 다른 자리에서 다시 재생할 때).
    @discardableResult
    func setLoop(_ range: ClosedRange<Double>?, reschedule: Bool = true) -> Bool {
        guard range != loopRange else { return canLoopSampleAccurately }
        loopRange = range
        guard let decoded, file != nil else { return false }
        guard isPlaying, reschedule else { return true }
        // 예약은 재생 노드가 이미 그린 곳보다 충분히 앞서야 샘플 단위로 맞는다(렌더 블록 하나 이상, 2026-09-26 오프라인 실험).
        let now = Int64(renderedNode)
        let ahead = now + Int64((0.1 + latency) * sampleRate)
        let target = range.map { (start: frame(of: $0.lowerBound), end: frame(of: $0.upperBound)) }
        guard let plan = LoopPlanner.plan(pieces: pieces, now: now, ahead: ahead, loop: target) else {
            restartKeepingPosition()
            return true
        }
        // 버퍼를 먼저 모두 만든 뒤 예약한다(하나라도 못 만들면 다시 재생).
        var buffers: [(AVAudioPCMBuffer, LoopPlanner.Buffer)] = []
        for item in plan.buffers {
            guard let buffer = decoded.segment(from: item.from, to: item.to) else { restartKeepingPosition(); return true }
            buffers.append((buffer, item))
        }
        for (buffer, item) in buffers {
            var options: AVAudioPlayerNodeBufferOptions = []
            if item.interrupts { options.insert(.interrupts) }
            if item.loops { options.insert(.loops) }
            trackNode.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: item.at, atRate: sampleRate), options: options, completionHandler: nil)
        }
        pieces += plan.pieces
        switch plan.kind {
        case .engage: AudioEvents.record("루프 걸기(샘플 단위) · \(range.map { String(format: "%.3f~%.3f", $0.lowerBound, $0.upperBound) } ?? "")초")
        case .resize: AudioEvents.record("루프 길이 바꿈(샘플 단위) · \(range.map { String(format: "%.3f~%.3f", $0.lowerBound, $0.upperBound) } ?? "")초")
        case .exit: AudioEvents.record("루프 나가기(샘플 단위)")
        case .none: break
        }
        return true
    }

    /// 지금 위치에서 다시 예약한다(짧은 끊김이 있다). 샘플 단위로 이어 붙일 수 없는 드문 경우에만 쓴다.
    private func restartKeepingPosition() {
        guard isPlaying else { return }
        play(from: position)
    }
    /// 출력·변환 지연. 매 프레임 Core Audio에 묻지 않도록 재생 시작·속도 변경 때만 갱신한다.
    private var latency: Double = 0
    private var configObserver: NSObjectProtocol?
    /// 출력 장치가 바뀌어 엔진이 멈췄을 때 알린다(재생 상태 정리용).
    var onInterrupted: ((Double) -> Void)?

    var rate: Double = 1 { didSet { if rate != oldValue { applyRate() } } }
    var keyLock = true { didSet { if keyLock != oldValue { applyRate() } } }
    var volume: Float = 0.9 { didSet { trackMixer.outputVolume = volume } }
    /// 곡 게인(dB). 볼륨 페이더 앞에 걸린다.
    var gainDB: Float = 0 { didSet { gainUnit.globalGain = min(max(gainDB, -24), 24) } }
    /// 게인 뒤·볼륨 앞 레벨(미터). 오디오 탭이 채우고 화면이 읽는다.
    let meter = LevelMeter()
    /// 메모리 디코딩이 끝나면 곡 음량을 알린다(오토게인).
    var onLoudness: ((Loudness) -> Void)?
    /// 메모리 디코딩이 끝나면 크로마(조성 흐름 추정용, 음원 시간축)를 알린다.
    var onChroma: ((KeyAnalyzer.Chroma) -> Void)?
    /// 캐시가 있으면 끈다(디코딩 뒤 크로마를 다시 계산하지 않는다).
    var needsChroma = true
    var metronomeVolume: Float = 0.8 { didSet { clickNode.volume = metronomeVolume } }
    var metronome = false { didSet { if metronome != oldValue { resetClicks() } } }

    var isLoaded: Bool { file != nil }
    /// rekordbox 시간축 길이(음원 길이 + 인코더 지연)
    var duration: Double { fileDuration + timelineOffset }
    /// rekordbox 시간축 − 음원(AVFoundation) 시간축. 위치는 모두 rekordbox 시간축이고,
    /// 음원을 읽을 때만 이만큼 빼서 프레임을 고른다(rekordbox처럼 앞의 지연 샘플만큼 늦게 소리가 난다).
    private(set) var timelineOffset: Double = 0

    init() {
        clickFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        downbeatClick = Self.makeClick(format: clickFormat, frequency: 1_760)
        beatClick = Self.makeClick(format: clickFormat, frequency: 1_175)
        for node in [trackNode, gainUnit, trackMixer, clickNode, subMixer, varispeed, timePitch] as [AVAudioNode] { engine.attach(node) }
        gainUnit.bands[0].bypass = true
        engine.connect(clickNode, to: subMixer, format: clickFormat)
        engine.connect(subMixer, to: varispeed, format: nil)
        engine.connect(varispeed, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        trackMixer.outputVolume = volume
        clickNode.volume = metronomeVolume
        applyRate()
        // 헤드폰·에어팟 연결 등으로 출력 구성이 바뀌면 엔진이 멈춘다. 위치를 기억하고 정지 상태로 정리한다.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    /// 다른 앱이 장치를 바꾸거나(샘플레이트·버퍼·기본 출력) 장치가 빠졌다 들어오면 macOS가 엔진을 멈춘다.
    /// 연결을 새 장치 형식으로 다시 잡고, 재생 중이었으면 같은 자리에서 이어서 재생한다.
    private func handleConfigurationChange() {
        let wasPlaying = isPlaying
        let position = self.position
        AudioEvents.record("출력 구성 변경 · 재생 중=\(wasPlaying) · 엔진 동작=\(engine.isRunning) · \(String(format: "%.2f", position))초 · 장치 \(outputDeviceName())")
        trackNode.stop()
        clickNode.stop()
        isPlaying = false
        pausedPosition = position
        reconnectOutput()
        guard wasPlaying else { return }
        resume(at: position, attempt: 1)
    }

    /// 메인 믹서 → 출력 연결을 지금 장치 형식으로 다시 만든다(구성 변경 뒤 옛 형식이 남으면 소리가 안 난다).
    private func reconnectOutput() {
        if engine.isRunning { engine.stop() }
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.prepare()
    }

    /// 장치가 자리 잡는 동안 잠깐 기다렸다 재생을 이어 간다. 세 번 실패하면 멈춘 상태로 알린다.
    private func resume(at position: Double, attempt: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250 * attempt))
            guard let self, !self.isPlaying else { return }
            if self.play(from: position) {
                AudioEvents.record("재생 이어 가기 성공(\(attempt)번째) · \(String(format: "%.2f", position))초 · 장치 \(self.outputDeviceName())")
                self.onRecovered?()
            } else if attempt < 3 {
                self.resume(at: position, attempt: attempt + 1)
            } else {
                AudioEvents.record("재생 이어 가기 실패 · 정지 상태로 둠")
                self.onInterrupted?(position)
            }
        }
    }

    /// 화면은 재생 중인데 엔진이 멈춰 있으면(알림 없이 멈춘 경우) 같은 자리에서 다시 시작한다.
    /// 디스플레이 갱신마다 부르며, 1초에 한 번만 시도한다.
    func recoverIfStalled() {
        guard isPlaying, !engine.isRunning else { return }
        let now = Self.now()
        guard now - lastRecovery > 1 else { return }
        lastRecovery = now
        let position = self.position
        AudioEvents.record("엔진이 멈춰 있음(재생 중) · \(String(format: "%.2f", position))초에서 복구 · 장치 \(outputDeviceName())")
        trackNode.stop()
        clickNode.stop()
        isPlaying = false
        reconnectOutput()
        resume(at: position, attempt: 1)
    }

    private var lastRecovery: Double = 0
    /// 구성 변경 뒤 재생을 자동으로 이어 갔을 때(화면 갱신 재개용)
    var onRecovered: (() -> Void)?

    var isEngineRunning: Bool { engine.isRunning }

    /// 진단: 곡 믹서 출력(속도 변환 전)을 받아 본다. 스피커는 음소거한다(개발용 자가 테스트).
    func debugCaptureTrack(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        engine.mainMixerNode.outputVolume = 0
        trackMixer.removeTap(onBus: 0)
        trackMixer.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.captureTap(handler))
    }

    /// 오디오 스레드에서 불리므로 메인 액터 밖에서 만든다.
    nonisolated private static func captureTap(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in handler(buffer) }
    }

    /// 진단: 메트로놈 노드 출력을 받아 본다(클릭이 빠지지 않는지 세는 자가 테스트).
    func debugCaptureClicks(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        engine.mainMixerNode.outputVolume = 0
        clickNode.removeTap(onBus: 0)
        clickNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.captureTap(handler))
    }

    /// 진단: 알림 없이 엔진이 멈춘 상황을 흉내 낸다.
    func debugStopEngine() { engine.stop() }

    /// 진단: 다른 앱이 장치를 바꿔 엔진이 멈추고 구성 변경 알림이 온 상황을 흉내 낸다.
    func debugConfigurationChange() {
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }

    func load(url: URL, timelineOffset: Double = 0) throws {
        stop()
        self.timelineOffset = timelineOffset
        decodeTask?.cancel()
        decoded = nil
        loadGeneration += 1
        let file = try AVAudioFile(forReading: url)
        gainUnit.removeTap(onBus: 0)
        for node in [trackNode, gainUnit, trackMixer] as [AVAudioNode] { engine.disconnectNodeOutput(node) }
        engine.connect(trackNode, to: gainUnit, format: file.processingFormat)
        engine.connect(gainUnit, to: trackMixer, format: file.processingFormat)
        engine.connect(trackMixer, to: subMixer, format: file.processingFormat)
        meter.reset()
        gainUnit.installTap(onBus: 0, bufferSize: 1024, format: file.processingFormat, block: Self.meterTap(meter))
        self.file = file
        fileDuration = Double(file.length) / file.processingFormat.sampleRate
        pausedPosition = 0
        engine.prepare()
        AudioEvents.record("곡 로드 · \(url.lastPathComponent) · \(Int(file.processingFormat.sampleRate))Hz \(file.processingFormat.channelCount)ch · \(String(format: "%.1f", fileDuration))초 · rekordbox 지연 \(String(format: "%.1f", timelineOffset * 1000))ms")

        guard fileDuration <= DecodedAudio.maxDuration else { return }
        let generation = loadGeneration
        let started = Self.now()
        let wantsChroma = needsChroma
        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            AudioDebug.log("메모리 디코딩 시작")
            guard let decoded = DecodedAudio.decode(url: url) else {
                AudioDebug.log("메모리 디코딩 실패·취소 → 파일 재생 유지")
                return
            }
            let loudness = decoded.loudness()
            let chroma = wantsChroma ? decoded.chroma() : nil
            await self?.adopt(decoded, loudness: loudness, chroma: chroma, generation: generation, started: started)
        }
    }

    private func adopt(_ decoded: DecodedAudio, loudness: Loudness, chroma: KeyAnalyzer.Chroma?, generation: Int, started: Double) {
        guard generation == loadGeneration, file != nil else {
            AudioDebug.log("메모리 디코딩 결과 버림(다른 곡으로 바뀜)")
            return
        }
        self.decoded = decoded
        onLoudness?(loudness)
        if let chroma { onChroma?(chroma) }
        AudioDebug.log("메모리 디코딩 완료 \(String(format: "%.0f", (Self.now() - started) * 1000))ms · \(decoded.frameCount)프레임")
    }

    func unload() {
        stop()
        decodeTask?.cancel()
        decodeTask = nil
        decoded = nil
        loadGeneration += 1
        file = nil
        fileDuration = 0
        timelineOffset = 0
    }

    // MARK: - 재생

    /// 지금 들리는 곡 위치. 출력·변환 지연만큼 빼서 화면이 소리와 맞게 한다.
    var position: Double {
        guard isPlaying else { return pausedPosition }
        let elapsed = max(0, Self.now() - anchorHost - latency)
        let linear = anchorPosition + elapsed * rate
        return min(duration, songPosition(atNode: node(ofLinear: linear)))
    }

    private var fileDuration: Double = 0

    /// 지금 렌더링 중인 직선 시간(지연 보정 없음). 클릭 예약·재앵커에 쓴다.
    private var renderPosition: Double {
        anchorPosition + max(0, Self.now() - anchorHost) * rate
    }

    /// 재생을 시작한다. 곡 끝이거나 엔진을 켤 수 없으면 false(재생 상태로 두지 않는다).
    @discardableResult
    func play(from position: Double) -> Bool {
        guard let file else { return false }
        idleTask?.cancel()
        trackNode.stop()
        clickNode.stop()
        let sampleRate = file.processingFormat.sampleRate
        // rekordbox 위치 → 음원 위치. 앞의 지연 구간(음원 위치 < 0)에서 시작하면 그만큼 늦게 소리를 낸다.
        let audioPosition = position - timelineOffset
        let startFrame = AVAudioFramePosition(max(0, audioPosition) * sampleRate)
        let leadIn = max(0, -audioPosition)
        guard startFrame < file.length else {
            isPlaying = false
            pausedPosition = duration
            return false
        }
        if !engine.isRunning {
            do { try engine.start() } catch {
                AudioEvents.record("엔진 시작 실패: \(error) · 장치 \(outputDeviceName())")
                isPlaying = false
                pausedPosition = position
                return false
            }
        }
        schedule = PlaybackSchedule(sampleRate: sampleRate, timelineOffset: timelineOffset, startLinear: position,
                                    leadInFrames: Int64((leadIn * sampleRate).rounded()),
                                    pieces: [PlaybackPiece(node: 0, frame: startFrame, loop: nil)])
        if let decoded, let range = loopRange, position < range.upperBound - 0.001,
           case let (loopStart, loopEnd) = (frame(of: range.lowerBound), frame(of: range.upperBound)),
           loopEnd - loopStart > 16, loopEnd > startFrame,
           let head = decoded.segment(from: startFrame, to: loopEnd), let body = decoded.segment(from: loopStart, to: loopEnd) {
            // 루프 끝까지 + 루프 되풀이(샘플 단위로 이어진다)
            trackNode.scheduleBuffer(head, at: nil, options: [], completionHandler: nil)
            trackNode.scheduleBuffer(body, at: nil, options: .loops, completionHandler: nil)
            pieces.append(PlaybackPiece(node: loopEnd - startFrame, frame: loopStart, loop: loopEnd - loopStart))
        } else if let segment = decoded?.segment(from: startFrame) {
            trackNode.scheduleBuffer(segment, at: nil, options: [], completionHandler: nil)
        } else {
            // 디코딩이 끝나기 전(곡을 막 불러온 직후)이나 아주 긴 파일: 파일에서 바로 읽는다.
            trackNode.scheduleSegment(file, startingFrame: startFrame,
                                      frameCount: AVAudioFrameCount(file.length - startFrame), at: nil)
        }
        latency = currentLatency()
        let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.02)
        let when = AVAudioTime(hostTime: startHost)
        let trackStart = AVAudioTime(hostTime: startHost + AVAudioTime.hostTime(forSeconds: leadIn / rate))
        trackNode.play(at: leadIn > 0 ? trackStart : when)
        clickNode.play(at: when)
        anchorPosition = position
        anchorHost = AVAudioTime.seconds(forHostTime: startHost)
        clickEpochPosition = position
        clickScheduledUntil = position - 0.001
        isPlaying = true
        AudioEvents.record("재생 \(String(format: "%.2f", position))초 · \(decoded == nil ? "파일" : "메모리") · 지연 \(String(format: "%.3f", latency)) · 음량 \(String(format: "%.2f", volume)) · 장치 \(outputDeviceName())")
        installDebugTap()
        return true
    }

    func pause() {
        guard isPlaying else { return }
        pausedPosition = position
        trackNode.stop()
        clickNode.stop()
        isPlaying = false
        scheduleIdlePause()
    }

    /// 곡을 바꾸거나 끝났을 때. 엔진도 바로 쉰다.
    func stop() {
        idleTask?.cancel()
        trackNode.stop()
        clickNode.stop()
        isPlaying = false
        // pause()가 아니라 stop(): pause 뒤 다시 켜면 재생 노드가 시작 시각(호스트 시각)을 쉬기 전 기준으로
        // 바꿔서, 엔진이 쉰 시간만큼 소리가 늦게 나고 그 밀림이 쌓인다(곡 전환·오래 멈춤 뒤 무음의 원인).
        if engine.isRunning { engine.stop() }
    }

    /// 멈춘 뒤 엔진을 끄기까지의 시간(개발용으로 `DJC_IDLE_SECONDS`로 줄일 수 있다).
    static let idleSeconds: Double = ProcessInfo.processInfo.environment["DJC_IDLE_SECONDS"].flatMap(Double.init) ?? 20

    /// 멈춘 뒤에도 잠시 엔진을 켜 두어 CUE·재생이 바로 반응하게 하고, 오래 쉬면 CPU를 쓰지 않게 끈다.
    private func scheduleIdlePause() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleSeconds))
            guard !Task.isCancelled, let self, !self.isPlaying, self.engine.isRunning else { return }
            self.engine.stop()
            AudioEvents.record("\(Int(Self.idleSeconds))초 유휴 · 엔진 정지")
        }
    }

    func seekWhilePaused(_ position: Double) {
        pausedPosition = position
    }

    private func applyRate() {
        if isPlaying {
            anchorPosition = renderPosition
            anchorHost = Self.now()
        }
        let stretching = keyLock && rate != 1
        let resampling = !keyLock && rate != 1
        timePitch.rate = Float(stretching ? rate : 1)
        varispeed.rate = Float(resampling ? rate : 1)
        timePitch.bypass = !stretching
        varispeed.bypass = !resampling
        latency = currentLatency()
    }

    private func currentLatency() -> Double {
        (timePitch.bypass ? 0 : timePitch.latency) + (varispeed.bypass ? 0 : varispeed.latency)
            + engine.outputNode.presentationLatency
    }

    // MARK: - 메트로놈

    /// 1.5초 앞까지 클릭을 예약한다. 디스플레이 갱신마다 부른다. 루프 중에는 조각을 따라 바퀴마다 같은 박을 친다.
    func scheduleClicks(_ grid: BeatGrid?) {
        guard isPlaying, metronome, let grid, let down = downbeatClick, let beat = beatClick, !pieces.isEmpty else { return }
        let horizon = renderPosition + 1.5 * rate
        // 반열린 구간 [지난번 끝, 이번 끝): 박이 빠지거나 두 번 예약되지 않는다.
        guard clickScheduledUntil < horizon else { return }
        for click in schedule.clicks(in: clickScheduledUntil..<horizon, grid: grid) {
            let offset = click.linear - clickEpochPosition
            guard offset >= 0 else { continue }
            let when = AVAudioTime(sampleTime: AVAudioFramePosition(offset * clickFormat.sampleRate), atRate: clickFormat.sampleRate)
            clickNode.scheduleBuffer(click.downbeat ? down : beat, at: when, options: [], completionHandler: nil)
        }
        clickScheduledUntil = horizon
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

    // MARK: - 진단

    /// 엔진이 실제로 소리를 내보내는 장치 이름(기본 출력이 바뀌었는지 확인용).
    func outputDeviceName() -> String {
        guard let unit = engine.outputNode.audioUnit else { return "?" }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) == noErr else { return "?" }
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return "#\(device)" }
        return name.takeRetainedValue() as String
    }

    private var tapInstalled = false

    /// 메인 믹서 출력이 무음↔소리로 바뀌는 순간을 기록한다. 재생 예정 시각과 비교해 시작 지연을 잰다.
    private func installDebugTap() {
        guard !tapInstalled else { return }
        tapInstalled = true
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 512, format: nil, block: Self.silenceLogger())
    }

    /// 미터 탭: 버퍼마다 채널 피크·RMS를 잰다.
    nonisolated private static func meterTap(_ meter: LevelMeter) -> AVAudioNodeTapBlock {
        { @Sendable buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let n = vDSP_Length(buffer.frameLength)
            guard n > 0 else { return }
            let channels = Int(buffer.format.channelCount)
            var peaks: [Float] = [], rms: [Float] = []
            for ch in 0..<min(channels, 2) {
                var peak: Float = 0, level: Float = 0
                vDSP_maxmgv(data[ch], 1, &peak, n)
                vDSP_rmsqv(data[ch], 1, &level, n)
                peaks.append(peak); rms.append(level)
            }
            if peaks.count == 1 { peaks.append(peaks[0]); rms.append(rms[0]) }
            meter.update(peak: (peaks[0], peaks[1]), rms: (rms[0], rms[1]))
        }
    }

    /// 탭 블록은 오디오 스레드에서 불린다. `@MainActor` 안에서 만들면 메인 액터 격리로 추론돼
    /// Swift 6 런타임이 앱을 종료시키므로, 격리되지 않은 정적 함수에서 만든다.
    nonisolated private static func silenceLogger() -> AVAudioNodeTapBlock {
        final class State: @unchecked Sendable { var silent: Bool? }
        let state = State()
        return { @Sendable buffer, time in
            guard let data = buffer.floatChannelData else { return }
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[0][i])) }
            let silent = peak == 0
            guard silent != state.silent else { return }
            state.silent = silent
            let host = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : -1
            // 상시 기록: 재생 중 출력이 무음으로 바뀌는 순간을 남긴다(곡의 실제 무음 구간도 찍힌다).
            AudioEvents.record("출력 \(silent ? "무음" : "소리") 시작 · 렌더 시각 \(String(format: "%.3f", host))")
        }
    }
}
