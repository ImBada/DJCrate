import DJCDomain
import DJCStorage
import Foundation

/// 스냅샷의 곡·추가한 곡 어디에도 이어지지 않는 초안(#175). 어디서 왔는지 모르므로 자동으로 지우지 않고,
/// 쓰기 대기 목록에서 보여 주고 사용자가 고른 것만 버린다.
struct UnlinkedDraft: Identifiable, Hashable, Sendable {
    enum Kind: CaseIterable, Hashable, Sendable {
        case cue, grid, gain, tag
        var label: String {
            switch self {
            case .cue: String(ui: "큐")
            case .grid: String(ui: "그리드")
            case .gain: String(ui: "게인")
            case .tag: String(ui: "태그")
            }
        }
    }
    var id: String { uuid }
    var uuid: String
    var kinds: [Kind]
    /// 태그 초안에 남은 제목(없으면 nil)
    var title: String?
    var modified: Date?
}

extension LibraryStore {
    /// 초안 파일(저장하지 못한 입력 포함)이 있는 곡 UUID
    private func draftUUIDs(home: URL) -> [String: [UnlinkedDraft.Kind]] {
        let sources: [(UnlinkedDraft.Kind, Set<String>)] = [
            (.cue, CueDraftStore.uuids(directory: home.appending(path: "cue-drafts"))),
            (.grid, GridDraftStore.uuids(directory: home.appending(path: "grid-drafts"))),
            (.gain, GainDraftStore.uuids(url: home.appending(path: "gain-drafts.json"))),
            (.tag, TagDraftStore.uuids(directory: home.appending(path: "tag-drafts"))),
        ]
        var kinds: [String: [UnlinkedDraft.Kind]] = [:]
        for (kind, uuids) in sources { for uuid in uuids { kinds[uuid, default: []].append(kind) } }
        return kinds
    }

    /// 목록 위 안내에 쓸 연결되지 않은 초안 곡을 다시 센다(파일 이름만 본다). 라이브러리를 읽기 전에는 모른다.
    func refreshUnlinkedDrafts() {
        guard case .loaded = phase, !rowsByUUID.isEmpty else {
            if !unlinkedDraftUUIDs.isEmpty { unlinkedDraftUUIDs = [] }
            return
        }
        let linked = Set(rowsByUUID.keys).union(staged.map(\.uuid))
        let unlinked = Set(draftUUIDs(home: draftHome).keys).subtracting(linked)
        if unlinked != unlinkedDraftUUIDs { unlinkedDraftUUIDs = unlinked }
    }

    /// 연결되지 않은 초안의 자세한 목록(최근에 고친 것부터)
    func unlinkedDrafts() -> [UnlinkedDraft] {
        let home = draftHome
        let kinds = draftUUIDs(home: home)
        let folders = ["cue-drafts", "grid-drafts", "tag-drafts"].map { home.appending(path: $0) }
        return unlinkedDraftUUIDs.map { uuid in
            let dates = folders.compactMap { folder in
                (try? folder.appending(path: "\(uuid).json").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            let tag = TagDraftStore.load(trackUUID: uuid, directory: home.appending(path: "tag-drafts"))
            let title = [tag?.fields.title, tag?.base.title].compactMap { $0 }.first { !$0.isEmpty }
            return UnlinkedDraft(uuid: uuid, kinds: kinds[uuid] ?? [], title: title, modified: dates.max())
        }
        .sorted { ($0.modified ?? .distantPast, $1.uuid) > ($1.modified ?? .distantPast, $0.uuid) }
    }

    /// 고른 곡의 초안(큐·그리드·게인·태그)을 버린다. 버리지 못한 곡이 있으면 이유와 할 일을 돌려준다.
    func discardUnlinkedDrafts(_ uuids: Set<String>) -> String? {
        let home = draftHome
        let targets = uuids.intersection(unlinkedDraftUUIDs)
        guard !targets.isEmpty, !isWritingRekordbox else { return nil }
        let cues = home.appending(path: "cue-drafts"), grids = home.appending(path: "grid-drafts")
        let gain = home.appending(path: "gain-drafts.json"), tags = home.appending(path: "tag-drafts")
        let kinds = draftUUIDs(home: home)
        var clearedTags: [TagDraft] = []
        for uuid in targets.sorted() {
            let present = kinds[uuid] ?? []
            // 저장 실패 기록까지 함께 비우려고 DraftWriter로 지운다(손상된 파일은 지우지 않고 옮겨 둔다).
            if present.contains(.cue) { DraftWriter.save(CueDraft(trackUUID: uuid, rekordboxCues: []), directory: cues) }
            if present.contains(.grid) { DraftWriter.save(GridDraft(trackUUID: uuid, base: [], segments: []), directory: grids) }
            if present.contains(.gain) { DraftWriter.save(gain: nil, trackUUID: uuid, url: gain) }
            if present.contains(.tag) {
                tagDrafts[uuid] = nil
                clearedTags.append(TagDraft(trackUUID: uuid, base: TagFields()))
            }
        }
        if !clearedTags.isEmpty {
            persistTagDrafts(clearedTags)
            tagRevision += 1
        }
        DraftWriter.flush()
        applyMovedDrafts(DamagedDrafts.take(home: home))
        let failed = Set(DraftWriter.failures(cueDirectory: cues, gridDirectory: grids, gainURL: gain).map(\.trackUUID))
            .union(failedTagSaves(in: tags)).intersection(targets)
        refreshUnlinkedDrafts()
        guard !failed.isEmpty else { return nil }
        return String(ui: "\(failed.count)곡의 초안을 버리지 못했으니 초안 폴더의 접근 권한을 확인한 뒤 다시 버리세요.")
    }
}
