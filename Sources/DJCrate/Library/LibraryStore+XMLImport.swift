import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 가져오기 차이 미리 보기 시트의 내용
struct XMLImportPreview: Identifiable, Sendable {
    let id = UUID()
    var fileName: String
    var snapshot: URL
    var shareRoot: URL?
    var xml: XMLLibrary
    var library: XMLLibrary
    var diff: XMLLibraryDiff.Result
}

/// 초안 만들기 결과(시트가 보여 준다)
struct XMLImportDraftResult: Equatable {
    var cues = 0
    var grids = 0
    var tags = 0
    var playlists = 0
    var skipped: [XMLImportDrafts.Note] = []
    var losses: [XMLImportDrafts.Note] = []
    var failure: String?
}

/// 파일 메뉴의 "rekordbox XML 가져오기…"(#72). 다른 도구가 만든 rekordbox XML을 메인 스레드 밖에서 읽어 지금 라이브러리와 비교하고,
/// 고른 차이를 초안으로만 만든다. rekordbox에는 쓰지 않는다(쓰기는 "rekordbox에 쓰기"가 다른 초안과 똑같이 한다).
extension LibraryStore {
    /// - Parameter shareRoot: 분석 파일 뿌리(읽기만). 시험은 합성 사본의 `share`를 준다. 없는 폴더면 그리드를 비교하지 않는다.
    func importRekordboxXML(from url: URL, shareRoot: URL = RekordboxShare.directory) {
        guard !isReadingXMLImport, let snapshot = snapshotURL else { return }
        isReadingXMLImport = true
        var isDirectory: ObjCBool = false
        let share = FileManager.default.fileExists(atPath: shareRoot.path, isDirectory: &isDirectory) && isDirectory.boolValue ? shareRoot : nil
        xmlImportTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<XMLImportPreview, any Error> in
                Result {
                    let xml = try RekordboxXMLReader.read(url: url)
                    try Task.checkCancellation()
                    let library = try RekordboxXMLImport.library(snapshot: snapshot, shareRoot: share)
                    return XMLImportPreview(fileName: url.lastPathComponent, snapshot: snapshot, shareRoot: share, xml: xml, library: library,
                                            diff: XMLLibraryDiff.compute(xml: xml, library: library))
                }
            }.value
            guard let self else { return }
            isReadingXMLImport = false
            xmlImportTask = nil
            switch result {
            case let .success(preview): xmlImportPreview = preview
            case let .failure(error): stagingMessage = AppMessage(kind: .failure, text: Self.xmlImportFailure(error))
            }
        }
    }

    static func xmlImportFailure(_ error: any Error) -> String {
        let reason = (error as? RekordboxXMLReader.ReadError)?.reason ?? AppErrorMessage.message(for: error)
        return String(ui: "rekordbox XML을 가져오지 못했습니다: \(reason)")
    }

    /// 고른 차이를 초안으로 만든다. 저장 전 입력(메모리 태그 초안·저장하지 못한 큐·그리드)과 기존 초안 파일은 덮지 않고,
    /// 재생 목록은 메모리 초안에 편집을 덧붙여 저장한다. 계획은 메인 스레드 밖에서 세운다.
    @discardableResult
    func makeXMLImportDrafts(_ preview: XMLImportPreview, selection: XMLImportDrafts.Selection,
                             home: URL = DJCPaths.userData) async -> XMLImportDraftResult {
        isMakingXMLImportDrafts = true
        defer { isMakingXMLImportDrafts = false }
        _ = DraftWriter.flush()
        let folders = XMLImportDraftStore.Folders(home: home)
        let unsaved = DraftWriter.unsavedUUIDs(cueDirectory: folders.cues, gridDirectory: folders.grids)
        let existing: [XMLImportDrafts.Kind: Set<String>] = [.cue: unsaved, .grid: unsaved, .tag: Set(tagDrafts.keys)]
        let playlistBase = playlistDraft
        let diff = preview.diff, snapshot = preview.snapshot, share = preview.shareRoot
        let planned = await Task.detached(priority: .userInitiated) {
            Result {
                try XMLImportDraftStore.plan(diff: diff, selection: selection, snapshot: snapshot, shareRoot: share, folders: folders,
                                             playlistDraft: playlistBase, existing: existing)
            }
        }.value
        var result = XMLImportDraftResult()
        do {
            var plan = try planned.get()
            let playlist = plan.playlistDraft
            plan.playlistDraft = nil
            let saved = try XMLImportDraftStore.save(plan, folders: folders, playlistBase: playlistBase)
            let raced = Set(saved.raced.map(\.subject))
            result.cues = plan.cueDrafts.filter { !raced.contains($0.trackUUID) }.count
            result.grids = plan.gridDrafts.filter { !raced.contains($0.trackUUID) }.count
            result.tags = plan.tagDrafts.filter { !raced.contains($0.trackUUID) }.count
            result.skipped = plan.skipped + saved.raced
            result.losses = plan.losses
            if let playlist {
                // 계획을 세우는 동안 사이드바에서 재생 목록을 고쳤으면 덮지 않는다.
                if playlistDraft == playlistBase {
                    playlistDraft = playlist
                    savePlaylistDraft()
                    refreshPlaylists()
                    result.playlists = plan.playlistLists
                } else {
                    result.skipped.append(XMLImportDrafts.Note(kind: .playlist, libraryKey: nil, subject: "",
                                                               reason: XMLImportDrafts.existingReason(.playlist)))
                }
            }
            if result.cues + result.grids + result.tags > 0 { refreshExternalDrafts(home: home) }
        } catch {
            result.failure = String(ui: "초안을 만들지 못했습니다: \(AppErrorMessage.message(for: error))")
        }
        if xmlImportPreview?.id == preview.id { xmlImportResult = result }
        return result
    }
}
