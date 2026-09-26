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
}

/// 창을 띄운다. 시험에서는 정해 둔 답을 돌려준다.
@MainActor
protocol ReflectionPrompter {
    /// 확인을 누르면 true
    func show(_ prompt: ReflectionPrompt) -> Bool
}

struct AlertPrompter: ReflectionPrompter {
    func show(_ prompt: ReflectionPrompt) -> Bool {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.text
        if prompt.critical { alert.alertStyle = .critical }
        guard let confirm = prompt.confirm else {
            alert.runModal()
            return false
        }
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// 반영 흐름이 쓰는 라이브러리 쪽 기능(`LibraryStore`). 시험에서는 가짜로 바꾼다.
@MainActor
protocol ReflectionHost: AnyObject {
    var isWritingRekordbox: Bool { get }
    var writeStage: String? { get set }
    var toast: AppToast? { get set }
    func setWriteLock(_ locked: Bool)
    func writeTargets(_ rows: [TrackRow]) -> [TrackRow]
    func previewWrite(rows: [TrackRow]) async throws -> LibraryStore.WritePreview
    func writeToRekordbox(_ drafts: [CueDraft], grids: [GridDraft], gains: [String: Double]) async throws -> RekordboxWriter.Report
    func libraryChangedSince(_ backup: RekordboxWriter.Backup) async -> Bool?
    func restoreRekordbox(_ backup: RekordboxWriter.Backup) async throws
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

    func write(rows: [TrackRow]) async {
        guard !host.isWritingRekordbox else { return }
        guard !isRekordboxRunning() else {
            inform("rekordbox가 켜져 있어 쓰지 않았습니다",
                   "rekordbox를 완전히 종료한 뒤 다시 누르세요. DJCrate는 rekordbox가 켜져 있는 동안에는 rekordbox 라이브러리에 절대 쓰지 않습니다.")
            return
        }
        let targets = host.writeTargets(rows)
        guard !targets.isEmpty else {
            inform("반영할 초안이 없습니다", "고른 곡에 rekordbox와 다른 큐·그리드 초안이 없습니다.")
            return
        }
        host.setWriteLock(true)
        defer { host.setWriteLock(false) }
        do {
            host.writeStage = "바꿀 내용을 확인하는 중…"
            let preview = try await host.previewWrite(rows: targets)
            host.writeStage = nil
            let report = preview.report
            guard !report.written.isEmpty || !report.gridWritten.isEmpty || !report.gainWritten.isEmpty else {
                inform("rekordbox에 쓸 수 있는 초안이 없습니다", Self.reasons(report).prefix(8).joined(separator: "\n"))
                return
            }
            guard prompter.show(Self.confirmation(report)) else { return }
            let cues = Set(report.written.map(\.trackUUID)), grids = Set(report.gridWritten.map(\.trackUUID))
            let gains = Set(report.gainWritten.map(\.trackUUID))
            _ = try await host.writeToRekordbox(preview.drafts.filter { cues.contains($0.trackUUID) },
                                                grids: preview.grids.filter { grids.contains($0.trackUUID) },
                                                gains: preview.gains.filter { gains.contains($0.key) })
        } catch {
            host.writeStage = nil
            host.toast = AppToast(kind: .failure, title: "rekordbox에 쓰지 않았습니다", detail: String(describing: error))
        }
    }

    /// 추가한 곡을 rekordbox 컬렉션에 넣는다(그리드·파형·오토게인까지). 흐름은 쓰기와 같다.
    func addTracks(rows: [TrackRow]) async {
        guard !host.isWritingRekordbox else { return }
        guard !isRekordboxRunning() else {
            inform("rekordbox가 켜져 있어 넣지 않았습니다",
                   "rekordbox를 완전히 종료한 뒤 다시 누르세요. DJCrate는 rekordbox가 켜져 있는 동안에는 rekordbox 라이브러리에 절대 쓰지 않습니다.")
            return
        }
        let targets = host.trackAddTargets(rows)
        guard !targets.isEmpty else {
            inform("rekordbox에 넣을 곡이 없습니다", "DJCrate에 추가한 곡만 rekordbox에 넣을 수 있습니다.")
            return
        }
        host.setWriteLock(true)
        defer { host.setWriteLock(false) }
        do {
            host.writeStage = "넣을 곡을 확인하는 중…"
            let preview = try await host.previewTrackAdd(rows: targets)
            host.writeStage = nil
            guard preview.report.added.contains(where: \.written) else {
                inform("rekordbox에 넣을 수 있는 곡이 없습니다", Self.addReasons(preview).prefix(8).joined(separator: "\n"))
                return
            }
            guard prompter.show(Self.addConfirmation(preview)) else { return }
            _ = try await host.addTracksToRekordbox(preview)
        } catch {
            host.writeStage = nil
            host.toast = AppToast(kind: .failure, title: "rekordbox에 넣지 않았습니다", detail: String(describing: error))
        }
    }

    /// rekordbox 컬렉션에서 곡을 뺀다(음원 파일은 그대로). 흐름은 쓰기와 같고 확인 창은 경고 모양이다.
    func deleteTracks(rows: [TrackRow]) async {
        guard !host.isWritingRekordbox else { return }
        guard !isRekordboxRunning() else {
            inform("rekordbox가 켜져 있어 빼지 않았습니다",
                   "rekordbox를 완전히 종료한 뒤 다시 누르세요. DJCrate는 rekordbox가 켜져 있는 동안에는 rekordbox 라이브러리에 절대 쓰지 않습니다.")
            return
        }
        let targets = host.trackDeleteTargets(rows)
        guard !targets.isEmpty else {
            inform("rekordbox에서 뺄 곡이 없습니다", "rekordbox 컬렉션의 로컬 곡만 뺄 수 있습니다(스트리밍·추가한 곡 제외).")
            return
        }
        host.setWriteLock(true)
        defer { host.setWriteLock(false) }
        do {
            host.writeStage = "뺄 곡을 확인하는 중…"
            let preview = try await host.previewTrackDelete(rows: targets)
            host.writeStage = nil
            guard preview.report.deleted.contains(where: \.written) else {
                inform("rekordbox에서 뺄 수 있는 곡이 없습니다",
                       preview.report.deleted.map { "• \($0.title): \($0.reason ?? "")" }.prefix(8).joined(separator: "\n"))
                return
            }
            guard prompter.show(Self.deleteConfirmation(preview)) else { return }
            _ = try await host.deleteTracksFromRekordbox(preview)
        } catch {
            host.writeStage = nil
            host.toast = AppToast(kind: .failure, title: "rekordbox에서 빼지 않았습니다", detail: String(describing: error))
        }
    }

    func restore(_ backup: RekordboxWriter.Backup) async {
        guard !host.isWritingRekordbox else { return }
        guard !isRekordboxRunning() else {
            inform("rekordbox가 켜져 있어 되돌리지 않았습니다", "rekordbox를 완전히 종료한 뒤 다시 누르세요.")
            return
        }
        host.setWriteLock(true)
        defer { host.setWriteLock(false) }
        host.writeStage = "백업 뒤 바뀐 것을 확인하는 중…"
        let changed = await host.libraryChangedSince(backup)
        host.writeStage = nil
        guard prompter.show(Self.restoreConfirmation(backup, changedSince: changed)) else { return }
        do {
            try await host.restoreRekordbox(backup)
        } catch {
            host.writeStage = nil
            host.toast = AppToast(kind: .failure, title: "되돌리지 못했습니다", detail: String(describing: error))
        }
    }

    private func inform(_ title: String, _ text: String) {
        _ = prompter.show(ReflectionPrompt(title: title, text: text))
    }

    // MARK: - 창 문구

    static func reasons(_ report: RekordboxWriter.Report) -> [String] {
        (report.blocked + report.gridBlocked + report.gainBlocked).map { "• \($0.title): \($0.reason ?? "")" }
    }

    /// 쓰기 전 확인 창: 종류별 곡 수, 곡마다 바뀌는 것, 쓰지 않는 것과 이유
    static func confirmation(_ report: RekordboxWriter.Report) -> ReflectionPrompt {
        let cues = report.written, grids = report.gridWritten, gains = report.gainWritten
        var kinds: [String] = []
        if !cues.isEmpty { kinds.append("큐 \(cues.count)곡") }
        if !grids.isEmpty { kinds.append("그리드 \(grids.count)곡") }
        if !gains.isEmpty { kinds.append("게인 \(gains.count)곡") }
        let gridBlocked = Set(report.gridBlocked.map(\.trackUUID)), gridWritten = Set(grids.map(\.trackUUID))
        var body = cues.prefix(12).map { outcome -> String in
            var line = "• \(outcome.title) — 큐 추가 \(outcome.added) · 삭제 \(outcome.removed)"
            if gridWritten.contains(outcome.trackUUID) { line += " · 그리드" }
            if gridBlocked.contains(outcome.trackUUID) { line += " · ⚠︎ 그리드는 안 들어감" }
            return line
        }
        let cueUUIDs = Set(cues.map(\.trackUUID))
        for grid in grids where !cueUUIDs.contains(grid.trackUUID) { body.append("• \(grid.title) — 그리드(박 \(grid.added)개)") }
        for gain in gains { body.append(String(format: "• %@ — 오토게인 %+.1f dB", gain.title, Double(gain.added) / 100)) }
        if cues.count > 12 { body.append("… 외 \(cues.count - 12)곡") }
        let reasons = reasons(report)
        if !reasons.isEmpty { body += ["", "쓰지 않는 것 \(reasons.count):"] + reasons.prefix(8) }
        body += ["", "쓰기 전에 rekordbox 라이브러리(master.db)와 바꿀 분석 파일을 백업하고, 쓴 뒤 다시 읽어 확인합니다. 끝날 때까지 rekordbox를 켜지 마세요."]
        return ReflectionPrompt(title: "rekordbox에 " + kinds.joined(separator: " · ") + "을 씁니다",
                                text: body.joined(separator: "\n"), confirm: "rekordbox에 쓰기")
    }

    static func addReasons(_ preview: LibraryStore.TrackAddPreview) -> [String] {
        preview.report.added.filter { !$0.written }.map { "• \($0.title): \($0.reason ?? "")" } + preview.unreadable.map { "• \($0)" }
    }

    /// 넣기 전 확인 창: 곡마다 분석까지 붙는지, 넣지 않는 곡과 이유
    static func addConfirmation(_ preview: LibraryStore.TrackAddPreview) -> ReflectionPrompt {
        let written = preview.report.added.filter(\.written)
        var body = written.prefix(12).map { outcome -> String in
            if let reason = preview.withoutAnalysis[outcome.path] { return "• \(outcome.title) — 분석 없이(\(reason))" }
            return "• \(outcome.title) — 그리드·파형·오토게인까지"
        }
        if written.count > 12 { body.append("… 외 \(written.count - 12)곡") }
        let reasons = addReasons(preview)
        if !reasons.isEmpty { body += ["", "넣지 않는 곡 \(reasons.count):"] + reasons.prefix(8) }
        let bare = written.filter { preview.withoutAnalysis[$0.path] != nil }.count
        if bare > 0 { body += ["", "분석 없이 넣는 곡은 rekordbox에서 분석해야 파형·그리드가 생깁니다."] }
        body += ["", "쓰기 전에 rekordbox 라이브러리(master.db)를 백업하고, 곡 행과 분석 파일을 쓴 뒤 다시 읽어 확인합니다. "
                 + "프레이즈·보컬 분석은 rekordbox에서 Phrase만 분석하면 더해집니다. 끝날 때까지 rekordbox를 켜지 마세요."]
        return ReflectionPrompt(title: "rekordbox 컬렉션에 \(written.count)곡을 넣습니다", text: body.joined(separator: "\n"), confirm: "rekordbox에 넣기")
    }

    /// 빼기 전 확인 창(경고): 뺄 곡, 빼지 않는 곡과 이유, 함께 사라지는 것
    static func deleteConfirmation(_ preview: LibraryStore.TrackDeletePreview) -> ReflectionPrompt {
        let written = preview.report.deleted.filter(\.written), blocked = preview.report.deleted.filter { !$0.written }
        var body = written.prefix(12).map { "• \($0.title)" }
        if written.count > 12 { body.append("… 외 \(written.count - 12)곡") }
        if !blocked.isEmpty { body += ["", "빼지 않는 곡 \(blocked.count):"] + blocked.prefix(8).map { "• \($0.title): \($0.reason ?? "")" } }
        body += ["", "음원 파일은 지우지 않습니다. rekordbox의 큐·재생 목록 항목·재생 기록·분석 파일이 함께 사라집니다.",
                 "쓰기 전에 전체를 백업하므로 \"되돌리기\"로 되살릴 수 있습니다. 끝날 때까지 rekordbox를 켜지 마세요."]
        return ReflectionPrompt(title: "rekordbox 컬렉션에서 \(written.count)곡을 뺍니다", text: body.joined(separator: "\n"),
                                confirm: "rekordbox에서 빼기", critical: true)
    }

    /// 되돌리기 확인 창. 백업 뒤 rekordbox에서 바뀐 게 있으면 경고로 띄운다.
    static func restoreConfirmation(_ backup: RekordboxWriter.Backup, changedSince changed: Bool?) -> ReflectionPrompt {
        var lines: [String] = []
        if !backup.titles.isEmpty {
            lines.append("그때 쓴 곡: " + backup.titles.prefix(8).joined(separator: ", ") + (backup.titles.count > 8 ? " 외 \(backup.titles.count - 8)곡" : ""))
        }
        if let tracks = backup.trackReport {
            let added = tracks.added.filter(\.written).count, deleted = tracks.deleted.filter(\.written).count
            lines.append("rekordbox 라이브러리 파일 전체를 그때 백업으로 바꿉니다. "
                         + (added > 0 ? "그때 넣은 \(added)곡은 컬렉션에서 빠지고(만든 분석 파일도 지움) DJCrate 추가 목록으로 돌아옵니다. " : "")
                         + (deleted > 0 ? "그때 뺀 \(deleted)곡은 큐·재생 목록·분석 파일과 함께 되살아납니다. " : "")
                         + "지금 상태도 따로 백업해 둡니다.")
        } else {
            lines.append("rekordbox 라이브러리 파일 전체를 그때 백업으로 바꿉니다. 그때 쓴 큐 초안은 DJCrate에 다시 살아납니다. 지금 상태도 따로 백업해 둡니다.")
        }
        switch changed {
        case true?: lines.append("⚠︎ 이 백업 뒤에 rekordbox에서도 라이브러리가 바뀌었습니다(큐·재생 목록·곡 추가 등). 되돌리면 그 변경도 함께 사라집니다.")
        case nil: lines.append("백업 뒤 rekordbox에서 바뀐 것이 있는지 확인하지 못했습니다. 그 뒤 rekordbox에서 한 변경은 함께 사라집니다.")
        case false?: break
        }
        return ReflectionPrompt(title: "rekordbox를 \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)) 쓰기 전으로 되돌릴까요?",
                                text: lines.joined(separator: "\n\n"), confirm: "되돌리기", critical: changed == true)
    }
}

extension LibraryStore: ReflectionHost {
    func setWriteLock(_ locked: Bool) {
        isWritingRekordbox = locked
        onWriteLock?(locked)
    }
}
