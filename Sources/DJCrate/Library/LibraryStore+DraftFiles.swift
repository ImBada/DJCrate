import DJCDomain
import DJCStorage
import Foundation

/// 읽지 못한 초안 파일과 재생 목록 초안 저장 실패(#174).
/// 손상된 파일은 지우지 않고 `damaged-drafts`에 옮겨 알리고, 메모리에 남은 입력은 다시 저장한다.
extension LibraryStore {
    /// 옮긴 초안 파일을 알린다(닫을 때까지 남고, 그사이 더 옮기면 수를 더한다).
    /// 추가 목록(`staged.json`)은 초안이 아니라 곡 파일 경로의 목록이라 파일 수에 세지 않고 다시 추가할 일을 따로 안내한다(#178).
    func reportDamagedDrafts(_ entries: [DamagedDrafts.Entry]) {
        guard !entries.isEmpty else { return }
        let fresh = draftFileMessage == nil
        let drafts = entries.filter { $0.name != StagingStore.fileName }
        damagedDraftCount = (fresh ? 0 : damagedDraftCount) + drafts.count
        damagedStagedList = (fresh ? false : damagedStagedList) || drafts.count < entries.count
        FileHandle.standardError.write(Data("[초안 파일] 읽지 못해 옮긴 파일 \(entries.count)개: \(entries.map(\.name).joined(separator: ", "))\n".utf8))
        draftFileMessage = AppMessage(kind: .warning, text: Self.damagedDraftText(damagedDraftCount, stagedList: damagedStagedList))
    }

    static func damagedDraftText(_ count: Int, stagedList: Bool = false) -> String {
        var sentences: [String] = []
        if count > 0 {
            sentences.append(String(ui: "초안 파일 \(count)개를 읽지 못해 DJCrate 데이터 폴더의 damaged-drafts에 옮겨 두었으니 필요한 곡의 초안을 다시 만드세요."))
        }
        if stagedList {
            sentences.append(String(ui: "추가한 곡 목록 파일을 읽지 못해 DJCrate 데이터 폴더의 damaged-drafts에 옮겨 두었으니 추가했던 곡 파일을 다시 추가하세요."))
        }
        return sentences.joined(separator: " ")
    }

    /// 합치기 초안·추가 목록 저장이 손상된 기존 파일을 옮겼으면 알린다(저장 중 옮긴 파일은 기록만 남는다).
    /// 메모리 값으로 새 파일을 썼으니 그 목록이 비어 있지 않으면 잃은 것이 없어 알리지 않는다.
    func reportDraftFilesMovedBySave() {
        guard let draftHome else { return }
        applyMovedDrafts(DamagedDrafts.take(home: draftHome).filter {
            switch $0.name {
            case StagingStore.fileName: staged.isEmpty
            case DuplicateMergeDraftStore.fileName: mergeDrafts.isEmpty
            default: true
            }
        })
    }

    var mergeDraftURL: URL { (draftHome ?? DJCPaths.userData).appending(path: DuplicateMergeDraftStore.fileName) }
    var stagedListURL: URL { (draftHome ?? DJCPaths.userData).appending(path: StagingStore.fileName) }

    /// 데이터 폴더의 손상된 초안 파일을 옮기고 알린다. 메모리에 남은 태그·재생 목록 초안은 다시 저장하고, 옮긴 초안의 표시를 거둔다.
    /// - Returns: 옮긴 파일
    @discardableResult
    func preserveDamagedDraftFiles(previousTags: [String: TagDraft]? = nil,
                                   previousPlaylist: PlaylistDraft? = nil) -> [DamagedDrafts.Entry] {
        guard let draftHome else { return [] }
        let moved = DraftWriter.preserveDamagedDrafts(home: draftHome)
        applyMovedDrafts(moved, previousTags: previousTags, previousPlaylist: previousPlaylist)
        return moved
    }

    /// 옮긴 파일을 화면 상태에 반영한다. 메모리 입력(태그·재생 목록)이 있으면 그것을 다시 저장해 잃지 않는다.
    func applyMovedDrafts(_ moved: [DamagedDrafts.Entry], previousTags: [String: TagDraft]? = nil,
                          previousPlaylist: PlaylistDraft? = nil, reporting: Bool = true) {
        guard !moved.isEmpty else { return }
        if reporting { reportDamagedDrafts(moved) }
        let tags = previousTags ?? tagDrafts
        var resave: [TagDraft] = []
        for entry in moved {
            guard let uuid = entry.trackUUID else { continue }
            switch entry.name.split(separator: "/").first.map(String.init) ?? "" {
            case "tag-drafts":
                if let draft = tags[uuid], draft.hasChanges {
                    tagDrafts[uuid] = draft
                    resave.append(draft)
                }
            case "cue-drafts" where DraftWriter.pendingCue(trackUUID: uuid)?.hasChanges != true:
                draftCueCounts[uuid] = nil
                draftChanged(trackUUID: uuid, kind: .cue, exists: false)
            case "grid-drafts" where DraftWriter.pendingGrid(trackUUID: uuid)?.hasChanges != true:
                draftChanged(trackUUID: uuid, kind: .grid, exists: false)
            default: break
            }
        }
        if !resave.isEmpty {
            persistTagDrafts(resave)
            DraftWriter.flush()
            tagRevision += 1
        }
        if moved.contains(where: { $0.name == "gain-drafts.json" }) { refreshGainDraftUUIDs() }
        if moved.contains(where: { $0.name == "playlist-drafts.json" }) {
            let draft = previousPlaylist ?? playlistDraft
            if !draft.isEmpty {
                playlistDraft = draft
                savePlaylistDraft()
                refreshPlaylists()
            }
        }
    }

    /// 쓰기 전에: 대상 곡의 초안 파일이 손상돼 옮겼으면 쓰지 않고 알린다(미리 보기에서 조용히 빠지지 않게).
    func requireReadableDrafts(for uuids: Set<String>, playlists: Bool) throws {
        let moved = preserveDamagedDraftFiles()
        let affected = moved.contains { entry in
            if let uuid = entry.trackUUID { return uuids.contains(uuid) }
            return entry.name == "gain-drafts.json" || (playlists && entry.name == "playlist-drafts.json")
        }
        guard affected else { return }
        throw DJCError.writeRefused(String(ui: "읽지 못한 초안 파일을 damaged-drafts에 옮겨 두었으니 남은 초안을 확인한 뒤 쓰기를 다시 시도하세요."))
    }

    /// 게인 초안 파일을 읽는다. 읽지 못하면 빈 값으로 넘기지 않고 쓰기를 막는다.
    func readGainDrafts() throws -> [String: Double] {
        do { return try GainDraftStore.read() }
        catch {
            throw DJCError.writeRefused(String(ui: "게인 초안 파일을 읽지 못했으니 DJCrate 데이터 폴더의 접근 권한을 확인한 뒤 쓰기를 다시 시도하세요."))
        }
    }

    /// 디스크와 저장하지 못한 입력을 합친 게인 초안 곡
    func refreshGainDraftUUIDs() {
        var uuids = GainDraftStore.uuids()
        for uuid in DraftWriter.unsavedUUIDs() {
            guard let pending = DraftWriter.pendingGain(trackUUID: uuid) else { continue }
            if pending == nil { uuids.remove(uuid) } else { uuids.insert(uuid) }
        }
        for uuid in uuids.symmetricDifference(gainDraftUUIDs) {
            draftChanged(trackUUID: uuid, kind: .gain, exists: uuids.contains(uuid))
        }
    }

    // MARK: - 재생 목록 초안 저장

    static var playlistSaveFailureText: String {
        String(ui: "재생 목록 초안을 저장하지 못했으니 DJCrate 데이터 폴더의 쓰기 권한을 확인한 뒤 쓰기를 다시 시도하세요.")
    }

    /// 메모리 초안을 저장한다. 실패하면 메모리 초안을 그대로 두고 기록해, 쓰기 전에 다시 저장한다.
    @discardableResult
    func savePlaylistDraft() -> Bool {
        do {
            try playlistDraftSaver(playlistDraft)
            playlistDraftUnsaved = false
            if playlistMessage?.text == Self.playlistSaveFailureText { playlistMessage = nil }
            return true
        } catch {
            playlistDraftUnsaved = true
            AppErrorMessage.log(error)
            playlistMessage = AppMessage(kind: .warning, text: Self.playlistSaveFailureText)
            return false
        }
    }

    /// 쓰기 전에: 저장하지 못한 재생 목록 초안은 다시 저장해 보고, 그래도 안 되면 쓰지 않는다.
    func requirePlaylistDraftSaved() throws {
        guard playlistDraftUnsaved else { return }
        guard savePlaylistDraft() else { throw DJCError.writeRefused(Self.playlistSaveFailureText) }
    }
}
