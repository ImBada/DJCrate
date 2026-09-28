#if DEBUG
import AppKit
import DJCDomain

extension DevSelfTests {
    /// 파일이 없는 곡 화면(#126)을 전체 목록·'파일 없음' 필터로 나눠 라이트·다크로 캡처한다(`--missing-files-capture=<폴더>`).
    /// `MissingFilesFixtureCapture` 합성 사본에서만 돈다(실제 라이브러리 화면을 남기지 않게).
    static func runMissingFilesCaptureIfRequested(store: LibraryStore) {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--missing-files-capture=") }),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil else { return }
        let directory = String(argument.dropFirst("--missing-files-capture=".count))
        func log(_ text: String) { FileHandle.standardError.write(Data("[파일 없음 화면] \(text)\n".utf8)) }
        Task {
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            for _ in 0..<100 {
                if case .loaded = store.phase, !store.isCheckingFiles { break }
                await wait(0.1)
            }
            let titles = ["음원 있는 곡", "음원 지운 곡", "외장 디스크 곡", "스트리밍 곡"]
            guard !store.rows.isEmpty, store.rows.allSatisfy({ row in titles.contains { row.title.hasPrefix($0) } }),
                  let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else {
                log("파일 없음 합성 사본이 아닙니다")
                exit(2)
            }
            let volumes = store.missingFiles.unmountedVolumes.map { "\($0.name) \($0.trackCount)곡" }.joined(separator: ", ")
            log("파일 없음 \(store.count(.missingFile))곡 · 연결되지 않은 외장 디스크: \(volumes.isEmpty ? "없음" : volumes)")
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            var failures = 0
            for (screen, item) in [("all", SidebarItem.filter(.all)), ("filter", .filter(.missingFile))] {
                store.sidebar = item
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    await wait(1.5)
                    let capture = Process()
                    capture.executableURL = URL(filePath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), "\(directory)/\(screen)-\(name).png"]
                    do { try capture.run(); capture.waitUntilExit() } catch { failures += 1; continue }
                    if capture.terminationStatus != 0 { failures += 1 }
                }
            }
            log(failures == 0 ? "끝: 통과" : "끝: 캡처 실패 \(failures)건")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
