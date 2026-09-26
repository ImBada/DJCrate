#if DEBUG
import AppKit
import DJCDomain
import DJCStorage

extension DevSelfTests {
    /// LayoutFixtureCapture가 만든 합성 라이브러리로 최소 창의 반영 UI를 확인한다.
    static func runReflectionLayoutIfRequested(store: LibraryStore) {
        let args = ProcessInfo.processInfo.arguments
        guard let argument = args.first(where: { $0.hasPrefix("--reflection-layout=") }),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil else { return }
        Task {
            for _ in 0..<100 {
                if case .loaded = store.phase { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !store.rows.isEmpty, store.rows.allSatisfy({ $0.title.hasPrefix("레이아웃 시험 ") }),
                  let row = store.rows.first, let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
            NSApp.appearance = NSAppearance(named: argument.hasSuffix("dark") ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.center()
            var draft = CueDraft(trackUUID: row.track.uuid, rekordboxCues: row.cues)
            draft.cues.append(EditableCue(kind: .memory, time: 10, name: "레이아웃 시험"))
            try? CueDraftStore.save(draft)
            store.cueDraftChanged(draft)
            store.selection = [row.id]
            let backup = DJCPaths.userData.appending(path: "synthetic-backup")
            store.lastWriteBackup = backup
            store.resultHistory.record(WriteResult(kind: .warning, title: "일부 곡을 반영했습니다", text: "합성 데이터의 화면 배치 시험입니다"))
            store.toast = AppToast(kind: .warning, title: "일부 곡을 반영했습니다", detail: "합성 데이터의 화면 배치 시험입니다", undoBackup: backup)
            if argument.contains("locked-") {
                store.toast = nil
                store.setWriteLock(true)
                store.writeStage = WriteStage("rekordbox에 쓰는 중…")
            }
        }
    }
}
#endif
