import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation

/// 백그라운드 그리드 추정 한 건.
struct GridJobItem: Sendable, Hashable {
    var uuid: String
    var path: String
    /// 추가한 곡이면 추정 BPM을 목록에도 적어 두고, 키도 찾는다.
    var staged: Bool
    /// 그리드도 추정할지(추가한 곡의 키만 남았으면 false)
    var grid = true
}

struct GridJob: Sendable {
    var done: Int
    var total: Int
}

/// 곡 추가(아직 rekordbox에 없는 곡) · 그리드 일괄 추정 · rekordbox XML 내보내기.
extension LibraryStore {
    // MARK: - 추가한 곡

    func loadStaged() {
        staged = StagingStore.load()
        verifyImports()
        resolvePlaylistImports()
        rebuildStagedRows()
        // 지난번에 추정을 마치지 못한 곡(그리드·키)을 이어서 한다.
        enqueueGrid(staged.filter { $0.bpm == nil || $0.needsKey }.map {
            GridJobItem(uuid: $0.uuid, path: $0.path, staged: true, grid: $0.bpm == nil)
        })
    }

    func rebuildStagedRows() {
        for row in stagedRows { rowsByID[row.id] = nil; rowsByUUID[row.track.uuid] = nil }
        stagedRows = staged.map {
            var row = TrackRow(track: $0.track, cues: [], playCount: 0, commentRule: commentPreset.rule)
            row.keyEstimated = $0.keyEstimated
            return row
        }
        for row in stagedRows { rowsByID[row.id] = row; rowsByUUID[row.track.uuid] = row }
        if case .staged = sidebar { refreshBase() }
    }

    private func persistStaged() {
        do { try stagingSaver(staged) } catch { stagingMessage = AppMessage(kind: .failure, text: String(ui: "추가한 곡 목록을 저장하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하세요: \(error.localizedDescription)")) }
    }

    /// 파일·폴더를 추가한다. 이미 rekordbox 컬렉션에 있는 파일은 건너뛴다
    /// (XML로 다시 가져오면 rekordbox의 기존 큐·그리드를 덮을 수 있다).
    func addFiles(_ urls: [URL], appleMusicOrigins: [String: [AppleMusicOrigin]] = [:],
                  createPlaylists: Bool = false, toPlaylist playlistID: String? = nil) async {
        guard writeLockPolicy.allowsLibraryInteraction,
              playlistID.map({ canEditTracks(of: $0) }) ?? true else { return }
        let files = StagedTrack.audioFiles(in: urls)
        guard !files.isEmpty else {
            stagingMessage = AppMessage(kind: .warning, text: String(ui: "추가할 음원이 없습니다. MP3·M4A·WAV·AIFF·FLAC 파일을 고르세요."))
            return
        }
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }
        let inLibrary = Dictionary(rows.map { (key($0.track.folderPath), $0) }, uniquingKeysWith: { first, _ in first })
        let stagedByPath = Dictionary(staged.map { (key($0.path), $0.id) }, uniquingKeysWith: { first, _ in first })
        var known = Set(stagedByPath.keys)
        let today = String(ISO8601DateFormatter().string(from: .now).prefix(10))
        var added: [StagedTrack] = [], libraryRows: [TrackRow] = [], stagedIDs: [String] = [], failed = 0
        var originsChanged = false
        for url in files {
            let path = key(url.path)
            // 이미 rekordbox에 있는 곡은 추가하지 않고 그 곡을 바로 연다(XML로 다시 가져오면 기존 큐를 덮을 수 있다).
            if let row = inLibrary[path] { libraryRows.append(row); continue }
            if let id = stagedByPath[path] {
                stagedIDs.append(id)
                if let origins = appleMusicOrigins[path], let index = staged.firstIndex(where: { $0.id == id }) {
                    staged[index].rememberAppleMusicOrigins(origins)
                    originsChanged = true
                }
                continue
            }
            if known.contains(path) { continue }
            do {
                var track = try await StagedTrack.make(fileAt: url, addedOn: today)
                track.rememberAppleMusicOrigins(appleMusicOrigins[path] ?? [])
                added.append(track)
                known.insert(path)
            } catch {
                failed += 1
            }
        }
        // 태그를 읽는 동안 반영이 시작되면 추가 목록도 바꾸지 않는다.
        guard writeLockPolicy.allowsLibraryInteraction else { return }
        stagingMessage = nil
        staged += added
        if !added.isEmpty || originsChanged {
            persistStaged()
            rebuildStagedRows()
        }
        if createPlaylists || playlistID != nil {
            let paths = added.map(\.path) + staged.filter { stagedIDs.contains($0.id) }.map(\.path) + libraryRows.map(\.track.folderPath)
            var imports = playlistImports
            if createPlaylists {
                let accepted = Set(paths.map(key))
                imports.addAppleMusic(appleMusicOrigins.filter { accepted.contains($0.key) })
            }
            if let playlistID { imports.addFiles(paths, to: PlaylistRef(playlistID)) }
            if savePlaylistImports(imports) {
                resolvePlaylistImports()
            } else {
                stagingMessage = AppMessage(kind: .failure, text: playlistMessage?.text ?? String(ui: "재생 목록 연결을 저장하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하고 다시 시도하세요."))
            }
        }
        var parts: [String] = []
        if !added.isEmpty { parts.append(String(ui: "\(added.count)곡 추가")) }
        if !libraryRows.isEmpty { parts.append(String(ui: "rekordbox에 이미 있는 \(libraryRows.count)곡을 골랐습니다")) }
        if !stagedIDs.isEmpty { parts.append(String(ui: "이미 추가한 \(stagedIDs.count)곡을 골랐습니다")) }
        if failed > 0 { parts.append(String(ui: "\(failed)곡은 읽지 못함")) }
        if createPlaylists || playlistID != nil {
            parts.append(String(ui: "컬렉션에 들어간 곡은 재생 목록 초안에 연결합니다. 목록은 ‘rekordbox에 쓰기’로 만듭니다."))
        }
        if stagingMessage?.kind != .failure {
            stagingMessage = AppMessage(kind: failed > 0 ? .warning : .success, text: parts.joined(separator: " · "))
        }
        // 넣은 곡은 목록에서 골라 보여 주기만 한다. 덱은 그대로 둔다(덱에 올리기는 더블클릭·⌘→, #93).
        if !added.isEmpty || (!stagedIDs.isEmpty && libraryRows.isEmpty) {
            // 새 곡(또는 이미 추가한 곡)은 "추가한 곡"에서 고른다.
            sidebar = .staged
            selection = Set(added.map(\.id) + stagedIDs)
        } else if let first = libraryRows.first {
            // rekordbox 곡: 지금 목록에 없으면 "전체"로 바꿔 고른다.
            if !displayRows.contains(where: { $0.id == first.id }) { sidebar = .filter(.all); search = "" }
            selection = Set(libraryRows.map(\.id))
        }
        enqueueGrid(added.map { GridJobItem(uuid: $0.uuid, path: $0.path, staged: true) })
    }

    func removeStaged(_ ids: Set<TrackRow.ID>) {
        let removing = staged.filter { ids.contains($0.id) }
        guard !removing.isEmpty else { return }
        var imports = playlistImports
        imports.removePending(paths: Set(removing.map(\.path)))
        guard savePlaylistImports(imports) else { return }
        let uuids = Set(removing.map(\.uuid))
        gridQueue.removeAll { uuids.contains($0.uuid) }
        stagingMessage = nil
        staged.removeAll { ids.contains($0.id) }
        persistStaged()
        selection.subtract(ids)
        rebuildStagedRows()
        refreshDeckTrack()
        if stagingMessage?.kind != .failure {
            stagingMessage = AppMessage(text: String(ui: "\(removing.count)곡을 추가 목록에서 뺐습니다(파일은 그대로)."))
        }
    }

    /// rekordbox에 바로 넣은 곡을 추가 목록에서 뺀다(초안은 남긴다: 되돌리면 다시 붙는다). 뺀 곡을 돌려준다.
    func unstage(uuids: Set<String>) -> [StagedTrack] {
        let removing = staged.filter { uuids.contains($0.uuid) }
        guard !removing.isEmpty else { return [] }
        gridQueue.removeAll { uuids.contains($0.uuid) }
        staged.removeAll { uuids.contains($0.uuid) }
        persistStaged()
        selection.subtract(removing.map(\.id))
        rebuildStagedRows()
        return removing
    }

    /// 되돌린 곡을 추가 목록에 다시 넣는다(이미 있는 곡은 건너뜀). 넣은 곡 수.
    func restage(_ tracks: [StagedTrack]) -> Int {
        let known = Set(staged.map(\.uuid))
        let fresh = tracks.filter { !known.contains($0.uuid) }
        guard !fresh.isEmpty else { return 0 }
        staged += fresh
        persistStaged()
        rebuildStagedRows()
        return fresh.count
    }

    // MARK: - 가져오기 뒤 확인

    /// 새 스냅샷에 추가한 곡과 같은 경로의 곡이 있으면(= rekordbox로 가져옴) 그리드를 비교해 적어 둔다.
    /// 둘 다 rekordbox 시간축이라 그대로 비교한다. 어긋나면 인코더 지연 규칙이 그 파일에서 틀린 것이다.
    func verifyImports() {
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }
        let byPath = Dictionary(rows.map { (key($0.track.folderPath), $0) }, uniquingKeysWith: { first, _ in first })
        let today = String(ISO8601DateFormatter().string(from: .now).prefix(10))
        var changed = false
        for index in staged.indices {
            guard let row = byPath[key(staged[index].path)] else { continue }
            let check = Self.compareImported(staged[index], with: row.track, today: today)
            if staged[index].importCheck != check {
                staged[index].importCheck = check
                changed = true
            }
        }
        if changed { persistStaged() }
        let checked = staged.compactMap(\.importCheck)
        guard !checked.isEmpty else { return }
        let counts = Dictionary(grouping: checked, by: \.result).mapValues(\.count)
        var parts = [String(ui: "rekordbox 가져오기 확인 \(checked.count)곡")]
        if let n = counts[.matched] { parts.append(String(ui: "그리드 일치 \(n)")) }
        if let n = counts[.shifted] { parts.append(String(ui: "박 어긋남 \(n)")) }
        if let n = counts[.reanalyzed] { parts.append(String(ui: "rekordbox가 재분석 \(n)")) }
        if let n = counts[.pending] { parts.append(String(ui: "분석 대기 \(n)")) }
        if let n = counts[.noGrid] { parts.append(String(ui: "그리드 없이 보냄 \(n)")) }
        guard stagingMessage?.kind != .failure else { return }
        stagingMessage = AppMessage(kind: checked.allSatisfy { $0.result == .matched } ? .success : .warning, text: parts.joined(separator: " · "))
    }

    nonisolated static func compareImported(_ staged: StagedTrack, with track: Track, today: String) -> StagedTrack.ImportCheck {
        let imported = RekordboxShare.analysisURL(track.analysisDataPath).flatMap { try? BeatGrid.load(anlz: $0) }
        return .compare(sent: GridDraftStore.load(trackUUID: staged.uuid)?.segments ?? [], imported: imported,
                        duration: Double(track.lengthSeconds), checkedOn: today)
    }

    /// rekordbox로 가져온 게 확인된 곡을 추가 목록에서 뺀다(초안은 그대로 둔다).
    func removeImportedStaged() {
        let ids = Set(staged.filter { $0.importCheck != nil && $0.importCheck?.result != .pending }.map(\.id))
        removeStaged(ids)
    }

    // MARK: - 그리드 일괄 추정

    /// 초안이 없는 곡만 순서대로 추정해 그리드 초안으로 저장한다(rekordbox 시간축).
    func enqueueGrid(_ items: [GridJobItem]) {
        let queued = Set(gridQueue.map(\.uuid))
        let fresh = items.filter { !queued.contains($0.uuid) }
        guard !fresh.isEmpty else { return }
        gridQueue += fresh
        if gridJob == nil { gridJob = GridJob(done: 0, total: 0) }
        gridJob?.total += fresh.count
        if gridTask == nil {
            gridTask = Task { [weak self] in await self?.runGridQueue() }
        }
    }

    /// 지금 보이는 "BPM·그리드 없음" 곡을 모두 추정한다.
    func estimateGridsForDisplayedRows() {
        enqueueGrid(displayRows.filter { !$0.track.isStreaming }.map {
            GridJobItem(uuid: $0.track.uuid, path: $0.track.folderPath, staged: $0.isStaged)
        })
    }

    private func runGridQueue() async {
        while !gridQueue.isEmpty {
            let item = gridQueue.removeFirst()
            if item.grid { await estimateGrid(item) }
            // 키는 그리드 뒤에 본다(마디 창을 쓰려고).
            if item.staged { await findKey(item) }
            gridJob?.done += 1
        }
        gridJob = nil
        gridTask = nil
    }

    /// 지금의 그리드 초안. 저장에 실패해 DraftWriter에만 남은 입력이 디스크보다 최신이다.
    private func currentGridDraft(_ uuid: String) -> GridDraft? {
        if let pending = DraftWriter.pendingGrid(trackUUID: uuid) { return pending.hasChanges ? pending : nil }
        return GridDraftStore.load(trackUUID: uuid)
    }

    private func estimateGrid(_ item: GridJobItem) async {
        let url = URL(filePath: item.path)
        if let existing = currentGridDraft(item.uuid) {
            // 덱에서 이미 적용했거나 편집한 곡: 목록 BPM만 맞춘다.
            if item.staged { updateStaged(item.uuid, bpm: existing.segments.first?.bpm, confident: nil) }
            return
        }
        guard FileManager.default.fileExists(atPath: item.path),
              let estimate = try? await gridEstimator(url, item.uuid) else { return }
        // 추정하는 동안 덱에서 초안을 만들었으면 덮지 않는다.
        guard currentGridDraft(item.uuid) == nil else { return }
        let offset = RekordboxTimeline.predictedOffset(url: url)
        let draft = GridDraft(trackUUID: item.uuid, base: [], segments: estimate.segments).shifted(by: offset)
        // 바로 뒤 키 찾기·덱이 디스크의 초안을 읽으니 저장을 끝낸다. 실패해도 입력은 DraftWriter에 남는다.
        DraftWriter.save(draft)
        if let failure = DraftWriter.flush().first(where: { $0.kind == .grid && $0.trackUUID == item.uuid }) {
            reportLibraryError(failure.message)
        }
        draftChanged(trackUUID: item.uuid, kind: .grid, exists: true)
        if item.staged { updateStaged(item.uuid, bpm: estimate.bpm, confident: estimate.isConfident) }
        onGridDraftSaved?(item.uuid)
    }

    private func updateStaged(_ uuid: String, bpm: Double?, confident: Bool?) {
        guard let index = staged.firstIndex(where: { $0.uuid == uuid }) else { return }
        staged[index].bpm = bpm
        if let confident { staged[index].gridConfident = confident }
        persistStaged()
        rebuildStagedRows()
    }

    // MARK: - 추가한 곡 키

    /// 태그에 키가 없던 곡은 조성을 추정해 staged.json에 적어 둔다(다음 실행 때 다시 계산하지 않는다).
    private func findKey(_ item: GridJobItem) async {
        guard let track = staged.first(where: { $0.uuid == item.uuid }), track.needsKey,
              FileManager.default.fileExists(atPath: item.path) else { return }
        let url = URL(filePath: item.path)
        let grid = GridDraftStore.load(trackUUID: item.uuid)?.grid(duration: track.duration)
        guard let found = await Self.stagedKey(fileAt: url, grid: grid, offset: RekordboxTimeline.predictedOffset(url: url),
                                               duration: track.duration, cacheKey: item.uuid) else { return }
        setStagedKey(uuid: item.uuid, key: found.key, source: found.source)
    }

    /// 태그의 키, 없으면 곡 전체의 주 조성 추정(덱과 같은 크로마·마디 창). 파일을 읽지 못하면 nil(다음에 다시 본다).
    /// `grid`는 rekordbox 시간축이라 `offset`만큼 당겨 크로마(음원 시간축)에 맞춘다. 크로마는 덱과 같은 캐시를 쓴다.
    nonisolated static func stagedKey(fileAt url: URL, grid: BeatGrid?, offset: Double, duration: Double,
                                      cacheKey: String?) async -> (key: String?, source: StagedTrack.KeySource)? {
        if let tag = await StagedTrack.tagKey(fileAt: url) { return (tag, .tag) }
        return await Task.detached(priority: .utility) { () -> (key: String?, source: StagedTrack.KeySource)? in
            let chroma: KeyAnalyzer.Chroma
            if let cacheKey, let cached = AnalysisCache.chroma(key: cacheKey, file: url) {
                chroma = cached
            } else {
                guard let computed = try? KeyAnalyzer.chroma(fileAt: url) else { return nil }
                if let cacheKey { AnalysisCache.store(computed, key: cacheKey, file: url) }
                chroma = computed
            }
            let windows = KeyAnalyzer.windows(grid: grid, duration: duration).map { ($0.0 - offset, $0.1 - offset) }
            // 소리가 없어 조성을 못 찾아도 추정한 것으로 적어 두어 되풀이하지 않는다.
            return (KeyAnalyzer.mainKey(chroma: chroma, windows: windows)?.camelot, .estimate)
        }.value
    }

    func setStagedKey(uuid: String, key: String?, source: StagedTrack.KeySource) {
        guard let index = staged.firstIndex(where: { $0.uuid == uuid }) else { return }
        staged[index].key = key
        staged[index].keySource = source
        persistStaged()
        rebuildStagedRows()
    }

    /// 덱에서 추가한 곡의 그리드를 바꾸면 목록 BPM도 맞춘다.
    func stagedGridChanged(uuid: String, bpm: Double?) {
        guard let index = staged.firstIndex(where: { $0.uuid == uuid }), staged[index].bpm != bpm else { return }
        staged[index].bpm = bpm
        persistStaged()
        rebuildStagedRows()
    }

    // MARK: - 개발용 검증

    /// 개발용: `--add-files <경로,…>`로 곡을 추가하고, 그리드 추정이 끝나면 `--export-staged <파일>`로 내보낸다.
    /// `DJC_HOME`과 함께 써서 사용자 초안과 섞이지 않게 한다.
    func runLaunchStagingTest() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--add-files"), args.indices.contains(i + 1) else { return }
        let urls = args[i + 1].split(separator: ",").map { URL(filePath: String($0)) }
        let export = args.firstIndex(of: "--export-staged").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        Task {
            await addFiles(urls)
            log("추가: \(stagingMessage?.text ?? "")")
            while gridJob != nil { try? await Task.sleep(for: .milliseconds(300)) }
            for track in staged {
                let draft = GridDraftStore.load(trackUUID: track.uuid)
                log("추가한 곡 \(track.title) · BPM \(track.bpm.map { String(format: "%.2f", $0) } ?? "-") · 자신 \(track.gridConfident.map(String.init) ?? "-") · 키 \(track.key ?? "-")\(track.keySource.map { "(\($0.rawValue))" } ?? "") · 구간 \(draft?.segments.count ?? 0) · 첫 구간 \(draft?.segments.first.map { String(format: "%.3f초 %d박", $0.start, $0.firstBeatNumber) } ?? "-")")
            }
            if let export {
                do {
                    let result = try exportStaged(to: URL(filePath: export))
                    log("내보내기: \(result.count)곡 · 그리드 없음 \(result.withoutGrid) → \(export)")
                } catch {
                    log("내보내기 실패: \(error)")
                }
            }
        }
        func log(_ text: String) { FileHandle.standardError.write(Data("[staging] \(text)\n".utf8)) }
    }

    // MARK: - rekordbox XML

    /// 추가한 곡을 rekordbox XML로 쓴다. 태그 초안(시트·인스펙터에서 고친 값)과 그리드·큐 초안을 넣는다.
    /// 반환: 내보낸 곡 수와 그리드가 없는 곡 수.
    func exportStaged(to url: URL, only ids: Set<TrackRow.ID>? = nil) throws -> (count: Int, withoutGrid: Int) {
        let tracks = staged.filter { ids?.contains($0.id) ?? true }
        // 저장에 실패한 큐·그리드 초안이 있으면 디스크의 옛 초안을 XML로 내보내지 않는다(#170).
        try requireDraftSaves(for: Set(tracks.map(\.uuid)))
        var withoutGrid = 0
        let entries = tracks.map { original -> RekordboxXML.Entry in
            var track = original
            if let fields = tagDrafts[original.uuid]?.fields {
                track.title = fields.title.isEmpty ? original.title : fields.title
                track.artist = fields.artist
                track.album = fields.album
                track.genre = fields.genre
                track.composer = fields.composer
                track.year = Int(fields.year)
                track.trackNumber = Int(fields.trackNumber)
                track.comment = fields.comment
            }
            let tempos = GridDraftStore.load(trackUUID: original.uuid)?.segments ?? []
            if tempos.isEmpty { withoutGrid += 1 }
            let cues = CueDraftStore.load(trackUUID: original.uuid)?.cues ?? []
            return RekordboxXML.Entry(track: track, tempos: tempos, cues: cues)
        }
        let today = String(ISO8601DateFormatter().string(from: .now).prefix(10))
        _ = today
        let xml = RekordboxXML.document(entries: entries, playlistName: "DJCrate 추가")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return (entries.count, withoutGrid)
    }
}
