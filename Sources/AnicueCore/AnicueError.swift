import Foundation

public enum AnicueError: Error, CustomStringConvertible {
    case keyDerivationFailed
    case databaseOpenFailed(path: String, message: String)
    case queryFailed(sql: String, message: String)
    case rekordboxRunning
    case writeAheadLogPresent(path: String)
    case sourceChangedDuringCopy(path: String)
    case snapshotNotFound
    case invalidAnalysisFile(String)

    public var description: String {
        switch self {
        case .keyDerivationFailed:
            "rekordbox DB 키를 풀지 못했습니다."
        case let .databaseOpenFailed(path, message):
            "DB를 열지 못했습니다 (\(path)): \(message)"
        case let .queryFailed(sql, message):
            "쿼리 실패: \(message)\n\(sql)"
        case .rekordboxRunning:
            "rekordbox가 실행 중입니다. 종료한 뒤 다시 시도하세요 (읽기 전용 스냅샷은 --force로 강행 가능)."
        case let .writeAheadLogPresent(path):
            "WAL 파일이 남아 있습니다: \(path). rekordbox를 완전히 종료한 뒤 다시 시도하세요."
        case let .sourceChangedDuringCopy(path):
            "복사하는 동안 원본이 바뀌었습니다: \(path). 스냅샷을 버렸습니다."
        case .snapshotNotFound:
            "스냅샷이 없습니다. 먼저 `anicue snapshot`을 실행하세요."
        case let .invalidAnalysisFile(path):
            "rekordbox 분석 파일 형식이 아닙니다: \(path)"
        }
    }
}
