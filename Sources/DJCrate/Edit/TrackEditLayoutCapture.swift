#if DEBUG
import AppKit
import AVFoundation
import DJCDomain
import DJCStorage

extension TrackEditWindow {
    /// 개발용. 합성 라이브러리(EditLayoutFixtureCapture)의 곡으로 편집 창을 띄운다. 초안이 섞이지 않게 `DJC_HOME`이 있을 때만.
    /// - `--edit-layout=light|dark`: 창 번호를 표준 오류에 적는다(`screencapture -l`로 그 창만 찍는다).
    /// - `--edit-selftest`: 이음새 미리 듣기(실제 재생기) → 렌더 → 추가한 곡으로 이동 → 덱에 편집본이 올라오는지까지 돌린다.
    func runLayoutCaptureIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        let layout = args.first { $0.hasPrefix("--edit-layout=") }
        let selfTest = args.contains("--edit-selftest")
        guard layout != nil || selfTest, ProcessInfo.processInfo.environment["DJC_HOME"] != nil else { return }
        Task { @MainActor in
            guard let store, let deck else { return }
            for _ in 0..<150 {
                if case .loaded = store.phase { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let row = store.rows.first(where: { $0.title.hasPrefix("편집 화면 시험") }) else { Self.log("합성 곡 없음"); return }
            if let layout { NSApp.appearance = NSAppearance(named: layout.hasSuffix("dark") ? .darkAqua : .aqua) }
            store.selection = [row.id]
            for _ in 0..<150 where deck.row?.id != row.id || deck.draft == nil || deck.waveform == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard deck.waveform != nil else { Self.log("파형을 읽지 못함"); return }
            deck.seek(deck.duration * 0.42)
            open(entries: [BarRange(0, 16), BarRange(1, 16), BarRange(17, 48), BarRange(81, 96)])
            model?.barsToAdd = 8
            try? await Task.sleep(for: .milliseconds(800))
            if layout != nil {
                Self.log("창 번호 \(window?.windowNumber ?? -1)")
            }
            if selfTest { await runSelfTest(deck: deck, store: store) }
        }
    }

    private func runSelfTest(deck: DeckModel, store: LibraryStore) async {
        guard let model, let seam = model.seams.first, let edit = model.edit else { Self.log("실패: 편집 계획 없음"); return }
        var passed = true
        func check(_ ok: Bool, _ text: String) {
            passed = passed && ok
            Self.log("\(ok ? "통과" : "실패"): \(text)")
        }
        // 1) 이음새 미리 듣기: 실제 재생기가 소리를 내기 시작하는지(바로 멈춘다)
        model.previewSeam(seam.index)
        for _ in 0..<100 where !model.player.isPlaying { try? await Task.sleep(for: .milliseconds(50)) }
        let previews = (try? FileManager.default.contentsOfDirectory(at: model.previewDirectory, includingPropertiesForKeys: nil)) ?? []
        let seconds = previews.first.flatMap { try? AVAudioFile(forReading: $0) }.map { Double($0.length) / $0.processingFormat.sampleRate }
        check(model.player.isPlaying && model.preview == .seam(seam.index),
              String(format: "이음새(%@) 미리 듣기 재생 · 임시 파일 %.2f초", seam.preview.map(\.description).joined(separator: "→"), seconds ?? -1))
        model.stopPreview()

        // 2) 렌더 → 추가한 곡
        let started = Date()
        model.render()
        for _ in 0..<600 where model.staged == nil && model.renderProgress != nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let staged = model.staged else { check(false, "렌더: \(model.message?.text ?? "끝나지 않음")"); return }
        let rendered = try? AVAudioFile(forReading: URL(filePath: staged.path))
        let length = rendered.map { Double($0.length) / $0.processingFormat.sampleRate } ?? -1
        check(abs(length - edit.duration) < 0.001 && staged.path.hasPrefix(DJCPaths.userData.appending(path: "edits").path),
              String(format: "렌더 %.1f초 걸림 · 결과 %.3f초(계획 %.3f초) · %@", Date().timeIntervalSince(started), length, edit.duration,
                     URL(filePath: staged.path).lastPathComponent))

        // 3) 창이 닫히고 추가한 곡에서 편집본이 덱에 올라온다(변환한 그리드·옮긴 큐)
        for _ in 0..<100 where deck.row?.track.uuid != staged.uuid || deck.draft == nil { try? await Task.sleep(for: .milliseconds(100)) }
        check(store.sidebar == .staged && store.selection == [staged.id] && self.model == nil
              && window?.isVisible != true, "창 닫고 추가한 곡에서 고름")
        check(deck.row?.track.uuid == staged.uuid && deck.gridDraft?.segments == [edit.outputGrid]
              && deck.draft?.cues.count == model.carry?.placed.count,
              "덱에 편집본 · 그리드 \(deck.gridDraft?.segments.first.map { String(format: "%.2f BPM", $0.bpm) } ?? "없음") · 큐 \(deck.draft?.cues.count ?? 0)개")
        Self.log("끝: \(passed ? "통과" : "실패")")
    }

    static func log(_ text: String) {
        FileHandle.standardError.write(Data("[편집 화면] \(text)\n".utf8))
    }
}
#endif
