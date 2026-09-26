import DJCAnalysis
import Foundation
import RekordboxKit
import Testing
@testable import djc

@Suite("프레이즈 비교 실험")
struct PhraseEvaluationTests {
    func tag(starts: [Int] = [1, 17, 33], end: Int = 49) -> Data {
        var bytes = [UInt8](repeating: 0, count: 32 + starts.count * 24)
        bytes.replaceSubrange(0..<4, with: "PSSI".utf8)
        func put(_ value: Int, _ offset: Int, _ width: Int = 2) {
            for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * (width - i - 1))) }
        }
        put(32, 4, 4); put(bytes.count, 8, 4); put(24, 12, 4)
        put(starts.count, 16); put(2, 18); put(end, 26); bytes[30] = 4
        for (i, beat) in starts.enumerated() {
            put(i + 1, 32 + 24 * i); put(beat, 34 + 24 * i); put(i + 1, 36 + 24 * i)
        }
        return Data(bytes)
    }

    func grid() -> [BeatGridTags.Beat] {
        (0..<64).map { .init(number: $0 % 4 + 1, bpm100: 12_000, time: Double($0) * 500) }
    }

    @Test func PSSI_칸과_끝은_박_단위로_읽는다() throws {
        let value = try PhraseStructure(data: tag())
        #expect(value.mood == 2 && value.bank == 4 && value.endBeat == 49)
        #expect(value.entries.map(\.beat) == [1, 17, 33])
        #expect(value.entries.map(\.kind) == [1, 2, 3])
        #expect(!value.masked)
    }

    @Test func XOR_내보내기_형식도_읽는다() throws {
        // 공개 마스크 규칙으로 미리 계산한 1개 엔트리 표본(기분 2, 시작 1, 끝 49).
        let hex = "505353490000002000000038000000180001cce0effbe6efaeefeae2eaece6eaf4e8eaf4e2cde2effbe6efaeefead3eaece2eaf4e9eaf5e2"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        let value = try PhraseStructure(data: Data(bytes))
        #expect(value.masked && value.mood == 2 && value.endBeat == 49)
        #expect(value.entries.map(\.beat) == [1])
    }

    @Test func 잘린_길이와_잘못된_순서를_거부한다() {
        for n in [0, 12, 31, 32, 55] { #expect(throws: (any Error).self) { try PhraseStructure(data: tag().prefix(n)) } }
        #expect(throws: (any Error).self) { try PhraseStructure(data: tag(starts: [1, 1])) }
        #expect(throws: (any Error).self) { try PhraseStructure(data: tag(starts: [0])) }
        #expect(throws: (any Error).self) { try PhraseStructure(data: tag(end: 20)) }
        var invalid = tag(); invalid[15] = 25
        #expect(throws: (any Error).self) { try PhraseStructure(data: invalid) }
    }

    @Test func 경계는_한_번만_대응하고_시작과_끝은_제외한다() throws {
        let result = try PhraseEvaluation.compare(phrase: PhraseStructure(data: tag()), grid: grid(),
                                                   sectionStarts: [0, 8, 8.1, 18], offset: 0)
        #expect(result.exact.reference == 2 && result.exact.predicted == 3)
        #expect(result.exact.matched == 1 && result.withinOneBar.matched == 2)
        #expect(result.exact.precision == 1.0 / 3 && result.exact.recall == 0.5)
    }

    @Test func 시간축_보정과_가변_템포를_실제_박으로_환산한다() throws {
        var beats = grid()
        for i in 16..<beats.count { beats[i].time = 8_000 + Double(i - 16) * 250 }
        let result = try PhraseEvaluation.compare(phrase: PhraseStructure(data: tag()), grid: beats,
                                                   sectionStarts: [0, 7.95, 11.95], offset: 0.05)
        #expect(result.exact.matched == 2)
        #expect(result.exact.f1 == 1)
    }

    @Test func 분모가_없으면_만점으로_취급하지_않는다() {
        let value = PhraseEvaluation.Metrics(reference: 0, predicted: 0, matched: 0)
        #expect(value.precision == nil && value.recall == nil && value.f1 == nil)
    }

    @Test func 빈_그리드와_비유한_경계는_거부한다() throws {
        let phrase = try PhraseStructure(data: tag())
        #expect(throws: (any Error).self) { try PhraseEvaluation.compare(phrase: phrase, grid: [], sectionStarts: [0, 8], offset: 0) }
        #expect(throws: (any Error).self) { try PhraseEvaluation.compare(phrase: phrase, grid: grid(), sectionStarts: [0, .nan], offset: 0) }
        var broken = grid(); broken[4].time = 0
        #expect(throws: (any Error).self) { try PhraseEvaluation.compare(phrase: phrase, grid: broken, sectionStarts: [0, 8], offset: 0) }
    }

    @Test func 인자는_코퍼스를_명시하고_상한을_검증한다() throws {
        #expect(throws: (any Error).self) { try PhraseEvaluation.Options(["phrase-eval"]) }
        #expect(throws: (any Error).self) { try PhraseEvaluation.Options(["phrase-eval", "--corpus", "/tmp", "--limit", "0"]) }
        #expect(throws: (any Error).self) { try PhraseEvaluation.Options(["phrase-eval", "--corpus", "/tmp", "--wat"]) }
        #expect(try PhraseEvaluation.Options(["phrase-eval", "--corpus", "/tmp"]).limit == 16)
        #expect(CLI.lab.contains { $0.name == "phrase-eval" })
    }

    func anlz(_ tags: [Data]) -> Data {
        var data = Data("PMAI".utf8)
        for value in [UInt32(12), UInt32(12 + tags.reduce(0) { $0 + $1.count })] {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        for tag in tags { data.append(tag) }
        return data
    }

    @Test func 코퍼스_결과는_익명이며_누락을_분리하고_입력을_보존한다() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "phrase-test-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for i in 1...2 {
            let folder = root.appending(path: "sample-\(i)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try anlz(i == 1 ? [tag()] : []).write(to: folder.appending(path: "ANLZ0000.EXT"))
            try anlz([BeatGridTags.pqtz(grid())]).write(to: folder.appending(path: "ANLZ0000.DAT"))
            try Data().write(to: folder.appending(path: "audio.wav"))
        }
        let before = try Data(contentsOf: root.appending(path: "sample-1/ANLZ0000.EXT"))
        let json = """
        {"duration":32,"beats":[],"bars":[],"sections":[{"start":0,"end":8},{"start":8,"end":16},{"start":16,"end":32}],
        "segments":[],"phrases":[],"keys":[],"pace":[],"vocal":[],"drum":[],"loudness":[]}
        """
        let report = try await PhraseEvaluation.evaluate(corpus: root, limit: 2) { _ in
            try JSONDecoder().decode(PartAnalysis.self, from: Data(json.utf8))
        }
        #expect(report.rows.count == 2 && report.rows[1].failure?.contains("PSSI") == true)
        #expect(report.exact.reference == 2 && report.exact.matched == 2)
        let output = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!output.contains(root.path) && !output.contains("audio.wav") && !output.contains("PMAI"))
        #expect(output.contains("precision"))
        #expect(try Data(contentsOf: root.appending(path: "sample-1/ANLZ0000.EXT")) == before)
        let failed = try await PhraseEvaluation.evaluate(corpus: root, limit: 1) { _ in
            throw NSError(domain: "민감한_음원_경로", code: 1)
        }
        #expect(failed.rows[0].failure != nil)
        #expect(!String(decoding: try JSONEncoder().encode(failed), as: UTF8.self).contains("민감한"))
        #expect(failed.exact.f1 == nil)
    }

    @Test func 빈_코퍼스와_취소는_실패로_전달한다() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phrase-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) { try await PhraseEvaluation.evaluate(corpus: root, limit: 16) }
        let folder = root.appending(path: "sample-1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try anlz([tag()]).write(to: folder.appending(path: "ANLZ0000.EXT"))
        try anlz([BeatGridTags.pqtz(grid())]).write(to: folder.appending(path: "ANLZ0000.DAT"))
        try Data().write(to: folder.appending(path: "audio.wav"))
        await #expect(throws: CancellationError.self) {
            try await PhraseEvaluation.evaluate(corpus: root, limit: 16) { _ in throw CancellationError() }
        }
    }
}
