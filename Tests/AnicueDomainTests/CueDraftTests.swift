@testable import AnicueDomain
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
