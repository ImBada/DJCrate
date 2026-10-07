import AppKit
import DJCDomain
import DJCStorage
import Observation
import RekordboxKit
import SwiftUI

/// 시점 스냅샷 창(#224·#225): 지금 상태를 이름 붙여 남기고, 시점 스냅샷과 쓰기 전 백업을 한 목록에서 보고, 스냅샷을 고정한다.
/// 고른 스냅샷을 지금과 비교하고, 확인 창 하나를 거쳐 그 시점으로 복원한다(되돌릴 수 없는 외부 쓰기라 묻는다).
/// 쓰기 전 백업은 따로 정리되고 '쓰기 전으로 복원…'으로 되돌리므로 여기서는 보기만 한다(#223 결정).
@MainActor
final class PointSnapshotWindow: NSObject, NSWindowDelegate {
    static let shared = PointSnapshotWindow()
    private var window: NSWindow?
    private var model: PointSnapshotModel?

    func open(store: LibraryStore) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            Task { await model?.refresh() }
            return
        }
        let model = PointSnapshotModel(store: store)
        let window = NSWindow(contentViewController: NSHostingController(rootView: PointSnapshotView(model: model)))
        window.title = String(ui: "시점 스냅샷")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 760, height: 520))
        window.contentMinSize = NSSize(width: 620, height: 400)
        window.center()
        self.window = window
        self.model = model
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { model?.isWorking != true }
}

/// 시점 스냅샷 목록 한 줄. 쓰기 전 백업도 같은 줄 모양으로 함께 보인다.
struct PointSnapshotRow: Identifiable, Hashable {
    enum Source: Hashable {
        case point(RekordboxPointSnapshot.Entry)
        /// 쓰기 전 백업(`isWrite`가 거짓이면 복원 직전 백업)
        case backup(URL, isWrite: Bool)
    }

    var source: Source
    var date: Date
    var name: String
    var kind: String
    var bytes: Int64?
    var id: String {
        switch source {
        case let .point(entry): "point:" + entry.id
        case let .backup(url, _): "backup:" + url.lastPathComponent
        }
    }

    var entry: RekordboxPointSnapshot.Entry? {
        if case let .point(entry) = source { return entry }
        return nil
    }

    var pinned: Bool { entry?.metadata.pinned == true }
}

@MainActor @Observable
final class PointSnapshotModel {
    private(set) var rows: [PointSnapshotRow] = []
    var selection: PointSnapshotRow.ID?
    var newName = ""
    private(set) var isWorking = false
    /// 마지막 동작 결과 한 줄(실패면 `isError`)
    private(set) var message: String?
    private(set) var isError = false
    /// 같은 디스크가 아니라 클론이 안 될 때의 안내
    private(set) var cloneNote: String?
    /// 마지막으로 비교한 스냅샷과 결과
    private(set) var comparison: RekordboxPointSnapshotDiff?
    private(set) var comparedID: PointSnapshotRow.ID?

    let database: URL
    let shareRoot: URL?
    let snapshots: URL
    let backups: URL
    @ObservationIgnored private let writeGuard: RekordboxWriteGuard
    @ObservationIgnored private let autoDays: () -> Int
    @ObservationIgnored private let busy: () -> String?
    @ObservationIgnored private let prompter: any ReflectionPrompter
    @ObservationIgnored private let now: () -> Date
    /// 복원(앱은 `LibraryStore.restorePointSnapshot`: 쓰기 잠금·다시 읽기까지)
    @ObservationIgnored private let restoreAction: (RekordboxPointSnapshot.Entry, Set<String>) async throws -> RekordboxWriter.PointRestoreReport

    init(database: URL, shareRoot: URL?, snapshots: URL, backups: URL, guard writeGuard: RekordboxWriteGuard = .system,
         autoDays: @escaping () -> Int = { Int(SettingKeys.pointSnapshotAutoDays.defaultValue) },
         busyReason: @escaping () -> String? = { nil }, prompter: any ReflectionPrompter = AlertPrompter(), now: @escaping () -> Date = { .now },
         restore: ((RekordboxPointSnapshot.Entry, Set<String>) async throws -> RekordboxWriter.PointRestoreReport)? = nil) {
        self.database = database
        self.shareRoot = shareRoot
        self.snapshots = snapshots
        self.backups = backups
        self.writeGuard = writeGuard
        self.autoDays = autoDays
        self.busy = busyReason
        self.prompter = prompter
        self.now = now
        let days = autoDays
        restoreAction = restore ?? { entry, _ in
            let time = now(), count = days()
            return try await Task.detached(priority: .userInitiated) {
                try RekordboxWriter.restore(pointSnapshot: entry.url, to: database, shareRoot: shareRoot, snapshots: snapshots, backups: backups,
                                            autoDays: count, now: time, guard: writeGuard)
            }.value
        }
    }

    /// 앱 창이 쓰는 모델: 쓰기·복원 대상은 `LibraryStore.rekordboxDatabase` 한 곳에서 정한다.
    convenience init(store: LibraryStore) {
        let settings = store.settings
        self.init(database: store.rekordboxDatabase, shareRoot: store.rekordboxShareRoot, snapshots: DJCPaths.pointSnapshots,
                  backups: store.backupDirectory, autoDays: { Int(settings.value(SettingKeys.pointSnapshotAutoDays)) },
                  busyReason: { [weak store] in
                      store?.isWritingRekordbox == true ? String(ui: "rekordbox에 쓰는 중입니다. 쓰기가 끝난 뒤 다시 누르세요") : nil
                  },
                  restore: { [weak store] entry, changed in
                      guard let store else { throw CancellationError() }
                      return try await store.restorePointSnapshot(entry, snapshots: DJCPaths.pointSnapshots, changedTracks: changed)
                  })
    }

    var selectedRow: PointSnapshotRow? { rows.first { $0.id == selection } }

    /// 만들기 단추를 막는 이유(도움말)
    var blockReason: String? { busy() }

    func refresh() async {
        let snapshots = snapshots, backups = backups, source = database.deletingLastPathComponent()
        let result = await Task.detached(priority: .userInitiated) {
            (Self.rows(snapshots: snapshots, backups: backups), RekordboxPointSnapshot.canClone(from: source, to: snapshots))
        }.value
        rows = result.0
        if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil }
        cloneNote = result.1 ? nil : String(ui: "DJCrate 데이터 폴더가 rekordbox와 다른 디스크라 스냅샷마다 라이브러리 전체를 복사합니다.")
    }

    /// 시점 스냅샷과 쓰기 전 백업을 최근 것부터 한 목록으로. 크기는 논리 크기다(클론이면 실제 사용은 더 작다).
    nonisolated static func rows(snapshots: URL, backups: URL) -> [PointSnapshotRow] {
        let points = RekordboxPointSnapshot.list(in: snapshots).map { entry in
            PointSnapshotRow(source: .point(entry), date: entry.metadata.createdAt, name: rowName(entry.metadata), kind: entry.metadata.kind.title,
                             bytes: RekordboxPointSnapshot.size(of: entry.url))
        }
        let writes = RekordboxWriter.backups(in: backups).map { backup in
            PointSnapshotRow(source: .backup(backup.url, isWrite: backup.isWrite), date: backup.createdAt,
                             name: backupTitles(backup).prefix(3).joined(separator: ", "),
                             kind: backup.isWrite ? String(ui: "쓰기 전 백업") : String(ui: "복원 직전 백업"),
                             bytes: RekordboxPointSnapshot.size(of: backup.url))
        }
        return (points + writes).sorted { $0.date > $1.date }
    }

    /// 복원 직전 스냅샷은 이름 대신 무엇으로 되돌리기 전인지 보인다
    nonisolated static func rowName(_ metadata: RekordboxPointSnapshot.Metadata) -> String {
        guard metadata.name.isEmpty, let target = metadata.restoredFrom else { return metadata.name }
        return String(ui: "‘\(target)’ 복원 전")
    }

    /// 쓰기 전 백업 줄의 이름: 그때 쓴 곡(그리드·게인만 쓴 곡도, 곡마다 한 번)
    nonisolated static func backupTitles(_ backup: RekordboxWriter.Backup) -> [String] {
        let extra = backup.report.map { ($0.gridWritten + $0.gainWritten).map(\.title) } ?? []
        var seen = Set<String>()
        return (backup.titles + extra).filter { seen.insert($0).inserted }
    }

    func create() async {
        guard !isWorking else { return }
        if let reason = blockReason { show(reason, error: true); return }
        isWorking = true
        defer { isWorking = false }
        let name = newName, database = database, share = shareRoot, snapshots = snapshots, days = autoDays(), now = now(), writeGuard = writeGuard
        do {
            let entry = try await Task.detached(priority: .userInitiated) {
                try RekordboxPointSnapshot.create(name: name, database: database, shareRoot: share, in: snapshots, autoDays: days, now: now,
                                                  guard: writeGuard)
            }.value
            newName = ""
            await refresh()
            selection = "point:" + entry.id
            show(String(ui: "시점 스냅샷을 남겼습니다."), error: false)
        } catch {
            AppErrorMessage.log(error)
            show(AppErrorMessage.message(for: error), error: true)
        }
    }

    func setPinned(_ pinned: Bool, _ row: PointSnapshotRow) async {
        guard let entry = row.entry, !isWorking else { return }
        do {
            try RekordboxPointSnapshot.setPinned(pinned, entry.url, in: snapshots)
            await refresh()
            show(pinned ? String(ui: "고정했습니다. 자동 정리에서 지우지 않습니다.") : String(ui: "고정을 풀었습니다."), error: false)
        } catch {
            show(AppErrorMessage.message(for: error), error: true)
        }
    }

    /// 지운 스냅샷은 되살릴 수 없어 한 번 묻는다.
    func delete(_ row: PointSnapshotRow) async {
        guard let entry = row.entry, !isWorking else { return }
        guard !entry.metadata.pinned else { show(String(ui: "고정한 시점 스냅샷은 지우지 않습니다. 고정을 푼 뒤 지우세요"), error: true); return }
        let title = entry.metadata.name.isEmpty ? row.date.formatted(date: .abbreviated, time: .shortened) : entry.metadata.name
        guard prompter.show(ReflectionPrompt(title: String(ui: "시점 스냅샷 ‘\(title)’을 지울까요?"),
                                             text: String(ui: "지운 스냅샷은 되살릴 수 없습니다. rekordbox 라이브러리는 그대로입니다."),
                                             confirm: String(ui: "지우기"), destructive: true)) else { return }
        isWorking = true
        defer { isWorking = false }
        let url = entry.url, snapshots = snapshots
        do {
            try await Task.detached(priority: .userInitiated) { try RekordboxPointSnapshot.delete(url, in: snapshots) }.value
            await refresh()
            show(String(ui: "시점 스냅샷을 지웠습니다."), error: false)
        } catch {
            show(AppErrorMessage.message(for: error), error: true)
        }
    }

    /// 고른 스냅샷과 지금 라이브러리를 견준다(읽기만).
    @discardableResult
    func compare(_ row: PointSnapshotRow) async -> RekordboxPointSnapshotDiff? {
        guard let entry = row.entry, !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        let database = database, share = shareRoot, writeGuard = writeGuard
        do {
            let diff = try await Task.detached(priority: .userInitiated) {
                try RekordboxPointSnapshotDiff.compare(entry, database: database, shareRoot: share, guard: writeGuard)
            }.value
            comparison = diff
            comparedID = row.id
            message = nil
            return diff
        } catch {
            AppErrorMessage.log(error)
            show(AppErrorMessage.message(for: error), error: true)
            return nil
        }
    }

    /// 비교한 뒤 확인 창 하나로 묻고 그 시점으로 되돌린다. 복원 직전 상태는 시점 스냅샷으로 남는다.
    func restore(_ row: PointSnapshotRow) async {
        guard let entry = row.entry, !isWorking else { return }
        if let reason = blockReason { show(reason, error: true); return }
        if writeGuard.isLive(database), writeGuard.isRekordboxRunning() {
            show(String(ui: "rekordbox가 켜져 있어 복원하지 않았습니다. rekordbox를 완전히 종료한 뒤 다시 누르세요"), error: true)
            return
        }
        guard let diff = await compare(row) else { return }
        guard prompter.show(Self.restoreConfirmation(entry, diff: diff)) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let report = try await restoreAction(entry, diff.changedTrackUUIDs)
            comparison = nil
            comparedID = nil
            await refresh()
            selection = row.id
            show(String(ui: "‘\(entry.displayName)’ 시점으로 복원했습니다. 복원 전 상태는 ‘복원 직전’ 스냅샷(\(report.beforeRestore.metadata.createdAt.formatted(date: .omitted, time: .shortened)))으로 남겼습니다."),
                 error: false)
        } catch {
            AppErrorMessage.log(error)
            let text = AppErrorMessage.message(for: error)
            show(text, error: true)
            if case DJCError.pointRestoreFailed = error {
                _ = prompter.show(ReflectionPrompt(title: String(ui: "복원하지 못했습니다"), text: text, critical: true))
            }
            await refresh()
        }
    }

    /// 복원 확인 창(하나). 무엇이 바뀌는지는 펼쳐 보기에, 클라우드 동기화 흔적은 한 줄로(#229 확인 전, 막지 않는다).
    static func restoreConfirmation(_ entry: RekordboxPointSnapshot.Entry, diff: RekordboxPointSnapshotDiff) -> ReflectionPrompt {
        let when = entry.metadata.createdAt.formatted(date: .abbreviated, time: .shortened)
        var lines = [String(ui: "rekordbox 라이브러리 전체(DB·재생 목록·분석 파일·앨범아트)를 \(when) 시점으로 되돌립니다. 그 뒤 rekordbox와 DJCrate에서 바꾼 것은 사라집니다."),
                     String(ui: "지금 상태는 ‘복원 직전’ 스냅샷으로 남겨 다시 되돌릴 수 있습니다. DJCrate 초안은 그대로 둡니다.")]
        if diff.isEmpty { lines.append(String(ui: "지금 라이브러리와 다른 곳이 없습니다.")) }
        if diff.cloudSyncedSince(entry) { lines.append("⚠︎ " + RekordboxPointSnapshotDiff.cloudSyncNote) }
        lines.append(String(ui: "끝날 때까지 rekordbox를 켜지 마세요."))
        var details = diff.summary
        for group in diff.details(limit: 20) { details += ["", group.title + ":"] + group.items.map { "• " + $0 } }
        return ReflectionPrompt(title: String(ui: "rekordbox를 ‘\(entry.displayName)’ 시점으로 복원할까요?"), text: lines.joined(separator: "\n\n"),
                                confirm: String(ui: "이 시점으로 복원"), destructive: true, details: details)
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}

struct PointSnapshotView: View {
    @State var model: PointSnapshotModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField(.ui("이름(선택)"), text: $model.newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.create() } }
                    .frame(maxWidth: 320)
                Button(.ui("지금 스냅샷 남기기")) { Task { await model.create() } }
                    .disabled(model.isWorking || model.blockReason != nil)
                    .help(model.blockReason ?? String(ui: "rekordbox 라이브러리(DB·분석 파일·앨범아트)를 지금 시점으로 남깁니다"))
                if model.isWorking { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text(.ui("rekordbox가 꺼져 있을 때만 남깁니다. 수동·고정 스냅샷은 지우지 않고, 쓰기 전 백업은 따로 정리됩니다."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = model.cloneNote {
                Label { Text(verbatim: note) } icon: { Image(systemName: "externaldrive") }
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Table(model.rows, selection: $model.selection) {
                TableColumn(.ui("시각")) { row in
                    Text(verbatim: row.date.formatted(date: .abbreviated, time: .shortened))
                        .monospacedDigit()
                }
                .width(min: 130, ideal: 150)
                TableColumn(.ui("이름")) { row in
                    Text(verbatim: row.name.isEmpty ? "—" : row.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(row.entry == nil ? .secondary : .primary)
                }
                .width(min: 140, ideal: 240)
                TableColumn(.ui("종류")) { row in Text(verbatim: row.kind) }
                    .width(min: 80, ideal: 100)
                TableColumn(.ui("크기")) { row in
                    Text(verbatim: row.bytes.map { $0.formatted(.byteCount(style: .file).locale(UIStrings.locale)) } ?? "")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 80)
                TableColumn(.ui("고정")) { row in
                    if row.entry != nil {
                        Button {
                            Task { await model.setPinned(!row.pinned, row) }
                        } label: {
                            Image(systemName: row.pinned ? "pin.fill" : "pin")
                                .foregroundStyle(row.pinned ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(row.pinned ? String(ui: "고정 풀기") : String(ui: "고정하면 자동 정리에서 지우지 않습니다"))
                        .accessibilityLabel(row.pinned ? Text(.ui("고정 풀기")) : Text(.ui("고정")))
                    }
                }
                .width(44)
            }
            if let diff = model.comparison, model.comparedID == model.selection {
                PointSnapshotComparisonView(diff: diff)
            }
            HStack {
                if let message = model.message {
                    Label { Text(verbatim: message) } icon: {
                        Image(systemName: model.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    }
                    .foregroundStyle(model.isError ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(.ui("현재와 비교")) {
                    if let row = model.selectedRow { Task { await model.compare(row) } }
                }
                .disabled(model.selectedRow?.entry == nil || model.isWorking)
                .help(String(ui: "이 시점으로 복원하면 무엇이 바뀌는지 봅니다"))
                Button(.ui("이 시점으로 복원…")) {
                    if let row = model.selectedRow { Task { await model.restore(row) } }
                }
                .disabled(model.selectedRow?.entry == nil || model.isWorking || model.blockReason != nil)
                .help(model.blockReason ?? String(ui: "rekordbox 라이브러리를 고른 시점으로 되돌립니다(rekordbox를 끈 뒤)"))
                Button(.ui("지우기…")) {
                    if let row = model.selectedRow { Task { await model.delete(row) } }
                }
                .disabled(model.selectedRow?.entry == nil || model.selectedRow?.pinned == true || model.isWorking)
                .help(model.selectedRow?.pinned == true ? String(ui: "고정을 푼 뒤 지우세요") : String(ui: "고른 시점 스냅샷을 지웁니다"))
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 400)
        .task { await model.refresh() }
    }
}

/// 비교 결과: 요약 줄과 펼쳐 보기
struct PointSnapshotComparisonView: View {
    let diff: RekordboxPointSnapshotDiff

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if diff.isEmpty {
                    Text(.ui("지금 라이브러리와 다른 곳이 없습니다."))
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: diff.summary.joined(separator: " · "))
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup(.ui("자세히")) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(diff.details(), id: \.title) { group in
                                    Text(verbatim: group.title).font(.callout.bold())
                                    ForEach(Array(group.items.enumerated()), id: \.offset) { item in
                                        Text(verbatim: "• " + item.element).font(.callout)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(.ui("복원하면 바뀌는 것"))
        }
    }
}
