@testable import DJCDomain
import Foundation
import Testing

@Suite("곡 편집 화면 규칙: 구간 추가·이음새 미리 듣기·출력 마디 수")
struct EditPlanTests {
    /// 120 BPM(1마디 2초), 첫 다운비트 0.5초, 100.5초 = 0마디 + 50마디
    let grid = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]

    // MARK: - 여기서 N마디

    @Test func 재생_위치가_든_마디부터_N마디를_고른다() throws {
        let bars = try BarLayout(grid: grid, duration: 100.5)
        #expect(bars.range(from: 33.0, length: 16, leading: false) == BarRange(17, 32))
        #expect(bars.range(from: 0.5, length: 8, leading: false) == BarRange(1, 8))
        // 박 한가운데여도 그 마디 처음부터
        #expect(bars.range(from: 34.4, length: 4, leading: false) == BarRange(17, 20))
        // 곡 끝을 넘으면 마지막 마디까지만
        #expect(bars.range(from: 95.0, length: 16, leading: false) == BarRange(48, 50))
        // 1마디 미만은 1마디로
        #expect(bars.range(from: 33.0, length: 0, leading: false) == BarRange(17, 17))
        // 곡 끝(마지막 마디 뒤)에서는 고를 마디가 없다
        #expect(bars.range(from: 100.5, length: 4, leading: false) == nil)
    }

    @Test func 첫_다운비트_앞이면_맨_앞_구간일_때만_곡_머리를_넣는다() throws {
        let bars = try BarLayout(grid: grid, duration: 100.5)
        // 목록이 비어 있으면 곡 머리(0마디) + N마디: 인트로 앞 픽업 소리를 살린다
        #expect(bars.range(from: 0.2, length: 16, leading: true) == BarRange(0, 16))
        // 뒤에 붙일 때는 0마디를 둘 수 없어 1마디부터
        #expect(bars.range(from: 0.2, length: 16, leading: false) == BarRange(1, 16))
        // 곡 머리가 없는 곡은 늘 1마디부터
        let flush = try BarLayout(grid: [GridSegment(start: 0, bpm: 120, firstBeatNumber: 1)], duration: 60)
        #expect(flush.range(from: 0, length: 4, leading: true) == BarRange(1, 4))
    }

    // MARK: - 이음새

    @Test func 원본에서_이어지지_않는_경계만_이음새다() {
        // 1-16 → 1-16은 이음새, 1-16 → 17-64는 원본에서 이어져 이음새가 아니다
        let seams = BarRange.seams(in: [BarRange(1, 16), BarRange(1, 16), BarRange(17, 64)])
        #expect(seams == [EditSeam(index: 1, preview: [BarRange(15, 16), BarRange(1, 2)])])
        #expect(BarRange.seams(in: [BarRange(1, 16)]).isEmpty && BarRange.seams(in: []).isEmpty)
    }

    @Test func 미리_듣기는_이어진_조각_단위로_앞뒤_2마디다() {
        // 1-1·2-2는 원본에서 이어진 한 조각(1-2)이라 이음새 앞 2마디가 두 구간에 걸친다
        let seams = BarRange.seams(in: [BarRange(1, 1), BarRange(2, 2), BarRange(9, 12), BarRange(3, 8)])
        #expect(seams == [EditSeam(index: 2, preview: [BarRange(1, 2), BarRange(9, 10)]),
                          EditSeam(index: 3, preview: [BarRange(11, 12), BarRange(3, 4)])])
        // 조각이 1마디뿐이면 있는 만큼만, 곡 머리(0마디)는 앞 조각 끝에 들면 그대로 둔다
        #expect(BarRange.seams(in: [BarRange(0, 1), BarRange(5, 5)]) == [EditSeam(index: 1, preview: [BarRange(0, 1), BarRange(5, 5)])])
        #expect(BarRange.seams(in: [BarRange(0, 8), BarRange(1, 8)], context: 4)
            == [EditSeam(index: 1, preview: [BarRange(5, 8), BarRange(1, 4)])])
    }

    @Test func 이음새_미리_듣기_구간은_그대로_편집이_된다() throws {
        // 끝에서 잘린 마지막 마디가 뒤 조각 머리에 들어도 맨 뒤라 편집할 수 있다
        let cut = try BarLayout(grid: grid, duration: 101.5)
        let bars = [BarRange(1, 4), BarRange(50, 51)]
        let seam = try #require(BarRange.seams(in: bars).first)
        #expect(seam.preview == [BarRange(3, 4), BarRange(50, 51)])
        let preview = try TrackEdit(grid: grid, sourceDuration: 101.5, bars: seam.preview)
        #expect(preview.pieces.count == 2 && cut.lastBarIsPartial)
        #expect(abs(preview.duration - (4 + 2 + 1)) < 1e-9)
    }

    // MARK: - 출력 마디 수

    @Test func 출력_마디_수는_곡_머리를_빼고_잘린_마지막_마디는_센다() throws {
        #expect(try TrackEdit(grid: grid, sourceDuration: 100.5, bars: [BarRange(0, 16), BarRange(1, 16)]).barCount == 32)
        #expect(try TrackEdit(grid: grid, sourceDuration: 100.5, bars: [BarRange(1, 16), BarRange(17, 50)]).barCount == 50)
        #expect(try TrackEdit(grid: grid, sourceDuration: 101.5, bars: [BarRange(48, 51)]).barCount == 4)
    }
}
