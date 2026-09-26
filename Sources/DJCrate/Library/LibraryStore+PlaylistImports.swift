import DJCDomain
import DJCStorage
import Foundation

extension LibraryStore {
    func resetPlaylistImports(contentIDs: Set<String>) {
        guard !contentIDs.isEmpty else { return }
        var imports = playlistImports, draft = playlistDraft
        imports.reset(contentIDs: contentIDs)
        draft.forgetContentIDs(contentIDs, rekordbox: rekordboxPlaylists)
        do {
            try playlistDraftSaver(draft)
            playlistDraft = draft
            refreshPlaylists()
            savePlaylistImports(imports)
        } catch {
            playlistMessage = AppMessage(kind: .warning,
                                         text: String(ui: "재생 목록 초안을 저장하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하세요: \(error.localizedDescription)"))
        }
    }

    func loadPlaylistImports() {
        guard let playlistImportURL else { return }
        do { playlistImports = try PlaylistImportStore.load(url: playlistImportURL) }
        catch {
            playlistImportsLoadFailed = true
            playlistMessage = AppMessage(kind: .warning, text: String(ui: "재생 목록 연결을 읽지 못했습니다. DJCrate 데이터 폴더의 playlist-imports.json을 확인한 뒤 앱을 다시 여세요."))
        }
    }

    @discardableResult
    func savePlaylistImports(_ imports: PlaylistImports) -> Bool {
        guard !playlistImportsLoadFailed else { return false }
        guard imports != playlistImports else { return true }
        do {
            if let playlistImportURL { try PlaylistImportStore.save(imports, url: playlistImportURL) }
            playlistImports = imports
            return true
        } catch {
            playlistMessage = AppMessage(kind: .warning, text: String(ui: "재생 목록 연결을 저장하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하고 다시 시도하세요."))
            return false
        }
    }

    /// 직접 추가·XML 가져오기 모두 새 스냅샷에서 컬렉션 등록을 확인한 뒤 연결한다.
    /// 초안 저장에 실패하면 연결은 남기며, 연결 저장만 실패하면 다음 읽기에서 중복 없이 다시 확인한다.
    func resolvePlaylistImports(contentIDsByPath: [String: String]? = nil) {
        guard !playlistImportsLoadFailed, playlistImports.pendingCount > 0 else { return }
        let ids = contentIDsByPath ?? Dictionary(rows.map { (PlaylistImports.pathKey($0.track.folderPath), $0.track.id) },
                                                 uniquingKeysWith: { first, _ in first })
        var imports = playlistImports, draft = playlistDraft
        let reasons = imports.reconcile(contentIDsByPath: ids, draft: &draft, rekordbox: rekordboxPlaylists)
        do {
            if draft != playlistDraft {
                try playlistDraftSaver(draft)
                playlistDraft = draft
                refreshPlaylists()
            }
            guard savePlaylistImports(imports) else { return }
            if let reason = reasons.first { playlistMessage = AppMessage(kind: .warning, text: reason) }
        } catch {
            playlistMessage = AppMessage(kind: .warning,
                                         text: String(ui: "재생 목록 초안을 저장하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하세요: \(error.localizedDescription)"))
        }
    }
}
