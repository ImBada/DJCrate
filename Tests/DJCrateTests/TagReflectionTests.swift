@testable import DJCrate
import DJCDomain
import Foundation
import Testing

/// 태그 초안도 rekordbox 반영 대상이다(#1). 쓴 곡은 초안을 비우고(반영한 값이 새 base), 되돌리면 백업의 초안을 살린다.
@Suite("태그 반영") @MainActor
struct TagReflectionTests {
    static func row(_ uuid: String) -> TrackRow { ReflectionCoordinatorTests.row(uuid) }

    @Test func 태그_초안만_있는_곡도_반영_대기다() {
        let store = LibraryStore(saveTagDrafts: { _ in })
        let row = Self.row("t")
        store.rowsByUUID[row.track.uuid] = row
        #expect(store.writeTargets([row]).isEmpty)
        store.applyTagEdits([(row, .title, "새 제목")])
        #expect(store.pendingUUIDs == ["t"] && store.writeTargets([row]).map(\.track.uuid) == ["t"])
    }

    @Test func 쓴_태그_초안은_비우고_되돌리면_다시_살린다() {
        var saved: [[TagDraft]] = []
        let store = LibraryStore(saveTagDrafts: { saved.append($0) })
        let row = Self.row("t")
        store.rowsByUUID[row.track.uuid] = row
        store.applyTagEdits([(row, .title, "새 제목"), (row, .comment, "코멘트")])
        let written = try? #require(store.tagDrafts["t"])
        let revision = store.tagRevision

        // 쓰기 뒤: 쓴 초안의 fields를 base로 되돌려 넘긴다(저장소는 변경 없는 초안 파일을 지운다)
        var cleared = written!
        cleared.fields = cleared.base
        store.replaceTagDrafts([cleared])
        #expect(store.tagDrafts.isEmpty && !store.pendingUUIDs.contains("t") && !store.editedUUIDs.contains("t"))
        #expect(saved.last == [cleared] && saved.last?.first?.hasChanges == false)
        #expect(store.tagRevision > revision, "시트가 다시 그린다")

        // 되돌린 뒤: 백업에 둔 초안을 그대로 살린다
        store.replaceTagDrafts([written!])
        #expect(store.tagDrafts["t"] == written && store.pendingUUIDs.contains("t") && store.editedUUIDs.contains("t"))
        #expect(saved.last == [written!])

        let count = saved.count
        store.replaceTagDrafts([])
        #expect(saved.count == count, "넘길 초안이 없으면 저장하지 않는다")
    }
}
