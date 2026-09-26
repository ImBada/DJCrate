import DJCDomain
import Foundation

/// 목록용 PWAV 미리 보기. 높이는 하위 5비트(0~31)이며 재생 시각과 무관하다.
public struct AnlzPreviewWaveform: Sendable, Equatable {
    public let heights: [UInt8]

    public init?(file: AnlzFile) throws {
        guard let tag = file.tag("PWAV") else { return nil }
        let bytes = [UInt8](tag.bytes)
        guard bytes.count >= 20 else { throw DJCError.invalidAnalysisFile("PWAV 머리가 짧음") }
        let header = Int(AnlzFile.u32(bytes, 4)), count = Int(AnlzFile.u32(bytes, 12))
        guard header >= 20, header <= bytes.count, count <= bytes.count - header else {
            throw DJCError.invalidAnalysisFile("PWAV 길이가 맞지 않음")
        }
        guard count > 0 else { return nil }
        heights = bytes[header..<header + count].map { $0 & 0x1F }
    }

    private init(heights: [UInt8]) { self.heights = heights }

    /// 짧은 피크와 곡 끝이 사라지지 않도록 겹치지 않는 구간의 최대값을 남긴다.
    public func downsampled(to points: Int) -> Self {
        guard points > 0 else { return Self(heights: []) }
        guard heights.count > points else { return self }
        return Self(heights: (0..<points).map { index in
            let start = index * heights.count / points, end = (index + 1) * heights.count / points
            return heights[start..<end].max() ?? 0
        })
    }
}
