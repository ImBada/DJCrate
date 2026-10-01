@testable import DJCrate
import AppKit
import Testing

#if DEBUG
@MainActor
@Suite("창 크기 성능 기록 계약")
struct ResizePerfTests {
    @Test func 두_축을_빠짐없이_선택하고_오타와_빈_축과_중복은_거부한다() {
        #expect(ResizePerfAxis.parse("all") == [.width, .height])
        #expect(ResizePerfAxis.parse("height,width") == [.height, .width])
        #expect(ResizePerfAxis.parse("width") == [.width])
        for value in ["", "width,", "width,height,other", "width,width", "other"] {
            #expect(ResizePerfAxis.parse(value) == nil)
        }
    }

    @Test func 축마다_같은_40단계를_왕복하고_다른_축과_위치를_보존한다() {
        let original = NSRect(x: 100, y: 200, width: 1500, height: 900)
        for axis in ResizePerfAxis.allCases {
            #expect(axis.frame(from: original, step: 0) == original)
            #expect(axis.frame(from: original, step: 39) == original)
            #expect(axis.frame(from: original, step: 19) == axis.frame(from: original, step: 20))
            for step in 0..<40 {
                let frame = axis.frame(from: original, step: step)
                #expect(frame.origin == original.origin)
                if axis == .width { #expect(frame.height == original.height) }
                else { #expect(frame.width == original.width) }
            }
        }
        #expect(ResizePerfAxis.width.frame(from: original, step: 19).width == 1215)
        #expect(ResizePerfAxis.height.frame(from: original, step: 19).height == 748)
    }

    @Test func 짝수와_홀수_표본의_중앙값과_최댓값을_구분한다() {
        let even = ResizePerfDistribution([40, 10, 30, 20])
        #expect(even.count == 4 && even.median == 25 && even.maximum == 40)
        let odd = ResizePerfDistribution([40, 10, 20])
        #expect(odd.count == 3 && odd.median == 20 && odd.maximum == 40)
        let empty = ResizePerfDistribution([])
        #expect(empty.count == 0 && empty.median == 0 && empty.maximum == 0)
    }

    @Test func 명시한_사본과_임시_홈이_없으면_시작하지_않는다() {
        let args = ["DJCrate", "--resize-perf=all"]
        let env = ["DJC_DB": "/tmp/synthetic/master.db", "DJC_REKORDBOX_DIR": "/tmp/synthetic", "DJC_HOME": "/tmp/home"]
        #expect(ResizePerfSelfTest.startupRefusal(arguments: args, environment: env) == nil)
        for key in env.keys {
            var incomplete = env
            incomplete.removeValue(forKey: key)
            #expect(ResizePerfSelfTest.startupRefusal(arguments: args, environment: incomplete) != nil)
        }
        for arg in ["--resize-perf-repeats=0", "--resize-perf-repeats=11", "--resize-perf-repeats=x",
                    "--resize-perf-delay=nan", "--resize-perf-delay=-1"] {
            #expect(ResizePerfSelfTest.startupRefusal(arguments: args + [arg], environment: env) != nil)
        }
    }
}
#endif
