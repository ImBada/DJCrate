import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation
import Observation

/// 태그 편집: 초안만 바뀌고, 시트(엑셀식) 일괄 편집은 되돌리기 단위로 묶는다.
extension LibraryStore {
    // MARK: - 태그 편집 (초안만 바뀐다)

    func tagDraft(for row: TrackRow) -> TagDraft {
        tagDrafts[row.track.uuid] ?? TagDraft(track: row.track)
    }

    /// 선택한 곡들의 값. 모두 같으면 그 값, 다르면 `mixed`.
    func tagValue(_ key: TagFields.Key, rows: [TrackRow]) -> (value: String, mixed: Bool) {
        guard let first = rows.first else { return ("", false) }
        let value = tagCell(first, key)
        for row in rows.dropFirst() where tagCell(row, key) != value { return ("", true) }
        return (value, false)
    }

    func setTag(_ key: TagFields.Key, _ value: String, rows: [TrackRow]) {
        applyTagEdits(rows.map { (row: $0, key: key, value: value) })
    }

    func revertTags(rows: [TrackRow]) {
        applyTagEdits(rows.flatMap { row in
            TagFields.Key.allCases.map { (row: row, key: $0, value: tagDraft(for: row).base[$0]) }
        })
    }

    // MARK: - 태그 시트(엑셀식) 일괄 편집 + 되돌리기

    func tagCell(_ row: TrackRow, _ key: TagFields.Key) -> String {
        if let draft = tagDrafts[row.track.uuid] { return draft.fields[key] }
        return TagFields(track: row.track)[key]
    }

    func isTagEdited(_ row: TrackRow, _ key: TagFields.Key) -> Bool {
        guard let draft = tagDrafts[row.track.uuid] else { return false }
        return draft.base[key] != draft.fields[key]
    }

    /// 여러 셀을 한 번에 바꾼다. 되돌리기 한 단위가 된다.
    func applyTagEdits(_ changes: [(row: TrackRow, key: TagFields.Key, value: String)]) {
        guard !isWritingRekordbox else { return }
        var before: [String: TagDraft] = [:]
        var after: [String: TagDraft] = [:]
        for change in changes where !change.row.track.isStreaming {
            let uuid = change.row.track.uuid
            let original = tagDraft(for: change.row)
            before[uuid] = original
            var edited = after[uuid] ?? original
            edited.fields[change.key] = change.value
            after[uuid] = edited
        }
        guard let change = DraftChange(before: before, after: after) else { return }
        applyTagSnapshot(after)
        registerTagUndo(change)
    }

    private func registerTagUndo(_ change: DraftChange<[String: TagDraft]>) {
        guard let undoManager else { return }
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        let groupsByEvent = undoManager.groupsByEvent
        if grouping {
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
        }
        undoManager.registerUndo(withTarget: self) { target in
            guard !target.isWritingRekordbox else { return }
            target.applyTagSnapshot(change.before)
            target.registerTagUndo(change.reversed)
        }
        undoManager.setActionName(String(ui: "태그 편집"))
        if grouping {
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = groupsByEvent
        }
    }

    /// 곡별 초안 전체를 복원해 base와 여러 칸을 함께 보존한다.
    private func applyTagSnapshot(_ drafts: [String: TagDraft]) {
        var updated = tagDrafts
        for (uuid, draft) in drafts { updated[uuid] = draft.hasChanges ? draft : nil }
        tagDrafts = updated
        for uuid in drafts.keys { updateEdited(uuid) }
        saveTagDrafts(Array(drafts.values))
        tagRevision += 1
    }
}
