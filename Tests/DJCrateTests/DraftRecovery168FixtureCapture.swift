import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

struct DraftRecovery168FixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_RECOVERY_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_RECOVERY_FIXTURE"] else { return }
        let root = URL(filePath: path), fixture = try RekordboxFixture()
        var spec = TrackSpec(id: "168", uuid: "16800000-0000-0000-0000-000000000001")
        spec.title = "복구 시험 원곡"
        spec.folderPath = root.appending(path: "audio/recovery.wav").path
        spec.fileType = 11; spec.length = 60; spec.bpm100 = 12000
        spec.analysisDataPath = "/PIONEER/USBANLZ/recovery/ANLZ0000.DAT"
        var cueSpec = CueSpec(id: "168-cue", kind: 0, inMsec: 2000); cueSpec.comment = "원래 큐"
        spec.cues = [cueSpec]
        _ = try AudioFixture.wav(seconds: 60, in: fixture.audio)
        let audio = try FileManager.default.contentsOfDirectory(at: fixture.audio, includingPropertiesForKeys: nil).first!
        try FileManager.default.moveItem(at: audio, to: fixture.audio.appending(path: "recovery.wav"))
        try fixture.add(spec)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = '168'")
        let beats = AnlzBuilder.beats(bpm: 120, first: 200, count: 120)
        try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        let library = try RekordboxLibrary.load(snapshot: fixture.database), track = try #require(library.tracks.first)
        var tag = TagDraft(track: track); tag.fields.comment = "내 코멘트"
        var cue = CueDraft(trackUUID: track.uuid, rekordboxCues: library.cues); cue.cues[0].name = "내 큐 이름"
        var grid = GridDraft(trackUUID: track.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: spec))); grid.segments[0].firstBeatNumber = 3
        try TagDraftStore.save(tag); try CueDraftStore.save(cue); try GridDraftStore.save(grid)
        try fixture.execute("UPDATE djmdContent SET Title = '복구 시험 최신 제목', Commnt = '외부 코멘트' WHERE ID = '168'")
        // 큐 내용은 writer가 두 표의 관계까지 검사하므로 그 writer로 외부 변경을 만든다.
        var externalCue = CueDraft(trackUUID: track.uuid, rekordboxCues: library.cues); externalCue.cues[0].time = 3
        let report = try RekordboxWriter.write(drafts: [externalCue], to: fixture.database, dryRun: false, backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.written.count == 1)
        let currentBeats = AnlzBuilder.beats(bpm: 160, first: 200, count: 160)
        try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: currentBeats), ext: AnlzBuilder.ext(beats: currentBeats))
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }
}
