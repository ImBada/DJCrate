import RekordboxKit
import AVFoundation
import QuartzCore
import AppKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation

// 개발용 자가 시험은 디버그 빌드에만 들어간다(설치하는 릴리스 앱에는 없다).
#if DEBUG
/// 개발용: 곡을 바꿔 가며 재생하는 흐름을 그대로 재현한다(`--switch-selftest`, 음량은 −70dB).
/// 결과는 `~/Library/Logs/DJCrate/audio.log`와 표준 오류에 남는다.
@MainActor
enum DevSelfTests {
    static func runIfRequested(store: LibraryStore, deck: DeckModel) {
        runReflectionLayoutIfRequested(store: store)
        runWriteSelfTestIfRequested(store: store, deck: deck)
        runTrackSelfTestIfRequested(store: store)
        runLoopSelfTestIfRequested(deck: deck)
        runScrollPerfIfRequested(deck: deck)
        runLoopAudioSelfTestIfRequested()
        runMetronomeSelfTestIfRequested()
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
            store.loadToDeck(b); await waitLoaded(b.id); await wait(1); mark("A 재생 중 B로 바꿈")
            deck.togglePlay(); await wait(3); mark("B 재생 3초")
            deck.togglePlay(); await wait(1); mark("B 정지")
            deck.togglePlay(); await wait(2); mark("B 다시 재생")
            deck.seek(60); await wait(2); mark("B 60초로 탐색")
            deck.togglePlay(); await wait(1); mark("B 정지")
            store.loadToDeck(c); await waitLoaded(c.id); await wait(1); mark("멈춘 채 C로 바꿈")
            deck.togglePlay(); await wait(3); mark("C 재생 3초")
            store.loadToDeck(a); await waitLoaded(a.id); await wait(1); mark("C 재생 중 A로 돌아옴")
            deck.togglePlay(); await wait(3); mark("A 재생 3초")
            deck.togglePlay(); mark("끝")
        }
    }

    /// 개발용: 사본 rekordbox 폴더(`DJC_REKORDBOX_DIR`)와 사본 초안(`DJC_HOME`)으로
    /// 미리 보기 → 쓰기 → 다시 읽기 → 되돌리기 → 초안 복구를 앱 흐름 그대로 해 본다(`--write-selftest`).
    /// 재생 목록 초안도 만들어(맨 위에 폴더 → 그 안에 목록 + 곡, 있던 목록에 곡 하나) 함께 쓰고 되돌린다.
    static func runWriteSelfTestIfRequested(store: LibraryStore, deck: DeckModel) {
        guard ProcessInfo.processInfo.arguments.contains("--write-selftest") else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[쓰기 시험] \(text)\n".utf8)) }
        let env = ProcessInfo.processInfo.environment
        guard env["DJC_REKORDBOX_DIR"]?.isEmpty == false, env["DJC_HOME"]?.isEmpty == false else {
            log("사본 폴더(DJC_REKORDBOX_DIR·DJC_HOME)가 아니면 하지 않습니다"); exit(2)
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
            // 재생 목록 초안: 새 폴더 안에 새 목록(곡 셋), 있던 목록 하나에 곡 하나
            let playable = store.rows.filter { !$0.isStaged && !$0.track.isStreaming }
            let folder = store.createPlaylist(isFolder: true, in: PlaylistLayout.root, name: "DJC 시험 폴더")
            let list = folder.flatMap { store.createPlaylist(isFolder: false, in: $0, name: "DJC 시험 목록", tracks: Array(playable.prefix(3))) }
            var extended: (id: String, before: [String], added: String)?
            if let existing = store.rekordboxPlaylists.outline.first(where: { $0.holdsTracks }),
               let track = playable.first(where: { !existing.trackIDs.contains($0.track.id) }) {
                store.addTracks([track], toPlaylist: existing.id)
                extended = (existing.id, existing.trackIDs, track.track.id)
            }
            store.renamingPlaylistID = nil
            let playlistEdits = store.playlistDraft.edits.count
            log("재생 목록 초안: 편집 \(playlistEdits)건 · 새 목록 \(list ?? "-") · 있던 목록에 넣기 \(extended == nil ? "없음" : "있음")")
            // 덱에 대상 곡 하나를 올려 둔다(쓴 뒤 덱이 새 큐로 다시 읽는지 본다).
            if let first = targets.first { store.selection = [first.id]; store.loadToDeck(first) }
            await wait(1.5)
            do {
                store.setWriteLock(true)
                let preview = try await store.previewWrite(rows: targets, playlists: true)
                log("미리 보기 재생 목록: 씀 \(preview.report.playlistWritten.count)건 · 막힘 \(preview.report.playlistBlocked.count)건")
                for o in preview.report.playlistBlocked { log("  막힘 \(o.name): \(o.reason ?? "")") }
                log("미리 보기: 큐 \(preview.report.written.count)곡 · 그리드 \(preview.report.gridWritten.count)곡 · 막힘 큐 \(preview.report.blocked.count) · 그리드 \(preview.report.gridBlocked.count)")
                for o in preview.report.blocked + preview.report.gridBlocked { log("  막힘 \(o.title): \(o.reason ?? "")") }
                log("미리 보기 분석 붙이기: \(preview.report.analysisWritten.count)곡 · 막힘 \(preview.report.analysisBlocked.count)")
                for o in preview.report.analysisBlocked { log("  막힘 \(o.title): \(o.reason ?? "")") }
                let uuids = Set(preview.report.written.map(\.trackUUID)), gridUUIDs = Set(preview.report.gridWritten.map(\.trackUUID))
                let attachUUIDs = Set(preview.report.analysisWritten.map(\.trackUUID))
                let expected = Dictionary(uniqueKeysWithValues: preview.drafts.filter { uuids.contains($0.trackUUID) }
                    .map { ($0.trackUUID, RekordboxWriter.key(RekordboxWriter.expectedCues(after: $0), withSource: false)) })
                // 그리드: 쓰기 전 분석 파일 바이트(되돌린 뒤 같은지 본다)
                var originals: [String: Data] = [:]
                for uuid in gridUUIDs {
                    if let row = store.rowsByUUID[uuid], let url = RekordboxShare.analysisURL(row.track.analysisDataPath) { originals[uuid] = try? Data(contentsOf: url) }
                }
                let grids = preview.grids.filter { gridUUIDs.contains($0.trackUUID) }
                let attachGrids = preview.grids.filter { attachUUIDs.contains($0.trackUUID) }
                let gainUUIDs = Set(preview.report.gainWritten.map(\.trackUUID))
                log("미리 보기 게인: \(preview.report.gainWritten.count)곡 · 막힘 \(preview.report.gainBlocked.count)")
                // 태그: 쓸 수 있는 칸(`RekordboxWriter.writableTagKeys`)만 쓰고, 다시 읽은 곡 정보가 초안과 같은지 본다.
                let tagUUIDs = Set(preview.report.tagWritten.map(\.trackUUID))
                let tags = preview.tags.filter { tagUUIDs.contains($0.trackUUID) }
                log("미리 보기 태그: \(preview.report.tagWritten.count)곡 · 막힘 \(preview.report.tagBlocked.count)")
                for o in preview.report.tagBlocked { log("  막힘 \(o.title): \(o.reason ?? "")") }
                let report = try await store.writeToRekordbox(preview.drafts.filter { uuids.contains($0.trackUUID) }, grids: grids + attachGrids,
                                                              gains: preview.gains.filter { gainUUIDs.contains($0.key) }, tags: tags,
                                                              playlists: preview.report.playlistWritten.isEmpty ? nil : preview.playlists)
                // 재생 목록: 다시 읽은 rekordbox에 새 폴더·목록(곡 셋)과 넣은 곡이 있고 초안이 비었는지
                let rekordbox = store.rekordboxPlaylists
                let newFolder = rekordbox.outline.first { $0.name == "DJC 시험 폴더" && $0.isFolder && $0.parentID == PlaylistLayout.root }
                let newList = newFolder.flatMap { folder in rekordbox.children(of: folder.id).first { $0.name == "DJC 시험 목록" } }
                let expectedTracks = Array(playable.prefix(3)).map(\.track.id)
                let extendedOK = extended.map { rekordbox.item($0.id)?.trackIDs == $0.before + [$0.added] }
                log("재생 목록 쓰기: \(report.playlistWritten.count)/\(playlistEdits)건 · 새 폴더 \(newFolder == nil ? "없음" : "있음") · 새 목록 곡이 같음 \(newList?.trackIDs == expectedTracks) · 있던 목록 곡 \(extendedOK.map { "\($0)" } ?? "-") · 남은 초안 \(store.playlistDraft.edits.count)건")
                for outcome in report.gainWritten {
                    let now = store.rowsByUUID[outcome.trackUUID]?.autoGain?.gainDB
                    log(String(format: "게인 쓰기: %@ → 다시 읽은 rekordbox 오토게인 %+.2f dB(초안 %+.2f)", outcome.title, now ?? .nan, Double(outcome.added) / 100))
                }
                store.setWriteLock(false)
                await wait(1.5)
                var same = 0
                for (uuid, key) in expected {
                    guard let row = store.rowsByUUID[uuid] else { continue }
                    let now = CueDraft(trackUUID: uuid, rekordboxCues: row.cues).cues
                    if RekordboxWriter.key(now, withSource: false) == key { same += 1 } else { log("  다름: \(row.title)") }
                }
                log("쓰기: \(report.written.count)곡 · 다시 읽은 큐가 초안과 같음 \(same)/\(expected.count) · 남은 반영 대기 \(store.pendingLibraryCount)곡")
                log("덱: \(deck.row?.title.prefix(20) ?? "-") · 덱 초안 변경 \(deck.draft?.changes.count ?? -1) · 알림: \(store.toast?.title ?? "") \(store.toast?.detail ?? "")")
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
                // 분석 붙이기: 다시 읽은 곡에 분석 경로·파형 파일이 있고 그리드가 초안과 같은지
                var attachSame = 0
                for grid in attachGrids {
                    guard let row = store.rowsByUUID[grid.trackUUID], RekordboxShare.hasWaveformAnalysis(row.track.analysisDataPath),
                          let url = RekordboxShare.analysisURL(row.track.analysisDataPath), let written = try? BeatGrid.load(anlz: url) else {
                        log("  분석 파일 없음: \(grid.trackUUID)"); continue
                    }
                    let intended = grid.grid(duration: Double(row.track.lengthSeconds) + 1)
                    let worst = written.beats.map { abs(intended.snap($0.time) - $0.time) }.max() ?? 1
                    if worst <= 0.0015 { attachSame += 1 } else { log(String(format: "  분석 그리드 다름 %@: 최대 %.1fms", row.title, worst * 1000)) }
                }
                var tagSame = 0
                for draft in tags {
                    guard let row = store.rowsByUUID[draft.trackUUID] else { continue }
                    let now = TagFields(track: row.track)
                    if draft.changedKeys.allSatisfy({ now[$0] == draft.fields[$0] }) { tagSame += 1 } else { log("  태그 다름: \(row.title)") }
                }
                log("태그 쓰기: \(report.tagWritten.count)곡 · 다시 읽은 곡 정보가 초안과 같음 \(tagSame)/\(tags.count) · 남은 태그 초안 \(tags.filter { store.tagDrafts[$0.trackUUID] != nil }.count)")
                let createdFiles = (report.createdFiles ?? []).map { URL(filePath: $0) }
                log("분석 붙이기: \(report.analysisWritten.count)곡 · 파형·그리드가 초안과 같음 \(attachSame)/\(attachGrids.count) · 만든 파일 \(createdFiles.count)개")
                guard let backup = RekordboxWriter.backups(in: DJCPaths.rekordboxBackups).first(where: \.isWrite) else { log("백업 없음!"); exit(1) }
                log("되돌리기 전 확인: 백업 뒤 라이브러리 바뀜 = \(String(describing: await store.libraryChangedSince(backup)))")
                try await store.restoreRekordbox(backup)
                await wait(1.5)
                var restored = 0
                for uuid in expected.keys where CueDraftStore.load(trackUUID: uuid)?.hasChanges == true { restored += 1 }
                var gridRestored = 0, filesRestored = 0
                for grid in grids + attachGrids where GridDraftStore.load(trackUUID: grid.trackUUID)?.hasChanges == true { gridRestored += 1 }
                for (uuid, data) in originals {
                    if let row = store.rowsByUUID[uuid], let url = RekordboxShare.analysisURL(row.track.analysisDataPath),
                       (try? Data(contentsOf: url)) == data { filesRestored += 1 }
                }
                log("되돌림 뒤 게인 초안: \(GainDraftStore.all().count)개")
                let tagRestored = tags.filter { store.tagDrafts[$0.trackUUID] == $0 && TagDraftStore.load(trackUUID: $0.trackUUID) == $0 }.count
                let tagBase = tags.filter { draft in store.rowsByUUID[draft.trackUUID].map { TagFields(track: $0.track) == draft.base } ?? false }.count
                log("되돌림: 태그 초안 복구 \(tagRestored)/\(tags.count) · rekordbox 곡 정보가 쓰기 전과 같음 \(tagBase)/\(tags.count)")
                let rolledBack = !store.rekordboxPlaylists.outline.contains { $0.name == "DJC 시험 폴더" }
                let extendedBack = extended.map { store.rekordboxPlaylists.item($0.id)?.trackIDs == $0.before }
                let redrafted = store.playlistProjection.layout.outline.contains { $0.name == "DJC 시험 목록" && $0.isNew }
                log("재생 목록 되돌림: rekordbox에서 새 폴더 사라짐 \(rolledBack) · 있던 목록 곡 원래대로 \(extendedBack.map { "\($0)" } ?? "-") · 초안 복구 \(store.playlistDraft.edits.count)/\(report.playlistWritten.count)건 · 초안에 새 목록 \(redrafted)")
                let createdLeft = createdFiles.filter { FileManager.default.fileExists(atPath: $0.path) }.count
                log("되돌림: 큐 초안 복구 \(restored)/\(expected.count) · 그리드 초안 복구 \(gridRestored)/\(grids.count + attachGrids.count) · 분석 파일 원본과 같음 \(filesRestored)/\(originals.count) · 붙인 분석 파일 남음 \(createdLeft)/\(createdFiles.count) · 반영 대기 \(store.pendingLibraryCount)곡")
                log("끝")
                exit(0)
            } catch {
                log("오류: \(error)")
                exit(1)
            }
        }
    }

    /// 개발용: 활성 루프가 있는 곡에서 루프 앞부터 재생해 반복되는지 본다(`--loop-selftest`, 음량 −70dB).
    static func runLoopSelfTestIfRequested(deck: DeckModel) {
        guard ProcessInfo.processInfo.arguments.contains("--loop-selftest") else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[루프 시험] \(text)\n".utf8)) }
        Task {
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            for _ in 0..<100 where !deck.canPlay || deck.draft == nil { await wait(0.1) }
            deck.volume = 0.0003
            deck.metronome = true   // 루프 중 클릭 예약도 함께 돈다
            guard let active = deck.draft?.cues.first(where: { $0.loop?.active == true }), let loop = active.loop else {
                log("활성 루프 없음"); exit(1)
            }
            log(String(format: "활성 루프 %.3f~%.3f초", active.time, loop.end))
            deck.seek(active.time - 1)
            deck.togglePlay()
            var samples: [Double] = []
            for _ in 0..<35 { await wait(0.2); samples.append(deck.currentTime) }
            deck.togglePlay()
            let inside = samples.dropFirst(8).allSatisfy { $0 >= active.time - 0.05 && $0 <= loop.end + 0.08 }
            log("위치: " + samples.map { String(format: "%.2f", $0) }.joined(separator: " "))
            log(inside ? "루프 안에서 반복됨" : "루프를 벗어남!")
            guard inside else { exit(1) }

            // 즉석 루프: 루프 없는 자리에서 L(4박) → ½ → 빈 핫큐 칸에 저장 → 나가기
            deck.exitLoop()
            let cues = deck.draft?.cues ?? []
            let spot = stride(from: 20.0, to: deck.duration - 20, by: 5).first { t in
                !cues.contains { cue in cue.loop.map { t > cue.time - 3 && t < $0.end + 3 } ?? false }
            } ?? 30
            deck.seek(spot)
            deck.togglePlay()
            await wait(0.5)
            deck.toggleLoop()
            guard let instant = deck.instantLoop else { log("즉석 루프가 안 걸림"); exit(1) }
            let beat = 60 / (deck.gridBPM ?? 120)
            log(String(format: "즉석 루프 %@박 %.3f~%.3f초 (%.2f박)", deck.loopSizeText, instant.start, instant.end, (instant.end - instant.start) / beat))
            samples = []
            for _ in 0..<15 { await wait(0.2); samples.append(deck.currentTime) }
            let instantInside = samples.dropFirst(2).allSatisfy { $0 >= instant.start - 0.05 && $0 <= instant.end + 0.08 }
            log("위치: " + samples.map { String(format: "%.2f", $0) }.joined(separator: " "))
            deck.resizeLoop(-1)
            let halved = deck.instantLoop.map { ($0.end - $0.start) / beat } ?? 0
            log(String(format: "½ 뒤 %@박 (%.2f박)", deck.loopSizeText, halved))
            let before = deck.draft?.cues.count ?? 0
            guard let slot = (0..<8).first(where: { deck.hotCue(slot: $0) == nil }) else { log("빈 핫큐 칸 없음"); exit(1) }
            deck.pressHotCue(slot: slot)
            let stored = deck.hotCue(slot: slot)
            let storedOK = stored?.loop != nil && deck.engagedLoopID == stored?.id && deck.instantLoop == nil
            log("핫큐 \(slot + 1)에 저장: \(storedOK ? "루프 핫큐로 저장·계속 반복" : "실패")")
            samples = []
            for _ in 0..<8 { await wait(0.2); samples.append(deck.currentTime) }
            let storedInside = stored.flatMap { cue in cue.loop.map { loop in samples.allSatisfy { $0 >= cue.time - 0.05 && $0 <= loop.end + 0.08 } } } ?? false
            log(String(format: "저장한 루프 %.3f~%.3f초 · 위치: ", stored?.time ?? 0, stored?.loop?.end ?? 0)
                + samples.map { String(format: "%.2f", $0) }.joined(separator: " "))
            deck.toggleLoop()
            let exited = !deck.isLooping
            if let id = stored?.id { deck.delete(id) }
            deck.togglePlay()
            let restored = (deck.draft?.cues.count ?? -1) == before
            log("즉석 루프 반복 \(instantInside) · ½ \(abs(halved - 2) < 0.1) · 저장 뒤 반복 \(storedInside) · 나가기 \(exited) · 시험 큐 지움 \(restored)")
            let ok = instantInside && abs(halved - 2) < 0.1 && storedOK && storedInside && exited && restored
            log(ok ? "통과" : "실패")
            exit(ok ? 0 : 1)
        }
    }

    /// 개발용: 재생 중에 곡 목록을 스크롤할 때 파형 갱신이 끊기는지 잰다(`--scroll-perf`).
    static func runScrollPerfIfRequested(deck: DeckModel) {
        guard PerfProbe.enabled else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[스크롤 성능] \(text)\n".utf8)) }
        Task {
            let args = ProcessInfo.processInfo.arguments
            if let value = args.first(where: { $0.hasPrefix("--perf-waveform=") })?.split(separator: "=").last,
               let mode = WaveformColorMode(rawValue: String(value)) { deck.waveformColorMode = mode }
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            for _ in 0..<200 where !deck.canPlay || deck.waveform == nil
                || (deck.waveformColorMode != .threeBand && deck.colorWaveform == nil) { await wait(0.1) }
            guard deck.canPlay else { log("재생 불가"); exit(1) }
            @MainActor func findTable(_ view: NSView?) -> NSTableView? {
                guard let view else { return nil }
                if let table = view as? NSTableView, table.identifier == KeyRouter.trackListID { return table }
                for sub in view.subviews { if let found = findTable(sub) { return found } }
                return nil
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible }), let table = findTable(window.contentView),
                  let clip = table.enclosingScrollView?.contentView else { log("목록을 찾지 못함"); exit(1) }
            log("파형 모드: \(deck.waveformColorMode.title)")
            if let column = table.tableColumns.first(where: { $0.identifier.rawValue == "preview" }) {
                log("미리 보기 컬럼: " + (column.isHidden ? "끔" : "켬"))
            }
            // 시험 음량은 오디오에만 주고 저장된 덱 음량은 바꾸지 않는다.
            deck.audio.volume = 0.0003
            PerfProbe.startRunLoopProbe()
            // 첫 메모리 큐가 곡 끝에 있어도 측정 도중 재생이 끝나지 않게 한다.
            deck.seek(0)
            deck.togglePlay()
            await wait(1.5)
            if let arg = args.first(where: { $0.hasPrefix("--perf-capture=") }) {
                let path = String(arg.dropFirst("--perf-capture=".count))
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                await wait(0.3)
                let capture = Process()
                capture.executableURL = URL(filePath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), path]
                do {
                    try capture.run()
                    capture.waitUntilExit()
                    log("화면 저장: \(capture.terminationStatus == 0 ? "통과" : "실패")")
                } catch { log("화면 저장 실패") }
            }
            if let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "preview" }),
               !table.tableColumns[column].isHidden {
                let visible = table.rows(in: table.visibleRect)
                let hasImage = (visible.location..<NSMaxRange(visible)).contains { row in
                    let cell = table.view(atColumn: column, row: row, makeIfNecessary: false)
                    // 앱 언어와 관계없이 통과하게 PreviewWaveform과 같은 키로 비교한다.
                    return cell?.accessibilityValue() as? String == String(ui: "곡 전체 미리 보기")
                }
                log("미리 보기 비트맵: " + (hasImage ? "표시됨" : "없음"))
            }
            PerfProbe.reset()
            await wait(3)
            log("가만히: " + PerfProbe.summary())
            PerfProbe.reset()
            // 3초씩: 천천히(8ms마다 14px), 빠르게 훑기(8ms마다 70px)
            var stepCosts: [Double] = []
            for (name, step) in [("천천히 스크롤", 14.0), ("빠르게 스크롤", 70.0)] {
                PerfProbe.reset()
                let started = ProcessInfo.processInfo.systemUptime
                var y = clip.bounds.origin.y
                var down = true
                while ProcessInfo.processInfo.systemUptime - started < 3 {
                    y += down ? step : -step
                    let maxY = table.bounds.height - clip.bounds.height
                    if y >= maxY { down = false } else if y <= 0 { down = true }
                    let t0 = CACurrentMediaTime()
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(y, 0), maxY)))
                    table.enclosingScrollView?.reflectScrolledClipView(clip)
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    stepCosts.append((CACurrentMediaTime() - t0) * 1000)
                    try? await Task.sleep(for: .milliseconds(8))
                }
                let sorted = stepCosts.sorted()
                guard deck.isPlaying else { log("측정 중 재생 종료: 더 긴 곡을 선택하세요"); exit(1) }
                log("\(name): " + PerfProbe.summary()
                    + String(format: " · 스크롤 한 번 처리 평균 %.2fms · 상위 10%% %.2fms · 최대 %.2fms",
                             stepCosts.reduce(0, +) / Double(max(stepCosts.count, 1)), sorted[Int(Double(sorted.count) * 0.9)], sorted.last ?? 0))
                stepCosts = []
            }
            deck.togglePlay()
            exit(0)
        }
    }

    /// 개발용: 루프 이음새가 샘플 단위로 맞는지 실제 재생 경로로 확인한다(`--loop-audio-selftest`, 스피커 음소거).
    /// 값이 곧 프레임 번호인 램프 WAV를 틀고, 곡 믹서 출력에서 "프레임이 +1이 아닌 곳"을 모두 찾는다.
    static func runLoopAudioSelfTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--loop-audio-selftest") else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[루프 소리 시험] \(text)\n".utf8)) }
        Task { @MainActor in
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            let rate = 44_100.0, seconds = 30
            let url = FileManager.default.temporaryDirectory.appending(path: "djc-ramp.wav")
            do {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
                let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let count = Int(rate) * seconds
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                for i in 0..<count { buffer.floatChannelData![0][i] = Float(i) / 1_000_000 }
                try file.write(from: buffer)
            } catch { log("램프 파일을 만들지 못함: \(error)"); exit(1) }

            let audio = DeckAudio()
            audio.volume = 1   // 값이 곧 프레임 번호여야 한다(볼륨을 곱하지 않게)
            try? audio.load(url: url)
            for _ in 0..<100 where !audio.canLoopSampleAccurately { await wait(0.05) }
            guard audio.canLoopSampleAccurately else { log("메모리 디코딩 안 됨"); exit(1) }
            let captured = Captured()
            audio.debugCaptureTrack { buffer in
                guard let data = buffer.floatChannelData else { return }
                captured.append((0..<Int(buffer.frameLength)).map { Int((Double(data[0][$0]) * 1_000_000).rounded()) })
            }
            func frame(_ t: Double) -> Int { Int((t * rate).rounded()) }
            // 루프(2.0~2.5초) 안에서 지금 몇 초째인지 보고 누른다(½이 새 끝 전·후 두 경우를 모두 지나게).
            @MainActor func waitPhase(_ range: ClosedRange<Double>) async {
                for _ in 0..<500 {
                    if range.contains((audio.position - 2.0).truncatingRemainder(dividingBy: 0.5)) { return }
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
            // 1) 1초부터 재생 → 2) 2.0~2.5초 루프 걸기 → 3) 바퀴 앞쪽에서 ½(새 끝에서 바로 줄어듦) → 4) ×2
            // → 5) 바퀴 뒤쪽에서 ½(새 길이만큼 뒤로 뜀) → 6) ×2 두 번(2.0~3.0) → 7) 나가기(바퀴 끝에서 이어 감)
            audio.play(from: 1.0)
            await wait(0.4)
            audio.setLoop(2.0...2.5)
            await wait(1.2)
            await waitPhase(0.0...0.08)
            audio.setLoop(2.0...2.25)
            await wait(0.8)
            audio.setLoop(2.0...2.5)
            await wait(0.8)
            await waitPhase(0.20...0.28)
            audio.setLoop(2.0...2.25)
            await wait(0.8)
            audio.setLoop(2.0...2.5)
            await wait(0.6)
            audio.setLoop(2.0...3.0)
            await wait(2.2)
            audio.setLoop(nil)
            await wait(2.0)
            audio.stop()
            await wait(0.2)
            // 재생 전·멈춘 뒤의 0은 뺀다.
            var frames = Array(captured.values.drop { $0 == 0 })
            while frames.last == 0 { frames.removeLast() }
            var jumps: [(Int, Int)] = []
            var previous: Int?
            for value in frames {
                if let p = previous, value != p + 1 { jumps.append((p, value)) }
                previous = value
            }
            let expected: Set<String> = ["\(frame(2.5) - 1)→\(frame(2.0))", "\(frame(2.25) - 1)→\(frame(2.0))", "\(frame(3.0) - 1)→\(frame(2.0))"]
            // 새 끝을 지나 ½하면 정확히 새 길이(0.25초)만큼 뒤로 뛴다
            let halfLength = frame(2.25) - frame(2.0)
            let backJumps = jumps.filter { $0.1 == $0.0 + 1 - halfLength && $0.0 >= frame(2.25) && $0.0 < frame(2.5) }
            let described = jumps.map { "\($0.0)→\($0.1)" }
            let unexpected = jumps.filter { jump in
                !expected.contains("\(jump.0)→\(jump.1)") && !backJumps.contains { $0 == jump }
            }.map { "\($0.0)→\($0.1)" }
            log("받은 프레임 \(frames.count) · 이음새 \(jumps.count)곳: " + Dictionary(grouping: described, by: { $0 }).map { "\($0.key) ×\($0.value.count)" }.sorted().prefix(12).joined(separator: ", "))
            // 순서대로(연속 0은 한 덩어리로)
            var ordered: [String] = []
            for (a, b) in jumps where !(a == 0 && b == 0) { ordered.append("\(a)→\(b)") }
            log("순서: " + ordered.prefix(40).joined(separator: " "))
            let exitedAt = frames.last.map { Double($0) / rate } ?? 0
            log(String(format: "마지막 프레임 %.3f초(나간 뒤 3.0초를 지나 이어졌는지)", exitedAt))
            log("½ 뒤로 뛰기 \(backJumps.count)번(새 끝을 지나 누른 경우)")
            let ok = unexpected.isEmpty && !jumps.isEmpty && backJumps.count == 1 && exitedAt > 3.2
            log(ok ? "통과: 루프 이음새가 모두 샘플 단위로 맞음" : "실패: 예상 밖 이음새 \(unexpected.prefix(5))")
            exit(ok ? 0 : 1)
        }
    }
}

/// 개발용: 메트로놈이 박마다 한 번씩 빠짐없이 치는지 실제 재생 경로로 센다(`--metronome-selftest`, 스피커 음소거).
/// 무음 WAV + 120BPM 그리드로 12초 재생(그중 루프 구간 포함), 클릭 노드 출력에서 클릭 시작을 찾아 박 수와 비교한다.
@MainActor
func runMetronomeSelfTestIfRequested() {
    guard ProcessInfo.processInfo.arguments.contains("--metronome-selftest") else { return }
    func log(_ text: String) { FileHandle.standardError.write(Data("[메트로놈 시험] \(text)\n".utf8)) }
    Task { @MainActor in
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        let rate = 44_100.0, seconds = 40
        let url = FileManager.default.temporaryDirectory.appending(path: "djc-silence.wav")
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Int(rate) * seconds))!
            buffer.frameLength = buffer.frameCapacity
            try file.write(from: buffer)
        } catch { log("무음 파일을 만들지 못함: \(error)"); exit(1) }
        var beats: [BeatGrid.Beat] = []
        for k in 0..<80 { beats.append(BeatGrid.Beat(number: k % 4 + 1, bpm: 120, time: 0.25 + Double(k) * 0.5)) }
        let grid = BeatGrid(beats: beats)
        let audio = DeckAudio()
        try? audio.load(url: url)
        for _ in 0..<100 where !audio.canLoopSampleAccurately { await wait(0.05) }
        let captured = Captured()
        audio.debugCaptureClicks { buffer in
            guard let data = buffer.floatChannelData else { return }
            // 클릭 시작 = 조용하다가 소리가 나는 순간(버퍼 단위로 모아 보낸다: 1 = 소리, 0 = 조용)
            captured.append((0..<Int(buffer.frameLength)).map { abs(data[0][$0]) > 0.01 ? 1 : 0 })
        }
        audio.metronome = true
        audio.play(from: 1.0)
        // 화면 틱처럼 약 14ms마다 예약한다(창 경계가 박 가까이에 자주 걸리게 조금씩 흔든다).
        let started = ProcessInfo.processInfo.systemUptime
        var i = 0
        while ProcessInfo.processInfo.systemUptime - started < 12 {
            audio.scheduleClicks(grid)
            i += 1
            try? await Task.sleep(for: .milliseconds(13 + i % 3))
        }
        audio.stop()
        await wait(0.2)
        // 소리 덩어리(클릭) 수: 0→1로 바뀌는 곳. 클릭 30ms 안의 작은 끊김은 합친다.
        var onsets = 0, silentRun = 10_000
        for v in captured.values {
            if v == 1 { if silentRun > 400 { onsets += 1 }; silentRun = 0 } else { silentRun += 1 }
        }
        let played = 12.0
        let expected = grid.beats.filter { $0.time >= 1.0 && $0.time < 1.0 + played - 0.3 }.count
        log("예상 박 약 \(expected)개(마지막 0.3초 제외) · 들린 클릭 \(onsets)개")
        let ok = onsets >= expected && onsets <= expected + 1
        log(ok ? "통과: 클릭이 빠지지 않음" : "실패: 클릭 수가 다름")
        exit(ok ? 0 : 1)
    }
}

/// 오디오 탭 스레드에서 모은 값(잠금으로 보호)
final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    func append(_ values: [Int]) { lock.lock(); storage += values; lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
}
#endif
