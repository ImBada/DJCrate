import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

extension UsbExportSessionTests {
    @Test("목록 모델의 없는 곡·삭제된 곡을 막힘으로 알리고 정상 곡의 반복 순서는 유지한다")
    func layoutReportsMissingAndDeletedCandidateIDs() throws {
        let env = try Env(tracks: 2)
        let db = try env.local.local.open()
        try db.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '102'")
        db.close()
        let layout = PlaylistLayout([(.init(id: "itunes:A", name: "합성 목록", entries: [
            .init(trackNo: 1, contentID: "101"), .init(trackNo: 2, contentID: "999"),
            .init(trackNo: 3, contentID: "101"), .init(trackNo: 4, contentID: "102"),
        ]), 1)])
        let preview = try env.session().preview(selection: .playlists(["itunes:A"]), options: Self.options { $0.playlistLayout = layout })
        let missing = preview.blocks.filter { $0.code == "localTrackMissing" }
        #expect(Set(missing.map(\.scope)) == [.track("999"), .track("102")])
        #expect(preview.blockedTrackCount == 2)
        let id = try #require(preview.plan.tracks.first { $0.localContentID == "101" }?.contentID)
        #expect(preview.plan.playlists.first?.contentIDs == [id, id])
        #expect(env.usb.tree().isEmpty && env.usb.backupFolders().isEmpty)
        #expect(env.leftoverCopies.isEmpty && env.leftoverStaging.isEmpty)
    }

    @Test("native 새 내보내기의 누락은 전체 묶음을 막고 새 선택 파일 관문도 유지한다")
    func nativeExportCannotMarkIncompleteLayoutAsSynced() throws {
        let env = try Env(tracks: 2)
        let db = try env.local.local.open()
        try db.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '102'")
        db.close()
        let layout = PlaylistLayout([(.init(id: "itunes:A", name: "합성 목록", entries: [
            .init(trackNo: 1, contentID: "101"), .init(trackNo: 2, contentID: "999"),
            .init(trackNo: 3, contentID: "102"), .init(trackNo: 4, contentID: "101"),
        ]), 1)])
        let options = Self.options {
            $0.playlistLayout = layout
            $0.syncSelection = .init(localDBID: 42, sourceNodes: [.init(id: "itunes:A", parentID: nil, isFolder: false)],
                                     selection: .init(selectedIDs: ["itunes:A"]), enabled: true, playlistRefs: [:], baseFiles: [:])
        }
        let session = env.session()
        let preview = try session.preview(selection: .playlists(["itunes:A"]), options: options)
        #expect(preview.blocks.filter { $0.code == "localTrackMissing" }.count == 2)
        #expect(preview.blocks.contains { $0.code == "syncSelectionIncomplete" })
        #expect(preview.blocks.contains { $0.code == "syncSelectionNewFile" })
        #expect(preview.changes == nil)
        #expect(throws: UsbError.self) {
            try session.write(selection: .playlists(["itunes:A"]), options: options, progress: { _ in }, isCancelled: { false })
        }
        #expect(env.usb.tree().isEmpty && env.usb.backupFolders().isEmpty && env.usb.journal() == nil)
        #expect(env.leftoverCopies.isEmpty && env.leftoverStaging.isEmpty)
    }
}
