import Foundation

/// 템포 구간 하나. rekordbox XML의 `<TEMPO Inizio Bpm Metro Battito>`와 같은 모델이다.
public struct GridSegment: Codable, Hashable, Sendable {
    /// 구간 첫 박의 시각(초)
    public var start: Double
    public var bpm: Double
    /// 구간 첫 박의 박 번호(1~4)
    public var firstBeatNumber: Int

    public init(start: Double, bpm: Double, firstBeatNumber: Int) {
        self.start = start
        self.bpm = bpm
        self.firstBeatNumber = firstBeatNumber
    }
}

/// 곡 하나의 비트 그리드 초안. 변속곡은 구간이 여러 개다.
/// rekordbox에는 쓰지 않는다(검증된 반영 경로를 통해서만 나간다).
public struct GridDraft: Codable, Sendable {
    public var trackUUID: String
    public var base: [GridSegment]
    public var segments: [GridSegment]

    public init(trackUUID: String, grid: BeatGrid) {
        self.trackUUID = trackUUID
        base = GridDraft.segments(from: grid)
        segments = base
    }

    /// 부동소수 오차(±10ms 이동 후 되돌리기 등)는 변경으로 보지 않는다.
    public var hasChanges: Bool {
        guard segments.count == base.count else { return true }
        return zip(segments, base).contains { a, b in
            abs(a.start - b.start) >= 0.0005 || abs(a.bpm - b.bpm) >= 0.0005 || a.firstBeatNumber != b.firstBeatNumber
        }
    }

    /// PQTZ 박 목록을 템포 구간으로 묶는다. BPM은 저장된 반올림 값(×100 정수) 대신
    /// 구간 첫 박~마지막 박 간격으로 다시 구해 재생성 오차를 줄인다.
    public static func segments(from grid: BeatGrid) -> [GridSegment] {
        var groups: [[BeatGrid.Beat]] = []
        for beat in grid.beats {
            // 템포가 같아도 박 간격이 예상과 5ms 넘게 다르면(위상 점프) 새 구간으로 본다.
            if let last = groups.last?.last, abs(last.bpm - beat.bpm) < 0.005,
               abs((beat.time - last.time) - 60 / beat.bpm) < 0.005 {
                groups[groups.count - 1].append(beat)
            } else {
                groups.append([beat])
            }
        }
        return groups.map { beats in
            let first = beats[0]
            var bpm = first.bpm
            if beats.count > 8, let last = beats.last {
                let interval = (last.time - first.time) / Double(beats.count - 1)
                if interval > 0 { bpm = 60 / interval }
            }
            return GridSegment(start: first.time, bpm: bpm, firstBeatNumber: first.number)
        }
    }

    /// 구간으로 박을 다시 만든다. 첫 구간은 곡 시작 쪽으로도 늘린다.
    public func grid(duration: Double) -> BeatGrid {
        var beats: [BeatGrid.Beat] = []
        for (index, segment) in segments.enumerated() where segment.bpm > 0 {
            let interval = 60 / segment.bpm
            let end = index + 1 < segments.count ? segments[index + 1].start : duration + 0.0005
            var k = index == 0 ? -Int((segment.start / interval).rounded(.down)) : 0
            while true {
                let t = segment.start + Double(k) * interval
                if t >= end - 0.0005 { break }
                if t >= 0 {
                    let number = ((segment.firstBeatNumber - 1 + k) % 4 + 4) % 4 + 1
                    beats.append(.init(number: number, bpm: segment.bpm, time: (t * 1000).rounded() / 1000))
                }
                k += 1
            }
        }
        return BeatGrid(beats: beats)
    }

    public func segmentIndex(at time: Double) -> Int {
        segments.lastIndex { $0.start <= time + 0.0005 } ?? 0
    }

    // MARK: - rekordbox식 편집

    /// 그리드 전체를 옮긴다.
    public mutating func shift(by seconds: Double) {
        for i in segments.indices { segments[i].start += seconds }
    }

    public mutating func setBPM(_ bpm: Double, at time: Double) {
        guard bpm >= 20, bpm <= 999 else { return }
        let index = segmentIndex(at: time)
        // 표시값(소수 둘째 자리)을 그대로 다시 넣는 경우는 무시한다. 그렇지 않으면 실측 BPM
        // (예: 153.9987)이 154.00으로 바뀌어 500박이면 약 16ms 어긋난다.
        guard abs(segments[index].bpm - bpm) >= 0.005 else { return }
        segments[index].bpm = (bpm * 100).rounded() / 100
    }

    /// `time`에 가장 가까운 박을 1박(마디 시작)으로 만든다.
    public mutating func setDownbeat(nearest time: Double, duration: Double) {
        guard let beat = grid(duration: duration).beats.min(by: { abs($0.time - time) < abs($1.time - time) }) else { return }
        // 가장 가까운 박이 다음 구간에 속할 수 있으므로 박 위치로 구간을 고른다.
        let index = segmentIndex(at: beat.time)
        let f = segments[index].firstBeatNumber
        segments[index].firstBeatNumber = ((f - beat.number) % 4 + 4) % 4 + 1
    }

    /// `time`에 박을 정확히 놓고 그 박을 1박으로 만든다(해당 구간의 시작점 이동).
    public mutating func setAnchor(at time: Double) {
        let index = segmentIndex(at: time)
        guard index == 0 || time > segments[index - 1].start else { return }
        segments[index].start = time
        segments[index].firstBeatNumber = 1
    }

    /// `time`에 가장 가까운 박에서 새 템포 구간을 시작한다(변속 지점).
    public mutating func addTempoChange(nearest time: Double, duration: Double) {
        guard let beat = grid(duration: duration).beats.min(by: { abs($0.time - time) < abs($1.time - time) }),
              !segments.contains(where: { abs($0.start - beat.time) < 0.001 })
        else { return }
        let bpm = segments[segmentIndex(at: beat.time)].bpm
        segments.append(GridSegment(start: beat.time, bpm: bpm, firstBeatNumber: beat.number))
        segments.sort { $0.start < $1.start }
    }

    public mutating func removeTempoChange(at index: Int) {
        guard index > 0, segments.indices.contains(index) else { return }
        segments.remove(at: index)
    }

    public mutating func revert() {
        segments = base
    }
}

public enum GridDraftStore {
    public static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "anicue/grid-drafts")
    }

    public static func load(trackUUID: String) -> GridDraft? {
        guard let data = try? Data(contentsOf: directory.appending(path: "\(trackUUID).json")) else { return nil }
        return try? JSONDecoder().decode(GridDraft.self, from: data)
    }

    public static func save(_ draft: GridDraft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(draft.trackUUID).json")
        if draft.hasChanges {
            try JSONEncoder().encode(draft).write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static func uuids() -> Set<String> { DraftFiles.uuids(in: directory) }
}

enum DraftFiles {
    static func uuids(in directory: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }
}

public extension CueDraftStore {
    static func uuids() -> Set<String> { DraftFiles.uuids(in: directory) }
}
