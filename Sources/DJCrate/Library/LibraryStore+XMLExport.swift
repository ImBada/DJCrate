import DJCDomain
import Foundation
import RekordboxKit

/// 라이브러리 XML 내보내기 진행. 읽기(곡·그리드)가 앞 70%, 쓰기가 나머지다.
struct LibraryXMLExportJob: Equatable {
    var fraction = 0.0
    /// 곡 수를 알기 전(라이브러리 읽는 중)
    var isPreparing = true

    mutating func apply(_ progress: RekordboxLibraryXML.Progress) {
        let part = progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0
        switch progress.phase {
        case .readingLibrary: fraction = 0; isPreparing = true
        case .readingGrids: fraction = max(fraction, 0.7 * part); isPreparing = false
        case .writing: fraction = max(fraction, 0.7 + 0.3 * part); isPreparing = false
        }
    }
}

/// 파일 메뉴의 "라이브러리 XML 내보내기…". 스냅샷(지금 화면의 라이브러리)과 분석 파일을 읽기만 하고 고른 파일 하나에만 쓴다.
/// 쓰지 않은 초안은 넣지 않는다(rekordbox에 있는 그대로). 무거운 일은 메인 스레드 밖에서 돈다.
extension LibraryStore {
    /// - Parameter shareRoot: 분석 파일 뿌리. 시험은 합성 사본의 `share`를 준다.
    func exportLibraryXML(to url: URL, shareRoot: URL = RekordboxShare.directory) {
        guard xmlExportJob == nil, let snapshot = snapshotURL else { return }
        do {
            try RekordboxLibraryXML.checkOutput(url)
        } catch {
            stagingMessage = AppMessage(kind: .failure, text: Self.xmlExportFailure(error))
            return
        }
        xmlExportJob = LibraryXMLExportJob()
        xmlExportTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<RekordboxLibraryXML.Summary, any Error> in
                Result {
                    try RekordboxLibraryXML.export(snapshot: snapshot, shareRoot: shareRoot, to: url) { progress in
                        Task { @MainActor in self?.xmlExportJob?.apply(progress) }
                    }
                }
            }.value
            self?.finishXMLExport(result, url: url)
        }
    }

    private func finishXMLExport(_ result: Result<RekordboxLibraryXML.Summary, any Error>, url: URL) {
        xmlExportJob = nil
        xmlExportTask = nil
        switch result {
        case let .success(summary):
            stagingMessage = AppMessage(kind: .success, text: Self.xmlExportSuccess(summary, name: url.lastPathComponent))
        case let .failure(error):
            stagingMessage = AppMessage(kind: .failure, text: Self.xmlExportFailure(error))
        }
    }

    static func xmlExportSuccess(_ summary: RekordboxLibraryXML.Summary, name: String) -> String {
        var lines = [String(ui: "라이브러리 XML을 내보냈습니다: \(name) · 곡 \(summary.tracks) · 큐·루프 \(summary.marks) · 재생 목록 \(summary.playlists)")]
        let omitted = summary.omitted
        if omitted.streamingTracks + omitted.intelligentPlaylists + omitted.unknownCues + omitted.playlistEntries + omitted.orphanedPlaylists > 0 {
            lines.append(String(ui: "뺀 것: 스트리밍 곡 \(omitted.streamingTracks) · 인텔리전트 목록 \(omitted.intelligentPlaylists) · XML로 옮길 수 없는 큐 \(omitted.unknownCues) · 뺀 곡을 가리킨 목록 항목 \(omitted.playlistEntries) · 상위 폴더가 없는 목록 \(omitted.orphanedPlaylists)"))
        }
        lines.append(String(ui: "쓰지 않은 초안은 넣지 않았습니다(rekordbox에 있는 그대로입니다)"))
        return lines.joined(separator: "\n")
    }

    static func xmlExportFailure(_ error: any Error) -> String {
        let reason = (error as? RekordboxLibraryXML.OutputError)?.reason ?? AppErrorMessage.message(for: error)
        return String(ui: "라이브러리 XML을 내보내지 못했습니다: \(reason)")
    }
}
