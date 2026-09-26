@testable import DJCrate
import DJCDomain
import Foundation
import Testing

/// 덱 동작(루프·큐·재생·그리드·게인)을 가짜 오디오·메모리 저장소로 확인한다. 120 BPM, 0.5초부터 박, 곡 180초.
@MainActor
@Suite("덱 — 루프")
struct DeckLoopTests {
    @Test func 즉석_루프는_가까운_박에서_걸고_오디오에_알린다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(10.6)
        h.deck.toggleLoop()
        #expect(h.deck.instantLoop == DeckModel.InstantLoop(start: 10.5, end: 12.5, beats: 4))
        #expect(h.audio.loop == 10.5...12.5 && h.deck.isLooping)
    }

    @Test func 반과_두_배는_시작을_두고_끝만_바꾼다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(10.5)
        h.deck.toggleLoop()
        h.deck.resizeLoop(-1)
        #expect(h.deck.loopSize == 2 && h.deck.instantLoop?.end == 11.5 && h.audio.loop == 10.5...11.5)
        h.deck.resizeLoop(1); h.deck.resizeLoop(1)
        #expect(h.deck.loopSize == 8 && h.deck.instantLoop?.end == 14.5)
    }

    @Test func 루프_중에_빈_핫큐를_누르면_루프_핫큐로_저장하고_계속_반복() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(10.5)
        h.deck.toggleLoop()
        h.deck.pressHotCue(slot: 2)
        let stored = try #require(h.deck.hotCue(slot: 2))
        #expect(stored.time == 10.5 && stored.loop == EditableCue.Loop(end: 12.5, active: false, beats: 4))
        #expect(h.deck.instantLoop == nil && h.deck.engagedLoopID == stored.id && h.deck.isLooping)
        #expect(h.drafts.cue("track-1")?.cues.contains { $0.id == stored.id } == true, "초안은 저장된다")
        // 반복 중인 그 칸을 다시 누르면 빠져나온다
        h.deck.pressHotCue(slot: 2)
        #expect(!h.deck.isLooping)
    }

    @Test func 루프_중에_메모리_큐를_누르면_메모리_루프() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(20.5)
        h.deck.toggleLoop()
        h.deck.addMemoryCue()
        let cue = try #require(h.deck.draft?.cues.first { $0.kind == .memory })
        #expect(cue.loop?.end == 22.5 && h.deck.engagedLoopID == cue.id)
    }

    @Test func 다른_자리로_옮기면_루프에서_나간다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(10.5)
        h.deck.toggleLoop()
        h.deck.seek(50)
        #expect(!h.deck.isLooping && h.audio.loop == nil)
        h.deck.toggleLoop()
        h.deck.scrub(to: 80)
        #expect(!h.deck.isLooping, "끌기도 마찬가지")
    }

    @Test func 활성_루프는_재생이_지나가면_걸린다() async throws {
        let active = Cue(id: "L", contentID: "1", kind: 1, inMsec: 20_000, name: "", colorTableIndex: 0,
                         outMsec: 24_000, color: 255, activeLoop: 1, beatLoopSize: 8 << 16 | 1)
        let h = try DeckHarness(cues: [active])
        try await h.loaded()
        h.deck.seek(19)
        h.deck.togglePlay()
        h.audio.position = 20.2
        h.deck.tick()
        #expect(h.deck.engagedLoopID != nil && h.audio.loop == 20...24)
    }
}

@MainActor
@Suite("덱 — 큐")
struct DeckCueTests {
    @Test func 메모리_큐는_자동_큐를_포함해_10개까지() async throws {
        let auto = Cue(id: "a", contentID: "1", kind: 0, inMsec: 500, name: "1.1Bars", colorTableIndex: 0)
        let manual = (1...9).map { Cue(id: "m\($0)", contentID: "1", kind: 0, inMsec: $0 * 10_000, name: "", colorTableIndex: nil) }
        let h = try DeckHarness(cues: [auto] + manual)
        try await h.loaded()
        #expect(h.deck.memoryCueCount == 10)
        h.deck.addMemoryCue(at: 150)
        #expect(h.deck.draft?.cues.filter { $0.kind == .memory }.count == 9)
        #expect(h.deck.toast?.text.contains("10개") == true)
    }

    @Test func 같은_자리_메모리_큐는_새로_만들지_않고_고른다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.addMemoryCue(at: 30.5)
        let first = h.deck.selectedCueID
        h.deck.addMemoryCue(at: 30.51)
        #expect(h.deck.draft?.cues.count == 1 && h.deck.selectedCueID == first)
        #expect(h.deck.deleteMemoryCue(at: 30.49) && h.deck.draft?.cues.isEmpty == true)
    }

    @Test func 반영_중에는_재생을_멈추고_편집을_막았다가_끝나면_이어서() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.togglePlay()
        h.deck.isWriteLocked = true
        #expect(!h.deck.isPlaying)
        h.deck.addMemoryCue(at: 40.5)
        #expect(h.deck.draft?.cues.isEmpty == true, "쓰는 동안 초안은 바뀌지 않는다")
        h.deck.isWriteLocked = false
        #expect(h.deck.isPlaying)
    }
}

@MainActor
@Suite("덱 — 재생")
struct DeckTransportTests {
    @Test func 재생과_멈춤은_오디오_위치를_따른다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(12)
        h.deck.togglePlay()
        #expect(h.deck.isPlaying && h.audio.log.last == "play 12.000")
        h.audio.position = 42
        h.deck.tick()
        #expect(h.deck.playhead == 42)
        h.deck.togglePlay()
        #expect(!h.deck.isPlaying && h.deck.playhead == 42)
    }

    @Test func 곡_끝에_닿으면_멈춘다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.togglePlay()
        h.audio.position = 180
        h.deck.tick()
        #expect(!h.deck.isPlaying)
    }

    @Test func CUE는_멈춘_자리를_큐_지점으로_재생_중이면_돌아가_멈춘다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(30.6)
        h.deck.cueDown(); h.deck.cueUp()
        #expect(h.deck.cuePoint == 30.5, "퀀타이즈로 가까운 박")
        h.deck.togglePlay()
        h.audio.position = 35
        h.deck.tick()
        h.deck.cueDown()
        #expect(!h.deck.isPlaying && h.deck.playhead == 30.5)
    }

    @Test func 조용한_다시_읽기는_소리를_다시_부르지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let row = try #require(h.deck.row)
        let newCue = Cue(id: "n", contentID: "1", kind: 1, inMsec: 60_000, name: "", colorTableIndex: nil)
        h.deck.load(TrackRow(track: row.track, cues: [newCue], playCount: 0))
        for _ in 0..<100 where h.deck.hotCue(slot: 0) == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(h.deck.hotCue(slot: 0)?.time == 60)
        #expect(h.audio.log.filter { $0 == "load" }.count == 1)
    }
}

@MainActor
@Suite("덱 — 그리드·게인")
struct DeckGridGainTests {
    @Test func 그리드를_옮기면_핫큐와_메모리_큐가_따라간다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(20.5)
        h.deck.pressHotCue(slot: 0)
        h.deck.addMemoryCue(at: 40.5)
        h.deck.shiftGrid(ms: 10)
        #expect(abs((h.deck.hotCue(slot: 0)?.time ?? 0) - 20.51) < 1e-6)
        #expect(abs((h.deck.draft?.cues.first { $0.kind == .memory }?.time ?? 0) - 40.51) < 1e-6)
        h.deck.carryCues = false
        h.deck.shiftGrid(ms: 10)
        #expect(abs((h.deck.hotCue(slot: 0)?.time ?? 0) - 20.51) < 1e-6, "끄면 그대로")
    }

    @Test func BPM을_바꾸면_박_위_큐는_새_박_위에_남는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(60.5)
        h.deck.pressHotCue(slot: 0)
        h.deck.addMemoryCue(at: 90.5)
        h.deck.nudgeGridBPM(0.5)
        let grid = try #require(h.deck.grid)
        for time in [h.deck.hotCue(slot: 0)?.time, h.deck.draft?.cues.first { $0.kind == .memory }?.time] {
            let t = try #require(time)
            #expect(abs(grid.snap(t) - t) < 0.002, "새 박 위: \(t)")
        }
        #expect((h.deck.hotCue(slot: 0)?.time ?? 99) < 60.5, "BPM이 빨라지면 뒤쪽 박은 앞으로 온다")
    }

    @Test func 그리드를_되돌리면_큐도_제자리로() async throws {
        let original = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]
        let h = try DeckHarness(grid: original, gridBase: original)
        try await h.loaded()
        h.deck.seek(20.5)
        h.deck.pressHotCue(slot: 0)
        h.deck.shiftGrid(ms: 10)
        h.deck.nudgeGridBPM(0.5)
        h.deck.revertGrid()
        #expect(abs((h.deck.hotCue(slot: 0)?.time ?? 0) - 20.5) < 0.0015)
    }

    @Test func 그리드를_끌면_큐가_마지막_위치만큼_따라간다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(20.5)
        h.deck.pressHotCue(slot: 0)
        h.deck.beginGridDrag(); h.deck.dragGrid(by: 0.02); h.deck.dragGrid(by: 0.035); h.deck.endGridDrag()
        #expect(abs((h.deck.hotCue(slot: 0)?.time ?? 0) - 20.535) < 0.0006)
    }

    @Test func 곡_게인_초안은_rekordbox와_같으면_지운다() async throws {
        let gain = RekordboxAutoGain(gain: pow(10, -3.0 / 20), peak: 0.9)
        let h = try DeckHarness(autoGain: gain)
        try await h.loaded()
        #expect(abs(h.deck.autoGainDB + 3) < 1e-9 && abs(Double(h.audio.gainDB) + 3) < 1e-6)
        h.deck.setTrackGain(-1)
        #expect(h.drafts.gain("track-1") == -1 && abs(Double(h.audio.gainDB) + 1) < 1e-6)
        h.deck.setTrackGain(-3.02)
        #expect(h.deck.gainDraft == nil && h.drafts.gain("track-1") == nil)
    }
}
