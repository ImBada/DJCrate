#if DEBUG
import AppKit
import DJCStorage
import Foundation

extension DevSelfTests {
    static func runITunesSelfTestIfRequested(store: LibraryStore, deck: DeckModel) {
        guard ProcessInfo.processInfo.arguments.contains("--itunes-selftest") else { return }
        let env = ProcessInfo.processInfo.environment
        func log(_ message: String) { FileHandle.standardError.write(Data("iTunes 시험: \(message)\n".utf8)) }
        guard env["DJC_HOME"]?.isEmpty == false, env["DJC_REKORDBOX_DIR"]?.isEmpty == false else {
            log("임시 DJC_HOME과 합성 DJC_REKORDBOX_DIR가 필요합니다"); exit(2)
        }
        Task {
            @MainActor func check(_ condition: Bool, _ message: String) {
                log("\(condition ? "통과" : "실패") · \(message)")
                if !condition { exit(1) }
            }
            for _ in 0..<300 {
                if case .loaded = store.phase { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let snapshot = store.snapshotURL, let before = try? Data(contentsOf: snapshot) else {
                log("실패 · 합성 라이브러리 로드"); exit(1)
            }
            check(store.iTunesLibrary.index["itunes:A"]?.name == "iTunes 합성 목록", "합성 iTunes 목록 로드")
            store.sidebar = .itunesPlaylist("itunes:A")
            check(store.displayRows.map(\.track.id) == ["2", "1", "2"]
                  && Set(store.displayRows.map(\.id)).count == 3
                  && store.displayRows.map(\.playlistTrackNumber) == [1, 2, 3], "반복 곡과 원본 순서")
            store.selection = [store.displayRows[2].id]
            check(store.selectedRows.map(\.track.id) == ["2"] && store.primaryRow?.track.id == "2", "반복 행 선택을 기존 곡에 연결")
            check(store.iTunesLibrary.index["itunes:A"]?.unavailableTrackCount == 1, "미연결 곡 안내")
            check(store.editablePlaylistID == nil && !store.canReorderDisplayedTracks
                  && !LibraryMenuAction.removeTracks.isEnabled(in: store), "순서 변경·목록 삭제·컬렉션 삭제 차단")
            guard let row = store.displayRows.first else { log("실패 · 곡 선택"); exit(1) }
            store.setTag(.comment, "iTunes 시험 초안", rows: [row])
            check(store.tagDrafts[row.track.uuid]?.fields.comment == "iTunes 시험 초안", "기존 곡에 태그 초안")
            store.loadToDeck(row)
            for _ in 0..<150 {
                if deck.canPlay, deck.row?.track.id == row.track.id, deck.draft?.trackUUID == row.track.uuid { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            deck.pressHotCue(slot: 0)
            check(deck.row?.track.id == row.track.id && deck.hotCue(slot: 0) != nil, "기존 곡에 핫큐 초안")
            DraftWriter.flush()
            check(CueDraftStore.load(trackUUID: row.track.uuid)?.hasChanges == true, "핫큐 초안 파일 저장")
            check((try? Data(contentsOf: snapshot)) == before && store.playlistDraft.isEmpty, "DB 사본과 목록 구성 불변")
            log("전체 통과 · 9개 검증")
            exit(0)
        }
    }
}
#endif
