@testable import DJCDomain
import Testing

/// 재생 퀀타이즈(#90): 재생 중 핫큐는 누른 뒤 다음 박 조각(1/4·1/2·1박) 경계에서 넘어가고,
/// 그 경계의 박 안 위치를 큐 쪽에서도 지켜 착지한다(1박 단위면 정확히 큐).
@Suite("재생 퀀타이즈")
struct PlayQuantizeTests {
    /// 120 BPM(0.5초 간격), 0.5초에서 시작하는 100박(마지막 박 50초)
    let grid = BeatGrid(beats: (0..<100).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: 120, time: 0.5 + Double($0) * 0.5) })

    func quantize(_ beats: Double, grid: BeatGrid? = nil) throws -> PlayQuantize {
        try #require(PlayQuantize(grid: grid ?? self.grid, beats: beats))
    }

    @Test func 기본_단위는_rekordbox처럼_4분의1박이고_고를_수_있는_단위는_셋() {
        #expect(PlayQuantize.defaultBeats == 0.25)
        #expect(PlayQuantize.choices == [0.25, 0.5, 1])
    }

    @Test func 그리드가_없거나_단위가_잘못되면_퀀타이즈하지_않는다() {
        #expect(PlayQuantize(grid: nil, beats: 0.25) == nil)
        #expect(PlayQuantize(grid: BeatGrid(beats: []), beats: 0.25) == nil)
        #expect(PlayQuantize(grid: grid, beats: 0) == nil)
        #expect(PlayQuantize(grid: grid, beats: .nan) == nil)
    }

    @Test func 다음_경계는_단위마다_다르다() throws {
        // 1.1초 = 1.2박째(박 0 = 0.5초)
        let quarter = try quantize(0.25).boundary(atOrAfter: 1.1)
        #expect(abs(quarter.time - 1.125) < 1e-9)
        #expect(quarter.phase == 0.25)
        let half = try quantize(0.5).boundary(atOrAfter: 1.1)
        #expect(abs(half.time - 1.25) < 1e-9)
        #expect(half.phase == 0.5)
        let beat = try quantize(1).boundary(atOrAfter: 1.1)
        #expect(abs(beat.time - 1.5) < 1e-9)
        #expect(beat.phase == 0)
    }

    @Test func 경계_위에서는_그_경계다() throws {
        let q = try quantize(0.25)
        #expect(abs(q.boundary(atOrAfter: 1.125).time - 1.125) < 1e-9)
        #expect(abs(q.boundary(atOrAfter: 1.5).time - 1.5) < 1e-9)
        #expect(q.boundary(atOrAfter: 1.5).phase == 0)
    }

    @Test func 박_끝_바로_앞이면_다음_박이_경계다() throws {
        let b = try quantize(0.25).boundary(atOrAfter: 1.49)
        #expect(abs(b.time - 1.5) < 1e-9)
        #expect(b.phase == 0)
    }

    @Test func 첫_박_앞과_마지막_박_뒤는_그_박_길이로_늘려_센다() throws {
        let q = try quantize(0.25)
        // 0.2초 = -0.6박 → 다음 ¼ 경계는 -0.5박(0.25초), 박 안 위치 ½
        let before = q.boundary(atOrAfter: 0.2)
        #expect(abs(before.time - 0.25) < 1e-9)
        #expect(before.phase == 0.5)
        // 50.3초 = 마지막 박(50초) + 0.6박 → 50.375초
        let after = q.boundary(atOrAfter: 50.3)
        #expect(abs(after.time - 50.375) < 1e-9)
        #expect(after.phase == 0.75)
    }

    @Test func 변속_그리드는_그_박의_길이로_나눈다() throws {
        // 0~2초 1초 간격(60BPM), 그 뒤 0.5초 간격(120BPM)
        let times = [0.0, 1, 2, 2.5, 3, 3.5]
        let variable = BeatGrid(beats: times.enumerated().map { BeatGrid.Beat(number: $0.offset % 4 + 1, bpm: $0.element < 2 ? 60 : 120, time: $0.element) })
        let q = try quantize(0.25, grid: variable)
        #expect(abs(q.boundary(atOrAfter: 1.1).time - 1.25) < 1e-9)
        #expect(abs(q.boundary(atOrAfter: 2.1).time - 2.125) < 1e-9)
    }

    @Test func 착지는_큐에서_경계의_박_안_위치만큼_뒤다() throws {
        // 1.1초에 누름 → 1.125초(¼)에 넘어가 10초 큐 + ¼박(0.125초)에 내린다
        let jump = try quantize(0.25).jump(earliest: 1.1, to: 10)
        #expect(abs(jump.at - 1.125) < 1e-9)
        #expect(abs(jump.to - 10.125) < 1e-9)
    }

    @Test func 한_박_단위면_다음_박에서_정확히_큐로() throws {
        let jump = try quantize(1).jump(earliest: 1.1, to: 10)
        #expect(abs(jump.at - 1.5) < 1e-9)
        #expect(jump.to == 10)
    }

    @Test func 박에서_벗어난_큐는_그_어긋남을_그대로_둔다() throws {
        // 큐 10.1초 = 19.2박째 → 19.45박째(10.225초)에 내린다
        let jump = try quantize(0.25).jump(earliest: 1.1, to: 10.1)
        #expect(abs(jump.to - 10.225) < 1e-9)
    }

    @Test func 착지가_루프_끝을_넘으면_큐에_내린다() throws {
        let q = try quantize(0.5)
        #expect(q.jump(earliest: 1.1, to: 10, loopEnd: 10.2).to == 10)
        #expect(abs(q.jump(earliest: 1.1, to: 10, loopEnd: 12).to - 10.25) < 1e-9)
    }
}

/// 재생 퀀타이즈 점프를 재생 노드에 예약하는 계획. 48kHz(1박 = 24000프레임, ¼박 = 6000), 120BPM 그리드.
/// 나중에 예약한 interrupts 버퍼가 그 시각에 앞서 예약한 미래 버퍼(루프 몸통 포함)를 모두 지운다(2026-09-27 오프라인 렌더 실험).
@Suite("재생 퀀타이즈 점프 계획")
struct JumpPlannerTests {
    let sr: Int64 = 48_000
    let grid = BeatGrid(beats: (0..<100).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: 120, time: 0.5 + Double($0) * 0.5) })
    /// 곡 1초(프레임 48000)에서 재생 시작
    var straight: PlaybackSchedule {
        PlaybackSchedule(sampleRate: 48_000, timelineOffset: 0, startLinear: 1, pieces: [PlaybackPiece(node: 0, frame: sr, loop: nil)])
    }
    let songFrames: Int64 = 48_000 * 60

    func quantize(_ beats: Double) throws -> PlayQuantize { try #require(PlayQuantize(grid: grid, beats: beats)) }

    @Test func 빠른_곡도_렌더_여유_밖의_바로_다음_4분의1박에_예약한다() throws {
        let fastGrid = BeatGrid(beats: (0..<100).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: 180, time: Double($0) / 3) })
        let q = try #require(PlayQuantize(grid: fastGrid, beats: 0.25))
        let flow = PlaybackSchedule(sampleRate: 48_000, timelineOffset: 0, startLinear: 0,
                                    pieces: [.init(node: 0, frame: 0, loop: nil)])
        // 180 BPM의 ¼박 = 4000프레임. 렌더 512프레임 두 덩어리 뒤도 첫 경계보다 앞이다.
        let lead = JumpPlanner.renderLeadFrames(bufferFrames: 512, outputSampleRate: 48_000, sampleRate: 48_000, rate: 1)
        let plan = try #require(JumpPlanner.plan(schedule: flow, ahead: 1000 + lead, quantize: q, cue: 10, loop: nil, frameCount: songFrames))
        #expect(plan.buffers.first?.at == 4000)
    }

    @Test func 렌더_여유는_출력과_곡의_샘플레이트_및_재생속도를_따른다() {
        #expect(JumpPlanner.renderLeadFrames(bufferFrames: 512, outputSampleRate: 48_000, sampleRate: 44_100, rate: 2) == 1882)
    }

    @Test func 흐름_중에는_다음_경계_샘플에서_큐_쪽으로_넘어간다() throws {
        // 노드 4800 = 곡 1.1초 → 1.125초(노드 6000)에 10.125초(프레임 486000)로
        let plan = try #require(JumpPlanner.plan(schedule: straight, ahead: 4_800, quantize: quantize(0.25), cue: 10, loop: nil, frameCount: songFrames))
        #expect(plan.buffers == [.init(from: 486_000, to: nil, at: 6_000, interrupts: true, loops: false)])
        #expect(plan.pieces == [PlaybackPiece(node: 0, frame: sr, loop: nil), PlaybackPiece(node: 6_000, frame: 486_000, loop: nil)])
        #expect(abs(plan.jump.at - 1.125) < 1e-9)
        #expect(abs(plan.jump.to - 10.125) < 1e-9)
    }

    @Test func 인코더_지연만큼_곡_위치가_밀린_곡도_같은_경계에서() throws {
        // rekordbox 시간축 = 음원 + 0.024초. 노드 0 = 프레임 48000 = 곡 1.024초
        let shifted = PlaybackSchedule(sampleRate: 48_000, timelineOffset: 0.024, startLinear: 1.024, pieces: [PlaybackPiece(node: 0, frame: sr, loop: nil)])
        let plan = try #require(JumpPlanner.plan(schedule: shifted, ahead: 100, quantize: quantize(1), cue: 10, loop: nil, frameCount: songFrames))
        // 다음 박 1.5초 = 프레임 (1.5 − 0.024) × 48000 = 70848 → 노드 22848, 착지 10초 = 프레임 478848
        #expect(plan.buffers == [.init(from: 478_848, to: nil, at: 22_848, interrupts: true, loops: false)])
    }

    @Test func 루프_핫큐는_착지에서_루프_끝까지_흘린_뒤_되풀이한다() throws {
        // 10~12초 루프, ¼ 경계에서 10.125초에 내림
        let plan = try #require(JumpPlanner.plan(schedule: straight, ahead: 4_800, quantize: quantize(0.25), cue: 10, loop: 10...12, frameCount: songFrames))
        #expect(plan.buffers == [.init(from: 486_000, to: 576_000, at: 6_000, interrupts: true, loops: false),
                                 .init(from: 480_000, to: 576_000, at: 6_000 + 90_000, interrupts: false, loops: true)])
        #expect(plan.pieces.suffix(2) == [PlaybackPiece(node: 6_000, frame: 486_000, loop: nil),
                                          PlaybackPiece(node: 96_000, frame: 480_000, loop: 96_000)])
    }

    @Test func 루프_시작에_내리면_바로_되풀이_버퍼_하나() throws {
        let plan = try #require(JumpPlanner.plan(schedule: straight, ahead: 4_800, quantize: quantize(1), cue: 10, loop: 10...12, frameCount: songFrames))
        #expect(plan.buffers == [.init(from: 480_000, to: 576_000, at: 24_000, interrupts: true, loops: true)])
        #expect(plan.pieces.last == PlaybackPiece(node: 24_000, frame: 480_000, loop: 96_000))
    }

    @Test func 되풀이_중이면_이번_바퀴_안의_다음_경계에서_끊고_넘어간다() throws {
        // 2~3초 루프(48000프레임)가 노드 48000부터 도는 중, 셋째 바퀴 0.3초째(곡 2.3초)
        var looping = straight
        looping.pieces.append(PlaybackPiece(node: sr, frame: 2 * sr, loop: sr))
        let ahead = sr + 2 * sr + 14_400
        let plan = try #require(JumpPlanner.plan(schedule: looping, ahead: ahead, quantize: quantize(0.25), cue: 20, loop: nil, frameCount: songFrames))
        // 2.3초 = 3.6박째 → 3.75박째(2.375초, 노드 +18000), 박 안 ¾ → 20초 + 0.375초
        #expect(plan.buffers == [.init(from: 978_000, to: nil, at: sr + 2 * sr + 18_000, interrupts: true, loops: false)])
        #expect(plan.pieces.count == 3)
    }

    @Test func 이번_바퀴에_경계가_없으면_다음_바퀴에서_찾는다() throws {
        // 2.0~2.1초 루프(¼박 0.125초보다 짧다), 첫 바퀴 0.05초째 → 다음 바퀴 시작(2.0초 = 박 위)에서
        var looping = straight
        looping.pieces.append(PlaybackPiece(node: sr, frame: 2 * sr, loop: 4_800))
        let plan = try #require(JumpPlanner.plan(schedule: looping, ahead: sr + 2_400, quantize: quantize(0.25), cue: 20, loop: nil, frameCount: songFrames))
        #expect(plan.buffers == [.init(from: 960_000, to: nil, at: sr + 4_800, interrupts: true, loops: false)])
    }

    @Test func 박_경계가_없는_루프면_바퀴가_끝날_때_큐로() throws {
        // 2.01~2.1초 루프: 안에 ¼ 경계가 없다 → 바퀴 끝에서 큐 그대로
        var looping = straight
        looping.pieces.append(PlaybackPiece(node: sr, frame: 96_480, loop: 4_320))
        let plan = try #require(JumpPlanner.plan(schedule: looping, ahead: sr + 100, quantize: quantize(0.25), cue: 20, loop: nil, frameCount: songFrames))
        #expect(plan.buffers == [.init(from: 960_000, to: nil, at: sr + 4_320, interrupts: true, loops: false)])
    }

    @Test func 아직_넘어가지_않은_점프가_있으면_새_점프가_그_자리를_대신한다() throws {
        // 노드 6000에 넘어갈 점프가 예약돼 있는데 노드 5000에서 다른 핫큐 → 같은 경계(6000)에서 새 큐로
        var pending = straight
        pending.pieces.append(PlaybackPiece(node: 6_000, frame: 486_000, loop: nil))
        let plan = try #require(JumpPlanner.plan(schedule: pending, ahead: 5_000, quantize: quantize(0.25), cue: 30, loop: nil, frameCount: songFrames))
        #expect(plan.buffers == [.init(from: 1_446_000, to: nil, at: 6_000, interrupts: true, loops: false)])
        #expect(plan.pieces == [PlaybackPiece(node: 0, frame: sr, loop: nil), PlaybackPiece(node: 6_000, frame: 1_446_000, loop: nil)])
    }

    @Test func 곡_끝을_넘는_착지는_계획하지_않는다() throws {
        #expect(try JumpPlanner.plan(schedule: straight, ahead: 4_800, quantize: quantize(0.25), cue: 59.99, loop: nil, frameCount: songFrames) == nil)
    }

    @Test func 경계가_곡_끝_뒤면_계획하지_않는다() throws {
        var near = straight
        near.pieces = [PlaybackPiece(node: 0, frame: songFrames - 100, loop: nil)]
        #expect(try JumpPlanner.plan(schedule: near, ahead: 0, quantize: quantize(1), cue: 10, loop: nil, frameCount: songFrames) == nil)
    }

    @Test func 조각이_없으면_계획하지_않는다() throws {
        var empty = straight
        empty.pieces = []
        #expect(try JumpPlanner.plan(schedule: empty, ahead: 0, quantize: quantize(1), cue: 10, loop: nil, frameCount: songFrames) == nil)
    }
}
