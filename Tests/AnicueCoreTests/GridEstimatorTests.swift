@testable import AnicueCore
import Foundation
import Testing

@Suite("그리드 추정")
struct GridEstimatorTests {
    /// 고정 BPM 박에 결정적 흔들림(±4ms)을 넣고, 몇 박은 빼고, 마디 시작은 `downbeatOffset`번째 박부터 4박마다.
    func beats(bpm: Double, count: Int, start: Double = 0.31, missing: Set<Int> = [], downbeatOffset: Int = 0) -> (beats: [Double], bars: [Double]) {
        let period = 60 / bpm
        var beats: [Double] = [], bars: [Double] = []
        for i in 0..<count where !missing.contains(i) {
            let jitter = Double((i * 37) % 9 - 4) / 1000
            beats.append(start + Double(i) * period + jitter)
        }
        for i in stride(from: downbeatOffset, to: count, by: 4) { bars.append(start + Double(i) * period) }
        return (beats, bars)
    }

    @Test func 고정_템포는_한_구간과_정확한_BPM() throws {
        let input = beats(bpm: 154, count: 400, missing: [50, 51, 200])
        let estimate = try #require(GridEstimator.estimate(beats: input.beats, bars: input.bars, duration: 170))
        #expect(estimate.segments.count == 1)
        #expect(abs(estimate.bpm - 154) < 0.02)
        #expect(estimate.isConfident)
        // 첫 박(0.31초 근처)이 1박
        let grid = GridDraft(trackUUID: "t", base: [], segments: estimate.segments).grid(duration: 170)
        let near = try #require(grid.beats.min { abs($0.time - 0.31) < abs($1.time - 0.31) })
        #expect(abs(near.time - 0.31) < 0.006)
        #expect(near.number == 1)
    }

    @Test func 마디_시작이_셋째_박이면_그_박이_1박() throws {
        let input = beats(bpm: 170, count: 300, downbeatOffset: 2)
        let estimate = try #require(GridEstimator.estimate(beats: input.beats, bars: input.bars, duration: 120))
        let grid = GridDraft(trackUUID: "t", base: [], segments: estimate.segments).grid(duration: 120)
        let third = 0.31 + 2 * 60 / 170
        let beat = try #require(grid.beats.min { abs($0.time - third) < abs($1.time - third) })
        #expect(beat.number == 1)
        #expect(estimate.downbeatConfidence > 0.9)
    }

    @Test func 절반_템포는_두_배로_옮긴다() throws {
        // MU가 178 BPM 곡을 89로 잡은 경우(라이브러리 BPM은 105~215)
        let input = beats(bpm: 89, count: 200)
        let estimate = try #require(GridEstimator.estimate(beats: input.beats, bars: input.bars, duration: 140))
        #expect(abs(estimate.bpm - 178) < 0.05)
    }

    @Test func 템포가_바뀌면_구간을_나눈다() throws {
        let first = beats(bpm: 120, count: 120)
        let switchTime = 0.31 + 120 * 0.5
        let second = beats(bpm: 150, count: 150, start: switchTime)
        let estimate = try #require(GridEstimator.estimate(beats: first.beats + second.beats, bars: first.bars + second.bars, duration: 130))
        #expect(estimate.segments.count == 2)
        #expect(abs(estimate.segments[0].bpm - 120) < 0.05)
        #expect(abs(estimate.segments[1].bpm - 150) < 0.05)
        // 경계 박(60.31초)은 두 템포 모두에 놓이므로 구간 시작은 그 박이나 다음 박일 수 있다. 만들어지는 박으로 본다.
        let grid = GridDraft(trackUUID: "t", base: [], segments: estimate.segments).grid(duration: 130)
        func has(_ time: Double) -> Bool { grid.beats.contains { abs($0.time - time) < 0.006 } }
        #expect(has(switchTime - 0.5) && has(switchTime) && has(switchTime + 0.4) && has(switchTime + 0.8))
        #expect(!has(switchTime + 0.5), "옛 템포 박이 변속 뒤에 남으면 안 된다")
    }

    @Test func 박이_너무_적으면_추정하지_않는다() {
        #expect(GridEstimator.estimate(beats: [0.5, 1.0, 1.5], bars: [], duration: 10) == nil)
    }
}

@Suite("rekordbox XML")
struct RekordboxXMLTests {
    func staged(path: String = "/Volumes/T7 Shield/새 폴더/곡 & 이름 (TV).mp3") -> StagedTrack {
        StagedTrack(uuid: "u1", path: path, title: #"제목 "따옴표" <꺾쇠>"#, artist: "아티스트", genre: "애니송",
                    comment: "TVA 테큐 OP 2", duration: 269.4, addedOn: "2026-09-25")
    }

    @Test func 첫_템포_구간은_곡_시작_쪽_첫_박으로_당긴다() {
        // 154 BPM, 첫 박 번호 1인 박이 10.0초 → 0~0.39초 사이 첫 박으로, 박 번호도 함께 되돌린다.
        let period = 60 / 154.0
        let normalized = RekordboxXML.normalized([GridSegment(start: 10.0, bpm: 154.0, firstBeatNumber: 1)])
        #expect(normalized.count == 1)
        #expect(normalized[0].start >= 0 && normalized[0].start < period)
        let movedBeats = Int(((10.0 - normalized[0].start) / period).rounded())
        #expect(normalized[0].firstBeatNumber == ((1 - 1 - movedBeats) % 4 + 4) % 4 + 1)
    }

    @Test func 문서는_올바른_XML이고_값이_보존된다() throws {
        let cues = [EditableCue(kind: .memory, time: 12.3456, name: "인트로"), EditableCue(kind: .hot(2), time: 30.0)]
        let entry = RekordboxXML.Entry(track: staged(), tempos: [GridSegment(start: 0.256, bpm: 153.9987, firstBeatNumber: 1)], cues: cues)
        let xml = RekordboxXML.document(entries: [entry], playlistName: "anicue 추가")
        let parser = XMLParser(data: Data(xml.utf8))
        final class Collector: NSObject, XMLParserDelegate {
            var elements: [(String, [String: String])] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                elements.append((name, attributes))
            }
        }
        let collector = Collector()
        parser.delegate = collector
        #expect(parser.parse(), "XML 파싱 실패: \(String(describing: parser.parserError))")
        let track = try #require(collector.elements.first { $0.0 == "TRACK" && $0.1["TrackID"] != nil }?.1)
        #expect(track["Name"] == #"제목 "따옴표" <꺾쇠>"#)
        #expect(track["Location"] == "file://localhost/Volumes/T7%20Shield/%EC%83%88%20%ED%8F%B4%EB%8D%94/%EA%B3%A1%20&%20%EC%9D%B4%EB%A6%84%20(TV).mp3")
        #expect(track["AverageBpm"] == "154.00")
        #expect(track["TotalTime"] == "269")
        let tempo = try #require(collector.elements.first { $0.0 == "TEMPO" }?.1)
        #expect(tempo["Inizio"] == "0.256" && tempo["Bpm"] == "154.00" && tempo["Battito"] == "1" && tempo["Metro"] == "4/4")
        let marks = collector.elements.filter { $0.0 == "POSITION_MARK" }.map(\.1)
        #expect(marks.count == 2)
        #expect(marks[0]["Num"] == "-1" && marks[0]["Start"] == "12.346" && marks[0]["Name"] == "인트로")
        #expect(marks[1]["Num"] == "2" && marks[1]["Type"] == "0")
        #expect(collector.elements.contains { $0.0 == "NODE" && $0.1["Name"] == "anicue 추가" && $0.1["Entries"] == "1" })
    }

    @Test func 그리드가_없으면_TEMPO를_쓰지_않는다() {
        let xml = RekordboxXML.document(entries: [.init(track: staged(), tempos: [], cues: [])], playlistName: "p")
        #expect(!xml.contains("<TEMPO"))
        #expect(!xml.contains("AverageBpm"))
    }
}

@Suite("시간축 이동")
struct TimelineShiftTests {
    @Test func 옮겼다_되돌리면_원래대로() {
        let draft = GridDraft(trackUUID: "t", base: [GridSegment(start: 0.2, bpm: 150, firstBeatNumber: 1)],
                              segments: [GridSegment(start: 0.25, bpm: 151, firstBeatNumber: 3)])
        let back = draft.shifted(by: -0.0512).shifted(by: 0.0512)
        #expect(abs(back.segments[0].start - 0.25) < 1e-9 && abs(back.base[0].start - 0.2) < 1e-9)
        #expect(!draft.shifted(by: 0.05).hasChanges == !draft.hasChanges)

        var cues = CueDraft(trackUUID: "t", rekordboxCues: [])
        cues.cues = [EditableCue(kind: .memory, time: 1.0)]
        #expect(abs(cues.shifted(by: -0.048).cues[0].time - 0.952) < 1e-9)
    }
}
