import Foundation

/// 재생 퀀타이즈(rekordbox QUANTIZE의 재생 쪽): 재생 중에 핫큐를 누르면 바로 넘어가지 않고
/// 누른 뒤 다음 박 조각(1/4·1/2·1박) 경계에서 넘어간다. 그 경계가 박 안 어디였는지(¼ 단위면 0·¼·½·¾)를
/// 큐 쪽에서도 지켜 착지해 박자가 끊기지 않는다(1박 단위면 정확히 큐 위치).
/// 큐를 찍을 때 박에 맞추는 퀀타이즈(`BeatGrid.snap`)와는 따로 켜고 끈다.
public struct PlayQuantize: Sendable, Equatable {
    /// 고를 수 있는 단위(박)
    public static let choices: [Double] = [0.25, 0.5, 1]
    /// rekordbox 기본값과 같은 1/4박
    public static let defaultBeats = 0.25

    public let grid: BeatGrid
    /// 경계 단위(박)
    public let beats: Double

    /// 그리드가 없거나 단위가 잘못되면 nil(퀀타이즈하지 않고 바로 넘어간다).
    public init?(grid: BeatGrid?, beats: Double) {
        guard let grid, !grid.beats.isEmpty, beats.isFinite, beats > 0 else { return nil }
        self.grid = grid
        self.beats = beats
    }

    /// 넘어가는 곡 위치(경계)와 착지 곡 위치(rekordbox 시간축)
    public struct Jump: Equatable, Sendable {
        public var at: Double
        public var to: Double

        public init(at: Double, to: Double) {
            self.at = at
            self.to = to
        }
    }

    /// `time` 이상인 첫 경계와 그 경계의 박 안 위치(0..<1)
    public func boundary(atOrAfter time: Double) -> (time: Double, phase: Double) {
        let coordinate = grid.beatCoordinate(at: time)
        // 경계 위(부동소수 오차 안)는 그 경계로 본다.
        let step = ((coordinate - 1e-9) / beats).rounded(.up)
        let target = step * beats
        let phase = target - target.rounded(.down)
        return (grid.time(atBeatCoordinate: target), phase)
    }

    /// 큐의 박 좌표에 박 안 위치를 더한 곳. 루프 핫큐라 루프 끝을 넘으면 큐 그대로.
    public func landing(cue: Double, phase: Double, loopEnd: Double? = nil) -> Double {
        guard phase > 0 else { return cue }
        let landing = grid.time(atBeatCoordinate: grid.beatCoordinate(at: cue) + phase)
        if let loopEnd, landing >= loopEnd - 0.001 { return cue }
        return landing
    }

    /// `earliest`(예약할 수 있는 가장 이른 곡 위치) 뒤 첫 경계에서 `cue` 쪽으로 넘어가는 점프
    public func jump(earliest: Double, to cue: Double, loopEnd: Double? = nil) -> Jump {
        let boundary = boundary(atOrAfter: earliest)
        return Jump(at: boundary.time, to: landing(cue: cue, phase: boundary.phase, loopEnd: loopEnd))
    }
}
