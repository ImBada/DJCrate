@testable import DJCrate
import DJCDomain
import Foundation
import Testing

/// 재생 퀀타이즈(#90): 재생 중 핫큐(버튼·단축키·메뉴 모두 `pressHotCue`)는 누른 뒤 다음 박 조각 경계에서 넘어가고,
/// 경계의 박 안 위치를 큐 쪽에서도 지킨다. 120 BPM(0.5초부터 박), 핫큐 A 30초, 핫큐 B 40~42초 루프.
@MainActor
@Suite("덱 — 재생 퀀타이즈")
struct DeckPlayQuantizeTests {
    func harness(grid: Bool = true) throws -> DeckHarness {
        let a = Cue(id: "A", contentID: "1", kind: 1, inMsec: 30_000, name: "", colorTableIndex: 0)
        let b = Cue(id: "B", contentID: "1", kind: 2, inMsec: 40_000, name: "", colorTableIndex: 0,
                    outMsec: 42_000, color: 255, beatLoopSize: 4 << 16 | 1)
        return grid ? try DeckHarness(cues: [a, b]) : try DeckHarness(cues: [a, b], grid: nil)
    }

    /// 10.6초에서 재생 중
    func playing(_ h: DeckHarness) {
        h.deck.seek(10.6)
        h.deck.togglePlay()
    }

    @Test func 기본은_켜져_있고_4분의1박이다() async throws {
        let h = try harness()
        #expect(h.deck.playQuantize)
        #expect(h.deck.playQuantizeBeats == 0.25)
    }

    @Test func 재생_중_핫큐는_다음_경계에서_넘어가게_예약한다() async throws {
        let h = try harness()
        try await h.loaded()
        playing(h)
        h.deck.pressHotCue(slot: 0)
        // 10.6초 = 20.2박째 → 20.25박째(10.625초)에 30초 + ¼박(0.125초)으로
        #expect(h.audio.log.last == "jump 10.625→30.125")
        #expect(!h.audio.log.contains("play 30.000"), "바로 다시 재생하지 않는다")
        #expect(h.deck.isPlaying)
        #expect(h.deck.selectedCueID == h.deck.hotCue(slot: 0)?.id)
    }

    @Test func 한_박_단위면_다음_박에서_정확히_큐로() async throws {
        let h = try harness()
        try await h.loaded()
        h.deck.playQuantizeBeats = 1
        playing(h)
        h.deck.pressHotCue(slot: 0)
        #expect(h.audio.log.last == "jump 11.000→30.000")
    }

    @Test func 멈춰_있으면_바로_큐로() async throws {
        let h = try harness()
        try await h.loaded()
        h.deck.seek(10.6)
        h.deck.pressHotCue(slot: 0)
        #expect(h.deck.playhead == 30)
        #expect(!h.audio.log.contains { $0.hasPrefix("jump") })
    }

    @Test func 끄면_누르는_즉시_넘어간다() async throws {
        let h = try harness()
        try await h.loaded()
        h.deck.playQuantize = false
        playing(h)
        h.deck.pressHotCue(slot: 0)
        #expect(h.audio.log.last == "play 30.000")
    }

    @Test func 그리드가_없으면_누르는_즉시_넘어간다() async throws {
        let h = try harness(grid: false)
        try await h.loaded()
        playing(h)
        h.deck.pressHotCue(slot: 0)
        #expect(h.audio.log.last == "play 30.000")
    }

    @Test func 루프_핫큐는_착지한_뒤_그_루프를_되풀이한다() async throws {
        let h = try harness()
        try await h.loaded()
        playing(h)
        h.deck.pressHotCue(slot: 1)
        let loopCue = try #require(h.deck.hotCue(slot: 1))
        #expect(h.audio.log.last == "jump 10.625→40.125 loop 40.000~42.000")
        #expect(h.deck.engagedLoopID == loopCue.id && h.audio.loop == 40...42)
        // 다음 틱이 루프를 다시 걸어 예약을 지우지 않는다
        h.deck.tick()
        #expect(h.audio.log.last == "jump 10.625→40.125 loop 40.000~42.000")
    }

    @Test func 즉석_루프_중에_누르면_경계에서_루프를_빠져나가_큐로() async throws {
        let h = try harness()
        try await h.loaded()
        h.deck.seek(10.5)
        h.deck.toggleLoop()
        h.deck.togglePlay()
        h.audio.position = 10.6
        h.deck.pressHotCue(slot: 0)
        #expect(h.audio.log.last == "jump 10.625→30.125")
        #expect(!h.deck.isLooping && h.audio.loop == nil)
        h.deck.tick()
        #expect(h.audio.log.last == "jump 10.625→30.125", "틱이 루프 나가기를 따로 예약하지 않는다")
    }

    @Test func 앞으로_건너뛴_구간의_활성_루프는_걸지_않는다() async throws {
        // 20~24초 활성 루프를 사이에 두고 10.6초 → 30초 핫큐. 오디오가 경계에서 넘기면 틱은 10.6 → 30.1로 뛴 것을 본다.
        let a = Cue(id: "A", contentID: "1", kind: 1, inMsec: 30_000, name: "", colorTableIndex: 0)
        let active = Cue(id: "L", contentID: "1", kind: 0, inMsec: 20_000, name: "", colorTableIndex: nil,
                         outMsec: 24_000, activeLoop: 1, beatLoopSize: 8 << 16 | 1)
        let h = try DeckHarness(cues: [a, active])
        try await h.loaded()
        playing(h)
        h.deck.pressHotCue(slot: 0)
        h.audio.position = 10.62
        h.deck.tick()
        h.audio.hasPendingJump = false
        h.audio.position = 30.15
        h.deck.tick()
        #expect(h.deck.engagedLoopID == nil && h.audio.loop == nil, "건너뛴 활성 루프가 걸렸다")
        // 그 뒤 평소처럼 활성 루프 시작을 지나가면 건다
        h.deck.seek(19.9)
        h.audio.position = 20.1
        h.deck.tick()
        #expect(h.deck.engagedLoopID != nil)
    }

    @Test func 오디오가_샘플_단위로_못_하면_화면_틱이_경계에서_넘긴다() async throws {
        let h = try harness()
        try await h.loaded()
        h.audio.schedulesJumps = false
        playing(h)
        h.deck.pressHotCue(slot: 0)
        #expect(h.deck.pendingJump?.jump == PlayQuantize.Jump(at: 10.625, to: 30.125))
        #expect(h.audio.log.last == "play 10.600")
        h.audio.position = 10.62
        h.deck.tick()
        #expect(h.audio.log.last == "play 10.600", "경계 전에는 넘어가지 않는다")
        h.audio.position = 10.63
        h.deck.tick()
        // 틱이 늦은 만큼(5ms) 착지 뒤에서 이어 간다
        #expect(h.audio.log.last == "play 30.130")
        #expect(h.deck.pendingJump == nil)
    }

    @Test func 넘어가기_전에_멈추면_예약을_버린다() async throws {
        let h = try harness()
        try await h.loaded()
        h.audio.schedulesJumps = false
        playing(h)
        h.deck.pressHotCue(slot: 0)
        h.deck.togglePlay()
        #expect(h.deck.pendingJump == nil)
        h.deck.togglePlay()
        h.audio.position = 11
        h.deck.tick()
        #expect(!h.audio.log.contains("play 30.125") && !h.audio.log.contains { $0.hasPrefix("play 30.") })
    }

    @Test func 루프_다음_바퀴에서_점프해도_착지를_알아본다() throws {
        let h = try harness()
        h.deck.scheduledJump = .init(at: 40, to: 30)
        h.deck.playhead = 30.1
        #expect(h.deck.landedPosition(previous: 41.99) == 30.1)
        #expect(h.deck.scheduledJump == nil)
    }

    @Test func 화면_틱이_늦어져도_착지를_알아본다() throws {
        let h = try harness()
        h.deck.scheduledJump = .init(at: 10.625, to: 30.125)
        h.deck.playhead = 30.9
        #expect(h.deck.landedPosition(previous: 10.6) == 30.9)
        #expect(h.deck.scheduledJump == nil)
    }

    @Test func 버퍼가_준비되기_전_다른_핫큐를_누르면_마지막_요청만_남는다() async throws {
        let h = try harness()
        try await h.loaded()
        h.audio.schedulesJumps = false
        playing(h)
        h.deck.pressHotCue(slot: 0)
        h.deck.pressHotCue(slot: 1)
        #expect(h.deck.pendingJump?.loopCueID == h.deck.hotCue(slot: 1)?.id)
        h.audio.position = 10.63
        h.deck.tick()
        #expect(h.audio.log.last == "play 40.130")
        #expect(h.audio.loop == 40...42)
    }

    @Test func 예약_뒤_탐색하면_이전_점프를_버린다() async throws {
        let h = try harness()
        try await h.loaded()
        playing(h)
        h.deck.pressHotCue(slot: 0)
        h.deck.seek(15)
        #expect(h.deck.scheduledJump == nil && h.deck.pendingJump == nil)
        #expect(h.audio.log.last == "play 15.000")
    }

    @Test func 루프_핫큐_예약_뒤_멈추면_도착_전_루프를_남기지_않는다() async throws {
        let h = try harness()
        try await h.loaded()
        playing(h)
        h.deck.pressHotCue(slot: 1)
        h.deck.togglePlay()
        #expect(!h.deck.isLooping)
        #expect(h.audio.loop == nil)
        #expect(h.deck.scheduledJump == nil)
        h.deck.togglePlay()
        #expect(!h.audio.handlesLoop)
    }

    @Test func 새_핫큐를_샘플로_예약하지_못하면_옛_오디오_예약도_취소한다() async throws {
        let h = try harness()
        try await h.loaded()
        playing(h)
        h.deck.pressHotCue(slot: 0)
        h.audio.schedulesJumps = false
        h.deck.pressHotCue(slot: 1)
        #expect(!h.audio.hasPendingJump)
        #expect(h.deck.pendingJump?.loopCueID == h.deck.hotCue(slot: 1)?.id)
        #expect(h.audio.log.last == "play 10.600")
    }

    @Test func 예약_뒤_루프_나가기는_점프와_옛_루프_백업도_취소한다() async throws {
        let h = try harness()
        try await h.loaded()
        h.deck.seek(10.5)
        h.deck.toggleLoop()
        h.deck.togglePlay()
        h.audio.position = 10.6
        h.deck.pressHotCue(slot: 0)
        h.deck.exitLoop()
        #expect(h.deck.scheduledJump == nil && !h.audio.hasPendingJump)
        h.deck.togglePlay()
        #expect(!h.deck.isLooping && h.audio.loop == nil)
    }

    @Test func 예약_뒤_루프_크기_조절은_아직_재생_중인_루프에_적용한다() async throws {
        let h = try harness()
        try await h.loaded()
        h.deck.seek(10.5)
        h.deck.toggleLoop()
        h.deck.togglePlay()
        h.audio.position = 10.6
        h.deck.pressHotCue(slot: 1)
        h.deck.resizeLoop(-1)
        #expect(h.deck.scheduledJump == nil && !h.audio.hasPendingJump)
        #expect(h.deck.instantLoop?.start == 10.5)
        #expect(h.audio.loop == 10.5...11.5)
    }

    @Test func 설정은_저장되고_기본값으로_되돌릴_수_있다() async throws {
        let h = try harness()
        h.deck.playQuantize = false
        h.deck.playQuantizeBeats = 0.5
        let reopened = DeckModel(audio: FakeDeckAudio(), storage: h.deck.storage, runsAnalysis: false)
        #expect(!reopened.playQuantize && reopened.playQuantizeBeats == 0.5)
        reopened.resetDeckSettings()
        #expect(reopened.playQuantize && reopened.playQuantizeBeats == PlayQuantize.defaultBeats)
    }

    @Test func 저장된_단위가_고를_수_있는_값이_아니면_기본값() {
        #expect(SettingKeys.playQuantizeBeats.value(from: 0.3) == PlayQuantize.defaultBeats)
        #expect(SettingKeys.playQuantizeBeats.value(from: 1.0) == 1)
        #expect(SettingKeys.all.contains(SettingKeys.playQuantize.name))
        #expect(SettingKeys.all.contains(SettingKeys.playQuantizeBeats.name))
    }
}
