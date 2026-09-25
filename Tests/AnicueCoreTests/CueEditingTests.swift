@testable import AnicueCore
import Foundation
import Testing

@Suite("큐 초안")
struct CueDraftTests {
    let rekordboxCues = [
        Cue(id: "1", contentID: "c", kind: 0, inMsec: 6672, name: "", colorTableIndex: nil),
        Cue(id: "2", contentID: "c", kind: 1, inMsec: 86150, name: "", colorTableIndex: nil),
        Cue(id: "3", contentID: "c", kind: 0, inMsec: 1000, name: "CUE(Auto)", colorTableIndex: nil),
        Cue(id: "4", contentID: "c", kind: 6, inMsec: 6672, name: "", colorTableIndex: nil),
    ]

    @Test func rekordbox_큐를_불러올_때_자동_큐는_뺀다() {
        let draft = CueDraft(trackUUID: "t", rekordboxCues: rekordboxCues)
        #expect(draft.cues.count == 3)
        #expect(draft.cues.map(\.kind) == [.memory, .hot(4), .hot(0)])
        #expect(!draft.hasChanges)
    }

    @Test func 같은_슬롯에_핫큐를_놓으면_기존_것을_대체한다() {
        var draft = CueDraft(trackUUID: "t", rekordboxCues: rekordboxCues)
        draft.place(EditableCue(kind: .hot(0), time: 120))
        #expect(draft.cues.filter { $0.kind == .hot(0) }.count == 1)
        #expect(draft.cues.first { $0.kind == .hot(0) }?.time == 120)
        let changes = draft.changes
        #expect(changes.contains { if case .removed = $0 { true } else { false } })
        #expect(changes.contains { if case .added = $0 { true } else { false } })
    }

    @Test func 이동과_이름_변경은_수정으로_잡힌다() {
        var draft = CueDraft(trackUUID: "t", rekordboxCues: rekordboxCues)
        var cue = draft.cues[0]
        cue.time = 7.0
        cue.name = "1사비"
        draft.place(cue)
        #expect(draft.changes.count == 1)
        guard case let .modified(from, to) = draft.changes[0] else { Issue.record("수정이 아님"); return }
        #expect(from.time == 6.672 && to.time == 7.0 && to.name == "1사비")
    }

    @Test func 되돌리면_변경이_없다() {
        var draft = CueDraft(trackUUID: "t", rekordboxCues: rekordboxCues)
        draft.remove(draft.cues[0].id)
        #expect(draft.hasChanges)
        draft.revert()
        #expect(!draft.hasChanges)
    }

    @Test func 곡_길이를_벗어난_큐는_문제로_보고한다() {
        var draft = CueDraft(trackUUID: "t", rekordboxCues: rekordboxCues)
        draft.place(EditableCue(kind: .memory, time: 500))
        #expect(!draft.issues(duration: 269).isEmpty)
    }
}

@Suite("rekordbox 비트 그리드")
struct BeatGridTests {
    /// PMAI 헤더 + PQTZ 태그를 가진 최소 ANLZ 파일을 만든다.
    func anlz(beats: [(Int, Int, Int)]) -> Data {
        func u32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        var tag = Array("PQTZ".utf8) + u32(24) + u32(24 + beats.count * 8) + u32(0) + u32(0x80000) + u32(beats.count)
        for (number, bpm100, ms) in beats { tag += u16(number) + u16(bpm100) + u32(ms) }
        let header = Array("PMAI".utf8) + u32(28) + u32(28 + tag.count) + [UInt8](repeating: 0, count: 16)
        return Data(header + tag)
    }

    @Test func PQTZ를_읽고_스냅_이동_마디를_계산한다() throws {
        // 120 BPM, 0.5초 간격, 첫 박은 4박째
        let beats = (0..<9).map { i in ((i + 3) % 4 + 1, 12000, 100 + i * 500) }
        let url = FileManager.default.temporaryDirectory.appending(path: "anicue-test-\(UUID()).DAT")
        try anlz(beats: beats).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let grid = try BeatGrid.load(anlz: url)
        #expect(grid.beats.count == 9)
        #expect(grid.beats[0].number == 4 && grid.beats[1].number == 1)
        #expect(grid.beats[0].bpm == 120)
        #expect(grid.snap(0.7) == 0.6)
        #expect(grid.snap(0.86) == 1.1)
        #expect(grid.nudge(1.1, beats: 2) == 2.1)
        #expect(grid.nudge(0.1, beats: -1) == 0.1)
        #expect(grid.bar(at: 0.3) == 0)
        #expect(grid.bar(at: 0.6) == 1)
        #expect(grid.bar(at: 2.6) == 2)
    }

    @Test func 아트워크_경로_크기_변형() {
        let url = RekordboxShare.artworkURL("/PIONEER/Artwork/031/abc/artwork.jpg", size: .small)
        #expect(url?.lastPathComponent == "artwork_s.jpg")
        #expect(RekordboxShare.artworkURL(nil, size: .full) == nil)
    }
}
