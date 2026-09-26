import DJCDomain
import DJCStorage
import AppKit
import RekordboxKit

/// 사용자에게 보여 주는 창 한 개. `confirm`이 있으면 확인·취소, 없으면 알림.
struct ReflectionPrompt: Equatable {
    var title: String
    var text: String
    var confirm: String?
    var critical = false
    var destructive = false
    var details: [String] = []
}

/// 창을 띄운다. 시험에서는 정해 둔 답을 돌려준다.
@MainActor
protocol ReflectionPrompter {
    /// 확인을 누르면 true
    func show(_ prompt: ReflectionPrompt) -> Bool
}

struct AlertPrompter: ReflectionPrompter {
    func show(_ prompt: ReflectionPrompt) -> Bool {
        let response = makeAlert(prompt).runModal()
        return prompt.confirm != nil && response == .alertFirstButtonReturn
    }

    func makeAlert(_ prompt: ReflectionPrompt) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.text
        if !prompt.details.isEmpty { alert.accessoryView = makeDetailsView(prompt.details) }
        if prompt.critical { alert.alertStyle = .critical }
        guard let confirm = prompt.confirm else {
            alert.addButton(withTitle: String(ui: "확인"))
            return alert
        }
        let confirmButton = alert.addButton(withTitle: confirm)
        // 번들이 없는 디버그 실행에서도 취소 단축키가 동작해야 한다.
        alert.addButton(withTitle: String(ui: "취소")).keyEquivalent = "\u{1b}"
        if prompt.destructive {
            confirmButton.hasDestructiveAction = true
            confirmButton.keyEquivalent = ""
        }
        return alert
    }

    private func makeDetailsView(_ details: [String]) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 240))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.isEditable = false
        // 목록이 입력 초점을 가져가면 자동으로 중간에 스크롤되고 Return을 가로챈다.
        textView.isSelectable = false
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize.height = .greatestFiniteMagnitude
        textView.setAccessibilityLabel(String(ui: "세부 내용"))
        textView.string = details.joined(separator: "\n")
        scroll.documentView = textView
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height) + 2 * textView.textContainerInset.height
            // 짧은 목록은 줄이고, 곡이 많아도 확인·취소 버튼은 창 안에 둔다.
            let borderHeight = scroll.frame.height - scroll.contentSize.height
            scroll.setFrameSize(NSSize(width: 440, height: min(240, max(44, height + borderHeight))))
            textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(height, scroll.contentSize.height)))
        }
        return scroll
    }
}

/// 반영 흐름이 쓰는 라이브러리 쪽 기능(`LibraryStore`). 시험에서는 가짜로 바꾼다.
@MainActor
protocol ReflectionHost: AnyObject {
    var isWritingRekordbox: Bool { get }
    var writeStage: WriteStage? { get set }
    var toast: AppToast? { get set }
    var resultHistory: WriteResultHistory { get }
    func setWriteLock(_ locked: Bool)
    func writeTargets(_ rows: [TrackRow]) -> [TrackRow]
    /// 재생 목록 초안이 있는지(곡을 고르지 않아도 반영할 것이 있다)
    var hasPlaylistDrafts: Bool { get }
    func previewWrite(rows: [TrackRow], playlists: Bool) async throws -> LibraryStore.WritePreview
    func writeToRekordbox(_ drafts: [CueDraft], grids: [GridDraft], gains: [String: Double], tags: [TagDraft],
                          playlists: PlaylistDraft?, merges: [DuplicateMergeDraft]) async throws -> RekordboxWriter.Report
    func libraryChangedSince(_ backup: RekordboxWriter.Backup) async -> Bool?
    func restoreRekordbox(_ backup: RekordboxWriter.Backup) async throws -> URL
    // 곡 넣기·빼기
    func trackAddTargets(_ rows: [TrackRow]) -> [TrackRow]
    func previewTrackAdd(rows: [TrackRow]) async throws -> LibraryStore.TrackAddPreview
    func addTracksToRekordbox(_ preview: LibraryStore.TrackAddPreview) async throws -> RekordboxTrackWriter.Report
    func trackDeleteTargets(_ rows: [TrackRow]) -> [TrackRow]
    func previewTrackDelete(rows: [TrackRow]) async throws -> LibraryStore.TrackDeletePreview
    func deleteTracksFromRekordbox(_ preview: LibraryStore.TrackDeletePreview) async throws -> RekordboxTrackWriter.Report
}

/// rekordbox에 바로 쓰기: rekordbox 꺼짐 확인 → 사본으로 미리 보기 → 확인 창 → 쓸 수 있는 것만 쓰기 → 토스트.
/// 되돌리기도 같은 순서(꺼짐 확인 → 그 뒤 바뀐 것 확인 → 확인 창 → 복원).
/// 쓰는 동안은 잠가서(`setWriteLock`) 덱이 재생을 멈추고 조작을 막는다.
@MainActor
struct ReflectionCoordinator {
    let host: any ReflectionHost
    var prompter: any ReflectionPrompter = AlertPrompter()
    var isRekordboxRunning: () -> Bool = LibrarySnapshot.isRekordboxRunning

    /// - Parameter playlists: 재생 목록 초안도 함께 쓸지(곡을 골라 쓰는 오른쪽 클릭 메뉴는 곡 초안만 쓴다)
    func write(rows: [TrackRow], playlists: Bool = true) async {
        guard !host.isWritingRekordbox else { return }
        guard !isRekordboxRunning() else {
            inform(String(ui: "rekordbox가 켜져 있어 쓰지 않았습니다"), Self.quitRekordboxText)
            return
        }
        let targets = host.writeTargets(rows)
        let withPlaylists = playlists && host.hasPlaylistDrafts
        guard !targets.isEmpty || withPlaylists else {
            inform(String(ui: "반영할 초안이 없습니다"), String(ui: "고른 곡에 rekordbox와 다른 큐·그리드·게인·태그 초안이 없습니다."))
            return
        }
        host.setWriteLock(true)
        defer { host.setWriteLock(false) }
        do {
            host.writeStage = WriteStage(String(ui: "바꿀 내용을 확인하는 중…"), completed: 0, total: targets.count, cancellable: true)
            try Task.checkCancellation()
            let preview = try await host.previewWrite(rows: targets, playlists: withPlaylists)
            try Task.checkCancellation()
            host.writeStage = nil
            let report = preview.report
            guard !report.written.isEmpty || !report.gridWritten.isEmpty || !report.analysisWritten.isEmpty || !report.gainWritten.isEmpty
                    || !report.tagWritten.isEmpty || !report.playlistWritten.isEmpty || !report.mergeWritten.isEmpty else {
                publish(.written(report, preview: report))
                inform(String(ui: "rekordbox에 쓸 수 있는 초안이 없습니다"), "", details: Self.reasons(report))
                return
            }
            guard prompter.show(Self.confirmation(report)) else { return }
            // 분석을 붙이는 곡도 그리드 초안으로 쓴다.
            let cues = Set(report.written.map(\.trackUUID)), grids = Set((report.gridWritten + report.analysisWritten).map(\.trackUUID))
            let gains = Set(report.gainWritten.map(\.trackUUID)), tags = Set(report.tagWritten.map(\.trackUUID))
            try Task.checkCancellation()
            let written = try await host.writeToRekordbox(preview.drafts.filter { cues.contains($0.trackUUID) },
                                                grids: preview.grids.filter { grids.contains($0.trackUUID) },
                                                gains: preview.gains.filter { gains.contains($0.key) },
                                                tags: preview.tags.filter { tags.contains($0.trackUUID) },
                                                playlists: report.playlistWritten.isEmpty ? nil : preview.playlists,
                                                merges: preview.merges.filter { draft in report.mergeWritten.contains { $0.trackUUID == draft.id } })
            publish(.written(written, preview: report), undo: written.backup)
        } catch is CancellationError {
            host.writeStage = nil
            publishCancelled()
        } catch {
            host.writeStage = nil
            fail(String(ui: "rekordbox에 쓰지 않았습니다"), error)
        }
    }

    /// 추가한 곡을 rekordbox 컬렉션에 넣는다(그리드·파형·오토게인까지). 흐름은 쓰기와 같다.
    func addTracks(rows: [TrackRow]) async {
        guard !host.isWritingRekordbox else { return }
        guard !isRekordboxRunning() else {
            inform(String(ui: "rekordbox가 켜져 있어 넣지 않았습니다"), Self.quitRekordboxText)
            return
        }
        let targets = host.trackAddTargets(rows)
        guard !targets.isEmpty else {
            inform(String(ui: "rekordbox에 넣을 곡이 없습니다"), String(ui: "DJCrate에 추가한 곡만 rekordbox에 넣을 수 있습니다."))
            return
        }
        host.setWriteLock(true)
        defer { host.setWriteLock(false) }
        do {
            host.writeStage = WriteStage(String(ui: "넣을 곡을 확인하는 중…"), completed: 0, total: targets.count, cancellable: true)
            try Task.checkCancellation()
            let preview = try await host.previewTrackAdd(rows: targets)
            try Task.checkCancellation()
            host.writeStage = nil
            guard preview.report.added.contains(where: \.written) else {
                publish(.tracks(preview.report, preview: preview.report, adding: true, withoutAnalysis: preview.withoutAnalysis, unreadable: preview.unreadable))
                inform(String(ui: "rekordbox에 넣을 수 있는 곡이 없습니다"), "", details: Self.addReasons(preview))
                return
            }
            guard prompter.show(Self.addConfirmation(preview)) else { return }
            try Task.checkCancellation()
            let written = try await host.addTracksToRekordbox(preview)
            publish(.tracks(written, preview: preview.report, adding: true, withoutAnalysis: preview.withoutAnalysis, unreadable: preview.unreadable), undo: written.backup)
        } catch is CancellationError {
            host.writeStage = nil
            publishCancelled()
        } catch {
            host.writeStage = nil
            fail(String(ui: "rekordbox에 넣지 않았습니다"), error)
        }
    }

    /// rekordbox 컬렉션에서 곡을 뺀다(음원 파일은 그대로). 흐름은 쓰기와 같고 확인 창은 경고 모양이다.
    func deleteTracks(rows: [TrackRow]) async {
        guard !host.isWritingRekordbox else { return }
        guard !isRekordboxRunning() else {
            inform(String(ui: "rekordbox가 켜져 있어 빼지 않았습니다"), Self.quitRekordboxText)
            return
        }
        let targets = host.trackDeleteTargets(rows)
        guard !targets.isEmpty else {
            inform(String(ui: "rekordbox에서 뺄 곡이 없습니다"), String(ui: "rekordbox 컬렉션의 로컬 곡만 뺄 수 있습니다(스트리밍·추가한 곡 제외)."))
            return
        }
        host.setWriteLock(true)
        defer { host.setWriteLock(false) }
        do {
            host.writeStage = WriteStage(String(ui: "뺄 곡을 확인하는 중…"), completed: 0, total: targets.count, cancellable: true)
            try Task.checkCancellation()
            let preview = try await host.previewTrackDelete(rows: targets)
            try Task.checkCancellation()
            host.writeStage = nil
            guard preview.report.deleted.contains(where: \.written) else {
                publish(.tracks(preview.report, preview: preview.report, adding: false))
                inform(String(ui: "rekordbox에서 뺄 수 있는 곡이 없습니다"), "",
                       details: preview.report.deleted.map { "• \($0.title): \($0.reason ?? "")" })
                return
            }
            guard prompter.show(Self.deleteConfirmation(preview)) else { return }
            try Task.checkCancellation()
            let written = try await host.deleteTracksFromRekordbox(preview)
            publish(.tracks(written, preview: preview.report, adding: false), undo: written.backup)
        } catch is CancellationError {
            host.writeStage = nil
            publishCancelled()
        } catch {
            host.writeStage = nil
            fail(String(ui: "rekordbox에서 빼지 않았습니다"), error)
        }
    }

    func restore(_ backup: RekordboxWriter.Backup) async {
        guard !host.isWritingRekordbox else { return }
        guard !isRekordboxRunning() else {
            inform(String(ui: "rekordbox가 켜져 있어 되돌리지 않았습니다"), String(ui: "rekordbox를 완전히 종료한 뒤 다시 누르세요."))
            return
        }
        host.setWriteLock(true)
        defer { host.setWriteLock(false) }
        host.writeStage = WriteStage(String(ui: "백업 뒤 바뀐 것을 확인하는 중…"))
        let changed = await host.libraryChangedSince(backup)
        host.writeStage = nil
        guard prompter.show(Self.restoreConfirmation(backup, changedSince: changed)) else { return }
        do {
            let saved = try await host.restoreRekordbox(backup)
            publish(.restored(backup, saved: saved))
        } catch {
            host.writeStage = nil
            host.toast = nil
            AppErrorMessage.log(error)
            let text = String(ui: "rekordbox 라이브러리 상태를 확인하지 못했으므로 rekordbox를 켜지 말고 백업 폴더의 위치와 접근 권한을 확인한 뒤 다시 되돌리세요.")
            let title = String(ui: "되돌리지 못했습니다")
            host.resultHistory.record(WriteResult(kind: .failure, title: title, text: text, backups: [backup.url]))
            _ = prompter.show(ReflectionPrompt(title: title, text: text, critical: true))
        }
    }

    /// 작업을 취소했을 때의 결과. 미리 보기 단계에서만 취소할 수 있어 아무것도 쓰지 않았다.
    private func publishCancelled() {
        let text = String(ui: "rekordbox에 아무것도 쓰지 않았습니다.")
        publish(WriteResult(kind: .success, title: String(ui: "작업을 취소했습니다"), text: text), detail: text)
    }

    private func publish(_ result: WriteResult, undo: String? = nil, detail: String? = nil) {
        host.resultHistory.record(result)
        var toast = result.toast
        if let detail { toast.detail = detail }
        toast.undoBackup = undo.map { URL(filePath: $0) }
        if let error = host.resultHistory.storageError {
            if toast.kind == .success { toast.kind = .warning }
            toast.detail = [toast.detail, error].compactMap { $0 }.joined(separator: "\n")
        }
        host.toast = toast
    }

    private func inform(_ title: String, _ text: String, details: [String] = []) {
        _ = prompter.show(ReflectionPrompt(title: title, text: text, details: details))
    }

    /// 쓰기 실패 알림. 자동 복원까지 실패했으면 사라지는 토스트가 아니라 닫아야 하는 경고 창으로 알린다.
    private func fail(_ title: String, _ error: any Error) {
        if let alert = Self.restoreFailureAlert(error) {
            host.toast = nil
            let backups: [URL]
            if case let DJCError.restoreFailed(_, _, backup, _) = error { backups = [URL(filePath: backup)] } else { backups = [] }
            host.resultHistory.record(WriteResult(kind: .failure, title: alert.title, text: alert.text, backups: backups))
            _ = prompter.show(alert)
        } else {
            let message = AppErrorMessage.message(for: error)
            publish(WriteResult(kind: .failure, title: title, text: message), detail: message)
        }
    }

    // MARK: - 창 문구

    static var quitRekordboxText: String {
        String(ui: "rekordbox를 완전히 종료한 뒤 다시 누르세요. DJCrate는 rekordbox가 켜져 있는 동안에는 rekordbox 라이브러리에 절대 쓰지 않습니다.")
    }

    /// 확인 창이 쓰는 백업 안내(쓰기·넣기·빼기 공통)
    private static var backupThenWriteText: String {
        String(ui: "백업한 뒤 쓰고 다시 확인합니다. 끝날 때까지 rekordbox를 켜지 마세요.")
    }

    /// 쓰기 확인도 자동 복원도 실패했을 때의 경고(상태를 알 수 없음 + 할 일). 그 밖의 오류면 nil.
    /// 반영·넣기·빼기 모두 '반영 대기' 목록의 '되돌리기…'(가장 최근 쓰기 백업으로 되돌림)를 안내한다.
    /// 툴바의 '마지막 반영 되돌리기…'는 쓰기가 성공했을 때만 활성화된다.
    static func restoreFailureAlert(_ error: any Error) -> ReflectionPrompt? {
        guard case let DJCError.restoreFailed(_, _, backup, database) = error else { return nil }
        AppErrorMessage.log(error)
        let command = DJCError.restoreCommand(backup: backup, database: database)
        let text = [
            String(ui: "rekordbox 라이브러리(master.db)와 분석 파일이 어떤 상태인지 알 수 없습니다. rekordbox를 켜지 말고, 사이드바에서 'rekordbox 반영 대기'를 고른 뒤 목록 위 '되돌리기…'로 쓰기 전 백업을 복원하세요."),
            String(ui: "터미널에서는: \(command)"),
        ]
        return ReflectionPrompt(title: String(ui: "쓰기 확인에 실패했고 자동 복원도 하지 못했습니다"), text: text.joined(separator: "\n\n"), critical: true)
    }

    static func reasons(_ report: RekordboxWriter.Report) -> [String] {
        (report.blocked + report.gridBlocked + report.analysisBlocked + report.gainBlocked + report.tagBlocked + report.mergeBlocked).map { "• \($0.title): \($0.reason ?? "")" }
            + report.playlistBlocked.map(PlaylistWriteText.reason)
    }

    /// 쓰기 전 확인 창: 종류별 곡 수, 곡마다 바뀌는 것, 쓰지 않는 것과 이유
    static func confirmation(_ report: RekordboxWriter.Report) -> ReflectionPrompt {
        let cues = report.written, grids = report.gridWritten, analyses = report.analysisWritten, gains = report.gainWritten
        let tags = report.tagWritten
        var kinds: [String] = []
        if !cues.isEmpty { kinds.append(WriteResult.Part.cue.summary(cues.count)) }
        if !grids.isEmpty { kinds.append(WriteResult.Part.grid.summary(grids.count)) }
        if !analyses.isEmpty { kinds.append(WriteResult.Part.analysis.summary(analyses.count)) }
        if !gains.isEmpty { kinds.append(WriteResult.Part.gain.summary(gains.count)) }
        if !tags.isEmpty { kinds.append(WriteResult.Part.tag.summary(tags.count)) }
        // 태그는 바꾼 칸 이름으로(제목·아티스트…)
        let tagFields = Dictionary(tags.map { tag in
            (tag.trackUUID, (tag.fields ?? []).compactMap { TagFields.Key(rawValue: $0)?.label }.joined(separator: "·"))
        }, uniquingKeysWith: { a, _ in a })
        if !report.mergeWritten.isEmpty { kinds.append(String(ui: "합치기 \(report.mergeWritten.count)묶음")) }
        let playlists = report.playlistWritten
        if !playlists.isEmpty { kinds.append(PlaylistWriteText.summary(playlists.count)) }
        let gridBlocked = Set((report.gridBlocked + report.analysisBlocked).map(\.trackUUID)), gridWritten = Set(grids.map(\.trackUUID))
        let analysisWritten = Set(analyses.map(\.trackUUID))
        // 분석을 붙이며 음원 그림으로 아트워크도 넣는 곡(rekordbox도 분석할 때 뽑는다, #87)
        let artwork = Set(report.artworkAdded ?? [])
        var body = cues.map { outcome -> String in
            var changes: [String] = []
            if outcome.added > 0 { changes.append("+\(outcome.added)") }
            if outcome.removed > 0 { changes.append("−\(outcome.removed)") }
            // 줄 모양 "• 곡 — 내용 · 내용"은 언어와 관계없고, 내용만 번역한다.
            var parts = [changes.isEmpty ? String(ui: "큐 변경") : String(ui: "큐 \(changes.joined(separator: " · "))")]
            if gridWritten.contains(outcome.trackUUID) { parts.append(String(ui: "그리드")) }
            if analysisWritten.contains(outcome.trackUUID) {
                parts.append(String(ui: "분석 파일 붙이기"))
                if artwork.contains(outcome.trackUUID) { parts.append(String(ui: "아트워크")) }
            }
            if gridBlocked.contains(outcome.trackUUID) { parts.append(String(ui: "⚠︎ 그리드는 안 들어감")) }
            if let fields = tagFields[outcome.trackUUID] { parts.append(String(ui: "태그(\(fields))")) }
            return "• \(outcome.title) — " + parts.joined(separator: " · ")
        }
        let cueUUIDs = Set(cues.map(\.trackUUID))
        for grid in grids where !cueUUIDs.contains(grid.trackUUID) { body.append("• \(grid.title) — " + String(ui: "그리드(박 \(grid.added)개)")) }
        for analysis in analyses where !cueUUIDs.contains(analysis.trackUUID) {
            let made = artwork.contains(analysis.trackUUID)
                ? String(ui: "분석 파일 붙이기(파형·그리드 박 \(analysis.added)개·오토게인·아트워크)")
                : String(ui: "분석 파일 붙이기(파형·그리드 박 \(analysis.added)개·오토게인)")
            body.append("• \(analysis.title) — " + made)
        }
        for gain in gains { body.append("• \(gain.title) — " + String(ui: "오토게인 \(Double(gain.added) / 100, specifier: "%+.1f") dB")) }
        for tag in tags where !cueUUIDs.contains(tag.trackUUID) {
            body.append("• \(tag.title) — " + String(ui: "태그(\(tagFields[tag.trackUUID] ?? ""))"))
        }
        body += playlists.map(PlaylistWriteText.line)
        body += report.mergeWritten.map { String(ui: "• \($0.title) 유지 · 중복 \($0.removed)곡을 컬렉션에서 뺍니다") }
        if !report.mergeWritten.isEmpty { body += ["", DuplicateMerge.lossNotice] }
        let reasons = reasons(report)
        if !reasons.isEmpty { body += ["", String(ui: "쓰지 않는 것 \(reasons.count):")] + reasons }
        if !analyses.isEmpty {
            body += ["", analyses.contains { artwork.contains($0.trackUUID) }
                ? String(ui: "파형·그리드·오토게인과 음원의 아트워크를 붙입니다. 키·프레이즈·보컬 분석은 없습니다.")
                : String(ui: "파형·그리드·오토게인만 붙입니다. 키·프레이즈·보컬 분석은 없습니다.")]
        }
        if !tags.isEmpty {
            // 결정(#1, 2026-09-26): rekordbox 라이브러리만 쓰고 음원은 읽기만 한다.
            body += ["", String(ui: "태그는 rekordbox 라이브러리에만 씁니다. 음원 파일의 태그는 그대로라 다른 앱이나 rekordbox '태그 다시 읽기'에서는 예전 값이 보일 수 있습니다.")]
        }
        return ReflectionPrompt(title: String(ui: "\(kinds.joined(separator: " · "))을 rekordbox에 쓸까요?"),
                                text: backupThenWriteText,
                                confirm: String(ui: "rekordbox에 쓰기"), destructive: !report.mergeWritten.isEmpty, details: body)
    }

    static func addReasons(_ preview: LibraryStore.TrackAddPreview) -> [String] {
        preview.report.added.filter { !$0.written }.map { "• \($0.title): \($0.reason ?? "")" } + preview.unreadable.map { "• \($0)" }
    }

    /// 아트워크 쓰기가 닫혀 있을 때(`RekordboxTrackWriter.writesArtwork`) 음원에 아트워크가 든 곡을 넣으면 보이는 안내
    static var artworkClosedNote: String {
        String(ui: "음원의 아트워크는 아직 넣지 않으니, 필요하면 rekordbox 곡 정보 창에서 이미지를 끌어다 붙이세요.")
    }

    /// 넣기 전 확인 창: 곡마다 분석까지 붙는지(아트워크도 넣는지), 넣지 않는 곡과 이유.
    /// 아트워크는 분석까지 붙이는 곡에만 넣는다(rekordbox도 분석할 때 뽑는다, 2026-09-26 실험).
    static func addConfirmation(_ preview: LibraryStore.TrackAddPreview,
                                writesArtwork: Bool = RekordboxTrackWriter.writesArtwork) -> ReflectionPrompt {
        let written = preview.report.added.filter(\.written)
        let artwork = Set(preview.plans.filter { $0.artwork != nil }.map(\.path))
        let bare = written.filter { preview.withoutAnalysis[$0.path] != nil }
        let analysedArtwork = written.filter { preview.withoutAnalysis[$0.path] == nil && artwork.contains($0.path) }
        var body = written.map { outcome -> String in
            var parts = [preview.withoutAnalysis[outcome.path].map { String(ui: "분석 없이(\($0))") }
                ?? String(ui: "그리드·파형·오토게인까지")]
            if writesArtwork, analysedArtwork.contains(outcome) { parts.append(String(ui: "아트워크")) }
            if let count = outcome.cuesWritten, count > 0 { parts.append(String(ui: "큐 \(count)개")) }
            if let reason = outcome.cueReason { parts.append(String(ui: "⚠︎ 큐는 안 들어감(\(reason))")) }
            return "• \(outcome.title) — " + parts.joined(separator: " · ")
        }
        let reasons = addReasons(preview)
        if !reasons.isEmpty { body += ["", String(ui: "넣지 않는 곡 \(reasons.count):")] + reasons }
        if !bare.isEmpty {
            body += ["", bare.contains { artwork.contains($0.path) }
                ? String(ui: "분석 없이 넣는 곡은 rekordbox에서 분석해야 파형·그리드·아트워크가 생깁니다.")
                : String(ui: "분석 없이 넣는 곡은 rekordbox에서 분석해야 파형·그리드가 생깁니다.")]
        }
        if !writesArtwork, !analysedArtwork.isEmpty {
            body += ["", Self.artworkClosedNote]
        }
        return ReflectionPrompt(title: String(ui: "\(written.count)곡을 rekordbox에 넣을까요?"),
                                text: backupThenWriteText,
                                confirm: String(ui: "rekordbox에 넣기"), details: body)
    }

    /// 빼기 전 확인 창(경고): 뺄 곡, 빼지 않는 곡과 이유, 함께 사라지는 것
    static func deleteConfirmation(_ preview: LibraryStore.TrackDeletePreview) -> ReflectionPrompt {
        let written = preview.report.deleted.filter(\.written), blocked = preview.report.deleted.filter { !$0.written }
        var body = written.map { "• \($0.title)" }
        if !blocked.isEmpty { body += ["", String(ui: "빼지 않는 곡 \(blocked.count):")] + blocked.map { "• \($0.title): \($0.reason ?? "")" } }
        return ReflectionPrompt(title: String(ui: "\(written.count)곡을 rekordbox에서 뺄까요?"),
                                text: String(ui: "음원 파일은 지우지 않습니다. rekordbox의 큐·재생 목록 항목·재생 기록·분석 파일·아트워크가 함께 사라집니다.")
                                    + "\n" + backupThenWriteText,
                                confirm: String(ui: "rekordbox에서 빼기"), critical: true, details: body)
    }

    /// 되돌리기 확인 창. 백업 뒤 변경이 있거나 확인하지 못했으면 파괴적 경고로 띄운다.
    static func restoreConfirmation(_ backup: RekordboxWriter.Backup, changedSince changed: Bool?) -> ReflectionPrompt {
        var lines = [String(ui: "백업: \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))")]
        let details = backup.titles.isEmpty ? [] : [String(ui: "그때 쓴 곡:")] + backup.titles.map { "• \($0)" }
        if let tracks = backup.trackReport {
            let added = tracks.added.filter(\.written).count, deleted = tracks.deleted.filter(\.written).count
            // 문장마다 번역하고, 문장 뒤 빈칸은 원래 모양 그대로 둔다.
            var sentences = [String(ui: "라이브러리 전체를 이 백업으로 되돌립니다.")]
            if added > 0 { sentences.append(String(ui: "넣었던 \(added)곡은 컬렉션에서 빠지고 DJCrate 추가 목록으로 돌아옵니다(분석·아트워크 파일도 삭제).")) }
            if deleted > 0 { sentences.append(String(ui: "뺐던 \(deleted)곡은 큐·재생 목록·분석 파일·아트워크와 함께 복원됩니다.")) }
            lines.append(sentences.map { $0 + " " }.joined())
        } else {
            lines.append(String(ui: "라이브러리 전체를 이 백업으로 되돌립니다. 그때 쓴 초안(큐·그리드·게인·태그)도 DJCrate에 복원됩니다."))
        }
        switch changed {
        case true?: lines.append(String(ui: "⚠︎ 이 백업 뒤에 rekordbox에서도 라이브러리가 바뀌었습니다(큐·재생 목록·곡 추가 등). 되돌리면 그 변경도 함께 사라집니다."))
        case nil: lines.append(String(ui: "백업 뒤 rekordbox에서 바뀐 것이 있는지 확인하지 못했습니다. 그 뒤 rekordbox에서 한 변경은 함께 사라집니다."))
        case false?: break
        }
        lines.append(String(ui: "백업한 뒤 되돌리고 다시 확인합니다. 끝날 때까지 rekordbox를 켜지 마세요."))
        return ReflectionPrompt(title: String(ui: "rekordbox를 쓰기 전으로 되돌릴까요?"),
                                text: lines.joined(separator: "\n\n"), confirm: String(localized: "reflection.restore", defaultValue: "되돌리기", bundle: UIStrings.bundle),
                                critical: changed != false, destructive: changed != false, details: details)
    }
}

extension LibraryStore: ReflectionHost {
    func setWriteLock(_ locked: Bool) {
        isWritingRekordbox = locked
        onWriteLock?(locked)
    }
}
