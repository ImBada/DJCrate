import DJCAnalysis
import DJCDomain
import Foundation

/// 키 고르기(태그 인스펙터·태그 시트)의 규칙: 고를 수 있는 이름, 곡 묶음의 지금 값, 고칠 수 있는 곡, DJCrate 추정 제안(#5).
/// 키는 글자를 직접 쓰지 않고 rekordbox 키 목록의 Camelot 이름(1A~12B)과 "없음"에서만 고른다. 목록의 키 칸은 보기만 한다.
enum KeyPicker {
    /// 곡 여럿의 키가 서로 다를 때 고르기 목록의 현재 표식(고를 수 있는 값이 아니다)
    static let mixedTag = "\u{1}mixed"

    /// 이 곡의 키를 못 고치는 이유(고칠 수 있으면 nil). 추가한 곡은 곡을 rekordbox에 넣을 때 키를 쓰지 않아(KeyID '0') 고른 키가 사라지므로 막는다.
    static func unavailableReason(_ row: TrackRow) -> String? {
        TrackListTagEditing.unavailableReason(row, key: .musicalKey)
    }

    /// 고르기를 쓸 수 있는 곡이 하나라도 있는지(고른 곡 가운데 고칠 수 없는 곡은 쓰기에서 빼고 알린다)
    static func isEditable(_ rows: [TrackRow]) -> Bool { rows.contains { unavailableReason($0) == nil } }

    /// 고르기에서 고른 값을 초안에 넣을 곡: 고칠 수 없는 곡(추가한 곡·USB·스트리밍)은 뺀다.
    static func targets(_ rows: [TrackRow]) -> [TrackRow] { rows.filter { unavailableReason($0) == nil } }

    /// 고르기 목록의 글자(없음 · 24개 이름, 현재 값이 옛 표기이면 맨 앞에 그대로)
    static func choices(current: String) -> [String] { KeyNotation.pickerChoices(current: current) }

    // MARK: DJCrate 추정 제안

    /// 분석 캐시에 크로마가 이미 있는 곡만 추정한다. 캐시가 없으면 계산하지 않는다: 크로마는 곡 전체를 읽어야 해서 인스펙터에서 돌리지 않는다
    /// (덱이 곡을 불러올 때 캐시를 만든다). 오디오 스레드가 아니라 백그라운드에서 부른다.
    nonisolated static func cachedEstimate(uuid: String, file: URL, duration: Double) -> String? {
        guard let chroma = AnalysisCache.chroma(key: uuid, file: file), !chroma.frames.isEmpty else { return nil }
        return KeyAnalyzer.mainKey(chroma: chroma, windows: KeyAnalyzer.windows(grid: nil, duration: duration))?.camelot
    }

    /// 인스펙터에 보일 제안. 곡 하나를 골랐고, 키를 고칠 수 있고, 지금 키가 비었고, 추정이 Camelot 이름일 때만 있다.
    /// 제안은 보이기만 한다: 사용자가 눌러야 초안에 들어간다(이슈 #5 결정: 사용자가 확인한 키만 쓴다).
    static func suggestion(estimate: String?, rows: [TrackRow], current: (value: String, mixed: Bool)) -> String? {
        guard let estimate, KeyNotation.camelotNames.contains(estimate), rows.count == 1, let row = rows.first,
              unavailableReason(row) == nil, !current.mixed, current.value.isEmpty else { return nil }
        return estimate
    }

    /// 추정을 구할 곡(캐시를 읽을 곡): 고를 수 있는 곡 하나이고 rekordbox 키가 비어 있을 때
    static func suggestionTarget(rows: [TrackRow]) -> (uuid: String, path: String, duration: Double)? {
        guard rows.count == 1, let row = rows.first, unavailableReason(row) == nil, (row.track.key ?? "").isEmpty else { return nil }
        return (row.track.uuid, row.track.folderPath, Double(row.track.lengthSeconds))
    }

    // MARK: 시트·붙여넣기 입력

    /// 시트 붙여넣기·채우기에서 키 칸이 받는 값. 비웠으면 "", Camelot 이름이면 정확한 이름, 아니면 nil(건너뛴다).
    static func accepted(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : KeyNotation.normalizedCamelotName(trimmed)
    }
}
