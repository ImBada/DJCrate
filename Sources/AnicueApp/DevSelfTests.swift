import AnicueCore
import Foundation

/// 개발용: 곡을 바꿔 가며 재생하는 흐름을 그대로 재현한다(`--switch-selftest`, 음량은 −70dB).
/// 결과는 `~/Library/Logs/anicue/audio.log`와 표준 오류에 남는다.
@MainActor
enum DevSelfTests {
    static func runIfRequested(store: LibraryStore, deck: DeckModel) {
        runWriteSelfTestIfRequested(store: store, deck: deck)
        guard ProcessInfo.processInfo.arguments.contains("--switch-selftest") else { return }
        Task {
            @MainActor func mark(_ text: String) {
                let title = deck.row.map { String($0.title.prefix(16)) } ?? "-"
                let meter = deck.meter.read()
                let level = meter.maxPeak > 0 ? String(format: "%.1f", 20 * log10(meter.maxPeak)) : "−∞"
                let line = "── \(text) · 곡=\(title) · 재생=\(deck.isPlaying) · 위치=\(String(format: "%.2f", deck.currentTime)) · 음량=\(String(format: "%.4f", deck.volume)) · 게인 \(String(format: "%+.1f", deck.appliedGain))dB · 미터 최고 \(level)dBFS"
                AudioEvents.record(line)
            }
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            @MainActor func waitLoaded(_ id: String) async {
                for _ in 0..<100 {
                    if deck.row?.id == id, deck.canPlay { return }
                    await wait(0.1)
                }
            }
            for _ in 0..<100 {
                if deck.canPlay { break }
                await wait(0.1)
            }
            deck.volume = 0.0003
            let rows = store.displayRows.filter { !$0.track.isStreaming }
            guard let a = deck.row, let start = rows.firstIndex(where: { $0.id == a.id }), rows.count > start + 2 else {
                mark("곡이 부족해 중단"); return
            }
            let b = rows[start + 1], c = rows[start + 2]
            mark("A 로드됨"); deck.togglePlay(); await wait(3); mark("A 재생 3초")
            store.selection = [b.id]; await waitLoaded(b.id); await wait(1); mark("A 재생 중 B로 바꿈")
            deck.togglePlay(); await wait(3); mark("B 재생 3초")
            deck.togglePlay(); await wait(1); mark("B 정지")
            deck.togglePlay(); await wait(2); mark("B 다시 재생")
            deck.seek(60); await wait(2); mark("B 60초로 탐색")
            deck.togglePlay(); await wait(1); mark("B 정지")
            store.selection = [c.id]; await waitLoaded(c.id); await wait(1); mark("멈춘 채 C로 바꿈")
            deck.togglePlay(); await wait(3); mark("C 재생 3초")
            store.selection = [a.id]; await waitLoaded(a.id); await wait(1); mark("C 재생 중 A로 돌아옴")
            deck.togglePlay(); await wait(3); mark("A 재생 3초")
            deck.togglePlay(); mark("끝")
        }
    }

    /// 개발용: 사본 rekordbox 폴더(`ANICUE_REKORDBOX_DIR`)와 사본 초안(`ANICUE_HOME`)으로
    /// 미리 보기 → 쓰기 → 다시 읽기 → 되돌리기 → 초안 복구를 앱 흐름 그대로 해 본다(`--write-selftest`).
    static func runWriteSelfTestIfRequested(store: LibraryStore, deck: DeckModel) {
        guard ProcessInfo.processInfo.arguments.contains("--write-selftest") else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[쓰기 시험] \(text)\n".utf8)) }
        let env = ProcessInfo.processInfo.environment
        guard env["ANICUE_REKORDBOX_DIR"]?.isEmpty == false, env["ANICUE_HOME"]?.isEmpty == false else {
            log("사본 폴더(ANICUE_REKORDBOX_DIR·ANICUE_HOME)가 아니면 하지 않습니다"); exit(2)
        }
        let realShare = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer/rekordbox/share/PIONEER/USBANLZ")
            .resolvingSymlinksInPath().path
        guard RekordboxShare.directory.appending(path: "PIONEER/USBANLZ").resolvingSymlinksInPath().path != realShare else {
            log("분석 파일 폴더가 실제 rekordbox 폴더를 가리킵니다. 사본으로 바꾼 뒤 하세요"); exit(2)
        }
        Task {
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            @MainActor func loaded() -> Bool { if case .loaded = store.phase { !store.rows.isEmpty } else { false } }
            for _ in 0..<50 { if loaded() || store.isLoading { break }; await wait(0.1) }
            if !loaded(), !store.isLoading { await store.takeSnapshot() }
            for _ in 0..<600 { if loaded() { break }; await wait(0.1) }
            guard loaded() else { log("라이브러리를 읽지 못했습니다"); exit(1) }
            let targets = store.writeTargets(store.rows)
            log("반영 대기 \(store.pendingLibraryCount)곡 · 대상 \(targets.count)곡")
            // 덱에 대상 곡 하나를 올려 둔다(쓴 뒤 덱이 새 큐로 다시 읽는지 본다).
            if let first = targets.first { store.selection = [first.id] }
            await wait(1.5)
            do {
                store.onWriteLock?(true)
                let preview = try await store.previewWrite(rows: targets)
                log("미리 보기: 큐 \(preview.report.written.count)곡 · 그리드 \(preview.report.gridWritten.count)곡 · 막힘 큐 \(preview.report.blocked.count) · 그리드 \(preview.report.gridBlocked.count)")
                for o in preview.report.blocked + preview.report.gridBlocked { log("  막힘 \(o.title): \(o.reason ?? "")") }
                let uuids = Set(preview.report.written.map(\.trackUUID)), gridUUIDs = Set(preview.report.gridWritten.map(\.trackUUID))
                let expected = Dictionary(uniqueKeysWithValues: preview.drafts.filter { uuids.contains($0.trackUUID) }
                    .map { ($0.trackUUID, RekordboxWriter.key($0.cues, withSource: false)) })
                // 그리드: 쓰기 전 분석 파일 바이트(되돌린 뒤 같은지 본다)
                var originals: [String: Data] = [:]
                for uuid in gridUUIDs {
                    if let row = store.rowsByUUID[uuid], let url = RekordboxShare.analysisURL(row.track.analysisDataPath) { originals[uuid] = try? Data(contentsOf: url) }
                }
                let grids = preview.grids.filter { gridUUIDs.contains($0.trackUUID) }
                let report = try await store.writeToRekordbox(preview.drafts.filter { uuids.contains($0.trackUUID) }, grids: grids)
                store.onWriteLock?(false)
                await wait(1.5)
                var same = 0
                for (uuid, key) in expected {
                    guard let row = store.rowsByUUID[uuid] else { continue }
                    let now = CueDraft(trackUUID: uuid, rekordboxCues: row.cues).cues
                    if RekordboxWriter.key(now, withSource: false) == key { same += 1 } else { log("  다름: \(row.title)") }
                }
                log("쓰기: \(report.written.count)곡 · 다시 읽은 큐가 초안과 같음 \(same)/\(expected.count) · 남은 반영 대기 \(store.pendingLibraryCount)곡")
                log("덱: \(deck.row?.title.prefix(20) ?? "-") · 덱 초안 변경 \(deck.draft?.changes.count ?? -1) · 안내: \(store.reflectionMessage ?? "")")
                // 그리드: 분석 파일을 다시 읽어 초안 그리드와 같은지(박 시각 ±1ms)
                var gridSame = 0
                for grid in grids {
                    guard let row = store.rowsByUUID[grid.trackUUID], let url = RekordboxShare.analysisURL(row.track.analysisDataPath),
                          let written = try? BeatGrid.load(anlz: url) else { continue }
                    let intended = grid.grid(duration: Double(row.track.lengthSeconds) + 1)
                    let worst = written.beats.map { abs(intended.snap($0.time) - $0.time) }.max() ?? 1
                    if worst <= 0.0015 { gridSame += 1 } else { log(String(format: "  그리드 다름 %@: 최대 %.1fms", row.title, worst * 1000)) }
                }
                log("그리드 쓰기: \(report.gridWritten.count)곡 · 다시 읽은 그리드가 초안과 같음 \(gridSame)/\(grids.count) · 덱 그리드 초안 변경 \(deck.gridDraft?.hasChanges == true ? "있음" : "없음")")
                guard let backup = RekordboxWriter.backups().first(where: \.isWrite) else { log("백업 없음!"); exit(1) }
                log("되돌리기 전 확인: 백업 뒤 라이브러리 바뀜 = \(String(describing: await store.libraryChangedSince(backup)))")
                try await store.restoreRekordbox(backup)
                await wait(1.5)
                var restored = 0
                for uuid in expected.keys where CueDraftStore.load(trackUUID: uuid)?.hasChanges == true { restored += 1 }
                var gridRestored = 0, filesRestored = 0
                for grid in grids where GridDraftStore.load(trackUUID: grid.trackUUID)?.hasChanges == true { gridRestored += 1 }
                for (uuid, data) in originals {
                    if let row = store.rowsByUUID[uuid], let url = RekordboxShare.analysisURL(row.track.analysisDataPath),
                       (try? Data(contentsOf: url)) == data { filesRestored += 1 }
                }
                log("되돌림: 큐 초안 복구 \(restored)/\(expected.count) · 그리드 초안 복구 \(gridRestored)/\(grids.count) · 분석 파일 원본과 같음 \(filesRestored)/\(originals.count) · 반영 대기 \(store.pendingLibraryCount)곡")
                log("끝")
                exit(0)
            } catch {
                log("오류: \(error)")
                exit(1)
            }
        }
    }
}
