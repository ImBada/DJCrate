import DJCDomain
import Testing

@Suite("#107 다음 큰 박선에서 저장 핫큐로")
struct QuantizeBoundaryRegressionTests {
    @Test(arguments: [120.0, 180.0], [0.25, 0.5, 1.0])
    func 기존_단위에_관계없이_현재_박을_끝까지_재생한다(bpm: Double, legacyBeats: Double) throws {
        let period = 60 / bpm
        let grid = BeatGrid(beats: (0..<100).map {
            .init(number: $0 % 4 + 1, bpm: bpm, time: Double($0) * period)
        })
        let q = try #require(PlayQuantize(grid: grid, beats: legacyBeats))
        // 기대는 제품의 boundary/landing 계산을 사용하지 않고 실제 그리드 선과 저장 큐로 정한다.
        for cue in [10.0, 10.1, 59.99] {
            let jump = q.jump(earliest: period * 0.2, to: cue)
            #expect(abs(jump.at - period) < 1e-9)
            #expect(jump.to == cue)
        }
    }

    @Test(arguments: [120.0, 180.0], [0.25, 0.5, 1.0])
    func 경계_전후와_렌더_여유를_구분한다(bpm: Double, legacyBeats: Double) throws {
        let rate = 48_000.0
        let beatFrames = Int64(rate * 60 / bpm)
        let grid = BeatGrid(beats: (0..<100).map {
            .init(number: $0 % 4 + 1, bpm: bpm, time: Double($0) * 60 / bpm)
        })
        let q = try #require(PlayQuantize(grid: grid, beats: legacyBeats))
        let flow = PlaybackSchedule(sampleRate: rate, timelineOffset: 0, startLinear: 0,
                                    pieces: [.init(node: 0, frame: 0, loop: nil)])
        for (ahead, expected) in [(beatFrames - 48, beatFrames), (beatFrames, beatFrames),
                                  (beatFrames + 48, 2 * beatFrames), (beatFrames - 48 + 1024, 2 * beatFrames)] {
            let plan = try #require(JumpPlanner.plan(schedule: flow, ahead: ahead, quantize: q,
                                                     cue: 10.1, loop: nil, frameCount: 2_880_000))
            #expect(plan.buffers.first?.at == expected)
            #expect(plan.buffers.first?.from == 484_800)
            #expect(plan.buffers[0].at >= ahead, "이미 렌더한 경계를 소급 예약하지 않는다")
        }
    }

    @Test func 변속과_인코더_지연에서도_큰_박선과_저장큐를_쓴다() throws {
        let grid = BeatGrid(beats: [0.0, 1, 2, 2.5, 3].enumerated().map {
            .init(number: $0.offset % 4 + 1, bpm: $0.element < 2 ? 60 : 120, time: $0.element)
        })
        let q = try #require(PlayQuantize(grid: grid, beats: 0.25))
        #expect(q.jump(earliest: 1.1, to: 2.1) == .init(at: 2, to: 2.1))
        #expect(q.jump(earliest: 2.1, to: 1.1) == .init(at: 2.5, to: 1.1))
        let flow = PlaybackSchedule(sampleRate: 48_000, timelineOffset: 0.024, startLinear: 1.024,
                                    pieces: [.init(node: 0, frame: 48_000, loop: nil)])
        let plan = try #require(JumpPlanner.plan(schedule: flow, ahead: 4_000, quantize: q,
                                                 cue: 2.1, loop: nil, frameCount: 480_000))
        #expect(plan.buffers.first?.at == 46_848)
        #expect(plan.buffers.first?.from == 99_648)
    }

    @Test(arguments: [44_100.0, 48_000.0], [0.5, 1.0, 2.0])
    func 샘플레이트와_재생속도를_바꿔도_큰_박의_샘플에_예약한다(sampleRate: Double, rate: Double) throws {
        let grid = BeatGrid(beats: (0..<100).map {
            .init(number: $0 % 4 + 1, bpm: 120, time: Double($0) * 0.5)
        })
        let q = try #require(PlayQuantize(grid: grid, beats: 0.25))
        let flow = PlaybackSchedule(sampleRate: sampleRate, timelineOffset: 0.024, startLinear: 1.024,
                                    pieces: [.init(node: 0, frame: Int64(sampleRate), loop: nil)])
        let lead = JumpPlanner.renderLeadFrames(bufferFrames: 512, outputSampleRate: 48_000, sampleRate: sampleRate, rate: rate)
        let rendered = Int64((0.076 * sampleRate).rounded()) // 곡 위치 1.100초
        let plan = try #require(JumpPlanner.plan(schedule: flow, ahead: rendered + lead, quantize: q,
                                                 cue: 10, loop: nil, frameCount: Int64(sampleRate * 60)))
        #expect(plan.buffers.first?.at == Int64((0.476 * sampleRate).rounded()))
        #expect(plan.buffers.first?.from == Int64((9.976 * sampleRate).rounded()))
    }
}
