import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

struct UsbCueGridImportSummary: Sendable {
    var cueCount = 0
    var gridCount = 0
    var infoCount = 0
    var skippedCount = 0
    var details: [String] = []
    var message: String {
        let counts = String(ui: "큐 \(cueCount)곡·그리드 \(gridCount)곡·평점 \(infoCount)곡을 초안으로 가져왔습니다. \(skippedCount)곡은 건너뛰었습니다.")
        return details.first.map { counts + "\n" + $0 } ?? counts
    }
}

/// 기기의 값도 로컬 초안의 표현 범위를 벗어나면 덮어쓰지 않는다.
enum UsbCueGridDraftImport {
    static func uniqueLocalMatches(library: UsbLibrary, local: LocalLibraryKeys) -> [Int: String] {
        // 사이드바 배지는 비동기로 갱신된다. 지금 읽은 USB 사본과 같은 로컬 스냅샷으로만 짝을 확정한다.
        let fresh = UsbSyncBadges.evaluate(library: library, local: local).matches
        var counts: [String: Int] = [:]
        for track in library.tracks {
            if let id = fresh[track.id] { counts[id, default: 0] += 1 }
        }
        // 여러 USB 곡이 같은 로컬 곡을 가리키면 첫 곡을 임의로 고르지 않는다.
        return fresh.filter { counts[$0.value] == 1 }
    }

    /// 가져오는 칸. rekordbox의 "← CUE GRID INFO"는 로컬이 더 새로워도 USB 값으로 바꿨다(2026-10-08 실험 G5b: 로컬에서
    /// 더한 메모리 큐가 USB의 큐로 돌아갔다). 그래서 로컬 갱신 횟수는 보지 않고, 두 USB 형식이 서로 다를 때만 건너뛴다.
    enum Part: Sendable { case cue, grid, rating }

    static func formatConflictReason(_ part: Part, conflicts: Set<String>) -> String? {
        switch part {
        case .cue where conflicts.contains("cueUpdateCount"):
            String(ui: "두 USB 형식의 큐 갱신 횟수가 다르니 rekordbox에서 USB를 확인한 뒤 큐를 가져오세요.")
        case .grid where conflicts.contains("analysisDataUpdateCount"):
            String(ui: "두 USB 형식의 그리드 갱신 횟수가 다르니 rekordbox에서 USB를 확인한 뒤 그리드를 가져오세요.")
        case .rating where conflicts.contains("rating") || conflicts.contains("informationUpdateCount"):
            String(ui: "두 USB 형식의 평점이나 정보 갱신 횟수가 다르니 rekordbox에서 확인한 뒤 다시 가져오세요.")
        default: nil
        }
    }

    /// USB 평점을 초안의 평점 칸 값으로. 0(빈 평점)은 가져오지 않는다(nil): rekordbox도 USB 평점이 0인 곡의
    /// 로컬 평점을 지우지 않았다(2026-10-08 실험 G5b). 범위 밖이면 막는다.
    static func importedRating(_ rating: Int) throws -> String? {
        guard (0...5).contains(rating) else {
            throw issue(String(ui: "USB 평점이 별 0~5개 범위를 벗어나니 rekordbox에서 확인한 뒤 다시 가져오세요."))
        }
        return rating > 0 ? String(rating) : nil
    }

    static func cueDraft(uuid: String, local: [Cue], imported: [EditableCue], legacy: Bool) throws -> CueDraft {
        var draft = CueDraft(trackUUID: uuid, rekordboxCues: local)
        var unused = draft.base
        draft.cues = imported.map { incoming in
            var cue = incoming
            let index = unused.firstIndex { old in
                old.kind == cue.kind && (cue.kind != .memory || abs(old.time - cue.time) < 0.001)
            }
            if let index {
                let old = unused.remove(at: index)
                cue.id = old.id
                cue.sourceID = old.sourceID
                // PCOB에는 이름 칸이 없다. 같은 원본 큐의 이름을 빈칸으로 지우지 않는다.
                if legacy { cue.name = old.name }
            }
            return cue
        }
        guard draft.hasChanges else { return draft }
        guard !local.contains(where: { ($0.colorTableIndex ?? 0) != 0 || (1...8).contains($0.color ?? 255) }) else {
            throw issue(String(ui: "로컬 색 큐를 초안으로 보존할 수 없으니 rekordbox에서 직접 가져오세요."))
        }
        guard !local.contains(where: { $0.activeLoop != 0 }) else {
            throw issue(String(ui: "로컬 활성 루프를 초안으로 보존할 수 없으니 rekordbox에서 직접 가져오세요."))
        }
        guard !legacy || !local.contains(where: \.isLoop) else {
            throw issue(String(ui: "확장 큐 정보가 없어 로컬 루프 정보를 보존할 수 없으니 rekordbox에서 직접 가져오세요."))
        }
        return draft
    }

    static func gridDraft(uuid: String, local: BeatGrid, imported: BeatGrid, duration: Double) throws -> GridDraft {
        guard duration > 0, duration.isFinite, !imported.beats.isEmpty,
              imported.beats.allSatisfy({ $0.time >= 0 && $0.time <= duration + 1 }) else {
            throw issue(String(ui: "박 위치가 곡 길이를 벗어나니 rekordbox에서 그리드를 확인한 뒤 다시 가져오세요."))
        }
        guard canRepresent(local, duration: duration), canRepresent(imported, duration: duration) else {
            throw issue(String(ui: "이 그리드의 박 위치나 박 번호를 초안으로 보존할 수 없으니 rekordbox에서 직접 가져오세요."))
        }
        let draft = GridDraft(trackUUID: uuid, base: GridDraft.segments(from: local), segments: GridDraft.segments(from: imported))
        // 경계 처리는 base에 따라 달라지므로 실제 반환 초안에서도 USB의 모든 박을 검사한다.
        let rebuilt = draft.grid(duration: max(duration + 1, imported.beats.last!.time + 0.01))
        guard preservesBeats(imported, in: rebuilt) else {
            throw issue(String(ui: "이 그리드의 박 위치나 박 번호를 초안으로 보존할 수 없으니 rekordbox에서 직접 가져오세요."))
        }
        return draft
    }

    private static func canRepresent(_ grid: BeatGrid, duration: Double) -> Bool {
        guard !grid.beats.isEmpty else { return true }
        guard grid.beats.allSatisfy({ $0.time.isFinite && $0.time >= 0 && GridDraft.bpmRange.contains($0.bpm) && (1...4).contains($0.number) }),
              zip(grid.beats, grid.beats.dropFirst()).allSatisfy({ $0.time < $1.time }) else { return false }
        let rebuilt = GridDraft(trackUUID: "", grid: grid).grid(duration: max(duration + 1, grid.beats.last!.time + 0.01))
        return preservesBeats(grid, in: rebuilt)
    }

    private static func preservesBeats(_ source: BeatGrid, in rebuilt: BeatGrid) -> Bool {
        // 가장 가까운 박의 시각만 비교하면 박 번호의 불연속을 놓친다.
        return source.beats.allSatisfy { beat in
            let index = rebuilt.firstIndex(atOrAfter: beat.time - 0.002)
            return [index - 1, index, index + 1].filter { rebuilt.beats.indices.contains($0) }.contains { i in
                let other = rebuilt.beats[i]
                return abs(other.time - beat.time) <= 0.002 && other.number == beat.number && abs(other.bpm - beat.bpm) < 0.005
            }
        }
    }

    static func issue(_ message: String) -> UsbCueGridReader.ReadFailure { .init(message: message) }
}

@MainActor
extension LibraryStore {
    /// USB를 읽고 로컬 큐·그리드·평점 초안만 만든다. rekordbox와 USB에 쓰는 것은 별도의 반영 동작이다.
    func importUsbCueGrid(volumeKey: String) async -> UsbCueGridImportSummary {
        var summary = UsbCueGridImportSummary()
        guard !isLoading, !isWritingRekordbox, !isSynchronizingLibrary, allowsLibrarySync?() != false,
              let snapshot = snapshotURL, let usb, let volume = usb.volume(volumeKey),
              let library = usb.libraries[volumeKey], !usb.ejecting.contains(volumeKey) else {
            summary.details = [String(ui: "로컬 라이브러리와 USB를 다 읽고 편집을 마친 뒤 다시 가져오세요.")]
            summary.skippedCount = 1
            return summary
        }
        guard let _ = usb.beginWrite(volume, title: String(ui: "USB의 큐와 그리드 읽는 중"), cancellable: false) else {
            summary.details = [String(ui: "USB 작업이 진행 중이니 끝난 뒤 다시 가져오세요.")]
            summary.skippedCount = library.tracks.count
            return summary
        }
        defer { usb.endWrite(volumeKey) }
        let revision = previewRevision
        let rows = rowsByID
        let home = draftHome ?? DJCPaths.userData
        let share = rekordboxShareRoot ?? RekordboxShare.directory
        let scratch = home.appending(path: "usb-snapshots").appending(path: "import-\(UUID().uuidString)")
        do {
            let plan = try await Task.detached(priority: .userInitiated) {
                let checked = try UsbRead.currentVolume(matching: volume)
                return try UsbCueGridImportPlan.read(volume: checked, snapshot: snapshot, share: share, scratch: scratch,
                                                     rows: rows)
            }.value
            guard !Task.isCancelled, snapshotURL == snapshot, previewRevision == revision,
                  !isLoading, !isWritingRekordbox, !isSynchronizingLibrary,
                  allowsLibrarySync?() != false, usb.volume(volumeKey) == volume,
                  plan.rows.allSatisfy({ rowsByID[$0.row.track.id] == $0.row }) else {
                summary.details = [String(ui: "읽는 동안 라이브러리나 편집 상태가 바뀌었으니 편집을 마친 뒤 다시 가져오세요.")]
                summary.skippedCount = library.tracks.count
                return summary
            }
            let cueDirectory = home.appending(path: "cue-drafts"), gridDirectory = home.appending(path: "grid-drafts")
            let tagDirectory = home.appending(path: "tag-drafts")
            DraftWriter.flush()
            var importedCues: [String: CueDraft] = [:]
            for item in plan.rows {
                let uuid = item.row.track.uuid
                var reasons = item.reasons
                if let draft = item.cues, draft.hasChanges {
                    if hasDraft(.cue, trackUUID: uuid) || DraftWriter.pendingCue(trackUUID: uuid, directory: cueDirectory) != nil
                        || recoveryMemoryInput?(uuid, .cues)?.hasChanges == true
                        || FileManager.default.fileExists(atPath: cueDirectory.appending(path: "\(uuid).json").path) {
                        reasons.append(String(ui: "큐 초안이 이미 있으니 먼저 반영하거나 버린 뒤 다시 가져오세요."))
                    } else {
                        do {
                            try CueDraftStore.save(draft, directory: cueDirectory)
                            cueDraftChanged(draft)
                            draftChanged(trackUUID: uuid, kind: .cue, exists: true)
                            importedCues[uuid] = draft
                            summary.cueCount += 1
                        } catch { reasons.append(Self.usbImportSaveFailure) }
                    }
                }
                if let draft = item.grid, draft.hasChanges {
                    if hasDraft(.grid, trackUUID: uuid) || DraftWriter.pendingGrid(trackUUID: uuid, directory: gridDirectory) != nil
                        || recoveryMemoryInput?(uuid, .grid)?.hasChanges == true
                        || FileManager.default.fileExists(atPath: gridDirectory.appending(path: "\(uuid).json").path) {
                        reasons.append(String(ui: "그리드 초안이 이미 있으니 먼저 반영하거나 버린 뒤 다시 가져오세요."))
                    } else {
                        do {
                            try GridDraftStore.save(draft, directory: gridDirectory)
                            draftChanged(trackUUID: uuid, kind: .grid, exists: true)
                            onGridDraftSaved?(uuid)
                            summary.gridCount += 1
                        } catch { reasons.append(Self.usbImportSaveFailure) }
                    }
                }
                if let draft = item.info, draft.hasChanges {
                    if tagDrafts[uuid] != nil || FileManager.default.fileExists(atPath: tagDirectory.appending(path: "\(uuid).json").path) {
                        reasons.append(String(ui: "태그 초안이 이미 있으니 먼저 반영하거나 버린 뒤 다시 가져오세요."))
                    } else {
                        do {
                            try TagDraftStore.save(draft, directory: tagDirectory)
                            tagDrafts[uuid] = draft
                            tagRevision += 1
                            updateEdited(uuid)
                            summary.infoCount += 1
                        } catch { reasons.append(Self.usbImportSaveFailure) }
                    }
                }
                if !reasons.isEmpty {
                    summary.skippedCount += 1
                    summary.details += reasons.map { item.row.track.title + ": " + $0 }
                }
            }
            summary.skippedCount += plan.unmatchedCount
            if plan.unmatchedCount > 0 {
                summary.details.append(String(ui: "로컬 곡과 짝이 하나로 맞지 않는 \(plan.unmatchedCount)곡은 가져오지 않았으니 원본 라이브러리를 확인하세요."))
            }
            // 덱의 다른 곡 초안을 nil로 다시 읽어 버리지 않게 지금 덱 곡을 포함한 전체 초안을 넘긴다.
            if !importedCues.isEmpty {
                var drafts: [String: CueDraft] = [:]
                for uuid in pendingUUIDs where hasDraft(.cue, trackUUID: uuid) {
                    drafts[uuid] = DraftWriter.pendingCue(trackUUID: uuid, directory: cueDirectory)
                        ?? CueDraftStore.load(trackUUID: uuid, directory: cueDirectory)
                }
                onCueDraftsReloaded?(drafts)
            }
            refreshUnlinkedDrafts()
            if case .pending = sidebar { refreshBase() }
            return summary
        } catch {
            summary.skippedCount = library.tracks.count
            summary.details = [(error as? UsbCueGridReader.ReadFailure)?.message
                ?? String(ui: "USB 정보를 읽지 못했으니 기기 사용을 마치고 USB를 다시 연결한 뒤 가져오세요.")]
            return summary
        }
    }

    private static var usbImportSaveFailure: String {
        String(ui: "초안을 저장하지 못했으니 DJCrate 데이터 폴더의 쓰기 권한을 확인한 뒤 다시 가져오세요.")
    }
}

private struct UsbCueGridImportPlan: Sendable {
    struct Row: Sendable {
        var row: TrackRow
        var cues: CueDraft?
        var grid: GridDraft?
        var info: TagDraft?
        var reasons: [String] = []
    }
    var rows: [Row] = []
    var unmatchedCount = 0

    static func read(volume: UsbVolumeInfo, snapshot: URL, share: URL, scratch: URL,
                     rows: [String: TrackRow]) throws -> Self {
        let root = UsbRoot(URL(filePath: volume.mountPoint))
        let copy = try UsbSnapshot.take(root: root, into: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let one = try copy.oneLibrary.map { try OneLibraryReader.read(copyAt: $0) }
        let device = try PdbReader.read(snapshot: copy)
        guard device?.1.issues.isEmpty != false else {
            throw UsbCueGridDraftImport.issue(String(ui: "Device Library 구조가 맞지 않으니 rekordbox에서 USB를 확인한 뒤 다시 가져오세요."))
        }
        let (library, mismatches) = UsbLibrary.merge(oneLibrary: one, deviceLibrary: device?.0)
        let localDatabase = try CipherDatabase(path: snapshot.path, key: .hex(RekordboxKey.derive()), mode: .readOnly)
        defer { localDatabase.close() }
        _ = try UsbLocalSource(database: localDatabase).localDBID()
        let local = try LocalLibraryKeys.load(database: localDatabase)
        let snapshotTime = try UsbSnapshotTime.resolve(explicit: nil, database: snapshot).date
        let freshMatches = UsbCueGridDraftImport.uniqueLocalMatches(library: library, local: local)
        var cueRows: Set<Int> = []
        if let url = copy.oneLibrary {
            let database = try CipherDatabase(path: url.path, key: .passphrase(RekordboxKey.oneLibrary()), mode: .readOnly)
            defer { database.close() }
            try database.query("SELECT DISTINCT content_id FROM cue") { if let id = $0.int(0) { cueRows.insert(id) } }
        }
        var result = Self()
        for track in library.tracks {
            guard let id = freshMatches[track.id], let row = rows[id], !row.track.isStreaming else {
                result.unmatchedCount += 1
                continue
            }
            var item = Row(row: row)
            let conflicts = mismatches.compactMap { mismatch -> String? in
                switch mismatch {
                case let .trackFieldDiffers(id, field) where id == track.id: return field
                case let .trackOnlyIn(_, id) where id == track.id: return "identity"
                case let .trackPathDiffers(id) where id == track.id: return "identity"
                default: return nil
                }
            }
            if conflicts.contains("identity") || conflicts.contains("masterDbId") || conflicts.contains("masterContentId") {
                item.reasons.append(String(ui: "두 USB 형식의 곡 연결이 다르니 rekordbox에서 USB를 확인한 뒤 다시 가져오세요."))
                result.rows.append(item)
                continue
            }
            let conflictSet = Set(conflicts)
            if let reason = UsbCueGridDraftImport.formatConflictReason(.rating, conflicts: conflictSet) {
                item.reasons.append(reason)
            } else {
                do {
                    if let rating = try UsbCueGridDraftImport.importedRating(track.rating) {
                        var info = TagDraft(track: row.track)
                        info.fields.rating = rating
                        if info.hasChanges, let reason = TrackListTagEditing.unavailableReason(row, key: .rating) {
                            item.reasons.append(reason)
                        } else { item.info = info }
                    }
                } catch { item.reasons.append(reason(error)) }
            }
            if conflicts.contains("analysisDataPath") || conflicts.contains("fileType") || conflicts.contains("fileSize") {
                item.reasons.append(String(ui: "두 USB 형식의 분석 파일 정보가 다르니 rekordbox에서 확인한 뒤 다시 가져오세요."))
                result.rows.append(item)
                continue
            }
            do {
                let source = try UsbCueGridReader.read(root: root, track: track)
                if cueRows.contains(track.id) {
                    item.reasons.append(String(ui: "OneLibrary 기기 큐 행의 해석을 확인하지 못했으니 큐는 rekordbox에서 직접 가져오세요."))
                } else if let reason = UsbCueGridDraftImport.formatConflictReason(.cue, conflicts: conflictSet) {
                    item.reasons.append(reason)
                } else if let cues = source.cues {
                    do {
                        let draft = try UsbCueGridDraftImport.cueDraft(uuid: row.track.uuid, local: row.cues, imported: cues, legacy: source.usesLegacyCues)
                        guard draft.issues(duration: Double(row.track.lengthSeconds) + 1).isEmpty,
                              draft.cues.allSatisfy({ ($0.loop?.end ?? $0.time) <= Double(row.track.lengthSeconds) + 1 }) else {
                            throw UsbCueGridDraftImport.issue(String(ui: "큐나 루프 위치가 곡 길이를 벗어나니 rekordbox에서 확인한 뒤 다시 가져오세요."))
                        }
                        item.cues = draft
                    } catch { item.reasons.append(reason(error)) }
                } else if let issue = source.cueIssue { item.reasons.append(issue) }
                if let reason = UsbCueGridDraftImport.formatConflictReason(.grid, conflicts: conflictSet) {
                    item.reasons.append(reason)
                } else if let grid = source.grid {
                    do {
                        guard let dat = RekordboxShare.analysisURL(row.track.analysisDataPath, root: share),
                              FileManager.default.fileExists(atPath: dat.path),
                              FileManager.default.fileExists(atPath: dat.deletingPathExtension().appendingPathExtension("EXT").path) else {
                            throw UsbCueGridDraftImport.issue(String(ui: "로컬 파형 분석 파일이 없으니 rekordbox에서 곡을 분석한 뒤 그리드를 가져오세요."))
                        }
                        let access = SnapshotFileAccess.posix
                        let ext = dat.deletingPathExtension().appendingPathExtension("EXT")
                        guard let datStamp = try access.stat(dat), let extStamp = try access.stat(ext),
                              datStamp.isRegularFile, extStamp.isRegularFile,
                              datStamp.modificationDate <= snapshotTime, extStamp.modificationDate <= snapshotTime else {
                            throw UsbCueGridDraftImport.issue(String(ui: "로컬 분석 파일이 스냅샷 뒤에 바뀌었으니 새 스냅샷을 뜬 뒤 그리드를 가져오세요."))
                        }
                        let localGrid = try BeatGrid.load(anlz: dat)
                        guard try access.stat(dat) == datStamp, try access.stat(ext) == extStamp else {
                            throw UsbCueGridDraftImport.issue(String(ui: "읽는 동안 로컬 분석 파일이 바뀌었으니 새 스냅샷을 뜬 뒤 그리드를 가져오세요."))
                        }
                        item.grid = try UsbCueGridDraftImport.gridDraft(uuid: row.track.uuid, local: localGrid,
                                                                       imported: grid, duration: Double(row.track.lengthSeconds))
                    } catch { item.reasons.append(reason(error)) }
                } else if let issue = source.gridIssue { item.reasons.append(issue) }
            } catch { item.reasons.append(reason(error)) }
            result.rows.append(item)
        }
        // 사본을 읽는 동안 매체 DB가 바뀌었으면 섞인 시점의 초안을 만들지 않는다.
        guard try unchanged(copy.fingerprint, root: root) else {
            throw UsbCueGridDraftImport.issue(String(ui: "읽는 동안 USB 라이브러리가 바뀌었으니 기기 사용을 마친 뒤 다시 가져오세요."))
        }
        _ = try UsbRead.currentVolume(matching: volume)
        return result
    }

    private static func unchanged(_ fingerprint: UsbFingerprint, root: UsbRoot) throws -> Bool {
        let access = SnapshotFileAccess.posix
        let paths = [UsbLayout.oneLibrary, UsbLayout.exportPdb, UsbLayout.exportExtPdb]
            + UsbLayout.oneLibrarySidecarSuffixes.map { UsbLayout.oneLibrary + $0 }
        for path in paths {
            let url = try root.url(for: path)
            let stamp = try access.stat(url)
            guard let old = fingerprint.files[path] else {
                if stamp != nil { return false }
                continue
            }
            guard let stamp, stamp.isRegularFile, stamp.size == old.size, stamp.modificationDate == old.mtime,
                  try access.sha256(url) == old.sha256 else { return false }
        }
        return true
    }

    private static func reason(_ error: any Error) -> String {
        (error as? UsbCueGridReader.ReadFailure)?.message
            ?? String(ui: "큐나 그리드를 읽지 못했으니 rekordbox에서 이 곡을 확인한 뒤 다시 가져오세요.")
    }
}
