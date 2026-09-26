import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

extension LibraryStore {
    func stageMerge(_ draft: DuplicateMergeDraft) throws {
        guard !isWritingRekordbox else { return }
        guard Set(draft.members.map(\.trackUUID)).isDisjoint(with: pendingUUIDs), playlistDraft.isEmpty else {
            throw DuplicateMerge.Blocked(String(ui: "같은 곡의 다른 초안이나 재생 목록 초안이 있습니다. 먼저 반영하거나 버린 뒤 합치세요"))
        }
        try setMergeDrafts(mergeDrafts + [draft])
    }

    func setMergeDrafts(_ drafts: [DuplicateMergeDraft]) throws {
        let before = mergeDrafts
        try mergeDraftSaver(drafts)
        mergeDrafts = drafts
        refreshBase()
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            guard !target.isWritingRekordbox else { return }
            do { try target.setMergeDrafts(before) }
            catch { target.reflectionMessage = AppMessage(kind: .warning, text: error.localizedDescription) }
        }
        undoManager.setActionName(String(ui: "중복 곡 합치기 초안"))
    }

    /// DB는 이미 반영·복원됐다. 초안 저장 오류를 쓰기 실패로 바꾸면 되돌리기 안내까지 잃는다.
    func saveMergeDraftsAfterWrite(_ drafts: [DuplicateMergeDraft]) {
        mergeDrafts = drafts
        do { try mergeDraftSaver(drafts) }
        catch {
            reflectionMessage = AppMessage(kind: .warning, text: String(ui: "라이브러리는 반영했지만 합치기 초안 파일을 저장하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하세요"))
        }
    }

    func prepareMerge(keeping id: String, removing: [String], prompter: any ReflectionPrompter = AlertPrompter()) async {
        guard let snapshotURL, !isWritingRekordbox else { return }
        do {
            let draft = try await Task.detached(priority: .userInitiated) {
                try RekordboxWriter.prepareMerge(keeping: id, removing: removing, snapshot: snapshotURL)
            }.value
            guard !isWritingRekordbox else { return }
            let details = [String(ui: "남길 곡: \(draft.keeping.title)") + "\n" + (rowsByID[id]?.track.folderPath ?? "")]
                + draft.removing.map { String(ui: "컬렉션에서 뺄 곡: \($0.title)") + "\n" + (rowsByID[$0.contentID]?.track.folderPath ?? "") }
            let prompt = ReflectionPrompt(title: String(ui: "같은 음원인지 확인하고 합치기 초안을 만들까요?"),
                                          text: String(ui: "직접 미리 들어 같은 음원인지 확인하세요. 인코더 지연만 보정하며, 곡 앞뒤의 편집 차이는 보정하지 않습니다. 초안은 ⇧⌘E로 반영합니다.")
                                            + "\n\n" + DuplicateMerge.lossNotice,
                                          confirm: String(ui: "같은 음원 확인 · 초안 만들기"), destructive: true, details: details)
            if prompter.show(prompt) { try stageMerge(draft) }
        } catch {
            _ = prompter.show(ReflectionPrompt(title: String(ui: "합치기 초안을 만들지 않았습니다"),
                                              text: (error as? PlaylistLayout.Blocked)?.reason ?? error.localizedDescription))
        }
    }
}
