import AppKit
import DJCDomain
import DJCStorage
import Observation
import SwiftUI

/// 설정 › 저장 공간(#227): 캐시 종류별 용량·비우기와 백업 용량(읽기만).
/// 캐시는 다시 만들어지므로 확인 창 없이 비우고 결과를 한 줄로 알린다. 지우는 규칙은 `DJCCache` 한 곳이다(#215).
/// 용량 계산·비우기는 메인 액터 밖에서, 탭을 열 때와 비운 뒤에만 한다.
@MainActor @Observable
final class StorageSettingsModel {
    private(set) var usage: [DJCCache.Usage]?
    private(set) var backups: [DJCCache.BackupUsage] = []
    /// 지금 비우면 실제로 지울 양(남기는 사본·USB 쓰기 중 건너뜀을 뺀 것). 0이면 그 종류의 단추를 막는다
    private(set) var clearable: [DJCCacheKind: Int64] = [:]
    private(set) var isWorking = false
    /// 마지막 비우기 결과 한 줄
    private(set) var message: String?

    let paths: DJCCachePaths
    /// 자동 시점 스냅샷 보관 일수(#223 결정, 설정에서 일수만). 시험은 설정 없이 기본값만 본다
    var autoSnapshotDays: Int {
        didSet { settings?.set(SettingKeys.pointSnapshotAutoDays, Double(autoSnapshotDays)) }
    }
    @ObservationIgnored private let settings: SettingsStore?
    @ObservationIgnored private let openSnapshot: () -> URL?
    @ObservationIgnored private let busy: () -> String?
    /// 파일을 지우기 전에 앱 메모리의 캐시를 비운다(메모리의 옛 값을 다시 저장하지 않게). 시험은 비워 둔다
    @ObservationIgnored private let clearMemory: ([DJCCacheKind]) async -> Void
    /// 지운 뒤 화면에 보이는 캐시를 다시 채운다(목록 미리 보기 파형)
    @ObservationIgnored private let rebuild: ([DJCCacheKind]) -> Void

    init(paths: DJCCachePaths = .current, settings: SettingsStore? = nil, openSnapshot: @escaping () -> URL? = { nil },
         busyReason: @escaping () -> String? = { nil },
         clearMemory: @escaping ([DJCCacheKind]) async -> Void = { _ in }, rebuild: @escaping ([DJCCacheKind]) -> Void = { _ in }) {
        self.paths = paths
        self.settings = settings
        autoSnapshotDays = Int(settings?.value(SettingKeys.pointSnapshotAutoDays) ?? SettingKeys.pointSnapshotAutoDays.defaultValue)
        self.openSnapshot = openSnapshot
        self.busy = busyReason
        self.clearMemory = clearMemory
        self.rebuild = rebuild
    }

    /// 앱 화면이 쓰는 모델: 앱이 연 스냅샷은 남기고, rekordbox·USB 쓰기 중에는 막는다
    convenience init(store: LibraryStore) {
        self.init(settings: store.settings, openSnapshot: { [weak store] in store?.snapshotURL },
                  busyReason: { [weak store] in
                      guard let store else { return nil }
                      return Self.busyReason(writingRekordbox: store.isWritingRekordbox,
                                             writingUsb: store.usb.map { $0.activeWrite != nil || !$0.busyVolumes.isEmpty } ?? false)
                  },
                  clearMemory: { [weak store] kinds in
                      if kinds.contains(.loudness) { LoudnessCache.shared.clear() }
                      if kinds.contains(.previewWaveforms) {
                          store?.previewWarmTask?.cancel()
                          await PreviewWaveformStore.shared.clear()
                      }
                  },
                  rebuild: { [weak store] kinds in
                      if kinds.contains(.previewWaveforms) { store?.warmPreviewWaveforms() }
                  })
    }

    /// 비우기 단추를 막는 이유(도움말로 보인다)
    var blockReason: String? { busy() }

    nonisolated static func busyReason(writingRekordbox: Bool, writingUsb: Bool) -> String? {
        if writingRekordbox { return String(ui: "rekordbox에 쓰는 중에는 비울 수 없습니다. 쓰기가 끝난 뒤 비우세요") }
        if writingUsb { return String(ui: "USB에 쓰는 중에는 비울 수 없습니다. 쓰기가 끝난 뒤 비우세요") }
        return nil
    }

    func refresh() async {
        let paths = paths, keep = [openSnapshot()].compactMap { $0 }
        let result = await Task.detached(priority: .userInitiated) {
            (DJCCache.usage(paths: paths), DJCCache.backupUsage(root: paths.root),
             DJCCache.clear(DJCCacheKind.allCases, paths: paths, keepingSnapshots: keep, dryRun: true))
        }.value
        usage = result.0
        backups = result.1
        clearable = Dictionary(uniqueKeysWithValues: result.2.map { ($0.kind, $0.freedBytes) })
    }

    func clear(_ kinds: [DJCCacheKind]) async {
        guard !isWorking, blockReason == nil else { return }
        isWorking = true
        defer { isWorking = false }
        let paths = paths, keep = [openSnapshot()].compactMap { $0 }
        await clearMemory(kinds)
        let outcomes = await Task.detached(priority: .userInitiated) {
            DJCCache.clear(kinds, paths: paths, keepingSnapshots: keep)
        }.value
        rebuild(kinds)
        message = Self.summary(outcomes)
        await refresh()
    }

    static func summary(_ outcomes: [DJCCache.Outcome]) -> String {
        let freed = StorageSize.text(outcomes.reduce(0) { $0 + $1.freedBytes })
        var line = outcomes.count == 1
            ? String(ui: "\(outcomes[0].kind.title) \(freed)를 비웠습니다.")
            : String(ui: "캐시 \(freed)를 비웠습니다.")
        if let skipped = outcomes.first(where: { $0.skipped != nil })?.skipped { line += " " + skipped }
        return line
    }
}

enum StorageSize {
    /// 파일 크기 표기. 화면 언어(`UIStrings.locale`)를 따르고 0도 숫자로 쓴다
    static func text(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false).locale(UIStrings.locale))
    }
}

struct StorageSettingsView: View {
    @State var model: StorageSettingsModel

    var body: some View {
        let blocked = model.blockReason
        Form {
            Section {
                ForEach(DJCCacheKind.allCases, id: \.self) { kind in
                    LabeledContent {
                        HStack(spacing: 10) {
                            Text(size(of: kind))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Button(.ui("비우기")) { Task { await model.clear([kind]) } }
                                .disabled(blocked != nil || model.isWorking || (model.clearable[kind] ?? 0) == 0)
                                .help(blocked ?? String(ui: "\(kind.title) 캐시를 비웁니다"))
                        }
                    } label: {
                        Text(kind.title)
                        Text(kind.detail)
                    }
                }
                HStack {
                    if let message = blocked ?? model.message {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(.ui("모두 비우기")) { Task { await model.clear(DJCCacheKind.allCases) } }
                        .disabled(blocked != nil || model.isWorking || !model.clearable.values.contains { $0 > 0 })
                        .help(blocked ?? String(ui: "모든 캐시를 비웁니다. 초안·백업은 그대로 둡니다"))
                }
            } header: {
                Text(.ui("캐시"))
            } footer: {
                Text(.ui("캐시는 다시 만들어지므로 확인 없이 비웁니다. 초안·추가 목록·백업은 지우지 않습니다."))
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(model.backups, id: \.kind) { backup in
                    LabeledContent(title(of: backup.kind)) {
                        Text(.ui("\(backup.count)개 · 최대 \(StorageSize.text(backup.bytes))"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $model.autoSnapshotDays, in: 1...90) {
                    LabeledContent(.ui("자동 시점 스냅샷 보관")) {
                        Text(.ui("\(model.autoSnapshotDays)일"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(.ui("백업(읽기만)"))
            } footer: {
                Text(.ui("같은 디스크의 복사본은 공간을 나눠 써서 실제로 차지하는 공간은 더 작을 수 있습니다. 백업과 자동 시점 스냅샷은 오래된 것부터 저절로 정리되고, 수동·고정 시점 스냅샷은 지우지 않습니다."))
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(.ui("데이터 폴더")) {
                    HStack(spacing: 10) {
                        Text((model.paths.root.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button(.ui("Finder에서 보기")) {
                            NSWorkspace.shared.activateFileViewerSelecting([model.paths.root])
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 720)
        .task { await model.refresh() }
    }

    private func bytes(of kind: DJCCacheKind) -> Int64? { model.usage?.first { $0.kind == kind }?.bytes }

    private func size(of kind: DJCCacheKind) -> String {
        bytes(of: kind).map(StorageSize.text) ?? String(ui: "계산 중…")
    }

    private func title(of kind: DJCCache.BackupUsage.Kind) -> String {
        switch kind {
        case .rekordboxBackups: String(ui: "rekordbox 쓰기 전 백업")
        case .pointSnapshots: String(ui: "rekordbox 시점 스냅샷")
        case .usbBackups: String(ui: "USB 쓰기 전 백업")
        }
    }
}
