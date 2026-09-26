import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

#if DEBUG
/// 확인 창에 늘 "예"라고 답하고 내용은 로그로 남긴다(개발용 자가 시험).
@MainActor
private struct AgreeingPrompter: ReflectionPrompter {
    var log: (String) -> Void
    func show(_ prompt: ReflectionPrompt) -> Bool {
        log("창: \(prompt.title)\n" + prompt.text.components(separatedBy: "\n").map { "    \($0)" }.joined(separator: "\n"))
        return prompt.confirm != nil
    }
}

extension DevSelfTests {
    /// 개발용: 사본 rekordbox 폴더(`DJC_REKORDBOX_DIR`)와 사본 초안(`DJC_HOME`)으로 곡 넣기 → 되돌리기 → 다시 넣기 → 빼기 → 되돌리기를
    /// 앱 흐름(`ReflectionCoordinator`) 그대로 해 본다(`--track-selftest <음원,…>`).
    static func runTrackSelfTestIfRequested(store: LibraryStore) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--track-selftest"), args.indices.contains(i + 1) else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[곡 시험] \(text)\n".utf8)) }
        let env = ProcessInfo.processInfo.environment
        guard env["DJC_REKORDBOX_DIR"]?.isEmpty == false, env["DJC_HOME"]?.isEmpty == false else {
            log("사본 폴더(DJC_REKORDBOX_DIR·DJC_HOME)가 아니면 하지 않습니다"); exit(2)
        }
        let realShare = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer/rekordbox/share").resolvingSymlinksInPath().path
        guard RekordboxShare.directory.resolvingSymlinksInPath().path != realShare else {
            log("분석 파일 폴더가 실제 rekordbox 폴더를 가리킵니다. 사본으로 바꾼 뒤 하세요"); exit(2)
        }
        let files = args[i + 1].split(separator: ",").map { URL(filePath: String($0)) }
        let coordinator = ReflectionCoordinator(host: store, prompter: AgreeingPrompter(log: log))
        Task {
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            @MainActor func loaded() -> Bool { if case .loaded = store.phase { !store.rows.isEmpty } else { false } }
            for _ in 0..<50 { if loaded() || store.isLoading { break }; await wait(0.1) }
            if !loaded(), !store.isLoading { await store.takeSnapshot() }
            for _ in 0..<600 { if loaded() { break }; await wait(0.1) }
            guard loaded() else { log("라이브러리를 읽지 못했습니다"); exit(1) }
            let before = store.rows.count
            @MainActor func rows(at paths: [String]) -> [TrackRow] {
                let wanted = Set(paths.map(\.precomposedStringWithCanonicalMapping))
                return store.rows.filter { wanted.contains($0.track.folderPath.precomposedStringWithCanonicalMapping) }
            }
            @MainActor func toast() -> String { "\(store.toast?.title ?? "-") / \(store.toast?.detail?.replacingOccurrences(of: "\n", with: " · ") ?? "")" }
            @MainActor func latestBackup() -> RekordboxWriter.Backup? { RekordboxWriter.backups(in: DJCPaths.rekordboxBackups).first(where: \.isWrite) }

            // 1. 추가 목록에 넣고 그리드 추정을 기다린다
            await store.addFiles(files)
            while store.gridJob != nil { await wait(0.3) }
            let paths = store.staged.map(\.path)
            log("추가 목록 \(store.staged.count)곡 · 그리드 " + store.staged.map { "\($0.title.prefix(16)) \($0.bpm.map { String(format: "%.2f", $0) } ?? "-")" }.joined(separator: ", "))
            // 곡마다 큐 초안(메모리 큐·핫큐)을 만들어 둔다(넣을 때 함께 들어가는지)
            for track in store.staged {
                var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: [])
                draft.place(EditableCue(kind: .memory, time: 0.2))
                draft.place(EditableCue(kind: .hot(0), time: 0.6))
                try? CueDraftStore.save(draft)
            }

            // 2. 넣기
            await coordinator.addTracks(rows: store.stagedRows)
            let added = rows(at: paths)
            log("넣기: 컬렉션 \(before) → \(store.rows.count)곡 · 알림 \(toast())")
            for row in added {
                let files = ["DAT", "EXT", "2EX"].compactMap { ext in
                    RekordboxShare.analysisURL(row.track.analysisDataPath).map { $0.deletingPathExtension().appendingPathExtension(ext) }
                }.filter { FileManager.default.fileExists(atPath: $0.path) }
                log("  \(row.title.prefix(24)) · BPM \(row.track.bpm.map { String(format: "%.2f", $0) } ?? "-") · 분석 파일 \(files.count)개 · 오토게인 \(row.autoGain.map { String(format: "%+.1f dB", $0.gainDB) } ?? "-") · 큐 \(row.cues.count)개 · 반영 대기 \(store.pendingUUIDs.contains(row.track.uuid))")
            }
            log("추가 목록 남은 곡 \(store.staged.count)")
            guard !added.isEmpty, let addBackup = latestBackup() else { log("넣은 곡이 없습니다"); exit(1) }
            let createdFiles = addBackup.trackReport?.createdFiles ?? []

            // 3. 되돌리기: 곡이 빠지고 분석 파일이 지워지고 추가 목록으로 돌아온다
            await coordinator.restore(addBackup)
            let leftFiles = createdFiles.filter { FileManager.default.fileExists(atPath: $0) }.count
            log("되돌리기: 컬렉션 \(store.rows.count)곡(처음 \(before)) · 남은 분석 파일 \(leftFiles)/\(createdFiles.count) · 추가 목록 \(store.staged.count)곡 · 알림 \(toast())")

            // 4. 다시 넣고 빼기 → 되돌리기
            await coordinator.addTracks(rows: store.stagedRows)
            let again = rows(at: paths)
            log("다시 넣기: \(again.count)곡 · 컬렉션 \(store.rows.count)")
            await coordinator.deleteTracks(rows: again)
            log("빼기: 컬렉션 \(store.rows.count)곡 · 남은 곡 \(rows(at: paths).count) · 알림 \(toast())")
            guard let deleteBackup = latestBackup() else { log("백업 없음"); exit(1) }
            await coordinator.restore(deleteBackup)
            let revived = rows(at: paths)
            let revivedFiles = revived.filter { row in
                RekordboxShare.analysisURL(row.track.analysisDataPath).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            }.count
            log("빼기 되돌리기: 되살아난 곡 \(revived.count) · 분석 파일 있는 곡 \(revivedFiles) · 알림 \(toast())")
            log("끝")
            exit(0)
        }
    }
}
#endif
