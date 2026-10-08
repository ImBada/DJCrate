@testable import DJCrate
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit
import Testing

@MainActor
extension UsbEditActionsTests {
    @Test("동기화 초안 설명은 목록 이름과 중복을 포함한 곡 수를 보이고 항목 편집의 막힘을 따른다")
    func syncDraftDescriptionAndEntryBlocks() {
        let library = UsbEditTestData.mixedLibrary()
        let edit = UsbLibraryEdit.syncPlaylist(playlist: .id("10"), localContentIDs: ["101", "102", "101"])
        #expect(UsbEditText.describe(edit, library: library) == "‘시험 목록’ 동기화 · 곡 3개")
        #expect(UsbEditText.describe(.syncPlaylist(playlist: .new("sync"), localContentIDs: []), library: library,
                                    created: ["sync": "새 동기화 목록"]) == "‘새 동기화 목록’ 동기화 · 곡 0개")
        func reason(_ ref: PlaylistRef) -> String? {
            UsbEditActions.blockReason(.syncPlaylist(playlist: ref, localContentIDs: ["101"]), volume: nil, library: library, info: nil)
        }
        #expect(reason(.id("10")) == nil)
        #expect(reason(.new("sync")) == nil)
        #expect(reason(.id("4")) == "이 재생 목록은 두 형식의 곡 목록이 달라 곡을 고칠 수 없습니다. 이름·위치만 바꿀 수 있습니다")
        #expect(reason(.id("5")) == "폴더·인텔리전트 재생 목록에는 곡을 넣거나 뺄 수 없습니다. 일반 재생 목록을 고르세요")
        #expect(reason(.id("999")) == "대상이 USB에서 사라졌습니다. USB를 다시 읽은 뒤 고치세요")
    }

    @Test("동기화 계획의 A/B → B/A 재부모화는 작성 순서의 작업 트리로 검사한다")
    func folderReparentBatchUsesTheProjectedTree() throws {
        var library = UsbLibrary.empty
        library.formats = [.oneLibrary]
        library.playlists = [
            .init(id: 10, name: "A", attribute: 1, presentIn: [.oneLibrary]),
            .init(id: 20, name: "B", parentID: 10, attribute: 1, presentIn: [.oneLibrary]),
        ]
        let source = PlaylistLayout([
            (.init(id: "B", name: "B", isFolder: true), 0),
            (.init(id: "A", name: "A", parentID: "B", isFolder: true), 0),
        ])
        var keys = ["B-key", "A-key"].makeIterator()
        let plan = try UsbSyncPlan.build(source: source, selection: .init(selectedIDs: ["0"]),
                                        library: library, matches: [:], badges: [:], bindings: [
                                            "A": .init(usbID: 10, path: ["A"], isFolder: true),
                                            "B": .init(usbID: 20, path: ["A", "B"], isFolder: true),
                                        ], newKey: { keys.next()! })
        // 이름이 같은 원본을 옮기면 rekordbox처럼 이은 USB 폴더를 새 자리로 옮긴다(2026-10-08 정상 USB 실험).
        #expect(plan.edits == [
            .playlist(edit: .move(playlist: .id("20"), into: .root)),
            .playlist(edit: .move(playlist: .id("10"), into: .id("20"))),
        ])
        #expect(UsbEditActions.blockReason(plan.edits, volume: nil, library: library, info: nil) == nil)
        // 묶음 검사는 작성 순서대로 얹은 트리로 본다(손으로 만든 재부모화 묶음).
        let reparent: [UsbLibraryEdit] = [
            .playlist(edit: .move(playlist: .id("20"), into: .root)),
            .playlist(edit: .move(playlist: .id("10"), into: .id("20"))),
        ]
        #expect(UsbEditActions.blockReason(reparent, volume: nil, library: library, info: nil) == nil)
        #expect(UsbEditActions.blockReason([reparent[1]], volume: nil, library: library, info: nil) != nil)
        #expect(UsbEditActions.blockReason(reparent + [
            .playlist(edit: .move(playlist: .id("20"), into: .id("10"))),
        ], volume: nil, library: library, info: nil) != nil)
    }

    @Test("묶음 검사도 두 형식의 충돌과 실물 관문을 유지하고 새 참조는 최종 엔진에 맡긴다")
    func batchPrecheckKeepsExistingSafetyGuards() {
        let library = UsbEditTestData.mixedLibrary()
        let edits: [UsbLibraryEdit] = [.playlist(edit: .rename(playlist: .id("10"), name: "변경"))]
        var info = UsbInfo(root: "/synthetic")
        info.consistency.editBlocked = true
        info.consistency.trackIDsMatch = false
        #expect(UsbEditActions.blockReason(edits, volume: nil, library: library, info: info) != nil)
        var physical = image
        physical.isDiskImage = false
        #expect(UsbEditActions.blockReason(edits, volume: physical, library: library, info: nil,
                                          isScratchMount: { _ in false }) != nil)
        #expect(UsbEditActions.blockReason([
            .playlist(edit: .create(key: "new-parent", name: "새 부모", isFolder: true, parent: .root)),
            .playlist(edit: .move(playlist: .id("5"), into: .new("new-parent"))),
            .addTracks(localContentIDs: ["unknown-local"], playlist: .new("new-list")),
        ], volume: nil, library: library, info: nil) == nil)
    }

}
