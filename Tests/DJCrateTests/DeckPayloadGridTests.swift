@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

@MainActor
@Suite("덱 그리드 편집 진입")
struct DeckPayloadGridTests {
    @Test(arguments: ["missing", "unreadable", "empty"])
    func 분석_파일의_부재와_읽기_실패와_박_없음을_구분한다(kind: String) throws {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec(id: "1", uuid: "analysis-issue")
        spec.analysisDataPath = "/PIONEER/USBANLZ/issue/ANLZ0000.DAT"
        if kind == "unreadable" {
            try fixture.putAnalysis(for: spec, dat: Data("broken".utf8), ext: nil)
        } else if kind == "empty" {
            try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: []), ext: nil)
        }
        let track = Track(id: spec.id, uuid: spec.uuid, title: "합성 안내", artist: nil, album: nil,
                          albumArtist: nil, genre: nil, composer: nil, releaseYear: nil, trackNumber: nil,
                          key: nil, bpm: 120, lengthSeconds: 5, folderPath: "/unused.wav", comment: "",
                          importedOn: nil, analysisDataPath: spec.analysisDataPath, imagePath: nil, isDeleted: false)
        let payload = DeckPayload.load(track: track, cues: [], duration: 5,
                                       storage: .memory(MemoryDrafts()), analysisRoot: fixture.shareRoot)
        let reason = try #require(payload.gridBlockedReason)
        #expect(reason.contains(kind == "missing" ? "없" : kind == "unreadable" ? "읽지 못" : "박 정보"))
        #expect(reason.contains("rekordbox"))
        #expect(payload.gridDraft == nil && payload.originalGrid == nil)
    }
    @Test(arguments: [(0.002).nextDown, 0.002, (0.002).nextUp, 0.00249, (0.003).nextDown, 0.003, (0.003).nextUp])
    func 부동소수점_주변값도_같은_ms로_판정한다(delta: Double) {
        let original = BeatGrid(beats: [.init(number: 1, bpm: 120, time: 1.5 + delta)])
        let rebuilt = BeatGrid(beats: [.init(number: 1, bpm: 120, time: 1.5)])
        #expect(GridEditEligibility.reconstructionErrorMilliseconds(original: original, rebuilt: rebuilt)
                == (delta < 0.0025 ? 2 : 3))
    }

    @Test(arguments: [false, true])
    func 승인한_대체_초안을_저장하고_재로드해도_편집할_수_있다(sameSegments: Bool) throws {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec(id: "1", uuid: "grid-replacement")
        spec.analysisDataPath = "/PIONEER/USBANLZ/replacement/ANLZ0000.DAT"
        var beats = AnlzBuilder.beats(bpm: 120, first: 500, count: 10)
        beats[2].time += 3
        try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        let original = try BeatGrid.load(anlz: fixture.shareRoot.appending(path: String(spec.analysisDataPath!.dropFirst())))
        var draft = GridDraft(trackUUID: spec.uuid, grid: original)
        if !sameSegments { draft.segments = [.init(start: 0.25, bpm: 128, firstBeatNumber: 1)] }
        let approved = try #require(draft.approvingReplacement(of: original, duration: 5))
        let directory = fixture.root.appending(path: "grid-drafts")
        try GridDraftStore.save(approved, directory: directory)
        let drafts = MemoryDrafts()
        drafts.save(try #require(GridDraftStore.load(trackUUID: spec.uuid, directory: directory)))
        let track = Track(id: spec.id, uuid: spec.uuid, title: "합성 대체", artist: nil, album: nil,
                          albumArtist: nil, genre: nil, composer: nil, releaseYear: nil, trackNumber: nil,
                          key: nil, bpm: 120, lengthSeconds: 5, folderPath: "/unused.wav", comment: "",
                          importedOn: nil, analysisDataPath: spec.analysisDataPath, imagePath: nil, isDeleted: false)
        let payload = DeckPayload.load(track: track, cues: [], duration: 5,
                                       storage: .memory(drafts), analysisRoot: fixture.shareRoot)
        #expect(payload.gridDraft == approved)
        #expect(payload.gridBlockedReason == nil)
        // 구간화 결과가 같아도 interior 박이 바뀌면 승인은 재사용할 수 없다.
        beats[2].time -= 1
        try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        let changed = try BeatGrid.load(anlz: fixture.shareRoot.appending(path: String(spec.analysisDataPath!.dropFirst())))
        #expect(GridDraft.segments(from: changed) == approved.base)
        #expect(!approved.isVerifiedReplacement(of: changed, duration: 5))
        let stale = DeckPayload.load(track: track, cues: [], duration: 5,
                                     storage: .memory(drafts), analysisRoot: fixture.shareRoot)
        #expect(stale.gridBlockedReason != nil)
    }

    @Test(arguments: ["legacy", "base", "marker", "shape", "uuid", "missing"])
    func 미검증_대체_초안은_편집_제한을_우회하지_못한다(invalid: String) throws {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec(id: "1", uuid: "grid-invalid")
        spec.analysisDataPath = "/PIONEER/USBANLZ/invalid/ANLZ0000.DAT"
        var beats = AnlzBuilder.beats(bpm: 120, first: 500, count: 10)
        beats[2].time += 3
        try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        let original = try BeatGrid.load(anlz: fixture.analysisURL(for: spec))
        var draft = GridDraft(trackUUID: spec.uuid, grid: original)
        draft.segments = [.init(start: 0.25, bpm: 128, firstBeatNumber: 1)]
        draft = try #require(draft.approvingReplacement(of: original, duration: 5))
        switch invalid {
        case "legacy": draft.replacementSource = nil
        case "base": draft.base[0].start += 0.01
        case "marker": draft.replacementSource = "invalid"
        case "shape": draft.segments.append(.init(start: 2, bpm: 140, firstBeatNumber: 1))
        case "uuid": draft.trackUUID = "another"
        case "missing": spec.analysisDataPath = nil
        default: Issue.record("알 수 없는 대조")
        }
        var storage = DeckStorage.memory(MemoryDrafts())
        let invalidDraft = draft
        storage.loadGridDraft = { _ in invalidDraft }
        let track = Track(id: spec.id, uuid: spec.uuid, title: "합성 거부", artist: nil, album: nil,
                          albumArtist: nil, genre: nil, composer: nil, releaseYear: nil, trackNumber: nil,
                          key: nil, bpm: 120, lengthSeconds: 5, folderPath: "/unused.wav", comment: "",
                          importedOn: nil, analysisDataPath: spec.analysisDataPath, imagePath: nil, isDeleted: false)
        let payload = DeckPayload.load(track: track, cues: [], duration: 5, storage: storage, analysisRoot: fixture.shareRoot)
        #expect(payload.gridBlockedReason != nil)
    }

    @Test(arguments: [0, 1, 2, 3])
    func 재생성_경계는_ANLZ_정수_ms로_판정한다(offset: Int) throws {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec(id: "1", uuid: "grid-boundary")
        spec.analysisDataPath = "/PIONEER/USBANLZ/boundary/ANLZ0000.DAT"
        var beats = AnlzBuilder.beats(bpm: 120, first: 500, count: 10)
        beats[2].time += Double(offset)
        try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: beats), ext: nil)
        let track = Track(id: spec.id, uuid: spec.uuid, title: "합성 경계", artist: nil, album: nil,
                          albumArtist: nil, genre: nil, composer: nil, releaseYear: nil, trackNumber: nil,
                          key: nil, bpm: 120, lengthSeconds: 5, folderPath: "/unused.wav", comment: "",
                          importedOn: nil, analysisDataPath: spec.analysisDataPath, imagePath: nil, isDeleted: false)
        let payload = DeckPayload.load(track: track, cues: [], duration: 5,
                                       storage: .memory(MemoryDrafts()), analysisRoot: fixture.shareRoot)
        #expect(payload.originalGrid != nil)
        #expect((payload.gridBlockedReason != nil) == (offset > 2))
    }
}
