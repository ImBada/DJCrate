import DJCDomain
import Foundation

extension ReflectionCoordinator {
    /// 쓸 수 없게 된 초안을 한 시트에서 고친다(#232). 곡·종류마다, 재생 목록마다 한 줄이고, 줄마다 고른 것을 한 번에 저장한다.
    /// 모든 진입(인스펙터·목록 오른쪽 클릭·곡 편집 창·쓰기 결과의 막힌 초안)이 이 흐름 하나를 쓰며, 시트가 닫힐 때까지 기다린다.
    func recover(store: LibraryStore, requests: [RecoveryRequest], anchor: RecoverySheetAnchor = .library) async {
        guard !requests.isEmpty, store.recoverySheet == nil else { return }
        await prompter.review(RecoverySheetModel(store: store, requests: requests, anchor: anchor))
    }

    /// 쓰기 결과에서 막힌 초안의 줄들: 쓰려던 곡마다 복구할 수 있는 종류, 그다음 막힌 재생 목록(미리 보기에서 막힌 것이 있을 때만)
    static func recoveryRequests(store: LibraryStore, targets: [TrackRow], playlistsBlocked: Bool) -> [RecoveryRequest] {
        targets.flatMap { row in store.recoveryKinds(for: row).map { RecoveryRequest.draft(row, $0) } }
            + (playlistsBlocked ? store.blockedPlaylistRecoveryIDs.map(RecoveryRequest.playlist) : [])
    }
}

@MainActor
enum DraftRecoveryPanels {
    /// 곡 하나·종류 하나만 든 시트(인스펙터·곡 목록 메뉴·곡 편집 창의 단추)
    static func recover(store: LibraryStore, row: TrackRow, kind: DraftRecoveryKind, anchor: RecoverySheetAnchor = .library) {
        present(store: store, requests: [.draft(row, kind)], anchor: anchor)
    }

    /// 막힌 재생 목록 하나, 또는 막힌 모든 재생 목록(`id`가 nil)을 줄로 든 시트
    static func recoverPlaylists(store: LibraryStore, playlist id: String? = nil) {
        let ids = id.map { [$0] } ?? store.blockedPlaylistRecoveryIDs
        present(store: store, requests: ids.map(RecoveryRequest.playlist), anchor: .library)
    }

    /// 시트가 열려 있는 동안은 쓰기 등 다른 쓰기 입구도 막는다(`writeTask`가 시트가 닫힐 때까지 남는다).
    private static func present(store: LibraryStore, requests: [RecoveryRequest], anchor: RecoverySheetAnchor) {
        guard !requests.isEmpty, !store.isRecoveringDraft, !store.isWritingRekordbox, store.writeTask == nil, store.recoverySheet == nil else { return }
        store.writeTask = Task {
            defer { store.writeTask = nil }
            await ReflectionCoordinator(host: store).recover(store: store, requests: requests, anchor: anchor)
        }
    }
}
