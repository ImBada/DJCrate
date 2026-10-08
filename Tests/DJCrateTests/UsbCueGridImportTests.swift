@testable import DJCrate
import DJCDomain
import Foundation
import RekordboxKit
import Testing

@Suite("USB 큐·그리드 초안 보호")
struct UsbCueGridImportTests {
    @Test func 핫큐_이동은_기존_원본_ID를_잇는다() throws {
        let local = [Cue(id: "a", contentID: "1", kind: 1, inMsec: 1_000, name: "도입", colorTableIndex: nil)]
        let draft = try UsbCueGridDraftImport.cueDraft(uuid: "uuid", local: local,
                                                      imported: [.init(kind: .hot(0), time: 2, name: "도입")], legacy: false)
        #expect(draft.cues.first?.id == draft.base.first?.id)
        #expect(draft.cues.first?.sourceID == "a")
        #expect(draft.changes.count == 1)
    }

    @Test func 색_큐를_고쳐_메타데이터를_잃는_초안은_막는다() {
        let local = [Cue(id: "a", contentID: "1", kind: 1, inMsec: 1_000, name: "", colorTableIndex: 4)]
        #expect(throws: UsbCueGridReader.ReadFailure.self) {
            try UsbCueGridDraftImport.cueDraft(uuid: "uuid", local: local, imported: [.init(kind: .hot(0), time: 2)], legacy: false)
        }
    }

    @Test func DAT_큐는_기존_같은_큐의_이름을_보존한다() throws {
        let local = [Cue(id: "a", contentID: "1", kind: 1, inMsec: 1_000, name: "도입", colorTableIndex: nil)]
        let draft = try UsbCueGridDraftImport.cueDraft(uuid: "uuid", local: local,
                                                      imported: [.init(kind: .hot(0), time: 2)], legacy: true)
        #expect(draft.cues.first?.name == "도입")
    }

    @Test func 로컬_카운터가_앞서면_기기변경_배지가_있어도_가져오지_않는다() {
        #expect(UsbCueGridDraftImport.localIsNewer("4", than: "3"))
        #expect(!UsbCueGridDraftImport.localIsNewer("3", than: "4"))
        #expect(!UsbCueGridDraftImport.localIsNewer(nil, than: ""))
        #expect(UsbCueGridDraftImport.localIsNewer("?", than: "4"))
    }

    @Test func 일정_그리드는_로컬_기준으로_초안을_만든다() throws {
        let old = BeatGrid(beats: (0..<20).map { .init(number: $0 % 4 + 1, bpm: 120, time: 0.1 + Double($0) * 0.5) })
        let new = old.shifted(by: 0.05)
        let draft = try UsbCueGridDraftImport.gridDraft(uuid: "uuid", local: old, imported: new, duration: 10)
        #expect(draft.base == GridDraft.segments(from: old))
        #expect(draft.hasChanges)
    }

    @Test func 원본_박번호를_구간으로_보존하지_못하면_그리드를_막는다() {
        let bad = BeatGrid(beats: (0..<20).map { .init(number: $0 == 10 ? 1 : $0 % 4 + 1, bpm: 120, time: 0.1 + Double($0) * 0.5) })
        #expect(throws: UsbCueGridReader.ReadFailure.self) {
            try UsbCueGridDraftImport.gridDraft(uuid: "uuid", local: .init(beats: []), imported: bad, duration: 10)
        }
    }
    @Test("로컬 기준으로 새 변속 경계를 만들 때 USB 박이 사라지는 초안은 거부한다")
    func returnedDraftCannotDropTheBeatBeforeATempoChange() {
        let local = BeatGrid(beats: (0..<20).map {
            .init(number: $0 % 4 + 1, bpm: 120, time: 0.1 + Double($0) * 0.5)
        })
        let imported = BeatGrid(beats: [
            .init(number: 1, bpm: 120, time: 0.1),
            .init(number: 2, bpm: 120, time: 0.6),
        ] + (0..<36).map {
            .init(number: ($0 + 2) % 4 + 1, bpm: 240, time: 0.85 + Double($0) * 0.25)
        })
        #expect(throws: UsbCueGridReader.ReadFailure.self) {
            try UsbCueGridDraftImport.gridDraft(uuid: "uuid", local: local, imported: imported, duration: 10)
        }
    }

    @Test("기존 변속 경계를 옮긴 초안은 실제 반환 그리드의 모든 USB 박을 보존한다")
    func shiftedExistingTempoBoundaryPreservesEveryImportedBeat() throws {
        let local = BeatGrid(beats: [
            .init(number: 1, bpm: 120, time: 0.1),
            .init(number: 2, bpm: 120, time: 0.6),
        ] + (0..<36).map {
            .init(number: ($0 + 2) % 4 + 1, bpm: 240, time: 0.85 + Double($0) * 0.25)
        })
        let imported = local.shifted(by: 0.05)
        let draft = try UsbCueGridDraftImport.gridDraft(uuid: "uuid", local: local, imported: imported, duration: 10)
        #expect(draft.base == GridDraft.segments(from: local))
        let actual = draft.grid(duration: 11)
        for beat in imported.beats {
            #expect(actual.beats.contains {
                abs($0.time - beat.time) <= 0.002 && $0.number == beat.number && abs($0.bpm - beat.bpm) < 0.005
            })
        }
    }

    @Test func 최신_스냅샷의_짝은_사이드바_캐시_없이_계산한다() {
        let local = LocalLibraryKeys(localDBID: 100,
                                     tracks: [.init(contentID: "local", masterSongID: "10", fileNameL: "test.mp3")], counters: [:])
        var library = UsbLibrary.empty
        library.tracks = [.init(id: 1, fileName: "test.mp3", masterDbId: 100, masterContentId: 10)]
        #expect(UsbCueGridDraftImport.uniqueLocalMatches(library: library, local: local) == [1: "local"])
    }

    @Test func 같은_로컬_곡으로_오는_USB_여러곡은_모두_건너뛴다() {
        let local = LocalLibraryKeys(localDBID: 100,
                                     tracks: [.init(contentID: "local", masterSongID: "10", fileNameL: "test.mp3"),
                                              .init(contentID: "other", masterSongID: "20", fileNameL: "other.mp3")], counters: [:])
        var library = UsbLibrary.empty
        library.tracks = [.init(id: 1, fileName: "test.mp3", masterDbId: 100, masterContentId: 10),
                          .init(id: 2, fileName: "test.mp3", masterDbId: 100, masterContentId: 10),
                          .init(id: 3, fileName: "other.mp3", masterDbId: 100, masterContentId: 20)]
        #expect(UsbCueGridDraftImport.uniqueLocalMatches(library: library, local: local) == [3: "other"])
    }

}
