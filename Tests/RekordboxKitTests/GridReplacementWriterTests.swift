import DJCDomain
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

@Suite("대체 그리드 쓰기 기준")
struct GridReplacementWriterTests {
    @Test func 내부_박이_바뀐_대체_초안은_계획_시점에도_막는다() throws {
        let fixture = try RekordboxFixture()
        var beats = AnlzBuilder.beats(bpm: 120, first: 500, count: 100)
        beats[2].time += 3
        let (track, _) = try RekordboxGridWriterTests().makeTrack(fixture, beats: beats)
        let source = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        var draft = GridDraft(trackUUID: track.uuid, grid: source)
        draft.segments = [.init(start: 0.25, bpm: 128, firstBeatNumber: 1)]
        let approved = try #require(draft.approvingReplacement(of: source, duration: 60))
        let normalPlan = try plan(approved, track: track, fixture: fixture)
        #expect(!normalPlan.beats.isEmpty)
        beats[2].time -= 1
        try fixture.putAnalysis(for: track, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        let changed = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(GridDraft.segments(from: changed) == approved.base)
        let before = try Data(contentsOf: fixture.analysisURL(for: track))
        #expect(throws: RekordboxGridWriter.Blocked.self) { try plan(approved, track: track, fixture: fixture) }
        #expect(try Data(contentsOf: fixture.analysisURL(for: track)) == before)
    }

    func plan(_ draft: GridDraft, track: TrackSpec, fixture: RekordboxFixture) throws -> RekordboxGridWriter.Plan {
        try RekordboxGridWriter.plan(draft: draft, title: track.title, analysisDataPath: track.analysisDataPath,
                                    rekordboxBPM100: track.bpm100, audioPath: track.folderPath, shareRoot: fixture.shareRoot)
    }
}
