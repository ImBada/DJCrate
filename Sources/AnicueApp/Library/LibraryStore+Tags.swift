import RekordboxKit
import AnicueAnalysis
import AnicueDomain
import AnicueStorage
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

    struct TagEdit: Sendable {
        let trackUUID: String
        let key: TagFields.Key
        let old: String
        let new: String
    }

    var canUndoTags: Bool { !undoStack.isEmpty }
    var canRedoTags: Bool { !redoStack.isEmpty }

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
        var edits: [TagEdit] = []
        for change in changes {
            let old = tagCell(change.row, change.key)
            guard old != change.value else { continue }
            edits.append(TagEdit(trackUUID: change.row.track.uuid, key: change.key, old: old, new: change.value))
        }
        guard !edits.isEmpty else { return }
        apply(edits, forward: true)
        undoStack.append(edits)
        redoStack.removeAll()
    }

    func undoTags() {
        guard let edits = undoStack.popLast() else { return }
        apply(edits, forward: false)
        redoStack.append(edits)
    }

    func redoTags() {
        guard let edits = redoStack.popLast() else { return }
        apply(edits, forward: true)
        undoStack.append(edits)
    }

    /// 곡별로 묶어 초안을 한 번만 고치고, 곡마다 한 번만 백그라운드에서 저장한다.
    func apply(_ edits: [TagEdit], forward: Bool) {
        var touched: [String: TagDraft] = [:]
        for edit in edits {
            guard let row = rowsByUUID[edit.trackUUID] else { continue }
            var draft = touched[edit.trackUUID] ?? tagDraft(for: row)
            draft.fields[edit.key] = forward ? edit.new : edit.old
            touched[edit.trackUUID] = draft
        }
        var updated = tagDrafts
        for (uuid, draft) in touched { updated[uuid] = draft.hasChanges ? draft : nil }
        tagDrafts = updated
        for uuid in touched.keys { updateEdited(uuid) }
        DraftWriter.save(Array(touched.values))
        tagRevision += 1
    }
}
