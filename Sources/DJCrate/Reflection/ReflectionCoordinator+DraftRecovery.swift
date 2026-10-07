import DJCDomain
import Foundation
import RekordboxKit

extension ReflectionCoordinator {
    /// 쓸 수 없게 된 초안을 한 시트에서 고친다(#232). 곡·종류마다, 재생 목록마다 한 줄이고, 줄마다 고른 것을 한 번에 저장한다.
    /// 모든 진입(인스펙터·목록 오른쪽 클릭·곡 편집 창·쓰기 결과의 막힌 초안)이 이 흐름 하나를 쓰며, 시트가 닫힐 때까지 기다린다.
    /// - Parameter staleOnly: 쓰기 결과에서 열 때. 현재값과 비교해 rekordbox가 바뀌어 막힌 곡·종류만 줄로 남기고, 줄이 없으면 시트를 열지 않는다.
    ///   다른 이유로 막힌 초안의 이유는 쓰기 결과(토스트·결과 보기)에 이미 있다.
    func recover(store: LibraryStore, requests: [RecoveryRequest], anchor: RecoverySheetAnchor = .library, staleOnly: Bool = false) async {
        guard !requests.isEmpty, store.recoverySheet == nil else { return }
        let model = RecoverySheetModel(store: store, requests: requests, anchor: anchor)
        if staleOnly {
            host.writeStage = WriteStage(String(ui: "막힌 초안을 rekordbox의 현재값과 비교하는 중…"))
            await model.load()
            host.writeStage = nil
            model.keepOnlyStale()
            guard !model.lines.isEmpty else { return }
        }
        await prompter.review(model)
    }

    /// 미리 보기에서 막힌 초안: 곡마다 막힌 종류, 막힌 재생 목록이 있는지
    struct BlockedDrafts {
        var kinds: [String: Set<DraftRecoveryKind>]
        var playlists: Bool

        init(kinds: [String: Set<DraftRecoveryKind>], playlists: Bool) {
            self.kinds = kinds
            self.playlists = playlists
        }

        init(report: RekordboxWriter.Report) {
            var kinds: [String: Set<DraftRecoveryKind>] = [:]
            for outcome in report.tagBlocked { kinds[outcome.trackUUID, default: []].insert(.tags) }
            for outcome in report.blocked { kinds[outcome.trackUUID, default: []].insert(.cues) }
            for outcome in report.gridBlocked + report.analysisBlocked { kinds[outcome.trackUUID, default: []].insert(.grid) }
            self.init(kinds: kinds, playlists: !report.playlistBlocked.isEmpty)
        }
    }

    /// 쓰기 결과에서 막힌 초안의 줄들: 쓰려던 곡(같은 곡은 한 번)마다 미리 보기에서 막힌 종류, 그다음 막힌 재생 목록
    static func recoveryRequests(store: LibraryStore, targets: [TrackRow], blocked: BlockedDrafts) -> [RecoveryRequest] {
        store.uniqueTracks(targets).flatMap { row in
            store.recoveryKinds(for: row).filter { blocked.kinds[row.track.uuid]?.contains($0) == true }.map { RecoveryRequest.draft(row, $0) }
        } + (blocked.playlists ? store.blockedPlaylistRecoveryIDs.map(RecoveryRequest.playlist) : [])
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
        if store.recoverySheet != nil {
            store.toast = .notice(String(ui: "막힌 초안 비교가 이미 열려 있습니다"), String(ui: "열려 있는 비교 창에서 저장하거나 취소한 뒤 다시 여세요."))
            return
        }
        guard !requests.isEmpty, !store.isRecoveringDraft, !store.isWritingRekordbox, store.writeTask == nil else { return }
        store.writeTask = Task {
            defer { store.writeTask = nil }
            await ReflectionCoordinator(host: store).recover(store: store, requests: requests, anchor: anchor)
        }
    }
}
