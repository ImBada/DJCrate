import Foundation

// 편집 화면이 쓰는 규칙: 재생 위치에서 N마디 고르기, 이음새 앞뒤 미리 듣기 구간, 출력 마디 수.

public extension BarLayout {
    /// "여기서 N마디": `time`이 든 마디 처음부터 `length`마디(곡 끝에서 자른다). 곡 끝 뒤면 nil.
    /// 첫 다운비트 앞(0마디)이면 맨 앞 구간일 때(`leading`)만 곡 머리를 넣고, 아니면 1마디부터 센다
    /// (0마디는 맨 앞에만 둘 수 있다).
    func range(from time: Double, length: Int, leading: Bool) -> BarRange? {
        let length = max(1, length)
        let bar = bar(at: time)
        if bar == 0, leading, hasLeadIn { return BarRange(0, min(length, count)) }
        let first = max(bar, 1)
        guard first <= count else { return nil }
        return BarRange(first, min(first + length - 1, count))
    }
}

/// 이음새(원본에서 이어지지 않는 구간 경계) 하나와 그 앞뒤를 들어 볼 마디 구간.
public struct EditSeam: Sendable, Equatable {
    /// 이음새 뒤 구간의 목록 순서
    public var index: Int
    /// 앞 조각의 끝 몇 마디 + 뒤 조각의 첫 몇 마디. 이대로 `TrackEdit`을 만들어 렌더하면 이음새 소리가 그대로 난다.
    public var preview: [BarRange]

    public init(index: Int, preview: [BarRange]) {
        self.index = index
        self.preview = preview
    }
}

public extension BarRange {
    /// 구간 목록의 이음새. 원본에서 이어진 구간은 한 조각으로 보고(`TrackEdit`과 같다), 조각 끝·머리에서 `context`마디씩 고른다.
    static func seams(in bars: [BarRange], context: Int = 2) -> [EditSeam] {
        let context = max(1, context)
        var runs: [(range: BarRange, index: Int)] = []
        for (index, range) in bars.enumerated() {
            if let last = runs.last, last.range.last + 1 == range.first {
                runs[runs.count - 1].range.last = range.last
            } else {
                runs.append((range, index))
            }
        }
        return zip(runs, runs.dropFirst()).map { before, after in
            let tail = BarRange(max(before.range.first, before.range.last - context + 1), before.range.last)
            let head = BarRange(after.range.first, min(after.range.last, after.range.first + context - 1))
            return EditSeam(index: after.index, preview: [tail, head])
        }
    }
}

public extension TrackEdit {
    /// 출력 마디 수. 곡 머리(0마디)는 세지 않고, 끝에서 잘린 마지막 마디는 한 마디로 센다.
    var barCount: Int { pieces.reduce(0) { $0 + $1.bars.last - max($1.bars.first, 1) + 1 } }
}
