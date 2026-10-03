import DJCDomain
import RekordboxKit

/// 옮기기 미리 보기·쓰기 요약. 세션의 계획에서 수·막힘·규칙만 받아 곡 제목이나 경로는 담지 않는다.
struct UsbMigrationSummary: Equatable, Sendable {
    var trackCount: Int
    var playlistCount: Int
    var artworkFiles: Int
    var blocks: [UsbBlock]
    var rules: [UsbProvisionalRule]
    var notes: [String]
    var hasChanges: Bool
    var isTestVolume: Bool

    var canWrite: Bool { blocks.isEmpty && hasChanges && trackCount > 0 }
    var stopping: String {
        var seen: Set<String> = []
        return blocks.map(\.message).filter { seen.insert($0).inserted }.joined(separator: "\n")
    }
}

extension UsbMigrationSummary {
    init(result: UsbMigrationResult, volume: UsbVolumeInfo) {
        self.init(trackCount: result.trackCount, playlistCount: result.playlistCount, artworkFiles: result.artworkFiles,
                  blocks: result.blocks, rules: (result.changes?.requiredRules ?? []).sorted { $0.rawValue < $1.rawValue },
                  notes: result.notes, hasChanges: result.changes != nil, isTestVolume: volume.isDiskImage)
    }
}

struct UsbMigrationWritten: Sendable {
    var summary: UsbMigrationSummary
    var report: UsbWriteReport?
}
