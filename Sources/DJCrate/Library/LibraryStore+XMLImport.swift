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
        guard let snapshot = snapshotURL else { return }
        cancelXMLImport()
        isReadingXMLImport = true
        var isDirectory: ObjCBool = false
        let share = FileManager.default.fileExists(atPath: shareRoot.path, isDirectory: &isDirectory) && isDirectory.boolValue ? shareRoot : nil
        xmlImportTask = Task { [weak self] in
            // 떼어 낸 작업은 부른 작업의 취소를 물려받지 않으므로 취소를 넘겨준다.
            let work = Task.detached(priority: .userInitiated) { () -> Result<XMLImportPreview, any Error> in
                Result {
                    let xml = try RekordboxXMLReader.read(url: url)
                    try Task.checkCancellation()
                    let library = try RekordboxXMLImport.library(snapshot: snapshot, shareRoot: share, gridsFor: xml)
                    try Task.checkCancellation()
                    return XMLImportPreview(fileName: url.lastPathComponent, snapshot: snapshot, shareRoot: share, xml: xml, library: library,
                                            diff: XMLLibraryDiff.compute(xml: xml, library: library))
                }
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled else { return }
            isReadingXMLImport = false
            xmlImportTask = nil
            switch result {
            case let .success(preview): xmlImportPreview = preview
            case .failure(is CancellationError): break
            case let .failure(error): stagingMessage = AppMessage(kind: .failure, text: Self.xmlImportFailure(error))
            }
        }
    }

    /// 읽는 중인 가져오기와 계획 중인 초안 만들기를 멈춘다(시트를 닫거나 새로 가져올 때). 저장을 시작한 초안은 끝까지 쓴다.
    func cancelXMLImport() {
        xmlImportTask?.cancel()
        xmlImportDraftTask?.cancel()
        isReadingXMLImport = false
    }

    static func xmlImportFailure(_ error: any Error) -> String {
        let reason = (error as? RekordboxXMLReader.ReadError)?.reason ?? AppErrorMessage.message(for: error)
        return String(ui: "rekordbox XML을 가져오지 못했습니다: \(reason)")
    }

    /// 미리 보기 시트의 "초안으로 만들기". 닫으면 취소할 수 있게 작업을 들고 있는다.
    func startXMLImportDrafts(_ preview: XMLImportPreview, selection: XMLImportDrafts.Selection) {
        xmlImportDraftTask?.cancel()
        xmlImportDraftTask = Task { [weak self] in await self?.makeXMLImportDrafts(preview, selection: selection) }
    }

    /// 고른 차이를 초안으로 만든다. 저장 전 입력(메모리 태그 초안·저장하지 못한 큐·그리드)과 기존 초안 파일은 덮지 않고,
    /// 재생 목록은 메모리 초안에 편집을 덧붙여 저장한다. 계획과 파일 저장은 메인 스레드 밖에서 한다.
    /// 덱에 올린 곡의 그리드 초안은 덱이 받아 자기 저장 경로로 쓴다(따로 쓰면 덱의 다음 편집·되돌리기가 그 파일을 덮거나 지운다).
    @discardableResult
    func makeXMLImportDrafts(_ preview: XMLImportPreview, selection: XMLImportDrafts.Selection,
                             home: URL = DJCPaths.userData) async -> XMLImportDraftResult {
        isMakingXMLImportDrafts = true
        defer { isMakingXMLImportDrafts = false }
        _ = DraftWriter.flush()
        let folders = XMLImportDraftStore.Folders(home: home)
        let unsaved = DraftWriter.unsavedUUIDs(cueDirectory: folders.cues, gridDirectory: folders.grids)
        var existing: [XMLImportDrafts.Kind: Set<String>] = [.cue: unsaved, .grid: unsaved, .tag: Set(tagDrafts.keys)]
        // 덱에서 고친 그리드는 파일보다 덱이 최신일 수 있다.
        if let deck = deckGridDraftState?(), deck.hasChanges { existing[.grid, default: []].insert(deck.uuid) }
        let playlistBase = playlistDraft
        let diff = preview.diff, snapshot = preview.snapshot, share = preview.shareRoot
        let planned = await Task.detached(priority: .userInitiated) {
            Result {
                try XMLImportDraftStore.plan(diff: diff, selection: selection, snapshot: snapshot, shareRoot: share, folders: folders,
                                             playlistDraft: playlistBase, existing: existing)
            }
        }.value
        var result = XMLImportDraftResult()
        guard !Task.isCancelled else { return result }
        do {
            var plan = try planned.get()
            let playlist = plan.playlistDraft
            plan.playlistDraft = nil
            // 덱에 올린 곡의 그리드는 아래에서 덱에 넘긴다.
            let deckUUID = deckGridDraftState?()?.uuid
            let deckGrid = plan.gridDrafts.first { $0.trackUUID == deckUUID }
            var files = plan
            files.gridDrafts.removeAll { $0.trackUUID == deckUUID }
            let saved = try await Task.detached(priority: .userInitiated) {
                try XMLImportDraftStore.save(files, folders: folders, playlistBase: playlistBase)
            }.value
            result.cues = saved.saved[.cue, default: 0]
            result.grids = saved.saved[.grid, default: 0]
            result.tags = saved.saved[.tag, default: 0]
            result.skipped = plan.skipped + saved.raced
            result.losses = plan.losses
            if let deckGrid {
                let subject = plan.titles[deckGrid.trackUUID] ?? deckGrid.trackUUID
                let skipped = XMLImportDrafts.Note(kind: .grid, libraryKey: nil, subject: subject, reason: XMLImportDrafts.existingReason(.grid))
                if let deck = deckGridDraftState?(), deck.uuid == deckGrid.trackUUID {
                    // 저장하는 동안 덱에서 그리드를 고쳤으면 덱 초안을 남긴다.
                    if !deck.hasChanges, adoptImportedGridDraft?(deckGrid) == true { result.grids += 1 } else { result.skipped.append(skipped) }
                } else {
                    // 그 사이 덱의 곡이 바뀌었으면 파일로 쓴다.
                    var rest = XMLImportDrafts.Plan()
                    rest.gridDrafts = [deckGrid]
                    rest.titles = plan.titles
                    let other = try XMLImportDraftStore.save(rest, folders: folders, playlistBase: playlistBase)
                    result.grids += other.saved[.grid, default: 0]
                    result.skipped += other.raced
                }
            }
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
