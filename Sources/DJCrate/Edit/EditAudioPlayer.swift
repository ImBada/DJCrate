import AVFoundation
import DJCAnalysis
import DJCDomain
import Foundation

/// 편집 창 전용 재생기(덱과 따로). 실제는 `EditAudioPlayer`, 시험에서는 가짜로 바꾼다.
@MainActor
protocol EditAudio: AnyObject {
    /// 원곡을 메모리에 풀어 재생할 수 있다
    var isReady: Bool { get }
    var sampleRate: Double { get }
    var isPlaying: Bool { get }
    /// 재생을 시작한 뒤 들린 시간(초, 출력 지연을 뺌)
    var elapsed: Double { get }
    /// 원곡을 메모리에 푼다. 끝나면(실패하면 false) `done`을 부른다.
    func prepare(url: URL, done: @escaping @MainActor (Bool) -> Void)
    /// 예약표를 `frame`부터 재생한다. 소리를 낼 수 없으면 false.
    func play(_ items: [EditPlaybackItem], from frame: Int64, volume: Float) -> Bool
    func stop()
    /// 창을 닫을 때: 멈추고 메모리를 놓는다.
    func close()
}

/// 원곡을 메모리에 풀어 두고, 원곡 그대로(원곡 줄) 또는 편집 결과(결과 줄)를 렌더하지 않고 바로 재생한다.
///
/// 결과는 `TrackEdit.playbackItems`의 칸을 재생 노드 샘플 시각에 이어 예약한다. 조각 본문은 원곡 버퍼를 복사 없이 잘라 쓰고,
/// 이음새 섞는 칸만 새로 만든다(`EditRenderer.playbackBuffer`, 렌더 파일과 같은 소리). 칸 사이 빈자리(원곡 밖)는 무음이다.
/// 멈출 때는 `AVAudioEngine.pause()`가 아니라 `stop()`을 쓴다(덱과 같은 이유: 다시 켤 때 시작 시각이 밀린다).
@MainActor
final class EditAudioPlayer: EditAudio {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var decoded: DecodedAudio?
    private var decodeTask: Task<Void, Never>?
    private var latency: Double = 0
    private var started = false

    init() {
        engine.attach(node)
    }

    var isReady: Bool { decoded != nil }
    var sampleRate: Double { decoded?.buffer.format.sampleRate ?? 44_100 }
    /// 장치가 바뀌어 엔진이 멈췄으면 재생 중이 아니다.
    var isPlaying: Bool { started && engine.isRunning }

    var elapsed: Double {
        guard isPlaying, let time = node.lastRenderTime, let player = node.playerTime(forNodeTime: time) else { return 0 }
        return max(0, Double(player.sampleTime) / player.sampleRate - latency)
    }

    func prepare(url: URL, done: @escaping @MainActor (Bool) -> Void) {
        decodeTask?.cancel()
        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            // 아주 긴 믹스 파일은 메모리를 너무 많이 써서 덱처럼 풀지 않는다.
            let length = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
            let decoded = length <= DecodedAudio.maxDuration ? DecodedAudio.decode(url: url) : nil
            guard !Task.isCancelled else { return }
            await self?.adopt(decoded, done: done)
        }
    }

    private func adopt(_ decoded: DecodedAudio?, done: @MainActor (Bool) -> Void) {
        if let decoded {
            engine.connect(node, to: engine.mainMixerNode, format: decoded.buffer.format)
            engine.prepare()
            self.decoded = decoded
        }
        done(decoded != nil)
    }

    func play(_ items: [EditPlaybackItem], from frame: Int64, volume: Float) -> Bool {
        guard let decoded else { return false }
        node.stop()
        if !engine.isRunning {
            do { try engine.start() } catch {
                started = false
                return false
            }
        }
        let rate = decoded.buffer.format.sampleRate
        for item in items.starting(at: frame) {
            let at = item.outputFrame - frame
            if item.fade != nil {
                guard let buffer = EditRenderer.playbackBuffer(item, source: decoded.buffer) else { continue }
                node.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: at, atRate: rate), options: [], completionHandler: nil)
            } else {
                // 원곡 안쪽만 복사 없이 예약한다. 앞뒤 빈자리는 예약하지 않아 무음이다.
                let first = max(item.sourceFrame, 0), last = min(item.sourceFrame + item.frameCount, decoded.frameCount)
                guard first < last, let segment = decoded.segment(from: first, to: last) else { continue }
                node.scheduleBuffer(segment, at: AVAudioTime(sampleTime: at + first - item.sourceFrame, atRate: rate),
                                    options: [], completionHandler: nil)
            }
        }
        node.volume = volume
        latency = engine.outputNode.presentationLatency
        node.play()
        started = true
        return true
    }

    func stop() {
        node.stop()
        started = false
        if engine.isRunning { engine.stop() }
    }

    func close() {
        stop()
        decodeTask?.cancel()
        decodeTask = nil
        decoded = nil
    }
}
