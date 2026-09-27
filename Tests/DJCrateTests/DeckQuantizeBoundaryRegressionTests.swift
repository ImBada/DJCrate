@testable import DJCrate
import DJCDomain
import Foundation
import Testing

@MainActor
@Suite("덱 — #107 큰 박 경계")
struct DeckQuantizeBoundaryRegressionTests {
    @Test(arguments: [0.25, 0.5, 1.0], [false, true])
    func 이전_설정과_예약방식에_관계없이_다음_큰_박까지_기다린다(legacyBeats: Double, sampleAccurate: Bool) async throws {
        let cue = Cue(id: "A", contentID: "1", kind: 1, inMsec: 30_000, name: "", colorTableIndex: 0)
        let h = try DeckHarness(cues: [cue])
        try await h.loaded()
        h.deck.playQuantizeBeats = legacyBeats
        h.audio.schedulesJumps = sampleAccurate
        h.deck.seek(10.6)
        h.deck.togglePlay()
        h.deck.pressHotCue(slot: 0)
        if sampleAccurate {
            #expect(h.deck.scheduledJump == .init(at: 11, to: 30))
            #expect(h.audio.log.last == "jump 11.000→30.000")
        } else {
            #expect(h.deck.pendingJump?.jump == .init(at: 11, to: 30))
            h.audio.position = 10.999
            h.deck.tick()
            #expect(h.audio.log.last == "play 10.600", "큰 박선 전에는 원래 구간을 재생한다")
            h.audio.position = 11.02
            h.deck.tick()
            #expect(h.audio.log.last == "play 30.020", "화면 틱이 늦은 20ms만 보상한다")
            #expect(h.deck.pendingJump == nil)
        }
    }
}
