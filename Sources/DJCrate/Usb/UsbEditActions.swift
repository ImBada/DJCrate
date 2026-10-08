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
    /// native 선택 초안은 만든 때의 전체 원본을 확인 창 뒤까지 고정한다.
    var syncSourceContext: UsbExportSyncSourceContext? = nil

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
    /// CDJ에서 확인하지 않은 항목(`UsbProvisionalRule.needsDeviceCheck`, 이름 순). 쓰기를 막지 않고 알리기만 한다
    var rules: [UsbProvisionalRule]
    /// 준비한 변경 묶음이 있는지
    var hasChanges: Bool
    var isTestVolume: Bool
    /// 한 형식이 막힌 채 곡을 더하거나 빼 두 형식의 곡이 달라진다(다음부터 이 USB 편집이 막힌다)
    var formatDrift: Bool
    /// 이 요약이 계획한 초안 편집(적힌 순서). 쓰기 직전 초안이 이것과 다르면 확인 창에 없던 편집을 쓰지 않게 다시 미리 본다
    var edits: [UsbLibraryEdit]

    init(editCount: Int, outcomes: [Int: Outcome], stopping: [String], skipped: [Count], formats: [FormatResult], removals: Int,
         deferred: [String], notes: [String], warnings: [String], rules: [UsbProvisionalRule], hasChanges: Bool, isTestVolume: Bool,
         formatDrift: Bool, edits: [UsbLibraryEdit] = []) {
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
        self.edits = edits
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
            case .refreshTracks, .playlist, .syncPlaylist, .syncSelection: return false
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
                  rules: UsbProvisionalRule.deviceCheckRules(result.changes?.requiredRules ?? []), hasChanges: result.changes != nil,
                  isTestVolume: volume.isDiskImage, formatDrift: !result.formatsBlocked.isEmpty && tracksChanged, edits: edits)
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
        case let .syncPlaylist(playlist, ids): return String(ui: "‘\(name(playlist))’ 동기화 · 곡 \(ids.count)개")
        case let .syncSelection(draft):
            return draft.enabledOnly ? String(ui: "USB 동기화 켜짐 저장") : String(ui: "USB 동기화 선택 저장")
        case let .playlist(edit):
            switch edit {
            case let .create(_, newName, isFolder, parent):
                let head = isFolder ? String(ui: "새 폴더 ‘\(newName)’") : String(ui: "새 재생 목록 ‘\(newName)’")
                return parent == .root ? head : String(ui: "\(head) · ‘\(name(parent))’ 안")
            case let .rename(ref, newName): return String(ui: "이름 바꾸기: ‘\(name(ref))’ → ‘\(newName)’")
            case let .move(ref, into): return String(ui: "옮기기: ‘\(name(ref))’ → ‘\(name(into))’")
            case let .reorder(ref, index): return String(ui: "순서 바꾸기: ‘\(name(ref))’ → \(index + 1)번째")
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

    /// 편집을 더할 수 있는 볼륨: 읽은 rekordbox USB, 이번 실행에서 읽은 뒤 빠진 초안 볼륨
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
        Self.blockReason(edit, volume: usb.volume(volumeKey), library: usb.editLibrary(volumeKey), info: usb.infos[volumeKey],
                         isScratchMount: usb.isScratchMount, physicalGate: usb.physicalGate)
    }

    /// 동기화 묶음은 앞선 폴더 이동을 반영한 트리에서 차례로 검사한다.
    func blockReason(_ edits: [UsbLibraryEdit], volumeKey: String) -> String? {
        Self.blockReason(edits, volume: usb.volume(volumeKey), library: usb.editLibrary(volumeKey), info: usb.infos[volumeKey],
                         isScratchMount: usb.isScratchMount, physicalGate: usb.physicalGate)
    }

    static func blockReason(_ edits: [UsbLibraryEdit], volume: UsbVolumeInfo?, library: UsbLibrary?, info: UsbInfo?,
                            isScratchMount: (String) -> Bool = UsbEditActions.isScratchMount,
                            physicalGate: UsbPhysicalWriteGate = .init()) -> String? {
        var projected = library
        var tree = library.map(UsbSyncPlan.usbLayout)
        for edit in edits {
            if let reason = blockReason(edit, volume: volume, library: projected, info: info,
                                        isScratchMount: isScratchMount, physicalGate: physicalGate) { return reason }
            guard case let .playlist(playlistEdit) = edit, var working = tree else { continue }
            switch playlistEdit {
            case .addTracks, .removeTracks, .moveTracks:
                // 새 곡의 USB 번호와 형식별 항목 변경은 최종 엔진이 확인한다.
                continue
            case .create, .rename, .move, .reorder, .delete:
                break
            }
            // 새 참조를 앞에서 만들지 못했는지는 최종 엔진이 확인한다.
            if case .create = playlistEdit {} else if working.item(playlistEdit.playlist.description) == nil { continue }
            if let destination = playlistEdit.destination, destination != .root,
               working.item(destination.description) == nil { continue }
            if case let .move(ref, into) = playlistEdit,
               working.subtree(of: ref.description).contains(into.description) {
                return String(ui: "재생 목록 폴더를 자기 안으로 옮길 수 없습니다. 다른 폴더를 고르세요")
            }
            do { try working.apply(playlistEdit) }
            catch let failure as PlaylistLayout.Blocked { return failure.reason }
            catch { return String(ui: "대상이 USB에서 사라졌습니다. USB를 다시 읽은 뒤 고치세요") }
            tree = working
            // .new 부모의 실제 USB 번호는 아직 없다. 트리에는 기호 참조로 남기고 DB 모델은 기존 ID만 갱신한다.
            if var model = projected {
                model.playlists = model.playlists.compactMap { old in
                    guard let item = working.item(String(old.id)) else { return nil }
                    var playlist = old
                    playlist.name = item.name
                    playlist.parentID = Int(item.parentID) ?? 0
                    return playlist
                }
                projected = model
            }
        }
        return nil
    }

    /// 마운트 지점(realpath)이 임시 폴더 뿌리 아래인지. 쓰기 세션의 실물 관문과 같은 판정이다
    nonisolated static func isScratchMount(_ mountPoint: String) -> Bool {
        UsbScratchRoots.realPath(mountPoint).map(UsbScratchRoots.isUnderAllowedRoot) ?? false
    }

    /// 편집을 초안에 더하기 전의 가벼운 막힘 판정: 사본으로 읽은 라이브러리와 볼륨만 본다(USB·로컬 사본을 열지 않는다).
    /// 쓰기 때의 계획(`UsbEditSession`)과 같은 문구를 쓴다. 볼륨이 빠져 있으면 볼륨 판정은 쓸 때 한다.
    /// 메뉴가 목록마다 부르므로 곡 번호 집합은 곡을 가리키는 편집에서만 만든다
    /// - physicalGate: 실물 쓰기 관문. 기본은 동의 없는 관문(실물은 막힘). 확인 안 된 규칙은 막지 않는다(확인 창이 알린다)
    static func blockReason(_ edit: UsbLibraryEdit, volume: UsbVolumeInfo?, library: UsbLibrary?, info: UsbInfo?,
                            isScratchMount: (String) -> Bool = UsbEditActions.isScratchMount,
                            physicalGate: UsbPhysicalWriteGate = .init()) -> String? {
        if case let .syncSelection(draft) = edit,
           let block = (library.map({ UsbSyncSelectionStage.gateBlock(baseFiles: draft.baseFiles, formats: $0.formats) }) ?? UsbSyncSelectionStage.productionBlock)
               ?? UsbSyncSelectionStage.draftBlock(draft) {
            return block.message
        }
        if let volume {
            if let problem = UsbVolumePolicy.problems(volume, purpose: .edit).first { return problem.message }
            // 임시 폴더 뿌리 밖에 붙인 디스크 이미지도 실물로 판정한다(세션의 실물 관문과 같다)
            let judged = volume.judgedForWrite(underScratch: isScratchMount(volume.mountPoint))
            // 앱은 쓰기 확인 창이 볼륨 이름 확인을 대신한다
            if let block = physicalGate.blocks(judged, confirmName: volume.name).first { return block.message }
        }
        if let consistency = info?.consistency, consistency.editBlocked {
            return !consistency.trackIDsMatch || !consistency.pathsMatch
                ? String(ui: "두 형식의 곡 번호가 달라 고칠 수 없습니다. rekordbox에서 다시 내보내세요")
                : String(ui: "두 형식에서 같은 번호의 재생 목록이 서로 달라 고칠 수 없습니다. rekordbox에서 다시 내보내세요")
        }
        guard let library else { return nil }
        let missing = String(ui: "대상이 USB에서 사라졌습니다. USB를 다시 읽은 뒤 고치세요")
        func trackIDs() -> Set<Int> { Set(library.tracks.map(\.id)) }
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
        case let .syncPlaylist(playlist, _):
            return entryReason(playlist)
        case .syncSelection:
            return nil
        case let .removeTracks(ids):
            let removing = Set(ids), all = trackIDs()
            if !removing.isSubset(of: all) { return missing }
            if library.histories.contains(where: { !removing.isDisjoint(with: $0.entries) }) {
                return String(ui: "재생 기록에 있는 곡이라 빼지 않았습니다. 먼저 기록을 가져오세요")
            }
            if all.isSubset(of: removing) { return String(ui: "USB에 곡이 하나도 남지 않습니다. 곡을 남기거나 USB를 새로 내보내세요") }
            return nil
        case let .refreshTracks(ids, _):
            return Set(ids).isSubset(of: trackIDs()) ? nil : missing
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
                let all = trackIDs()
                return ids.allSatisfy { Int($0).map(all.contains) ?? false } ? nil : missing
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

    /// 초안 한 번 고치기: 고치기 전·뒤 편집
    struct DraftChange: Sendable {
        var before: [UsbLibraryEdit]
        var after: [UsbLibraryEdit]
    }

    /// 그 볼륨의 초안을 한 줄(`UsbStore.draftQueue`)로 고친다. 메인 액터 밖에서 지금 초안 편집을 읽어 `change`로 새 편집을 받고
    /// (nil이면 그대로), 비면 초안을 지우고 아니면 저장한다. 초안 파일이 없을 때만 지금 USB DB 지문을 base로 뜬다 — 빠진 볼륨이거나
    /// 지문을 뜨지 못하면(그 자리의 볼륨이 바뀜·읽지 않는 볼륨) 빈 지문으로 둔다(쓸 때 지금 상태로 다시 계획한다).
    /// 고쳤으면 그 전·뒤 편집, 그대로면 nil
    private func mutateDraft(_ volumeKey: String, _ change: @escaping @Sendable ([UsbLibraryEdit]) -> [UsbLibraryEdit]?) async
        -> Result<DraftChange?, any Error> {
        guard let directory = usb.draftDirectory else { return .success(nil) }
        let usb = usb
        return await usb.draftQueue(volumeKey) {
            let volume = usb.volume(volumeKey), service = usb.writeService
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(edits: [UsbLibraryEdit], changed: DraftChange?), any Error> in
                Result {
                    let store = UsbDraftStore(directory: directory)
                    let draft = try store.load(volumeKey: volumeKey)
                    let before = draft?.edits ?? []
                    guard let after = change(before) else { return (before, nil) }
                    if after.isEmpty {
                        try store.discard(volumeKey: volumeKey)
                    } else {
                        let base = draft?.base ?? volume.flatMap { try? service.draftBase($0) } ?? UsbFingerprint(files: [:])
                        try store.save(UsbDraft(volumeKey: volumeKey, base: base, edits: after, createdAt: draft?.createdAt ?? Date()))
                    }
                    return (after, DraftChange(before: before, after: after))
                }
            }.value
            switch result {
            case let .success((edits, changed)):
                // 그대로여도 파일과 다르면(다른 곳에서 고침) 맞춘다
                if changed != nil || (usb.draftEdits[volumeKey] ?? []) != edits { usb.setDraft(edits, for: volumeKey) }
                return .success(changed)
            case let .failure(error):
                return .failure(error)
            }
        }
    }

    /// 편집 하나를 그 볼륨의 초안 끝에 더한다. 볼륨이 빠져 있어도 더한다(쓰기만 막힌다). 더하면 true
    @discardableResult
    func append(_ edit: UsbLibraryEdit, to volumeKey: String) async -> Bool {
        await append([edit], to: volumeKey, detail: UsbEditText.describe(edit, library: usb.editLibrary(volumeKey)))
    }

    /// 편집 여럿을 차례로 한 번에 더한다
    func append(_ edits: [UsbLibraryEdit], to volumeKey: String, detail: String) async -> Bool {
        guard !edits.isEmpty, usb.acceptsEdits(volumeKey) else { return false }
        let name = usb.editName(volumeKey) ?? "USB"
        switch await mutateDraft(volumeKey, { $0 + edits }) {
        case .success:
            host.toast = AppToast(kind: .success, title: String(ui: "USB 쓰기 대기에 더했습니다"), detail: "\(name) · \(detail)", isUsb: true)
            return true
        case let .failure(error):
            draftFailed(error)
            return false
        }
    }

    /// 막힐 편집은 더하지 않고 이유를 알린다
    @discardableResult
    private func appendChecked(_ edit: UsbLibraryEdit, to volumeKey: String) async -> Bool {
        await appendChecked([edit], to: volumeKey, detail: UsbEditText.describe(edit, library: usb.editLibrary(volumeKey)))
    }

    /// 하나라도 막히면 모두 더하지 않는다
    @discardableResult
    private func appendChecked(_ edits: [UsbLibraryEdit], to volumeKey: String, detail: String) async -> Bool {
        if let reason = blockReason(edits, volumeKey: volumeKey) {
            warnNotAdded(reason)
            return false
        }
        return await append(edits, to: volumeKey, detail: detail)
    }

    private func warnNotAdded(_ reason: String) {
        host.toast = AppToast(kind: .warning, title: String(ui: "USB 쓰기 대기에 더하지 않았습니다"), detail: reason, isUsb: true)
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

    /// 편집 하나를 초안에서 뺀다(번호는 1부터). `matching`을 주면 그 자리의 편집이 같을 때만 뺀다(그 사이 초안이 바뀌었으면 그대로).
    /// 남는 것이 없으면 초안을 지운다
    func removeEdit(_ number: Int, volumeKey: String, matching expected: UsbLibraryEdit? = nil) async {
        let result = await mutateDraft(volumeKey) { edits in
            guard edits.indices.contains(number - 1), expected.map({ edits[number - 1] == $0 }) ?? true else { return nil }
            var edits = edits
            edits.remove(at: number - 1)
            return edits
        }
        if case let .failure(error) = result { draftFailed(error) }
    }

    /// 초안 버리기(확인). USB는 바뀌지 않는다
    func discardDraft(volumeKey: String) async {
        let count = usb.draftCounts[volumeKey] ?? 0
        guard usb.draftDirectory != nil, count > 0, prompter.show(ReflectionPrompt(
            title: String(ui: "USB 초안 \(count)건을 버릴까요?"),
            text: String(ui: "\(usb.editName(volumeKey) ?? "USB")에 아직 쓰지 않은 편집(곡 더하기·빼기·갱신, 재생 목록 편집)을 모두 버립니다. USB는 바뀌지 않습니다."),
            confirm: String(ui: "버리기"), destructive: true)) else { return }
        if case let .failure(error) = await mutateDraft(volumeKey, { _ in [] }) { draftFailed(error) }
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

    /// 로컬 변경 반영 편집: 갱신 가능한 곡을 곡마다 로컬에서 바뀐 부분으로 묶는다(바뀐 부분이 같은 곡끼리 편집 하나, 처음 나온 차례,
    /// 묶음 안은 목록 순서). 다른 곡 때문에 바뀌지 않은 부분까지 다시 쓰거나, 그 부분 때문에 곡이 막히지 않게
    func refreshEdits(volumeKey: String, rows: [TrackRow]? = nil) -> [UsbLibraryEdit] {
        let badges = usb.syncBadges[volumeKey] ?? [:]
        var groups: [(parts: Set<UsbRefreshPart>, ids: [Int])] = []
        for id in updatableTracks(volumeKey: volumeKey, rows: rows) {
            guard case let .localNewer(changed)? = badges[id] else { continue }
            let parts = Self.refreshParts(changed)
            if let index = groups.firstIndex(where: { $0.parts == parts }) { groups[index].ids.append(id) } else { groups.append((parts, [id])) }
        }
        return groups.map { .refreshTracks(usbContentIDs: $0.ids, parts: $0.parts) }
    }

    /// 로컬 변경 반영이 막힐 까닭(메뉴 옆 도움말)
    func refreshBlockReason(volumeKey: String, rows: [TrackRow]? = nil) -> String? {
        refreshEdits(volumeKey: volumeKey, rows: rows).lazy.compactMap { blockReason($0, volumeKey: volumeKey) }.first
    }

    /// 로컬 변경을 USB에 반영(초안): 갱신 가능한 곡만, 곡마다 로컬에서 바뀐 부분만. 기기에서 고친 곡·로컬에 없는 곡은 건드리지 않는다
    func refreshLocalChanges(volumeKey: String, rows: [TrackRow]? = nil) async {
        let edits = refreshEdits(volumeKey: volumeKey, rows: rows)
        guard !edits.isEmpty else {
            host.toast = AppToast(kind: .success, title: String(ui: "로컬에서 더 고친 곡이 없습니다"), detail: usb.editName(volumeKey), isUsb: true)
            return
        }
        let ids = edits.flatMap { edit -> [Int] in if case let .refreshTracks(ids, _) = edit { ids } else { [] } }
        await appendChecked(edits, to: volumeKey, detail: UsbEditText.describe(.refreshTracks(usbContentIDs: ids, parts: []), library: nil))
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

    /// 초안의 목록 편집(만들기·옮기기·순서 바꾸기·지우기)을 읽은 라이브러리에 차례로 대 본 그 목록의 형제 순서(없거나 지웠으면 nil).
    /// 계획(`UsbEditPlanner`)과 같은 규칙: 순서 바꾸기는 나머지 사이 그 자리에 끼우고, 만들기·옮기기는 새 부모 끝에 붙인다.
    /// 읽은 순서는 사이드바와 같다(OneLibrary 순번 → Device Library 순번 → 번호)
    nonisolated static func siblingOrder(of target: PlaylistRef, library: UsbLibrary, edits: [UsbLibraryEdit]) -> [PlaylistRef]? {
        func order(_ item: UsbPlaylist) -> Int { item.sortOrder[.oneLibrary] ?? item.sortOrder[.deviceLibrary] ?? .max }
        var parents: [PlaylistRef: PlaylistRef] = [:], children: [PlaylistRef: [PlaylistRef]] = [:]
        for item in library.playlists.sorted(by: { (order($0), $0.id) < (order($1), $1.id) }) {
            let ref = PlaylistRef.id(String(item.id)), parent = item.parentID == 0 ? PlaylistRef.root : .id(String(item.parentID))
            parents[ref] = parent
            children[parent, default: []].append(ref)
        }
        /// 부모 목록에서 떼고 그 부모(없으면 nil)
        func detach(_ ref: PlaylistRef) -> PlaylistRef? {
            guard let parent = parents[ref] else { return nil }
            children[parent]?.removeAll { $0 == ref }
            return parent
        }
        func isInside(_ ref: PlaylistRef, _ folder: PlaylistRef) -> Bool {
            var cursor: PlaylistRef? = ref
            while let current = cursor {
                if current == folder { return true }
                cursor = parents[current]
            }
            return false
        }
        for case let .playlist(edit) in edits {
            switch edit {
            case let .create(key, _, _, parent):
                let ref = PlaylistRef.new(key)
                guard parents[ref] == nil else { continue }
                parents[ref] = parent
                children[parent, default: []].append(ref)
            case let .move(ref, into):
                // 자기 안으로 옮기기는 계획이 막는다
                guard parents[ref] != nil, !isInside(into, ref) else { continue }
                _ = detach(ref)
                parents[ref] = into
                children[into, default: []].append(ref)
            case let .reorder(ref, index):
                guard let parent = detach(ref) else { continue }
                var siblings = children[parent] ?? []
                siblings.insert(ref, at: min(max(index, 0), siblings.count))
                children[parent] = siblings
            case let .delete(ref):
                // 폴더를 지우면 그 아래도 없어진다
                var queue = [ref]
                while let next = queue.popLast() {
                    _ = detach(next)
                    parents[next] = nil
                    queue += children.removeValue(forKey: next) ?? []
                }
            case .rename, .addTracks, .removeTracks, .moveTracks:
                continue
            }
        }
        return parents[target].flatMap { children[$0] }
    }

    /// 같은 부모 안에서 사이드바 순서의 자리(0부터)와 형제 수. 초안의 목록 편집을 적용한 자리다(초안에서 지운 목록이면 nil)
    func siblingPosition(_ id: Int, volumeKey: String) -> (index: Int, count: Int)? {
        let ref = PlaylistRef.id(String(id))
        guard let library = usb.editLibrary(volumeKey),
              let siblings = Self.siblingOrder(of: ref, library: library, edits: usb.draftEdits[volumeKey] ?? []),
              let index = siblings.firstIndex(of: ref) else { return nil }
        return (index, siblings.count)
    }

    func canMovePlaylist(_ id: Int, by step: Int, volumeKey: String) -> Bool {
        guard let position = siblingPosition(id, volumeKey: volumeKey) else { return false }
        return (0..<position.count).contains(position.index + step)
    }

    /// 한 칸 옮기기가 막힐 까닭(볼륨·대상). 옮길 자리가 있는지는 `canMovePlaylist`가 본다
    func moveBlockReason(_ id: Int, by step: Int, volumeKey: String) -> String? {
        let index = siblingPosition(id, volumeKey: volumeKey).map { $0.index + step } ?? 0
        return blockReason(.playlist(edit: .reorder(playlist: .id(String(id)), index: index)), volumeKey: volumeKey)
    }

    /// 초안에 한 칸 옮기기를 더한 편집(옮길 자리가 없으면 nil). 바로 앞 편집이 같은 목록의 순서 바꾸기면 새로 쌓지 않고 그것을 고치고,
    /// 그 편집 전 자리로 돌아오면 뺀다. 자리는 초안의 목록 편집을 적용한 순서에서 센다(계획이 편집을 차례로 적용하는 것과 같다)
    nonisolated static func movedDraft(_ edits: [UsbLibraryEdit], playlist id: Int, by step: Int, library: UsbLibrary) -> [UsbLibraryEdit]? {
        let ref = PlaylistRef.id(String(id))
        guard let siblings = siblingOrder(of: ref, library: library, edits: edits), let index = siblings.firstIndex(of: ref),
              siblings.indices.contains(index + step) else { return nil }
        let target = index + step, move = UsbLibraryEdit.playlist(edit: .reorder(playlist: ref, index: target))
        guard case let .playlist(.reorder(last, _))? = edits.last, last == ref else { return edits + [move] }
        let earlier = Array(edits.dropLast())
        let start = siblingOrder(of: ref, library: library, edits: earlier)?.firstIndex(of: ref)
        return start == target ? earlier : earlier + [move]
    }

    /// 같은 부모 안에서 한 칸 올리거나 내린다(초안)
    func movePlaylist(_ id: Int, by step: Int, volumeKey: String) async {
        guard usb.acceptsEdits(volumeKey), let library = usb.editLibrary(volumeKey), canMovePlaylist(id, by: step, volumeKey: volumeKey) else { return }
        if let reason = moveBlockReason(id, by: step, volumeKey: volumeKey) {
            warnNotAdded(reason)
            return
        }
        let name = usb.editName(volumeKey) ?? "USB"
        switch await mutateDraft(volumeKey, { Self.movedDraft($0, playlist: id, by: step, library: library) }) {
        case let .success(change?):
            let created = UsbEditText.createdNames(change.after)
            if change.after.count < change.before.count {
                let playlist = library.playlists.first { $0.id == id }?.name ?? String(ui: "재생 목록 \(String(id))")
                host.toast = AppToast(kind: .success, title: String(ui: "USB 쓰기 대기에서 뺐습니다"),
                                      detail: String(ui: "\(name) · ‘\(playlist)’ 순서를 처음대로 돌렸습니다"), isUsb: true)
            } else if let last = change.after.last {
                let detail = "\(name) · \(UsbEditText.describe(last, library: library, created: created))"
                host.toast = AppToast(kind: .success, title: change.after.count > change.before.count ? String(ui: "USB 쓰기 대기에 더했습니다")
                                          : String(ui: "USB 쓰기 대기를 고쳤습니다"), detail: detail, isUsb: true)
            }
        case .success(nil):
            break
        case let .failure(error):
            draftFailed(error)
        }
    }
}

extension LibraryStore {
    /// 앱의 USB 초안 편집(사이드바 USB 절이 붙은 뒤에만)
    var usbEdits: UsbEditActions? { usb.map { UsbEditActions(usb: $0, host: self) } }

    /// USB 목록에서 고른 줄(표 순서, 같은 곡이 목록에 여러 번 있으면 줄마다)
    var selectedUsbRows: [TrackRow] { displayRows.filter { $0.isUsb && selection.contains($0.id) } }
}
