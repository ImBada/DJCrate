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
    /// 세 갈래 창(`choose`)의 둘째 동작 단추
    var alternate: String?
    /// 취소 단추 이름(nil이면 "취소")
    var cancel: String?
}

/// 세 갈래 창의 답
enum ReflectionChoice: Equatable {
    case confirm, alternate, cancel
}

/// 창을 띄운다. 시험에서는 정해 둔 답을 돌려준다.
@MainActor
protocol ReflectionPrompter {
    /// 확인을 누르면 true
    func show(_ prompt: ReflectionPrompt) -> Bool
    /// 확인·둘째 동작·취소 중 무엇을 눌렀는지(둘째 동작이 없는 창은 `show`와 같다)
    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice
}

extension ReflectionPrompter {
    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice { show(prompt) ? .confirm : .cancel }
}

struct AlertPrompter: ReflectionPrompter {
    func show(_ prompt: ReflectionPrompt) -> Bool {
        choose(prompt) == .confirm
    }

    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice {
        let response = makeAlert(prompt).runModal()
        guard prompt.confirm != nil else { return .cancel }
        switch response {
        case .alertFirstButtonReturn: return .confirm
        case .alertSecondButtonReturn where prompt.alternate != nil: return .alternate
        default: return .cancel
        }
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
        if let alternate = prompt.alternate { alert.addButton(withTitle: alternate) }
        // 번들이 없는 디버그 실행에서도 취소 단축키가 동작해야 한다.
        alert.addButton(withTitle: prompt.cancel ?? String(ui: "취소")).keyEquivalent = "\u{1b}"
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
    func writeToRekordbox(_ drafts: [CueDraft], grids: [GridDraft], gains: [String: Double], tags: [TagDraft], artworks: [ArtworkEdit],
                          playlists: PlaylistDraft?, merges: [DuplicateMergeDraft]) async throws -> RekordboxWriter.Report
    func libraryChangedSince(_ backup: RekordboxWriter.Backup) async -> Bool?
    func restoreRekordbox(_ backup: RekordboxWriter.Backup) async throws -> URL
    /// 쓰기·복원은 끝났지만 뒤따른 일(초안 정리·다시 읽기·복원 충돌)에 남은 경고(#175)
    var writeFollowUp: [String] { get }
    /// 쓰기 전 백업을 만들 수 있는지(백업 폴더에 쓸 수 있는지)
    var canBackUpBeforeWrite: Bool { get }
    /// 복원이 되살릴 백업 초안과 다른, 쓴 뒤 새로 만든 초안(확인 창에 보일 줄)
    func restoreDraftConflictDetails(_ backup: RekordboxWriter.Backup) -> [String]
    /// - Parameter keepingCurrentDrafts: 쓴 뒤 새로 만든 초안을 남기고 그 곡의 백업 초안은 되살리지 않는다
    func restoreRekordbox(_ backup: RekordboxWriter.Backup, keepingCurrentDrafts: Bool) async throws -> URL
    // 곡 넣기·빼기
    func trackAddTargets(_ rows: [TrackRow]) -> [TrackRow]
    func previewTrackAdd(rows: [TrackRow]) async throws -> LibraryStore.TrackAddPreview
    func addTracksToRekordbox(_ preview: LibraryStore.TrackAddPreview) async throws -> RekordboxTrackWriter.Report
    func trackDeleteTargets(_ rows: [TrackRow]) -> [TrackRow]
    func previewTrackDelete(rows: [TrackRow]) async throws -> LibraryStore.TrackDeletePreview
    func deleteTracksFromRekordbox(_ preview: LibraryStore.TrackDeletePreview) async throws -> RekordboxTrackWriter.Report
}

extension ReflectionHost {
    var writeFollowUp: [String] { [] }
    var canBackUpBeforeWrite: Bool { true }
    func restoreDraftConflictDetails(_ backup: RekordboxWriter.Backup) -> [String] { [] }
    func restoreRekordbox(_ backup: RekordboxWriter.Backup, keepingCurrentDrafts: Bool) async throws -> URL {
        try await restoreRekordbox(backup)
    }
}

/// rekordbox에 바로 쓰기: rekordbox 꺼짐 확인 → 사본으로 미리 보기 → (막힘·제외·손실이 있을 때만) 확인 창 → 쓸 수 있는 것만 쓰기 → 토스트.
/// 되돌리기도 같은 순서(꺼짐 확인 → 그 뒤 바뀐 것 확인 → 확인 창 → 복원). 토스트에서 누른 복원은 그 뒤 변경·초안 충돌이 없으면 묻지 않는다.
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
            inform(String(ui: "쓸 초안이 없습니다"), String(ui: "고른 곡에 rekordbox와 다른 큐·그리드·게인·태그 초안이 없습니다."),
                   details: (host as? LibraryStore)?.draftExclusionReasons(for: rows) ?? [])
            return
        }
        host.setWriteLock(true)
        defer { host.setWriteLock(false) }
        do {
            host.writeStage = WriteStage(String(ui: "바꿀 내용을 확인하는 중…"), completed: 0, total: targets.count, cancellable: true)
            try Task.checkCancellation()
            let preview = try await host.previewWrite(rows: rows, playlists: withPlaylists)
            try Task.checkCancellation()
            host.writeStage = nil
            let report = preview.report
            guard !report.written.isEmpty || !report.gridWritten.isEmpty || !report.analysisWritten.isEmpty || !report.gainWritten.isEmpty
                    || !report.tagWritten.isEmpty || !report.artworkWritten.isEmpty || !report.playlistWritten.isEmpty
                    || !report.mergeWritten.isEmpty else {
                publish(.written(report, preview: report))
                if let store = host as? LibraryStore,
                   targets.contains(where: { !store.recoveryKinds(for: $0).isEmpty }) || !report.playlistBlocked.isEmpty {
                    let tracks = targets.contains { !store.recoveryKinds(for: $0).isEmpty }
                    let playlists = !report.playlistBlocked.isEmpty
                    let prompt = ReflectionPrompt(title: String(ui: "rekordbox에 쓸 수 있는 초안이 없습니다"),
                                                  text: String(ui: "쓸 수 없는 곡이나 재생 목록의 현재값을 비교해 초안을 다시 적용하거나 버리세요."),
                                                  confirm: tracks ? String(ui: "현재값 비교…") : String(ui: "재생 목록 현재값 가져오기…"),
                                                  details: Self.reasons(report) + preview.exclusions,
                                                  alternate: tracks && playlists ? String(ui: "재생 목록 현재값 가져오기…") : nil)
                    let choice = prompter.choose(prompt)
                    if choice != .cancel {
                        host.setWriteLock(false)
                        if tracks && choice == .confirm { await chooseRecoveryTarget(store: store, rows: targets) }
                        else { await recoverPlaylistDraft(store: store) }
                    }
                } else {
                    inform(String(ui: "rekordbox에 쓸 수 있는 초안이 없습니다"), "", details: Self.reasons(report) + preview.exclusions)
                }
                return
            }
            // 막힘·제외·손실이 없으면 묻지 않고 쓴다. 결과 토스트와 메뉴의 "쓰기 전으로 복원…"으로 되돌린다(#210).
            let canBackUp = host.canBackUpBeforeWrite
            if !WriteConfirmPolicy.reasons(report, exclusions: preview.exclusions, canBackUp: canBackUp).isEmpty {
                guard prompter.show(Self.confirmation(report, exclusions: preview.exclusions, canBackUp: canBackUp)) else { return }
            }
            // 분석을 붙이는 곡도 그리드 초안으로 쓴다.
            let cues = Set(report.written.map(\.trackUUID)), grids = Set((report.gridWritten + report.analysisWritten).map(\.trackUUID))
            let gains = Set(report.gainWritten.map(\.trackUUID)), tags = Set(report.tagWritten.map(\.trackUUID))
            let artworks = Set(report.artworkWritten.map(\.trackUUID))
            try Task.checkCancellation()
            let written = try await host.writeToRekordbox(preview.drafts.filter { cues.contains($0.trackUUID) },
                                                grids: preview.grids.filter { grids.contains($0.trackUUID) },
                                                gains: preview.gains.filter { gains.contains($0.key) },
                                                tags: preview.tags.filter { tags.contains($0.trackUUID) },
                                                artworks: preview.artworks.filter { artworks.contains($0.trackUUID) },
                                                playlists: report.playlistWritten.isEmpty ? nil : preview.playlists,
                                                merges: preview.merges.filter { draft in report.mergeWritten.contains { $0.trackUUID == draft.id } })
            // 쓰기 결과와 뒤따른 일(초안 정리·다시 읽기)의 경고를 나눠 알린다(#175).
            publish(WriteResult.written(written, preview: report).followedUp(host.writeFollowUp), undo: written.backup)
        } catch is CancellationError {
            host.writeStage = nil
            publishCancelled()
        } catch {
            host.writeStage = nil
            fail(String(ui: "rekordbox에 쓰지 않았습니다"), error)
            let exclusions = (host as? LibraryStore)?.draftExclusionReasons(for: rows, blockedOnly: true) ?? []
            if !exclusions.isEmpty { inform(String(ui: "미리 보기에서 제외한 초안"), "", details: exclusions) }
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
            let canBackUp = host.canBackUpBeforeWrite, writesArtwork = RekordboxTrackWriter.writesArtwork
            if !WriteConfirmPolicy.addReasons(preview, writesArtwork: writesArtwork, canBackUp: canBackUp).isEmpty {
                guard prompter.show(Self.addConfirmation(preview, writesArtwork: writesArtwork, canBackUp: canBackUp)) else { return }
            }
            try Task.checkCancellation()
            let written = try await host.addTracksToRekordbox(preview)
            // 넣기는 끝났지만 백업에 추가 목록·초안을 남기지 못했다는 경고는 결과와 나눠 덧붙인다(#202).
            publish(.tracks(written, preview: preview.report, adding: true, withoutAnalysis: preview.withoutAnalysis, unreadable: preview.unreadable)
                .followedUp(host.writeFollowUp), undo: written.backup)
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

    /// - Parameter confirmed: 쓰기 결과 토스트의 복원 단추로 불렀는지(그 백업을 보고 누른 것이라 확인으로 본다)
    func restore(_ backup: RekordboxWriter.Backup, confirmed: Bool = false) async {
        guard !host.isWritingRekordbox else { return }
        guard !isRekordboxRunning() else {
            inform(String(ui: "rekordbox가 켜져 있어 복원하지 않았습니다"), String(ui: "rekordbox를 완전히 종료한 뒤 다시 누르세요."))
            return
        }
        host.setWriteLock(true)
        defer { host.setWriteLock(false) }
        host.writeStage = WriteStage(String(ui: "백업 뒤 바뀐 것을 확인하는 중…"))
        let changed = await host.libraryChangedSince(backup)
        // 쓴 뒤 같은 곡에 새로 만든 초안은 말없이 덮지 않고 고르게 한다(#175).
        let conflicts = host.restoreDraftConflictDetails(backup)
        host.writeStage = nil
        let keepingCurrentDrafts: Bool
        if conflicts.isEmpty {
            // 토스트의 복원 단추를 누른 것이 곧 확인이다. 그 뒤 rekordbox 변경을 잃을 수 있으면 다시 묻는다(#210).
            if !(confirmed && changed == false) {
                guard prompter.show(Self.restoreConfirmation(backup, changedSince: changed)) else { return }
            }
            keepingCurrentDrafts = true
        } else {
            switch prompter.choose(Self.restoreConfirmation(backup, changedSince: changed, conflicts: conflicts)) {
            case .confirm: keepingCurrentDrafts = true
            case .alternate: keepingCurrentDrafts = false
            case .cancel: return
            }
        }
        do {
            let saved = try await host.restoreRekordbox(backup, keepingCurrentDrafts: keepingCurrentDrafts)
            publish(WriteResult.restored(backup, saved: saved).followedUp(host.writeFollowUp))
        } catch {
            host.writeStage = nil
            host.toast = nil
            AppErrorMessage.log(error)
            let text = String(ui: "rekordbox 라이브러리 상태를 확인하지 못했으므로 rekordbox를 켜지 말고 백업 폴더의 위치와 접근 권한을 확인한 뒤 다시 복원하세요.")
            let title = String(ui: "복원하지 못했습니다")
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
            String(ui: "rekordbox 라이브러리(master.db)와 분석 파일이 어떤 상태인지 알 수 없습니다. rekordbox를 켜지 말고, 사이드바에서 'rekordbox 쓰기 대기'를 고른 뒤 목록 위 '쓰기 전으로 복원…'으로 백업을 복원하세요."),
            String(ui: "터미널에서는: \(command)"),
        ]
        return ReflectionPrompt(title: String(ui: "쓰기 확인에 실패했고 자동 복원도 하지 못했습니다"), text: text.joined(separator: "\n\n"), critical: true)
    }

    static func reasons(_ report: RekordboxWriter.Report) -> [String] {
        (report.blocked + report.gridBlocked + report.analysisBlocked + report.gainBlocked + report.tagBlocked + report.artworkBlocked
            + report.mergeBlocked).map { "• \($0.title): \($0.reason ?? "")" }
            + report.playlistBlocked.map(PlaylistWriteText.reason)
    }

    /// 쓰기 전 확인 창(#210): 막힘·제외·손실이 있거나 백업을 만들 수 없을 때만 뜬다(`WriteConfirmPolicy`).
    /// 제목에 종류별 곡 수를 두고, 목록에는 묻는 이유가 되는 항목(합치기·쓰지 않는 것·백업)만 보인다. 곡마다의 결과는 쓰기 결과 창에 남는다.
    static func confirmation(_ report: RekordboxWriter.Report, exclusions: [String] = [], canBackUp: Bool = true) -> ReflectionPrompt {
        var kinds: [String] = []
        if !report.written.isEmpty { kinds.append(WriteResult.Part.cue.summary(report.written.count)) }
        if !report.gridWritten.isEmpty { kinds.append(WriteResult.Part.grid.summary(report.gridWritten.count)) }
        if !report.analysisWritten.isEmpty { kinds.append(WriteResult.Part.analysis.summary(report.analysisWritten.count)) }
        if !report.gainWritten.isEmpty { kinds.append(WriteResult.Part.gain.summary(report.gainWritten.count)) }
        if !report.tagWritten.isEmpty { kinds.append(WriteResult.Part.tag.summary(report.tagWritten.count)) }
        if !report.artworkWritten.isEmpty { kinds.append(WriteResult.Part.artwork.summary(report.artworkWritten.count)) }
        if !report.mergeWritten.isEmpty { kinds.append(String(ui: "합치기 \(report.mergeWritten.count)묶음")) }
        if !report.playlistWritten.isEmpty { kinds.append(PlaylistWriteText.summary(report.playlistWritten.count)) }
        var sections: [[String]] = []
        if !report.mergeWritten.isEmpty {
            sections.append(report.mergeWritten.map { String(ui: "• \($0.title) 유지 · 중복 \($0.removed)곡을 컬렉션에서 뺍니다") }
                + report.mergeWritten.compactMap(\.reason) + ["", DuplicateMerge.lossNotice])
        }
        let reasons = reasons(report) + exclusions
        if !reasons.isEmpty { sections.append([String(ui: "쓰지 않는 것 \(reasons.count):")] + reasons) }
        if !canBackUp { sections.append([noBackupText]) }
        return ReflectionPrompt(title: String(ui: "\(kinds.joined(separator: " · "))을 rekordbox에 쓸까요?"),
                                text: backupThenWriteText,
                                confirm: String(ui: "rekordbox에 쓰기"), destructive: !report.mergeWritten.isEmpty,
                                details: Array(sections.joined(separator: [""])))
    }

    /// 쓰기 전 백업 폴더에 쓸 수 없을 때의 줄
    static var noBackupText: String {
        String(ui: "쓰기 전 백업을 만들 폴더에 쓸 수 없어 쓰기가 막힐 수 있으니 DJCrate 데이터 폴더의 쓰기 권한을 확인하세요.")
    }

    static func addReasons(_ preview: LibraryStore.TrackAddPreview) -> [String] {
        preview.report.added.filter { !$0.written }.map { "• \($0.title): \($0.reason ?? "")" } + preview.unreadable.map { "• \($0)" }
    }

    /// 넣는 곡 가운데 빠지는 것이 있는 곡의 줄(분석 없이 넣음, 큐·키가 안 들어감)과 그 안내(#210).
    /// 비어 있으면 넣기는 묻지 않는다. 아트워크는 분석까지 붙이는 곡에만 넣는다(rekordbox도 분석할 때 뽑는다, 2026-09-26 실험).
    static func addShortfalls(_ preview: LibraryStore.TrackAddPreview, writesArtwork: Bool) -> [String] {
        let written = preview.report.added.filter(\.written)
        let artwork = Set(preview.plans.filter { $0.artwork != nil }.map(\.path))
        let bare = written.filter { preview.withoutAnalysis[$0.path] != nil }
        let analysedArtwork = written.filter { preview.withoutAnalysis[$0.path] == nil && artwork.contains($0.path) }
        var body = written.filter { preview.withoutAnalysis[$0.path] != nil || $0.cueReason != nil || $0.keyReason != nil }.map { outcome -> String in
            var parts = [preview.withoutAnalysis[outcome.path].map { String(ui: "분석 없이(\($0))") }
                ?? String(ui: "그리드·파형·오토게인까지")]
            if writesArtwork, analysedArtwork.contains(outcome) { parts.append(String(ui: "앨범아트")) }
            if let count = outcome.cuesWritten, count > 0 { parts.append(String(ui: "큐 \(count)개")) }
            if let reason = outcome.cueReason { parts.append(String(ui: "⚠︎ 큐는 안 들어감(\(reason))")) }
            if let key = outcome.keyWritten { parts.append(String(ui: "키 \(key)")) }
            if let reason = outcome.keyReason { parts.append(String(ui: "⚠︎ 키는 안 들어감(\(reason))")) }
            return "• \(outcome.title) — " + parts.joined(separator: " · ")
        }
        if !bare.isEmpty {
            body += ["", bare.contains { artwork.contains($0.path) }
                ? String(ui: "분석 없이 넣는 곡은 rekordbox에서 분석해야 파형·그리드·앨범아트가 생깁니다.")
                : String(ui: "분석 없이 넣는 곡은 rekordbox에서 분석해야 파형·그리드가 생깁니다.")]
        }
        if !writesArtwork, !analysedArtwork.isEmpty {
            body += ["", Self.artworkClosedNote]
        }
        // 키를 쓰면 곡 정보 변경 횟수가 생겨, 분석 없이 넣은 곡에는 DJCrate가 나중에 분석을 붙이지 않는다(카운터 있는 분석 전 곡은 미확인).
        if bare.contains(where: { $0.keyWritten != nil }) {
            body += ["", Self.bareKeyNote]
        }
        return body.first == "" ? Array(body.dropFirst()) : body
    }

    /// 분석 없이 넣으며 키도 쓰는 곡의 안내
    static var bareKeyNote: String {
        String(ui: "분석 없이 넣으며 키를 함께 쓴 곡은 DJCrate가 나중에 분석을 붙이지 않으니 rekordbox에서 분석하세요.")
    }

    /// 아트워크 쓰기가 닫혀 있을 때(`RekordboxTrackWriter.writesArtwork`) 음원에 아트워크가 든 곡을 넣으면 보이는 안내
    static var artworkClosedNote: String {
        String(ui: "음원의 앨범아트는 아직 넣지 않으니, 필요하면 rekordbox 곡 정보 창에서 이미지를 끌어다 붙이세요.")
    }

    /// 넣기 전 확인 창(#210): 빠지는 것(`addShortfalls`)·넣지 않는 곡이 있거나 백업을 만들 수 없을 때만 뜨고, 그 줄만 보인다.
    static func addConfirmation(_ preview: LibraryStore.TrackAddPreview,
                                writesArtwork: Bool = RekordboxTrackWriter.writesArtwork, canBackUp: Bool = true) -> ReflectionPrompt {
        let written = preview.report.added.filter(\.written)
        var sections: [[String]] = []
        let shortfalls = addShortfalls(preview, writesArtwork: writesArtwork)
        if !shortfalls.isEmpty { sections.append(shortfalls) }
        let reasons = addReasons(preview)
        if !reasons.isEmpty { sections.append([String(ui: "넣지 않는 곡 \(reasons.count):")] + reasons) }
        if !canBackUp { sections.append([noBackupText]) }
        return ReflectionPrompt(title: String(ui: "\(written.count)곡을 rekordbox에 넣을까요?"),
                                text: backupThenWriteText,
                                confirm: String(ui: "rekordbox에 넣기"), details: Array(sections.joined(separator: [""])))
    }

    /// 빼기 전 확인 창(경고): 뺄 곡, 빼지 않는 곡과 이유, 함께 사라지는 것
    static func deleteConfirmation(_ preview: LibraryStore.TrackDeletePreview) -> ReflectionPrompt {
        let written = preview.report.deleted.filter(\.written), blocked = preview.report.deleted.filter { !$0.written }
        var body = written.map { "• \($0.title)" }
        if !blocked.isEmpty { body += ["", String(ui: "빼지 않는 곡 \(blocked.count):")] + blocked.map { "• \($0.title): \($0.reason ?? "")" } }
        return ReflectionPrompt(title: String(ui: "\(written.count)곡을 rekordbox에서 뺄까요?"),
                                text: String(ui: "음원 파일은 지우지 않습니다. rekordbox의 큐·재생 목록 항목·재생 기록·분석 파일·앨범아트가 함께 사라집니다.")
                                    + "\n" + backupThenWriteText,
                                confirm: String(ui: "rekordbox에서 빼기"), critical: true, details: body)
    }

    /// 되돌리기 확인 창. 백업 뒤 변경이 있거나 확인하지 못했으면 파괴적 경고로 띄운다.
    /// - Parameter conflicts: 쓴 뒤 새로 만든 초안이 있는 곡. 있으면 지금 초안을 남길지(확인), 백업 초안으로 바꿀지(둘째 단추) 고른다.
    static func restoreConfirmation(_ backup: RekordboxWriter.Backup, changedSince changed: Bool?, conflicts: [String] = []) -> ReflectionPrompt {
        var lines = [String(ui: "백업: \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))")]
        var details = backup.titles.isEmpty ? [] : [String(ui: "그때 쓴 곡:")] + backup.titles.map { "• \($0)" }
        if !conflicts.isEmpty { details += [String(ui: "쓴 뒤 새로 만든 초안:")] + conflicts }
        if let tracks = backup.trackReport {
            let added = tracks.added.filter(\.written).count, deleted = tracks.deleted.filter(\.written).count
            // 문장마다 번역하고, 문장 뒤 빈칸은 원래 모양 그대로 둔다.
            var sentences = [String(ui: "라이브러리 전체를 이 백업으로 복원합니다.")]
            if added > 0 { sentences.append(String(ui: "넣었던 \(added)곡은 컬렉션에서 빠지고 DJCrate 추가 목록으로 돌아옵니다(분석·앨범아트 파일도 삭제).")) }
            if deleted > 0 { sentences.append(String(ui: "뺐던 \(deleted)곡은 큐·재생 목록·분석 파일·앨범아트와 함께 복원됩니다.")) }
            lines.append(sentences.map { $0 + " " }.joined())
        } else {
            lines.append(String(ui: "라이브러리 전체를 이 백업으로 복원합니다. 그때 쓴 초안(큐·그리드·게인·태그·앨범아트)도 DJCrate에 복원됩니다."))
        }
        switch changed {
        case true?: lines.append(String(ui: "⚠︎ 이 백업 뒤에 rekordbox에서도 라이브러리가 바뀌었습니다(큐·재생 목록·곡 추가 등). 복원하면 그 변경도 함께 사라집니다."))
        case nil: lines.append(String(ui: "백업 뒤 rekordbox에서 바뀐 것이 있는지 확인하지 못했습니다. 그 뒤 rekordbox에서 한 변경은 함께 사라집니다."))
        case false?: break
        }
        if !conflicts.isEmpty {
            lines.append(String(ui: "\(conflicts.count)곡은 쓴 뒤 새로 만든 초안이 백업의 초안과 다릅니다. 지금 초안을 남기면 그 곡의 백업 초안은 되살리지 않고, 백업 초안으로 바꾸면 지금 초안이 사라집니다."))
        }
        lines.append(String(ui: "백업한 뒤 복원하고 다시 확인합니다. 끝날 때까지 rekordbox를 켜지 마세요."))
        return ReflectionPrompt(title: String(ui: "rekordbox를 쓰기 전으로 복원할까요?"),
                                text: lines.joined(separator: "\n\n"),
                                confirm: conflicts.isEmpty ? String(ui: "쓰기 전으로 복원") : String(ui: "복원하고 지금 초안 남기기"),
                                critical: changed != false, destructive: changed != false, details: details,
                                alternate: conflicts.isEmpty ? nil : String(ui: "복원하고 백업 초안으로 바꾸기"))
    }
}

extension LibraryStore: ReflectionHost {
    /// 백업 폴더(없으면 가장 가까운 있는 상위 폴더)에 쓸 수 있는지
    var canBackUpBeforeWrite: Bool {
        let fm = FileManager.default
        var folder = backupDirectory
        while !fm.fileExists(atPath: folder.path), folder.pathComponents.count > 1 { folder = folder.deletingLastPathComponent() }
        return fm.isWritableFile(atPath: folder.path)
    }

    func setWriteLock(_ locked: Bool) {
        isWritingRekordbox = locked
        onWriteLock?(locked)
    }
}
