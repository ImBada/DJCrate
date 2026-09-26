import AVFoundation
import Foundation
import Testing
@testable import djc

@Suite("두 번째 파형 합성 실험")
struct WaveformProbeTests {
    @Test func 모든_구간은_겹침과_나이퀴스트_초과_없이_음원_안에_있다() {
        for track in AudioLab.waveformProbe2Tracks() {
            var end = 0
            for part in track.segments {
                #expect(part.startFrame >= end && part.frameCount > 0)
                #expect(part.frequencies.count == part.amplitudes.count)
                #expect(part.frequencies.allSatisfy { $0 > 0 && $0 < Double(track.sampleRate) / 2 })
                #expect(part.amplitudes.allSatisfy { $0 >= 0 } && part.amplitudes.reduce(0, +) <= 1)
                end = part.startFrame + part.frameCount
                #expect(end <= track.frameCount)
            }
        }
    }

    @Test func 경계_주파수는_두_샘플레이트에서_같다() throws {
        let tracks = AudioLab.waveformProbe2Tracks()
        #expect(Set(tracks.map(\.sampleRate)) == [44_100, 48_000])
        #expect(Set(tracks.map(\.name)).count == tracks.count)
        for rate in [44_100, 48_000] {
            let boundaries = tracks.filter { $0.sampleRate == rate && $0.name.contains("boundary") }
            let expected = stride(from: 100, through: 350, by: 25).map(Double.init)
                + stride(from: 500, through: 3000, by: 100).map(Double.init)
                + stride(from: 8000, through: 20000, by: 1000).map(Double.init)
            #expect(boundaries.flatMap(\.segments).flatMap(\.frequencies).sorted() == expected.sorted())
            for track in boundaries {
                #expect(track.segments.allSatisfy { $0.frameCount == 2 * rate })
                for pair in zip(track.segments, track.segments.dropFirst()) {
                    #expect(pair.1.startFrame - pair.0.startFrame == 4 * rate)
                }
            }
        }
    }

    @Test func 혼합은_비율만_바꾸고_포화되지_않는다() throws {
        let track = try #require(AudioLab.waveformProbe2Tracks().first { $0.name == "probe2-mix-44100" })
        for frequencies in [[150.0, 300], [1000.0, 2500], [2500.0, 8000]] {
            let segments = track.segments.filter { $0.frequencies == frequencies }
            #expect(segments.map { $0.amplitudes[1] / $0.amplitudes[0] } == [0, 0.125, 0.25, 0.5, 0.75, 1])
            #expect(segments.allSatisfy { $0.amplitudes.reduce(0, +) <= 0.5 })
        }
    }

    @Test func 고역_진폭은_같은_주파수에서_문턱을_가른다() throws {
        let track = try #require(AudioLab.waveformProbe2Tracks().first { $0.name == "probe2-amplitude-48000" })
        let expected: [Double] = [1.0 / 256, 1.0 / 128, 1.0 / 64, 1.0 / 32, 1.0 / 16, 0.125, 0.25, 0.5, 0.75, 1]
        for hz in [1000.0, 2500, 8000, 12000, 16000] {
            let segments = track.segments.filter { $0.frequencies == [hz] }
            #expect(segments.map { $0.amplitudes[0] } == expected)
        }
    }

    @Test func 정규화_대조군은_지정한_조건만_바뀐다() throws {
        let tracks = AudioLab.waveformProbe2Tracks().filter { $0.sampleRate == 44_100 }
        func get(_ suffix: String) throws -> AudioLab.WaveformProbe2Track {
            try #require(tracks.first { $0.name == "probe2-normalize-\(suffix)-44100" })
        }
        let base = try get("base"), silence = try get("silence"), loud = try get("loud"), repeated = try get("repeat")
        #expect(silence.segments == base.segments && silence.frameCount == base.frameCount + 10 * 44_100)
        #expect(Array(loud.segments.prefix(base.segments.count)) == base.segments)
        #expect(loud.frameCount == base.frameCount)
        #expect(loud.segments.last?.amplitudes == [1])
        #expect(repeated.frameCount == base.frameCount)
        #expect(Array(repeated.segments.prefix(base.segments.count)) == base.segments)
        #expect(repeated.segments.count == base.segments.count * 2)
    }

    @Test func 버스트는_칸_경계의_네_위상과_1부터_100ms를_기록한다() throws {
        for rate in [44_100, 48_000] {
            let track = try #require(AudioLab.waveformProbe2Tracks().first { $0.name == "probe2-burst-\(rate)" })
            #expect(track.segments.count == 3 * 8 * 4)
            #expect(Set(track.segments.map { $0.startFrame % (rate / 150) }) ==
                Set([0, 0.25, 0.5, 0.75].map { Int((Double(rate) / 150 * $0).rounded()) }))
            #expect(Set(track.segments.map(\.frameCount)) ==
                Set([0.001, 0.002, 0.005, 0.01, 0.02, 0.033, 0.05, 0.1].map { Int(($0 * Double(rate)).rounded()) }))
        }
    }

    @Test func WAV는_명세대로_무음과_혼합을_쓰고_덮어쓰지_않는다() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "probe-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = AudioLab.WaveformProbe2Track(name: "probe2-test", sampleRate: 48_000, frameCount: 1000, segments: [
            .init(label: "혼합", startFrame: 320, frameCount: 480, frequencies: [1000, 2500], amplitudes: [0.25, 0.125])
        ])
        try AudioLab.writeWaveformProbe2(track, to: root)
        let url = root.appending(path: "probe2-test.wav")
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 1000 && file.processingFormat.sampleRate == 48_000)
        #expect(file.processingFormat.channelCount == 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1000))
        try file.read(into: buffer)
        let channels = try #require(buffer.floatChannelData)
        for i in 0..<1000 {
            let t = Double(i - 320) / 48_000
            let expected = (320..<800).contains(i) ? 0.25 * sin(2 * .pi * 1000 * t) + 0.125 * sin(2 * .pi * 2500 * t) : 0
            #expect(abs(Double(channels[0][i]) - expected) < 1.0 / 32768)
            #expect(channels[0][i] == channels[1][i])
        }
        let before = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { try AudioLab.writeWaveformProbe2(track, to: root) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func 잘못된_묶음은_출력_폴더를_만들기_전에_거부한다() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "probe-test-\(UUID())")
        for suffix in [["--suite", "3"], ["--suite"]] {
            await #expect(throws: (any Error).self) {
                try await AudioLab.waveformProbe(["waveform-probe", "--out", root.path] + suffix)
            }
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }
}
