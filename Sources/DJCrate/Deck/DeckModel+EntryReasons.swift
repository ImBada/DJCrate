import DJCDomain
import Foundation

extension DeckModel {
    var playbackUnavailableReason: String? {
        guard !canPlay else { return nil }
        guard let row else { return String(ui: "목록에서 곡을 골라 덱에 불러오세요") }
        if row.track.isStreaming { return String(ui: "스트리밍 곡은 재생할 수 없으니 로컬 음원 파일이 있는 곡을 고르세요") }
        if !FileManager.default.fileExists(atPath: row.track.folderPath) {
            return String(ui: "음원 파일이 없으니 외장 드라이브를 연결하거나 rekordbox에서 파일 위치를 확인하세요")
        }
        return String(ui: "음원 파일을 아직 재생할 수 없으니 불러오기가 끝날 때까지 기다린 뒤 파일 형식과 접근 권한을 확인하세요")
    }

    var hotCueCreationUnavailableReason: String? {
        if isWriteLocked { return String(ui: "rekordbox 쓰기가 끝난 뒤 편집하세요") }
        if draft == nil { return String(ui: "곡을 덱에 불러오고 초안 읽기가 끝난 뒤 편집하세요") }
        return canPlay || grid != nil || instantLoop != nil ? nil : playbackUnavailableReason
    }

    var gridUnavailableReason: String? {
        if isWriteLocked { return String(ui: "rekordbox 쓰기가 끝난 뒤 편집하세요") }
        if row?.track.isStreaming == true { return String(ui: "스트리밍 곡은 그리드를 편집할 수 없으니 로컬 음원 파일이 있는 곡을 고르세요") }
        if let gridEditBlockedReason { return gridEditBlockedReason }
        return gridDraft == nil ? gridSourceNotice ?? String(ui: "곡을 덱에 불러오고 그리드 읽기가 끝난 뒤 편집하세요") : nil
    }
}
