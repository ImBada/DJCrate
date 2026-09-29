import AppKit
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 앱의 USB 수정 한 번: 이 볼륨에 쌓인 초안을 쓴다(`UsbEditSession.writeDraft`)
struct UsbEditJob: Sendable, Equatable {
    /// 앱이 이미 연 로컬 스냅샷 사본(곡 더하기·갱신과 음원 지우기 확인에 쓴다. 새로 뜨지 않는다)
    var database: URL?
    /// 로컬 rekordbox share(읽기만)
    var share: URL?
    var volume: UsbVolumeInfo
    /// ISO 8601 스냅샷 시각(nil이면 사본 이름 → mtime)
    var snapshotTime: String?

    var volumeKey: String { volume.usbKey }
    var root: URL { URL(filePath: volume.mountPoint) }
}

/// 수정 미리 보기·쓰기 요약(확인 창·쓰기 대기 목록이 보인다). 곡 제목·경로는 담지 않는다
struct UsbEditSummary: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case written, unchanged
        case blocked(String)
        /// 라이브러리는 고치고 파일 지우기를 미뤘다(이유)
        case deferred(String)
    }

    /// 형식 하나의 결과
    struct FormatResult: Equatable, Sendable {
        var format: UsbFormat
        var written: Bool
        /// 그 형식을 고치지 않는 이유
        var blocked: String?
    }

    /// 같은 이유로 빼고 쓰는 곡 수(같은 곡은 한 번)
    struct Count: Equatable, Sendable {
        var message: String
        var count: Int
    }

    /// 초안 편집 수
    var editCount: Int
    /// 편집 번호(1부터) → 결과
    var outcomes: [Int: Outcome]
    /// 쓰기를 멈추는 막힘(USB 전체·볼륨)의 문구
    var stopping: [String]
    var skipped: [Count]
    var formats: [FormatResult]
    /// USB에서 지울 파일 수
    var removals: Int
    /// 파일 지우기를 미룬 이유
    var deferred: [String]
    var notes: [String]
    var warnings: [String]
    /// 확인 안 된 규칙(이름 순)
    var rules: [UsbProvisionalRule]
    /// 준비한 변경 묶음이 있는지
    var hasChanges: Bool
    var isTestVolume: Bool
    /// 한 형식이 막힌 채 곡을 더하거나 빼 두 형식의 곡이 달라진다(다음부터 이 USB 편집이 막힌다)
    var formatDrift: Bool

    init(editCount: Int, outcomes: [Int: Outcome], stopping: [String], skipped: [Count], formats: [FormatResult], removals: Int,
         deferred: [String], notes: [String], warnings: [String], rules: [UsbProvisionalRule], hasChanges: Bool, isTestVolume: Bool,
         formatDrift: Bool) {
        self.editCount = editCount
        self.outcomes = outcomes
        self.stopping = stopping
        self.skipped = skipped
        self.formats = formats
        self.removals = removals
        self.deferred = deferred
        self.notes = notes
        self.warnings = warnings
        self.rules = rules
        self.hasChanges = hasChanges
        self.isTestVolume = isTestVolume
        self.formatDrift = formatDrift
    }

    init(result: UsbEditResult, edits: [UsbLibraryEdit], volume: UsbVolumeInfo) {
        var outcomes: [Int: Outcome] = [:]
        var deferred: [String] = []
        for (edit, outcome) in result.outcomes {
            switch outcome {
            case .written: outcomes[edit] = .written
            case .unchanged: outcomes[edit] = .unchanged
            case let .blocked(block): outcomes[edit] = .blocked(block.message)
            case let .deferred(reason):
                outcomes[edit] = .deferred(reason)
                if !deferred.contains(reason) { deferred.append(reason) }
            }
        }
        var order: [String] = [], tracks: [String: Set<UsbBlock.Scope>] = [:]
        for block in result.trackBlocks {
            if tracks[block.message] == nil { order.append(block.message) }
            tracks[block.message, default: []].insert(block.scope)
        }
        let tracksChanged = result.outcomes.contains { entry in
            guard edits.indices.contains(entry.edit - 1) else { return false }
            switch entry.outcome {
            case .written, .deferred: break
            case .unchanged, .blocked: return false
            }
            switch edits[entry.edit - 1] {
            case .addTracks, .removeTracks: return true
            case .refreshTracks, .playlist: return false
            }
        }
        self.init(editCount: edits.count, outcomes: outcomes, stopping: Self.unique(result.blocks.map(\.message)),
                  skipped: order.map { Count(message: $0, count: tracks[$0]?.count ?? 0) },
                  formats: UsbFormat.allCases.compactMap { format in
                      if let block = result.formatsBlocked[format] { return FormatResult(format: format, written: false, blocked: block.message) }
                      return result.formatsWritten.contains(format) ? FormatResult(format: format, written: true, blocked: nil) : nil
                  },
                  removals: result.changes?.removals.count ?? 0, deferred: deferred, notes: Self.grouped(result.notes),
                  warnings: Self.unique(result.warnings.map(\.message)),
                  rules: (result.changes?.requiredRules ?? []).sorted { $0.rawValue < $1.rawValue }, hasChanges: result.changes != nil,
                  isTestVolume: volume.isDiskImage, formatDrift: !result.formatsBlocked.isEmpty && tracksChanged)
    }

    /// 이 USB에 초안이 없다
    static func noDraft(isTestVolume: Bool) -> UsbEditSummary {
        UsbEditSummary(editCount: 0, outcomes: [:], stopping: [String(ui: "이 USB에 쌓인 초안이 없습니다. 편집을 먼저 더하세요")], skipped: [],
                       formats: [], removals: 0, deferred: [], notes: [], warnings: [], rules: [], hasChanges: false,
                       isTestVolume: isTestVolume, formatDrift: false)
    }

    /// 쓸 편집(파일 지우기를 미룬 것 포함)
    var writtenCount: Int {
        outcomes.values.filter { if case .written = $0 { true } else if case .deferred = $0 { true } else { false } }.count
    }
    var blockedCount: Int { outcomes.values.filter { if case .blocked = $0 { true } else { false } }.count }
    var unchangedCount: Int { outcomes.values.filter { $0 == .unchanged }.count }
    var skippedTrackCount: Int { skipped.reduce(0) { $0 + $1.count } }
    var canWrite: Bool { stopping.isEmpty && hasChanges }

    static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    /// 끝에 USB 상대 경로가 붙은 알림은 같은 이유끼리 수로만 적는다(`djc usb-edit` 요약과 같다)
    static func grouped(_ notes: [String]) -> [String] {
        var lines: [String] = [], counts: [(head: String, count: Int)] = []
        for note in unique(notes) {
            guard let range = note.range(of: ": "),
                  ["contents/", "pioneer/"].contains(where: { note[range.upperBound...].lowercased().hasPrefix($0) }) else {
                lines.append(note)
                continue
            }
            let head = String(note[..<range.lowerBound])
            if let index = counts.firstIndex(where: { $0.head == head }) { counts[index].count += 1 } else { counts.append((head, 1)) }
        }
        return lines + counts.map { String(ui: "\($0.head) (\($0.count)개)") }
    }
}

/// 수정 쓰기 결과: 요약과 쓰기 보고서(쓸 것이 없었으면 nil)
struct UsbEditWritten: Sendable {
    var summary: UsbEditSummary
    var report: UsbWriteReport?
}

/// 재생 목록 이름을 받는 창. 시험은 정해 둔 답을 돌려준다
@MainActor
protocol UsbNamePrompter {
    /// 확인하면 입력한 이름, 취소하면 nil
    func askName(title: String, text: String, initial: String, confirm: String) -> String?
}

struct AlertNamePrompter: UsbNamePrompter {
    func askName(title: String, text: String, initial: String, confirm: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.setAccessibilityLabel(String(ui: "재생 목록 이름"))
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: String(ui: "취소")).keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

/// 편집을 더할 수 있는 USB(메뉴·끌어다 놓기 대상)
struct UsbEditTarget: Identifiable, Equatable {
    var volumeKey: String
    var name: String
    /// 빠진 볼륨이면 거짓(초안만 쌓는다)
    var isConnected: Bool
    var library: UsbLibrary

    var id: String { volumeKey }
}

/// 편집 한 건의 짧은 설명(대기 목록·알림). 목록 이름은 USB 라이브러리와 같은 초안에서 만든 목록에서 찾는다
enum UsbEditText {
    static func describe(_ edit: UsbLibraryEdit, library: UsbLibrary?, created: [String: String] = [:]) -> String {
        func name(_ ref: PlaylistRef) -> String {
            switch ref {
            case .root: String(ui: "맨 위")
            case let .id(text): library?.playlists.first { String($0.id) == text }?.name ?? String(ui: "재생 목록 \(text)")
            case let .new(key): created[key] ?? String(ui: "새 재생 목록")
            }
        }
        switch edit {
        case let .addTracks(ids, .none): return String(ui: "곡 \(ids.count)개 더하기")
        case let .addTracks(ids, .some(playlist)): return String(ui: "곡 \(ids.count)개 더하기 · ‘\(name(playlist))’에 넣기")
        case let .removeTracks(ids): return String(ui: "곡 \(ids.count)개 USB에서 빼기")
        case let .refreshTracks(ids, _): return String(ui: "곡 \(ids.count)개 로컬 변경 반영")
        case let .playlist(edit):
            switch edit {
            case let .create(_, newName, isFolder, parent):
                let head = isFolder ? String(ui: "새 폴더 ‘\(newName)’") : String(ui: "새 재생 목록 ‘\(newName)’")
                return parent == .root ? head : String(ui: "\(head) · ‘\(name(parent))’ 안")
            case let .rename(ref, newName): return String(ui: "이름 바꾸기: ‘\(name(ref))’ → ‘\(newName)’")
            case let .move(ref, into): return String(ui: "옮기기: ‘\(name(ref))’ → ‘\(name(into))’")
            case let .reorder(ref, _): return String(ui: "순서 바꾸기: ‘\(name(ref))’")
            case let .delete(ref): return String(ui: "지우기: ‘\(name(ref))’")
            case let .addTracks(ref, ids): return String(ui: "‘\(name(ref))’에 곡 \(ids.count)개 넣기")
            case let .removeTracks(ref, entries): return String(ui: "‘\(name(ref))’에서 곡 \(entries.count)개 빼기")
            case let .moveTracks(ref, _, _): return String(ui: "‘\(name(ref))’ 곡 순서 바꾸기")
            }
        }
    }

    /// 초안에서 만든 목록(key → 이름)
    static func createdNames(_ edits: [UsbLibraryEdit]) -> [String: String] {
        var names: [String: String] = [:]
        for case let .playlist(edit: .create(key, name, _, _)) in edits where names[key] == nil { names[key] = name }
        return names
    }
}

/// 앱의 USB 편집: 곡 목록·사이드바의 동작을 USB 초안(`usb-drafts/<볼륨키>.json`)으로 쌓는다. USB에는 쓰지 않는다 —
/// 쓰기는 쓰기 대기 목록의 "USB에 쓰기…"(`UsbWriteCoordinator.writeDraft`)만 한다. 초안 파일 입출력은 메인 액터 밖에서 한다.
@MainActor
struct UsbEditActions {
    let usb: UsbStore
    let host: any UsbWriteHost
    var prompter: any ReflectionPrompter = AlertPrompter()
    var namePrompter: any UsbNamePrompter = AlertNamePrompter()
    /// 새 목록의 key(같은 초안 안에서 겹치지 않게)
    var newKey: () -> String = { "djc-" + UUID().uuidString.prefix(8).lowercased() }

    // MARK: - 대상

    /// 편집을 더할 수 있는 볼륨: 읽은 rekordbox USB(쓰기 금지 목록 제외), 이번 실행에서 읽은 뒤 빠진 초안 볼륨
    var targets: [UsbEditTarget] {
        let connected = usb.volumes.compactMap { volume -> UsbEditTarget? in
            let key = volume.usbKey
            guard usb.acceptsEdits(key), let library = usb.libraries[key] else { return nil }
            return UsbEditTarget(volumeKey: key, name: volume.name, isConnected: true, library: library)
        }
        let absent = usb.absentDrafts.values.sorted { $0.volume.name.localizedStandardCompare($1.volume.name) == .orderedAscending }
            .compactMap { absent -> UsbEditTarget? in
                guard let library = absent.library, usb.acceptsEdits(absent.volume.usbKey) else { return nil }
                return UsbEditTarget(volumeKey: absent.volume.usbKey, name: absent.volume.name, isConnected: false, library: library)
            }
        return connected + absent
    }

    /// 이 편집이 막힐 까닭(모르면 nil). 메뉴 옆 도움말과 대기 목록에 쓴다
    func blockReason(_ edit: UsbLibraryEdit, volumeKey: String) -> String? {
        Self.blockReason(edit, volume: usb.volume(volumeKey), library: usb.editLibrary(volumeKey), info: usb.infos[volumeKey])
    }

    /// 편집을 초안에 더하기 전의 가벼운 막힘 판정: 사본으로 읽은 라이브러리와 볼륨만 본다(USB·로컬 사본을 열지 않는다).
    /// 쓰기 때의 계획(`UsbEditSession`)과 같은 문구를 쓴다. 볼륨이 빠져 있으면 볼륨 판정은 쓸 때 한다
    static func blockReason(_ edit: UsbLibraryEdit, volume: UsbVolumeInfo?, library: UsbLibrary?, info: UsbInfo?) -> String? {
        if let volume {
            if let problem = UsbVolumePolicy.problems(volume, purpose: .edit).first { return problem.message }
            if !volume.isDiskImage {
                // 실물 USB는 확인 안 된 규칙을 풀 수 없다(디스크 이미지 시험만)
                if case .addTracks = edit, !UsbProvisionalRule.analysisFolderNaming.isConfirmed {
                    return String(ui: "USB 폴더 이름 규칙이 확인되지 않아 실물 USB에는 곡을 더할 수 없습니다")
                }
                if let rule = edit.requiredRules.sorted(by: { $0.rawValue < $1.rawValue }).first(where: { !$0.isConfirmed }) {
                    return String(ui: "확인하지 않은 규칙(\(rule.summary))이 필요해 이 USB에 쓸 수 없습니다")
                }
                if !UsbPhysicalWriteGate.buildEnabled {
                    return String(ui: "실물 USB 쓰기는 아직 열리지 않았습니다. 디스크 이미지로만 시험할 수 있습니다")
                }
            }
        }
        if let consistency = info?.consistency, consistency.editBlocked {
            return !consistency.trackIDsMatch || !consistency.pathsMatch
                ? String(ui: "두 형식의 곡 번호가 달라 고칠 수 없습니다. rekordbox에서 다시 내보내세요")
                : String(ui: "두 형식에서 같은 번호의 재생 목록이 서로 달라 고칠 수 없습니다. rekordbox에서 다시 내보내세요")
        }
        guard let library else { return nil }
        let missing = String(ui: "대상이 USB에서 사라졌습니다. USB를 다시 읽은 뒤 고치세요")
        let trackIDs = Set(library.tracks.map(\.id))
        /// 가리킨 목록. 맨 위·같은 초안에서 만든 목록은 쓸 때 계획이 본다
        enum Found { case unchecked, missing, found(UsbPlaylist) }
        func lookup(_ ref: PlaylistRef) -> Found {
            guard case let .id(text) = ref else { return .unchecked }
            guard let id = Int(text), let found = library.playlists.first(where: { $0.id == id }) else { return .missing }
            return .found(found)
        }
        /// 맨 위나 폴더여야 하는 자리
        func folderReason(_ ref: PlaylistRef) -> String? {
            switch lookup(ref) {
            case .unchecked: return nil
            case .missing: return missing
            case let .found(found):
                return found.attribute == 1 ? nil : String(ui: "재생 목록 안에는 넣을 수 없습니다. 폴더를 고르세요")
            }
        }
        /// 곡 항목을 고치는 목록: 일반 목록이고, 목록이 있는 형식의 항목이 모두 같고, 고를 때의 자리에 그 곡이 있어야 한다
        func entryReason(_ ref: PlaylistRef, entries picked: [PlaylistEntry] = []) -> String? {
            switch lookup(ref) {
            case .unchecked: return nil
            case .missing: return missing
            case let .found(found):
                guard found.attribute == 0 else {
                    return String(ui: "폴더·인텔리전트 재생 목록에는 곡을 넣거나 뺄 수 없습니다. 일반 재생 목록을 고르세요")
                }
                let lists = UsbFormat.allCases.filter(found.presentIn.contains).map { found.entries[$0] ?? [] }
                guard lists.allSatisfy({ $0 == lists.first }) else {
                    return String(ui: "이 재생 목록은 두 형식의 곡 목록이 달라 곡을 고칠 수 없습니다. 이름·위치만 바꿀 수 있습니다")
                }
                let entries = lists.first ?? []
                for entry in picked where !(entries.indices.contains(entry.trackNo - 1) && String(entries[entry.trackNo - 1]) == entry.contentID) {
                    return String(ui: "\(entry.trackNo)번째 곡이 편집을 만들 때와 다릅니다. USB를 다시 읽은 뒤 고치세요")
                }
                return nil
            }
        }
        func target(_ ref: PlaylistRef) -> String? {
            if case .missing = lookup(ref) { return missing }
            return nil
        }
        switch edit {
        case let .addTracks(_, playlist):
            return playlist.flatMap { entryReason($0) }
        case let .removeTracks(ids):
            let removing = Set(ids)
            if !removing.isSubset(of: trackIDs) { return missing }
            if library.histories.contains(where: { !removing.isDisjoint(with: $0.entries) }) {
                return String(ui: "재생 기록에 있는 곡이라 빼지 않았습니다. 먼저 기록을 가져오세요")
            }
            if trackIDs.isSubset(of: removing) { return String(ui: "USB에 곡이 하나도 남지 않습니다. 곡을 남기거나 USB를 새로 내보내세요") }
            return nil
        case let .refreshTracks(ids, _):
            return Set(ids).isSubset(of: trackIDs) ? nil : missing
        case let .playlist(edit):
            switch edit {
            case let .create(_, _, _, parent): return folderReason(parent)
            case let .rename(ref, _), let .reorder(ref, _), let .delete(ref): return target(ref)
            case let .move(ref, into):
                if let reason = target(ref) ?? folderReason(into) { return reason }
                if case let .id(text) = ref, ref == into || Self.descendants(of: Int(text) ?? -1, in: library).contains(where: { PlaylistRef.id(String($0)) == into }) {
                    return String(ui: "재생 목록 폴더를 자기 안으로 옮길 수 없습니다. 다른 폴더를 고르세요")
                }
                return nil
            case let .addTracks(ref, ids):
                if let reason = entryReason(ref) { return reason }
                return ids.allSatisfy { Int($0).map(trackIDs.contains) ?? false } ? nil : missing
            case let .removeTracks(ref, entries), let .moveTracks(ref, entries, _):
                return entryReason(ref, entries: entries)
            }
        }
    }

    static func descendants(of id: Int, in library: UsbLibrary) -> [Int] {
        var result: [Int] = [], queue = [id]
        while let parent = queue.popLast() {
            let children = library.playlists.filter { $0.parentID == parent && $0.id != parent }.map(\.id).filter { !result.contains($0) }
            result += children
            queue += children
        }
        return result
    }

    // MARK: - 초안

    /// 편집 하나를 그 볼륨의 초안 끝에 더한다. 볼륨이 빠져 있어도 더한다(쓰기만 막힌다). 더하면 true.
    /// 초안이 없을 때만 지금 USB DB 지문을 base로 뜬다(메인 액터 밖). 빠진 볼륨·지문을 뜨지 못함이면 빈 지문 — 쓸 때 지금 상태로 다시 계획한다
    @discardableResult
    func append(_ edit: UsbLibraryEdit, to volumeKey: String) async -> Bool {
        guard let directory = usb.draftDirectory, usb.acceptsEdits(volumeKey) else { return false }
        let name = usb.editName(volumeKey) ?? "USB"
        let library = usb.editLibrary(volumeKey)
        var base = UsbFingerprint(files: [:])
        if (usb.draftCounts[volumeKey] ?? 0) == 0, let volume = usb.volume(volumeKey) {
            let service = usb.writeService
            if let fingerprint = try? await Task.detached(priority: .userInitiated, operation: { try service.draftBase(volume) }).value {
                base = fingerprint
            }
        }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Int, any Error> in
            Result {
                let store = UsbDraftStore(directory: directory)
                try store.append(edit, volumeKey: volumeKey, base: base)
                return try store.load(volumeKey: volumeKey)?.edits.count ?? 0
            }
        }.value
        switch result {
        case let .success(count):
            usb.setDraftCount(count, for: volumeKey)
            host.toast = AppToast(kind: .success, title: String(ui: "USB 쓰기 대기에 더했습니다"),
                                  detail: "\(name) · \(UsbEditText.describe(edit, library: library))", isUsb: true)
            return true
        case let .failure(error):
            draftFailed(error)
            return false
        }
    }

    /// 막힐 편집은 더하지 않고 이유를 알린다
    @discardableResult
    private func appendChecked(_ edit: UsbLibraryEdit, to volumeKey: String) async -> Bool {
        if let reason = blockReason(edit, volumeKey: volumeKey) {
            host.toast = AppToast(kind: .warning, title: String(ui: "USB 쓰기 대기에 더하지 않았습니다"), detail: reason, isUsb: true)
            return false
        }
        return await append(edit, to: volumeKey)
    }

    private func draftFailed(_ error: any Error) {
        AppErrorMessage.log(error)
        host.toast = AppToast(kind: .warning, title: String(ui: "USB 초안을 고치지 못했습니다"),
                              detail: String(ui: "DJCrate 데이터 폴더의 usb-drafts를 확인한 뒤 다시 시도하세요"), isUsb: true)
    }

    /// 그 볼륨의 초안(없으면 nil)
    func draft(volumeKey: String) async -> UsbDraft? {
        guard let directory = usb.draftDirectory else { return nil }
        return await Task.detached(priority: .userInitiated) { try? UsbDraftStore(directory: directory).load(volumeKey: volumeKey) }.value ?? nil
    }

    /// 편집 하나를 초안에서 뺀다(번호는 1부터). 남는 것이 없으면 초안을 지운다
    func removeEdit(_ number: Int, volumeKey: String) async {
        guard let directory = usb.draftDirectory else { return }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Int, any Error> in
            Result {
                let store = UsbDraftStore(directory: directory)
                guard var draft = try store.load(volumeKey: volumeKey) else { return 0 }
                guard draft.edits.indices.contains(number - 1) else { return draft.edits.count }
                draft.edits.remove(at: number - 1)
                if draft.edits.isEmpty { try store.discard(volumeKey: volumeKey) } else { try store.save(draft) }
                return draft.edits.count
            }
        }.value
        switch result {
        case let .success(count): usb.setDraftCount(count, for: volumeKey)
        case let .failure(error): draftFailed(error)
        }
    }

    /// 초안 버리기(확인). USB는 바뀌지 않는다
    func discardDraft(volumeKey: String) async {
        guard let directory = usb.draftDirectory else { return }
        let count = usb.draftCounts[volumeKey] ?? 0
        guard count > 0, prompter.show(ReflectionPrompt(
            title: String(ui: "USB 초안 \(count)건을 버릴까요?"),
            text: String(ui: "\(usb.editName(volumeKey) ?? "USB")에 아직 쓰지 않은 편집(곡 더하기·빼기·갱신, 재생 목록 편집)을 모두 버립니다. USB는 바뀌지 않습니다."),
            confirm: String(ui: "버리기"), destructive: true)) else { return }
        let result = await Task.detached(priority: .userInitiated) { Result { try UsbDraftStore(directory: directory).discard(volumeKey: volumeKey) } }.value
        switch result {
        case .success: usb.setDraftCount(0, for: volumeKey)
        case let .failure(error): draftFailed(error)
        }
    }

    // MARK: - 곡

    /// 로컬 곡 → 곡 더하기 편집(추가한 곡·스트리밍·USB 곡은 뺀다). 목록이면 그 목록 끝에도 넣는다
    static func addTracksEdit(_ rows: [TrackRow], target: UsbSidebarTarget) -> UsbLibraryEdit? {
        var seen: Set<String> = []
        let ids = rows.filter { !$0.isUsb && !$0.isStaged && !$0.track.isStreaming }.map(\.track.id).filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return nil }
        switch target {
        case .collection: return .addTracks(localContentIDs: ids, playlist: nil)
        case let .playlist(_, id): return .addTracks(localContentIDs: ids, playlist: .id(String(id)))
        case .pending: return nil
        }
    }

    /// 로컬 곡을 USB 컬렉션·목록에 더한다(초안). 막힐 편집이면 더하지 않고 알린다
    @discardableResult
    func addTracks(_ rows: [TrackRow], to target: UsbSidebarTarget) async -> Bool {
        guard let edit = Self.addTracksEdit(rows, target: target) else { return false }
        return await appendChecked(edit, to: target.volumeKey)
    }

    /// 사이드바 USB 컬렉션·일반 재생 목록에만 곡을 놓는다
    func acceptsDrop(on target: UsbSidebarTarget) -> Bool {
        guard usb.acceptsEdits(target.volumeKey), let library = usb.editLibrary(target.volumeKey) else { return false }
        switch target {
        case .collection: return true
        case let .playlist(_, id): return library.playlists.first { $0.id == id }?.attribute == 0
        case .pending: return false
        }
    }

    /// 끌어다 놓은 곡 ID(로컬 ContentID) → 곡 더하기 초안
    @discardableResult
    func drop(_ ids: [String], on target: UsbSidebarTarget, rows: [String: TrackRow]) async -> Bool {
        guard acceptsDrop(on: target) else { return false }
        return await addTracks(ids.compactMap { rows[$0] }, to: target)
    }

    /// USB 곡 줄의 content_id(`usb:<볼륨키>:<id>`)
    static func usbContentID(_ row: TrackRow, volumeKey: String) -> Int? {
        let prefix = UsbLibraryRows.idPrefix + volumeKey + ":"
        guard row.track.id.hasPrefix(prefix) else { return nil }
        return Int(row.track.id.dropFirst(prefix.count))
    }

    static func usbContentIDs(_ rows: [TrackRow], volumeKey: String) -> [Int] {
        var seen: Set<Int> = []
        return rows.compactMap { usbContentID($0, volumeKey: volumeKey) }.filter { seen.insert($0).inserted }
    }

    /// USB 곡을 USB에서 뺀다(초안)
    func removeTracks(_ rows: [TrackRow], volumeKey: String) async {
        let ids = Self.usbContentIDs(rows, volumeKey: volumeKey)
        guard !ids.isEmpty else { return }
        await appendChecked(.removeTracks(usbContentIDs: ids), to: volumeKey)
    }

    /// USB 목록에서 고른 항목 → 그 목록에서 빼기 편집(자리와 그 자리의 곡)
    static func removeFromPlaylistEdit(_ rows: [TrackRow], volumeKey: String, playlist: Int) -> UsbLibraryEdit? {
        var seen: Set<Int> = []
        let entries = rows.compactMap { row -> PlaylistEntry? in
            guard let number = row.playlistOccurrence?.number, let id = usbContentID(row, volumeKey: volumeKey), seen.insert(number).inserted else {
                return nil
            }
            return PlaylistEntry(trackNo: number, contentID: String(id))
        }.sorted { $0.trackNo < $1.trackNo }
        return entries.isEmpty ? nil : .playlist(edit: .removeTracks(playlist: .id(String(playlist)), entries: entries))
    }

    func removeFromPlaylist(_ rows: [TrackRow], volumeKey: String, playlist: Int) async {
        guard let edit = Self.removeFromPlaylistEdit(rows, volumeKey: volumeKey, playlist: playlist) else { return }
        await appendChecked(edit, to: volumeKey)
    }

    /// 로컬에서 더 고친 곡(갱신 가능)의 content_id(목록 순서). rows가 있으면 그 줄만 본다
    func updatableTracks(volumeKey: String, rows: [TrackRow]? = nil) -> [Int] {
        let badges = usb.syncBadges[volumeKey] ?? [:]
        let candidates = rows.map { Self.usbContentIDs($0, volumeKey: volumeKey) } ?? (usb.editLibrary(volumeKey)?.tracks.map(\.id) ?? [])
        return candidates.filter { if case .localNewer? = badges[$0] { true } else { false } }
    }

    /// 로컬에서 더 고친 필드 → 갱신할 부분(곡 정보는 그림과 함께)
    static func refreshParts(_ fields: Set<UsbSyncStatus.Field>) -> Set<UsbRefreshPart> {
        var parts: Set<UsbRefreshPart> = []
        if fields.contains(.information) { parts.formUnion([.info, .artwork]) }
        if fields.contains(.analysis) { parts.insert(.grid) }
        if fields.contains(.cue) { parts.insert(.cues) }
        return parts
    }

    /// 로컬 변경을 USB에 반영(초안): 갱신 가능한 곡만, 로컬에서 바뀐 부분만. 기기에서 고친 곡·로컬에 없는 곡은 건드리지 않는다
    func refreshLocalChanges(volumeKey: String, rows: [TrackRow]? = nil) async {
        let badges = usb.syncBadges[volumeKey] ?? [:]
        let ids = updatableTracks(volumeKey: volumeKey, rows: rows)
        guard !ids.isEmpty else {
            host.toast = AppToast(kind: .success, title: String(ui: "로컬에서 더 고친 곡이 없습니다"), detail: usb.editName(volumeKey), isUsb: true)
            return
        }
        var fields: Set<UsbSyncStatus.Field> = []
        for id in ids { if case let .localNewer(changed)? = badges[id] { fields.formUnion(changed) } }
        await appendChecked(.refreshTracks(usbContentIDs: ids, parts: Self.refreshParts(fields)), to: volumeKey)
    }

    // MARK: - 재생 목록

    /// 새 목록·폴더(이름 창). parent가 nil이면 맨 위
    func createPlaylist(isFolder: Bool, parent: Int?, volumeKey: String) async {
        let name = usb.editName(volumeKey) ?? "USB"
        let title = isFolder ? String(ui: "\(name)에 새 폴더") : String(ui: "\(name)에 새 재생 목록")
        guard let entered = namePrompter.askName(title: title, text: String(ui: "USB 쓰기 대기에 더합니다. USB는 ‘USB에 쓰기…’를 누를 때 바뀝니다."),
                                                 initial: isFolder ? String(ui: "새 폴더") : String(ui: "새 재생 목록"),
                                                 confirm: String(ui: "만들기")) else { return }
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await appendChecked(.playlist(edit: .create(key: newKey(), name: trimmed, isFolder: isFolder,
                                                    parent: parent.map { .id(String($0)) } ?? .root)), to: volumeKey)
    }

    func renamePlaylist(_ id: Int, volumeKey: String) async {
        guard let playlist = usb.editLibrary(volumeKey)?.playlists.first(where: { $0.id == id }),
              let entered = namePrompter.askName(title: String(ui: "재생 목록 이름 바꾸기"),
                                                 text: String(ui: "USB 쓰기 대기에 더합니다. USB는 ‘USB에 쓰기…’를 누를 때 바뀝니다."),
                                                 initial: playlist.name, confirm: String(ui: "이름 바꾸기")) else { return }
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != playlist.name else { return }
        await appendChecked(.playlist(edit: .rename(playlist: .id(String(id)), name: trimmed)), to: volumeKey)
    }

    func deletePlaylist(_ id: Int, volumeKey: String) async {
        await appendChecked(.playlist(edit: .delete(playlist: .id(String(id)))), to: volumeKey)
    }

    /// 같은 부모 안에서 사이드바에 보이는 순서의 자리(0부터)와 형제 수
    func siblingPosition(_ id: Int, volumeKey: String) -> (index: Int, count: Int)? {
        guard let library = usb.editLibrary(volumeKey), let playlist = library.playlists.first(where: { $0.id == id }) else { return nil }
        func order(_ item: UsbPlaylist) -> Int { item.sortOrder[.oneLibrary] ?? item.sortOrder[.deviceLibrary] ?? .max }
        let siblings = library.playlists.filter { $0.parentID == playlist.parentID }.sorted { (order($0), $0.id) < (order($1), $1.id) }
        return siblings.firstIndex { $0.id == id }.map { ($0, siblings.count) }
    }

    func canMovePlaylist(_ id: Int, by step: Int, volumeKey: String) -> Bool {
        guard let position = siblingPosition(id, volumeKey: volumeKey) else { return false }
        return (0..<position.count).contains(position.index + step)
    }

    /// 같은 부모 안에서 한 칸 올리거나 내린다(초안)
    func movePlaylist(_ id: Int, by step: Int, volumeKey: String) async {
        guard canMovePlaylist(id, by: step, volumeKey: volumeKey), let position = siblingPosition(id, volumeKey: volumeKey) else { return }
        await appendChecked(.playlist(edit: .reorder(playlist: .id(String(id)), index: position.index + step)), to: volumeKey)
    }
}

extension LibraryStore {
    /// 앱의 USB 초안 편집(사이드바 USB 절이 붙은 뒤에만)
    var usbEdits: UsbEditActions? { usb.map { UsbEditActions(usb: $0, host: self) } }

    /// USB 목록에서 고른 줄(표 순서, 같은 곡이 목록에 여러 번 있으면 줄마다)
    var selectedUsbRows: [TrackRow] { displayRows.filter { $0.isUsb && selection.contains($0.id) } }
}
