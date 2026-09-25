import Foundation
import QuartzCore

/// 개발용 성능 기록(`--scroll-perf`일 때만). 재생 화면 갱신 간격과 파형 그리기 시간을 잰다.
@MainActor
enum PerfProbe {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--scroll-perf")
    /// A/B: 확대 파형 막대를 그리지 않는다
    static let skipBands = ProcessInfo.processInfo.arguments.contains("--skip-bands")
    /// A/B: 이름을 준 화면 요소를 숨긴다(`--perf-hide zoom,label,overview,meter`)
    static let hidden: Set<String> = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--perf-hide"), args.indices.contains(i + 1) else { return [] }
        return Set(args[i + 1].components(separatedBy: ","))
    }()

    private static var ticks: [Double] = []
    private static var draws: [Double] = []
    /// 메인 런루프가 한 번 깨어나 일한 시간(ms)
    private static var busy: [Double] = []
    private static var wokeAt: Double = 0
    private static var observer: CFRunLoopObserver?

    /// 메인 런루프가 깨어 있던 시간을 잰다(깨어남 → 잠들기 직전).
    static func startRunLoopProbe() {
        guard enabled, observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            let now = CACurrentMediaTime()
            MainActor.assumeIsolated {
                if activity == .afterWaiting { wokeAt = now } else if wokeAt > 0 { busy.append((now - wokeAt) * 1000) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    static func tick() {
        guard enabled else { return }
        ticks.append(CACurrentMediaTime())
    }

    static func measureDraw<T>(_ body: () -> T) -> T {
        guard enabled else { return body() }
        let start = CACurrentMediaTime()
        let result = body()
        draws.append(CACurrentMediaTime() - start)
        return result
    }

    static func reset() { ticks = []; draws = []; busy = [] }

    /// 갱신 간격(ms): 평균·최대·25ms 넘은 횟수, 파형 그리기(ms): 평균·최대
    static func summary() -> String {
        let gaps = zip(ticks.dropFirst(), ticks).map { ($0 - $1) * 1000 }
        let avg = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
        let drawAvg = draws.isEmpty ? 0 : draws.reduce(0, +) / Double(draws.count) * 1000
        return String(format: "갱신 %d번 · 간격 평균 %.1fms 최대 %.1fms · 25ms 넘음 %d번 · 파형 그리기 %d번 평균 %.2fms 최대 %.2fms",
                      ticks.count, avg, gaps.max() ?? 0, gaps.filter { $0 > 25 }.count,
                      draws.count, drawAvg, (draws.max() ?? 0) * 1000)
            + String(format: " · 메인 스레드 일한 시간 합 %.0fms/초 · 한 번 최대 %.1fms · 10ms 넘은 번 %d",
                      busy.reduce(0, +) / 3, busy.max() ?? 0, busy.filter { $0 > 10 }.count)
    }
}
