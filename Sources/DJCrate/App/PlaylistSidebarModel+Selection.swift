import DJCApplication
import DJCDomain
import Foundation

/// 사이드바에서 끈 재생 목록을 놓을 자리
enum PlaylistDropTarget: Hashable {
    /// 그 폴더(또는 맨 위 `PlaylistLayout.root`)의 맨 끝
    case into(String)
    /// 그 목록·폴더 바로 앞(같은 부모 안)
    case before(String)
}

/// 사이드바 여러 개 고르기(#261): ⌘·⇧ 클릭으로 재생 목록·폴더를 여럿 고르고, 한 번에 지우거나 끌어 옮긴다.
/// 고른 항목은 묶음 요청 하나(`applyPlaylistRequests`, 막힌 항목만 건너뜀)로 쌓아 ⌘Z 한 번에 되돌린다.
extension PlaylistSidebarModel {
    /// 사이드바에서 고른 항목(목록이 강조하는 것). 곡 목록은 그중 마지막에 고른 항목(`LibraryStore.sidebar`)을 보인다
    var selection: Set<SidebarItem> { library.sidebarSelection }

    /// 재생 목록·폴더를 둘 이상 골랐다(⌫·오른쪽 클릭 메뉴가 묶음으로 다룬다)
    var isSelectingManyPlaylists: Bool { selection.count > 1 && selection.allSatisfy(\.isPlaylist) }

    /// 고른 재생 목록·폴더(지우기·옮기기 대상, `targets` 규칙)
    var selectedPlaylistIDs: [String] { targets(selection.compactMap(\.playlistID)) }

    private var library: LibraryStore { playlists.library }
    private var layout: PlaylistLayout { playlists.playlistProjection.layout }

    /// 사이드바 목록이 바꾼 고르기를 받는다. 더한 항목이 하나면 그것을(⌘ 클릭), 여럿이면 누른 끝을(⇧ 클릭) 보인다.
    /// 보던 항목을 빼면 남은 것 중 사이드바에서 마지막 것을 보인다. 여럿은 재생 목록끼리만 고른다(다른 항목을 고르면 그 하나만).
    /// 빈 곳을 눌러 비면 고른 것을 그대로 둔다(한 개 고르기 때와 같다).
    func select(_ items: Set<SidebarItem>) {
        let before = selection
        guard !items.isEmpty, items != before else { return }
        let current = library.sidebar
        let added = items.subtracting(before)
        let primary: SidebarItem
        if added.count == 1, let only = added.first {
            primary = only
        } else if !added.isEmpty {
            // 범위는 보던 항목에서 누른 줄까지다. 모두 아래면 맨 아래, 아니면 맨 위가 누른 줄이다
            let from = position(current)
            primary = added.allSatisfy({ position($0) > from }) ? last(of: added) : first(of: added)
        } else {
            primary = items.contains(current) ? current : last(of: items)
        }
        guard primary.isPlaylist else {
            library.selectSidebar([primary], showing: primary)
            return
        }
        library.selectSidebar(items.filter(\.isPlaylist), showing: primary)
    }

    /// 사이드바 순서(재생 목록 칸 위의 항목은 모두 앞)
    private func position(_ item: SidebarItem) -> Int {
        guard let id = item.playlistID else { return -1 }
        return layout.outline.firstIndex { $0.id == id } ?? -1
    }

    private func first(of items: Set<SidebarItem>) -> SidebarItem {
        items.min { position($0) < position($1) } ?? library.sidebar
    }

    private func last(of items: Set<SidebarItem>) -> SidebarItem {
        items.max { position($0) < position($1) } ?? library.sidebar
    }

    // MARK: - 요청 만들기

    /// 지우거나 옮길 목록·폴더를 사이드바 순서로. 고른 폴더 안의 항목은 폴더를 따라가므로 빼고(같은 항목에 요청을 두 번 만들지 않는다),
    /// 없는 목록도 뺀다.
    func targets(_ ids: some Sequence<String>) -> [String] {
        let chosen = Set(ids), layout = layout
        return layout.outline.map(\.id).filter { id in
            chosen.contains(id) && !layout.ancestors(of: id).contains { chosen.contains($0.id) }
        }
    }

    func deleteRequests(_ ids: some Sequence<String>) -> [PlaylistEditRequest] {
        targets(ids).map { .delete(.ref(PlaylistRef($0))) }
    }

    /// 폴더면 그 맨 끝, 목록이면 그 앞에 차례로 놓는다. 같은 자리에 차례로 놓으므로 사이드바 순서가 그대로 남는다.
    /// 폴더를 제 안으로 옮기는 요청은 묶음 계획이 그 항목만 막는다.
    func moveRequests(_ ids: some Sequence<String>, to target: PlaylistDropTarget) -> [PlaylistEditRequest] {
        let parent: String, position: PlaylistPosition?
        switch target {
        case let .into(folder):
            (parent, position) = (folder, nil)
        case let .before(id):
            (parent, position) = (layout.item(id)?.parentID ?? PlaylistLayout.root, .before(.ref(PlaylistRef(id))))
        }
        return targets(ids).map { .move(.ref(PlaylistRef($0)), into: .ref(PlaylistRef(parent)), position: position) }
    }

    // MARK: - 지우기·옮기기

    /// ⌫: 고른 목록·폴더를 모두 지운다
    func deleteSelection() { deletePlaylists(selectedPlaylistIDs) }

    /// 여러 목록·폴더를 지운다. 개수와 이름을 묻고, 막힌 항목(인텔리전트 목록 등)은 건너뛴다. 모두 막히면 묻지 않고 이유만 알린다
    func deletePlaylists(_ ids: [String]) {
        guard library.writeLockPolicy.allowsLibraryInteraction, renamingPlaylistID == nil, !library.isWritingRekordbox else { return }
        let requests = deleteRequests(ids)
        guard !requests.isEmpty else { return }
        let plan = playlists.planPlaylistRequests(requests)
        let deleting = plan.outcomes.filter { $0.status == .stacked }
        let skipped = plan.outcomes.filter { $0.status == .skipped }
        guard !deleting.isEmpty else {
            announce(String(ui: "재생 목록을 지우지 않았습니다: \(Self.reasons(skipped))"), warning: true)
            return
        }
        // 지운 뒤에는 모양에 없으므로 폴더인지 먼저 본다
        let folders = deleting.contains { $0.playlistID.flatMap(layout.item)?.isFolder == true }
        guard prompter.show(deletePrompt(deleting, skipped: skipped, folders: folders)) else { return }
        guard let batch = playlists.applyPlaylistRequests(requests, actionName: String(ui: "재생 목록 지우기"), allOrNothing: false) else { return }
        report(batch, done: folders ? String(ui: "재생 목록·폴더 \(batch.stackedCount)개를 지웠습니다(쓰기 대기).")
            : String(ui: "재생 목록 \(batch.stackedCount)개를 지웠습니다(쓰기 대기)."), none: String(ui: "재생 목록을 지우지 않았습니다"))
    }

    /// 여러 목록·폴더를 끌어 놓은 자리로 옮긴다(묻지 않고 ⌘Z로 되돌린다). 막힌 항목만 건너뛰고 이유를 알린다
    func movePlaylists(_ ids: [String], to target: PlaylistDropTarget) {
        draggingPlaylistIDs = []
        guard library.writeLockPolicy.allowsLibraryInteraction else { return }
        let requests = moveRequests(ids, to: target)
        guard !requests.isEmpty,
              let batch = playlists.applyPlaylistRequests(requests, actionName: String(ui: "재생 목록 옮기기"), allOrNothing: false) else { return }
        report(batch, done: String(ui: "재생 목록 \(batch.stackedCount)개를 옮겼습니다(쓰기 대기)."), none: String(ui: "재생 목록을 옮기지 않았습니다"))
    }

    // MARK: - 끌기

    /// 끌기를 시작한 줄이 실을 목록. 여럿 고른 것 중 하나면 고른 것 모두(`targets` 규칙), 아니면 그 줄만이다.
    /// 놓는 쪽이 고른 항목 위에는 놓지 않게(`refusesPlaylistDrop`) 고른 항목을 적어 둔다.
    func dragIDs(for id: String) -> [String] {
        guard isSelectingManyPlaylists, selection.contains(.playlist(id)) else {
            draggingPlaylistIDs = [id]
            return [id]
        }
        let chosen = selection.compactMap(\.playlistID)
        draggingPlaylistIDs = Set(chosen)
        return targets(chosen)
    }

    /// 끄는 재생 목록 중 하나 위에는 놓지 않는다(옮길 자리가 옮기는 항목이다)
    func refusesPlaylistDrop(on id: String) -> Bool { draggingPlaylistIDs.contains(id) }

    // MARK: - 알림

    private func deletePrompt(_ deleting: [EditPlaylists.BatchOutcome], skipped: [EditPlaylists.BatchOutcome], folders: Bool) -> ReflectionPrompt {
        let title = folders ? String(ui: "재생 목록·폴더 \(deleting.count)개를 지울까요?") : String(ui: "재생 목록 \(deleting.count)개를 지울까요?")
        var lines = [Self.names(deleting.map(Self.name))]
        if folders { lines.append(String(ui: "폴더 안의 목록도 함께 지웁니다.")) }
        lines.append(String(ui: "rekordbox에 쓰기 전까지는 초안이라 실행 취소(⌘Z)로 되돌릴 수 있습니다."))
        if !skipped.isEmpty { lines.append(String(ui: "건너뛸 항목: \(Self.reasons(skipped))")) }
        return ReflectionPrompt(title: title, text: lines.joined(separator: "\n"), confirm: String(ui: "지우기"), destructive: true)
    }

    /// 쌓은 것과 건너뛴 것을 알린다. 건너뛴 항목은 이름과 이유를 보인다
    private func report(_ batch: EditPlaylists.Batch, done: String, none: String) {
        let skipped = batch.outcomes.filter { $0.status == .skipped }
        guard batch.hasChanges else {
            if !skipped.isEmpty { announce(none + ": " + Self.reasons(skipped), warning: true) }
            return
        }
        guard !skipped.isEmpty else { return announce(done, warning: false) }
        announce(done + " " + String(ui: "건너뛴 \(skipped.count)개: \(Self.reasons(skipped))"), warning: true)
    }

    private func announce(_ text: String, warning: Bool) {
        playlists.playlistMessage = AppMessage(kind: warning ? .warning : .success, text: text)
    }

    /// 이름을 보일 수(넘으면 "외 N개"로 줄인다)
    static let listedLimit = 10

    static func name(_ outcome: EditPlaylists.BatchOutcome) -> String {
        let name = outcome.name ?? outcome.playlistID ?? ""
        return name.isEmpty ? String(ui: "(이름 없음)") : name
    }

    /// ‘가’, ‘나’ … 외 N개
    static func names(_ names: [String]) -> String {
        let listed = names.prefix(listedLimit).map { "‘\($0)’" }.joined(separator: ", ")
        return names.count > listedLimit ? listed + " " + String(ui: "외 \(names.count - listedLimit)개") : listed
    }

    /// ‘가’ — 이유 · ‘나’ — 이유 … 외 N개
    static func reasons(_ skipped: [EditPlaylists.BatchOutcome]) -> String {
        let listed = skipped.prefix(listedLimit).map { "‘\(name($0))’ — \($0.reason ?? "")" }.joined(separator: " · ")
        return skipped.count > listedLimit ? listed + " " + String(ui: "외 \(skipped.count - listedLimit)개") : listed
    }
}

extension SidebarItem {
    var playlistID: String? { if case let .playlist(id) = self { id } else { nil } }
    var isPlaylist: Bool { playlistID != nil }
}
