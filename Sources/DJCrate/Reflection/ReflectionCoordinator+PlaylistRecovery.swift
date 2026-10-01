import DJCDomain
import Foundation

extension ReflectionCoordinator {
    func recoverPlaylistDraft(store: LibraryStore, playlist id: String? = nil) async {
        let ids = id.map { [$0] } ?? store.blockedPlaylistRecoveryIDs
        for id in ids {
            if !store.blockedPlaylistRecoveryIDs.contains(id) { continue }
            do {
                let review = try await store.preparePlaylistRecovery(playlist: id)
                let canReapply = !review.recovery.reapplied.isEmpty
                switch prompter.choose(Self.playlistRecoveryConfirmation(review)) {
                case .cancel: continue
                case .confirm: try await store.applyPlaylistRecovery(review, reapply: canReapply)
                case .alternate: try await store.applyPlaylistRecovery(review, reapply: false)
                }
                store.toast = AppToast(kind: .success, title: String(ui: "재생 목록 초안을 저장했습니다"),
                                       detail: String(ui: "쓰기 미리 보기에서 최신 목록과 쓸 수 없는 편집을 다시 확인하세요."))
            } catch is CancellationError { return }
            catch {
                _ = prompter.show(ReflectionPrompt(title: String(ui: "재생 목록 초안을 복구하지 못했습니다"),
                                                  text: AppErrorMessage.message(for: error)))
                return
            }
        }
    }

    static func playlistRecoveryConfirmation(_ review: PlaylistRecoveryReview) -> ReflectionPrompt {
        let id = review.playlistID, current = review.current.layout
        let title = current.item(id)?.name ?? review.original.base[id]?.name ?? String(ui: "사라진 목록")
        func name(_ id: String, layout: PlaylistLayout) -> String {
            if id == PlaylistLayout.root { return String(ui: "맨 위") }
            return layout.item(id)?.name ?? review.original.base[id]?.name ?? String(ui: "사라진 목록")
        }
        func tracks(_ entries: [PlaylistEntry]) -> [String] {
            entries.map { String(ui: "\($0.trackNo)번째 · \(review.current.titles[$0.contentID] ?? String(ui: "사라진 곡"))") }
        }
        func baseDescription(_ base: PlaylistDraft.Base?, id: String) -> [String] {
            guard let base else { return [String(ui: "사라진 목록")] }
            if id == PlaylistLayout.root {
                return [String(ui: "맨 위")] + (base.childIDs ?? []).map { name($0, layout: current) }
            }
            var lines = [base.name, String(ui: "폴더: \(name(base.parentID, layout: current))")]
            if let children = base.childIDs { lines += children.map { name($0, layout: current) } }
            if !base.isFolder { lines += tracks(base.entries) }
            return lines
        }
        func itemDescription(_ id: String, layout: PlaylistLayout) -> [String] {
            if id == PlaylistLayout.root { return layout.children(of: id).map(\.name) }
            guard let item = layout.item(id) else { return [String(ui: "사라진 목록")] }
            var lines = [item.name, String(ui: "폴더: \(name(item.parentID, layout: layout))")]
            if item.isFolder {
                for child in layout.childIDs(of: id) {
                    lines += itemDescription(child, layout: layout)
                }
            } else { lines += tracks(item.entries) }
            return lines
        }
        var bases: [String: PlaylistDraft.Base] = [:]
        for index in review.blockedOffsets {
            let step = review.original.steps[index]
            for dependency in step.depends {
                if bases[dependency] == nil { bases[dependency] = (step.recoveryBase ?? review.original.base)[dependency] }
            }
        }
        var details = [String(ui: "기준:")] + baseDescription(bases[id], id: id)
            + [String(ui: "현재:")] + itemDescription(id, layout: current)
        for dependency in bases.keys.sorted() where dependency != id {
            details += [String(ui: "함께 확인할 목록: \(name(dependency, layout: current))"), String(ui: "기준:")]
                + baseDescription(bases[dependency], id: dependency) + [String(ui: "현재:")] + itemDescription(dependency, layout: current)
        }
        details += [String(ui: "내 편집:")]
        for index in review.blockedOffsets {
            details.append(playlistEditDescription(review.original.steps[index].edit, current: review.current))
            if let reason = review.recovery.refused[index] { details.append(String(ui: "이 편집은 다시 적용하지 못했으니 그대로 남기거나 버리고 다시 편집하세요: \(reason)")) }
        }
        if !review.recovery.reapplied.isEmpty {
            details += [String(ui: "다시 적용한 뒤:")] + itemDescription(id, layout: review.recovery.draft.project(onto: current).layout)
        } else {
            details.append(String(ui: "다시 적용할 수 있는 편집이 없으니 초안을 버리거나 취소하고 목록을 다시 편집하세요."))
        }
        let text = String(ui: "다시 적용할 수 있는 \(review.recovery.reapplied.count)건은 현재 목록에 초안으로 쌓고 나머지는 그대로 남기니, 비교한 뒤 다시 적용하거나 이 목록의 막힌 초안을 버리세요.")
        let canReapply = !review.recovery.reapplied.isEmpty
        return ReflectionPrompt(title: String(ui: "‘\(title)’의 현재 목록을 비교하세요"), text: text,
                                confirm: canReapply ? String(ui: "다시 적용") : String(ui: "초안 버리기"),
                                destructive: !canReapply, details: details,
                                alternate: canReapply ? String(ui: "초안 버리기") : nil,
                                cancel: String(ui: "선택하지 않고 남기기"))
    }

    private static func playlistEditDescription(_ edit: PlaylistEdit, current: PlaylistRecoveryCurrent) -> String {
        func target(_ ref: PlaylistRef) -> String {
            ref == .root ? String(ui: "맨 위") : current.layout.item(ref.layoutID)?.name ?? String(ui: "사라진 목록")
        }
        func titles(_ ids: [String]) -> String { ids.map { current.titles[$0] ?? String(ui: "사라진 곡") }.joined(separator: ", ") }
        switch edit {
        case let .create(_, name, _, parent): return String(ui: "‘\(target(parent))’ 안에 ‘\(name)’ 만들기")
        case let .rename(_, name): return String(ui: "이름을 ‘\(name)’으로 바꾸기")
        case let .move(_, into): return String(ui: "‘\(target(into))’ 안으로 옮기기")
        case let .reorder(_, index): return String(ui: "폴더 안 \(index + 1)번째로 옮기기")
        case .delete: return String(ui: "목록과 그 안의 항목 지우기")
        case let .addTracks(_, ids): return String(ui: "끝에 곡 넣기: \(titles(ids))")
        case let .removeTracks(_, entries): return String(ui: "목록에서 곡 빼기: \(titles(entries.map(\.contentID)))")
        case let .moveTracks(_, entries, to): return String(ui: "\(to)번째로 곡 옮기기: \(titles(entries.map(\.contentID)))")
        }
    }
}

extension DraftRecoveryPanels {
    static func recoverPlaylists(store: LibraryStore, playlist id: String? = nil) {
        guard !store.isRecoveringDraft, !store.isWritingRekordbox, store.writeTask == nil else { return }
        store.writeTask = Task {
            defer { store.writeTask = nil }
            await ReflectionCoordinator(host: store).recoverPlaylistDraft(store: store, playlist: id)
        }
    }
}
