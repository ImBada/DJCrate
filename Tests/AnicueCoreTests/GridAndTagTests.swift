@testable import AnicueCore
import Foundation
import Testing

@Suite("그리드 초안")
struct GridDraftTests {
    /// 120 BPM(0.5초 간격), 0.1초에서 시작하는 4/4 그리드. 첫 박은 1박.
    func constantGrid(count: Int = 40, start: Double = 0.1, bpm: Double = 120) -> BeatGrid {
        BeatGrid(beats: (0..<count).map { i in
            .init(number: i % 4 + 1, bpm: bpm, time: ((start + Double(i) * 60 / bpm) * 1000).rounded() / 1000)
        })
    }

    @Test func 고정_템포는_구간_하나로_묶이고_그대로_재현된다() {
        let grid = constantGrid()
        let draft = GridDraft(trackUUID: "t", grid: grid)
        #expect(draft.segments.count == 1)
        #expect(abs(draft.segments[0].bpm - 120) < 0.001)
        let rebuilt = draft.grid(duration: 20.2)
        for beat in grid.beats {
            #expect(abs(rebuilt.snap(beat.time) - beat.time) <= 0.001)
        }
        #expect(!draft.hasChanges)
    }

    @Test func 전체_이동() {
        var draft = GridDraft(trackUUID: "t", grid: constantGrid())
        draft.shift(by: 0.01)
        #expect(draft.hasChanges)
        #expect(draft.grid(duration: 20).beats.first?.time == 0.11)
    }

    @Test func 여기를_1박으로() {
        var draft = GridDraft(trackUUID: "t", grid: constantGrid())
        // 0.6초 박은 현재 2박 → 1박으로
        draft.setDownbeat(nearest: 0.62, duration: 20)
        let beats = draft.grid(duration: 20).beats
        #expect(beats.first { abs($0.time - 0.6) < 0.001 }?.number == 1)
        #expect(beats.first { abs($0.time - 0.1) < 0.001 }?.number == 4)
    }

    @Test func 여기서_그리드_시작() {
        var draft = GridDraft(trackUUID: "t", grid: constantGrid())
        draft.setAnchor(at: 0.333)
        let beats = draft.grid(duration: 20).beats
        #expect(beats.contains { abs($0.time - 0.333) < 0.0005 && $0.number == 1 })
    }

    @Test func 변속_지점과_구간별_BPM() {
        var draft = GridDraft(trackUUID: "t", grid: constantGrid())
        draft.addTempoChange(nearest: 10.1, duration: 20)
        #expect(draft.segments.count == 2)
        draft.setBPM(150, at: 12)
        let beats = draft.grid(duration: 20).beats
        let after = beats.filter { $0.time >= 10.1 }
        #expect(after.first?.bpm == 150)
        #expect(abs((after[1].time - after[0].time) - 0.4) < 0.0015)
        #expect(beats.filter { $0.time < 10.1 }.allSatisfy { $0.bpm == 120 })
        draft.removeTempoChange(at: 1)
        #expect(draft.segments.count == 1)
    }

    @Test func 템포가_같아도_위상이_튀면_구간을_나눈다() {
        var beats = constantGrid(count: 20).beats
        beats += (0..<20).map { i in .init(number: i % 4 + 1, bpm: 120, time: 10.3 + Double(i) * 0.5) }
        let draft = GridDraft(trackUUID: "t", grid: BeatGrid(beats: beats))
        #expect(draft.segments.count == 2)
        #expect(draft.segments[1].start == 10.3)
    }

    @Test func BPM은_소수점_둘째_자리로_반올림하고_범위를_지킨다() {
        var draft = GridDraft(trackUUID: "t", grid: constantGrid())
        draft.setBPM(154.0123, at: 1)
        #expect(draft.segments[0].bpm == 154.01)
        draft.setBPM(5, at: 1)
        #expect(draft.segments[0].bpm == 154.01)
    }
}

@Suite("그리드 초안 — 리뷰 회귀")
struct GridDraftRegressionTests {
    func grid(bpm: Double = 153.9987) -> BeatGrid {
        BeatGrid(beats: (0..<600).map { i in
            .init(number: i % 4 + 1, bpm: (bpm * 100).rounded() / 100, time: ((0.2 + Double(i) * 60 / bpm) * 1000).rounded() / 1000)
        })
    }

    @Test func 표시값_BPM을_다시_넣어도_그리드는_그대로다() {
        var draft = GridDraft(trackUUID: "t", grid: grid())
        let shown = (draft.segments[0].bpm * 100).rounded() / 100   // BPM 칸에 보이는 154.00
        draft.setBPM(shown, at: 10)
        #expect(!draft.hasChanges)
    }

    @Test func 이동했다_되돌리면_변경이_아니다() {
        var draft = GridDraft(trackUUID: "t", grid: grid())
        draft.shift(by: 0.010)
        draft.shift(by: -0.010)
        #expect(!draft.hasChanges)
    }

    @Test func 구간_경계_근처의_1박_지정은_박이_속한_구간을_고친다() {
        var draft = GridDraft(trackUUID: "t", grid: grid(bpm: 120))
        draft.addTempoChange(nearest: 60.2, duration: 200)   // 60.2초 박부터 새 구간
        let before = draft.segments[0].firstBeatNumber
        draft.setDownbeat(nearest: 60.1, duration: 200)       // 가장 가까운 박은 60.2초(두 번째 구간)
        #expect(draft.segments[0].firstBeatNumber == before)
        #expect(draft.segments[1].firstBeatNumber == 1)
    }

    @Test func 박_개수가_터무니없는_분석_파일도_안전하다() throws {
        func u32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        // 박 개수 필드는 40억인데 실제 항목은 2개뿐인 PQTZ
        var tag = Array("PQTZ".utf8) + u32(24) + u32(24 + 16) + u32(0) + u32(0x80000) + u32(4_000_000_000)
        tag += [0, 1, 0x2E, 0xE0] + u32(100) + [0, 2, 0x2E, 0xE0] + u32(600)
        let data = Data(Array("PMAI".utf8) + u32(28) + u32(28 + tag.count) + [UInt8](repeating: 0, count: 16) + tag)
        let url = FileManager.default.temporaryDirectory.appending(path: "anicue-bad-\(UUID()).DAT")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try BeatGrid.load(anlz: url).beats.count == 2)
    }
}

@Suite("태그 초안")
struct TagDraftTests {
    func track() -> Track {
        Track(id: "1", uuid: "u", title: "Song", artist: "A", album: "Al", albumArtist: nil, genre: "Anime",
              composer: nil, releaseYear: 2013, trackNumber: 1, key: "1A", bpm: 154, lengthSeconds: 269,
              folderPath: "/x.m4a", comment: "TVA 테큐 OP 2", importedOn: "2023-11-21",
              analysisDataPath: nil, imagePath: nil, isDeleted: false)
    }

    @Test func 변경된_필드만_잡는다() {
        var draft = TagDraft(track: track())
        #expect(!draft.hasChanges)
        #expect(draft.fields.year == "2013")
        draft.fields.genre = "애니송"
        draft.fields.comment = "TVA 테큐 OP 2 2013 4분기"
        #expect(draft.changedKeys == [.genre, .comment])
    }

    @Test func 숫자_필드_검증() {
        var draft = TagDraft(track: track())
        draft.fields.year = "2013년"
        #expect(!draft.issues.isEmpty)
    }
}

@Suite("엑셀·시트 붙여넣기(TSV)")
struct TSVTests {
    @Test func 기본_표() {
        #expect(TSV.parse("a\tb\nc\td\n") == [["a", "b"], ["c", "d"]])
    }

    @Test func 따옴표_칸_안의_줄바꿈과_탭은_한_칸이다() {
        // 엑셀은 칸 안에 줄바꿈이 있으면 따옴표로 감싸서 복사한다. 나눠 버리면 뒤 곡들이 한 줄씩 밀린다.
        let text = "제목1\t\"줄1\n줄2\"\n제목2\t\"탭\t포함\"\n"
        #expect(TSV.parse(text) == [["제목1", "줄1\n줄2"], ["제목2", "탭\t포함"]])
    }

    @Test func 이중_따옴표와_CR_줄끝() {
        #expect(TSV.parse("\"말 \"\"인용\"\"\"\tx\r\ny\tz\r") == [["말 \"인용\"", "x"], ["y", "z"]])
    }

    @Test func 복사한_칸을_다시_붙이면_같다() {
        let cells = [["TVA 작품 OP", "줄\n바꿈"], ["탭\t있음", "\"따옴표\""]]
        let text = cells.map { $0.map(TSV.quote).joined(separator: "\t") }.joined(separator: "\n")
        #expect(TSV.parse(text) == cells)
    }
}
