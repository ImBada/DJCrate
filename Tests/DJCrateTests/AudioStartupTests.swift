@testable import DJCrate
import DJCDomain
import DJCTestSupport
import Foundation
import Testing

/// coreaudiod가 응답하지 않아 출력 장치를 여는 호출이 끝나지 않아도 덱·편집 창이 메인 스레드를 막지 않는다(#142).
/// 엔진 만들기를 주입해 끝나지 않는 준비를 흉내 낸다(실제 오디오 장치는 열지 않는다).
@MainActor
@Suite(.serialized)
struct AudioStartupTests {
    /// 엔진 만들기가 `release()`(또는 3초)까지 끝나지 않는다. 만들지 못한 것(nil)으로 끝난다.
    final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        func wait() {
            lock.withLock { count += 1 }
            _ = semaphore.wait(timeout: .now() + 3)
        }
        func release() { semaphore.signal() }
    }

    /// 만들기를 부른 횟수만 센다(바로 nil).
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        func hit() { lock.withLock { count += 1 } }
    }

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// 합성 WAV 곡 한 줄(파일은 시험이 끝나면 지운다)
    static func row(in root: URL) throws -> TrackRow {
        let url = try AudioFixture.wav(seconds: 1, in: root)
        let track = Track(id: "1", uuid: "audio-startup", title: "오디오 준비 시험", artist: nil, album: nil, albumArtist: nil,
                          genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 1,
                          folderPath: url.path, comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
        return TrackRow(track: track, cues: [], playCount: 0, autoGain: nil)
    }

    static func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-audio-startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func deckIsReadyWithoutWaitingForOutputDevice() {
        let gate = Gate()
        defer { gate.release() }
        let started = Self.now()
        let deck = DeckModel(audio: DeckAudio(makeGraph: { gate.wait(); return nil }), storage: .memory(MemoryDrafts()),
                             runsAnalysis: false)
        let elapsed = Self.now() - started
        #expect(elapsed < 0.5, "덱 준비가 출력 장치를 기다렸다: \(elapsed)초")
        #expect(deck.audio.isOutputUnavailable)
    }

    @Test func playIsBlockedWithGuidanceUntilOutputIsReady() async throws {
        let gate = Gate()
        defer { gate.release() }
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = DeckAudio(makeGraph: { gate.wait(); return nil })
        let deck = DeckModel(audio: audio, storage: .memory(MemoryDrafts()), runsAnalysis: false)
        // 출력이 준비되기 전에도 곡은 불러 둔다(파형·큐 편집은 그대로 쓴다).
        deck.load(try Self.row(in: root))
        #expect(deck.canPlay)
        #expect(abs(deck.duration - 1) < 0.01)

        deck.togglePlay()
        #expect(!deck.isPlaying)
        #expect(!audio.isPlaying)
        #expect(deck.toast?.text == DeckModel.audioUnavailableMessage)
        #expect(deck.toast?.kind == .warning)
    }

    @Test func failedPreparationRetriesOnNextPlay() async throws {
        let counter = Counter()
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = DeckAudio(makeGraph: { counter.hit(); return nil })
        for _ in 0..<200 where counter.calls < 1 || !audio.isOutputUnavailable { try await Task.sleep(for: .milliseconds(5)) }
        // 첫 준비가 끝나(실패) 메인 액터로 결과가 돌아올 때까지
        for _ in 0..<50 { await Task.yield() }
        let deck = DeckModel(audio: audio, storage: .memory(MemoryDrafts()), runsAnalysis: false)
        deck.load(try Self.row(in: root))
        deck.togglePlay()
        #expect(!deck.isPlaying)
        #expect(deck.toast?.text == DeckModel.audioUnavailableMessage)
        // 막힌 재생은 출력 준비를 다시 시도한다(장치가 돌아왔으면 다음 재생에 쓴다).
        for _ in 0..<200 where counter.calls < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(counter.calls == 2)
    }

    @Test func editPlayerPreparesWithoutBlockingMainActor() async throws {
        let gate = Gate()
        defer { gate.release() }
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try AudioFixture.wav(seconds: 1, in: root)

        let started = Self.now()
        let player = EditAudioPlayer(makeGraph: { gate.wait(); return nil })
        // 메인 액터가 멈추지 않는지 10ms마다 잰다(준비가 메인 액터에서 장치를 기다리면 간격이 벌어진다).
        var longest = Self.now() - started
        var ready: Bool?
        player.prepare(url: url) { ready = $0 }
        var last = Self.now()
        for _ in 0..<150 where ready == nil {
            try await Task.sleep(for: .milliseconds(10))
            longest = max(longest, Self.now() - last)
            last = Self.now()
        }
        #expect(ready == true, "원곡을 메모리에 풀지 못함")
        #expect(longest < 0.5, "편집 창 재생기가 메인 액터를 \(longest)초 막았다")
        // 출력 장치가 준비되지 않았으면 재생만 막힌다(부른 쪽이 안내를 띄운다).
        #expect(!player.play([EditPlaybackItem(outputFrame: 0, frameCount: 44_100, sourceFrame: 0)], from: 0, volume: 0.5))
        #expect(!player.isPlaying)
    }
}
