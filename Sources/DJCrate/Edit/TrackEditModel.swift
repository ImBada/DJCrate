import AVFoundation
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation
import Observation

/// 곡 편집 창(#80·#128): 덱에 올린 곡을 컷 편집기처럼 다룬다.
/// 원곡 줄에서 마디 구간을 끌어 고르고 → 결과 타임라인에 넣고 → 자르기·지우기·복제·끌어 옮기기(실행 취소) → 어디서든 들어 보고 → 렌더해 추가한 곡에 넣는다.
///
/// 원곡의 그리드·큐·길이는 창을 열 때 덱에서 읽어 둔다(덱과 같은 rekordbox 시간축). 규칙은 `TrackEdit`·`EditTimeline`(순수)이 정하고,
/// 재생은 창 전용 재생기(`EditAudio`, 덱과 따로)가 원곡을 메모리에 풀어 결과를 렌더하지 않고 바로 낸다(이음새 섞는 소리까지 결과물과 같다).
/// 렌더는 `EditRenderer`, 넣기는 `EditStaging`이 한다. 원본 음원·rekordbox에는 쓰지 않는다.
@MainActor
@Observable
final class TrackEditModel {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        var range: BarRange

        init(id: UUID = UUID(), range: BarRange) {
            self.id = id
            self.range = range
        }
    }

    /// 재생선이 있는 줄: 원곡 전체, 편집 결과
    enum Lane: Equatable {
        case source, output
    }

    let row: TrackRow
    let source: URL
    let segments: [GridSegment]
    /// 편집할 수 없는 곡이면 nil(`blockedReason`)
    let layout: BarLayout?
    let blockedReason: String?
    let cues: [EditableCue]
    let timelineOffset: Double
    let duration: Double
    let waveform: Waveform?
    let home: URL
    @ObservationIgnored weak var deck: DeckModel?
    @ObservationIgnored let audio: any EditAudio

    /// 결과 타임라인의 클립(목록 순서 = 출력 순서)
    var entries: [Entry] = [] { didSet { if entries != oldValue { rebuild() } } }
    /// 원곡 줄에서 끌어 고른 마디 구간
    var selection: BarRange?
    /// 결과 타임라인에서 고른 클립
    var selectedClip: Entry.ID?
    /// 원곡에서 고른 구간을 결과로 끄는 동안 놓을 자리(결과 줄에 표시한다)
    var insertPreview: EditInsertion?
    /// 새 곡 제목(태그 초안)이자 파일 이름
    var title: String
    private(set) var edit: TrackEdit?
    /// 목록이 규칙에 맞지 않을 때 이유와 할 일(렌더를 막는다)
    private(set) var planError: String?
    private(set) var carry: CueCarry?
    /// 결과의 마디 눈금(출력 그리드)
    private(set) var outputLayout: BarLayout?
    /// 결과 타임라인에 그릴 클립 자리(목록 순서). 규칙에 맞지 않는 목록도 고칠 수 있게 그린다.
    private(set) var clipLayout: [TrackEdit.Piece] = []
    var message: AppMessage?

    // MARK: 재생

    /// 스페이스바·←→가 움직이는 줄(마지막으로 누른 줄)
    var focus: Lane = .source
    /// 멈춘 동안의 재생선. 재생 중 위치는 `position(_:)`으로 읽는다(매 프레임 바뀌어 관찰하지 않는다).
    private(set) var sourcePlayhead: Double = 0
    private(set) var outputPlayhead: Double = 0
    private(set) var playing: Lane?
    /// 듣고 있는 이음새(`edit.pieces`의 순서)
    private(set) var auditioning: Int?
    private(set) var isAudioReady = false
    @ObservationIgnored private var playStart: Double = 0
    @ObservationIgnored private var playLimit: Double = 0
    @ObservationIgnored private var playTask: Task<Void, Never>?
    /// 재생선을 끄는 동안 멈춘 재생(손을 떼면 그 자리에서 잇는다)
    @ObservationIgnored private var scrubbing: Lane?

    // MARK: 보기(확대·가로 스크롤)

    /// 줄마다 보이는 자리(#134). 두 줄은 길이가 달라 따로 확대한다.
    private(set) var sourceView = EditViewport()
    private(set) var outputView = EditViewport()

    // MARK: 실행 취소

    /// 편집 창의 실행 취소(편집 › 실행 취소 ⌘Z). 창이 준다.
    @ObservationIgnored weak var undoManager: UndoManager? { didSet { observeUndo() } }
    private(set) var canUndo = false
    private(set) var canRedo = false
    @ObservationIgnored private var undoObservers: [NSObjectProtocol] = []

    // MARK: 렌더

    /// 렌더 진행(0~1). nil이 아니면 렌더 중이다.
    private(set) var renderProgress: Double?
    private(set) var staged: StagedTrack?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored var onStaged: ((StagedTrack) -> Void)?

    /// 덱에 곡이 다 올라와(초안·그리드를 읽음) 편집 창을 열 수 있는지
    static func canOpen(_ deck: DeckModel) -> Bool {
        deck.row != nil && deck.draft != nil && !deck.isWriteLocked
    }

    /// - Parameter edits: 렌더한 편집본을 둘 폴더. 없으면 `home` 아래 `edits`(테스트용). 앱은 `DJCPaths.editOutput`을 준다.
    init?(deck: DeckModel, entries: [BarRange] = [], audio: any EditAudio = EditAudioPlayer(),
          home: URL = DJCPaths.userData, edits: URL? = nil) {
        guard let row = deck.row else { return nil }
        self.row = row
        self.deck = deck
        self.audio = audio
        self.home = home
        editsDirectory = edits ?? home.appending(path: "edits")
        source = URL(filePath: row.track.folderPath)
        segments = deck.gridDraft?.segments ?? []
        cues = deck.draft?.cues ?? []
        timelineOffset = deck.timelineOffset
        duration = deck.duration
        waveform = deck.waveform
        title = "\(row.title) (Edit)"
        var layout: BarLayout?
        var reason: String?
        if row.track.isStreaming {
            reason = String(ui: "스트리밍 곡은 편집할 수 없습니다. 파일로 된 곡을 고르세요")
        } else if !FileManager.default.fileExists(atPath: source.path) {
            reason = String(ui: "음원 파일이 없습니다. 외장 드라이브가 연결됐는지 확인하세요")
        } else if !deck.canPlay {
            reason = String(ui: "이 파일 형식은 읽지 못해 편집할 수 없습니다. MP3·AAC·WAV·AIFF·FLAC 곡을 고르세요")
        } else if segments.isEmpty {
            reason = String(ui: "그리드가 없습니다. 덱에서 추정 그리드를 적용하거나 rekordbox에서 트랙 분석을 한 뒤 편집하세요")
        } else if let blocked = deck.gridEditBlockedReason {
            reason = blocked
        } else {
            do { layout = try BarLayout(grid: segments, duration: duration) } catch { reason = Self.reason(error) }
        }
        self.layout = layout
        blockedReason = reason
        // 덱에서 듣던 자리부터 이어 고른다.
        sourcePlayhead = min(max(deck.currentTime, 0), duration)
        self.entries = entries.map { Entry(range: $0) }
        rebuild()
        if reason == nil {
            audio.prepare(url: source) { [weak self] ready in
                self?.isAudioReady = ready
                if !ready {
                    self?.message = AppMessage(kind: .warning, text: String(ui: "원곡을 메모리에 풀지 못해 창에서 재생할 수 없습니다(20분 넘는 곡 등). 렌더한 뒤 덱에서 들어 보세요"))
                }
            }
        }
    }

    let editsDirectory: URL

    var canRender: Bool { blockedReason == nil && edit != nil && renderProgress == nil }

    // MARK: - 원곡에서 고르기

    /// 원곡 줄에서 끈 두 시각으로 구간을 고른다(가까운 마디 줄에 붙인다).
    func select(from a: Double, to b: Double) {
        guard let layout else { return }
        focus = .source
        selection = layout.selection(from: a, to: b)
    }

    /// 끌어 고르기를 마치면 원곡 재생선을 고른 구간 처음에 둔다(스페이스바로 바로 들어 본다).
    func finishSelection() {
        guard let selection, let layout else { return }
        seek(.source, to: layout.start(ofBar: selection.first))
    }

    /// 고른 구간을 고른 클립 바로 뒤(없으면 결과 끝)에 넣고 그 클립을 고른다. 맨 앞에 넣을 때만 곡 머리(0마디)를 살린다.
    func addSelection() {
        guard let selection, layout != nil else { return }
        let index = selectedIndex.map { $0 + 1 } ?? entries.count
        guard let range = selection.fitted(leading: index == 0) else {
            message = AppMessage(kind: .warning, text: String(ui: "곡 머리(0마디)는 결과 맨 앞에만 둘 수 있습니다. 1마디 이상을 함께 고르세요"))
            return
        }
        insert(EditInsertion(offset: index, range: range))
    }

    /// 원곡 구간을 결과의 `offset` 자리(앞 클립 수)에 넣고 그 클립을 고른다(⏎·끌어 넣기).
    func insert(_ insertion: EditInsertion) {
        message = nil
        let entry = Entry(range: insertion.range)
        change(String(ui: "구간 넣기")) {
            entries.insert(entry, at: min(max(insertion.offset, 0), entries.count))
            selectedClip = entry.id
        }
    }

    /// 원곡 시각이 고른 구간 안인지(그 안을 아래로 끌면 결과로 끌어 넣는다)
    func selectionContains(_ time: Double) -> Bool {
        guard let selection, let layout else { return false }
        return time >= layout.start(ofBar: selection.first) && time <= layout.end(ofBar: selection.last)
    }

    /// 고른 구간을 결과 시각 `time`에 놓으면 들어갈 자리
    func insertion(atOutput time: Double) -> EditInsertion? {
        selection.flatMap { clipLayout.insertion(of: $0, atOutput: time) }
    }

    // MARK: - 결과 타임라인 편집(실행 취소 가능)

    var selectedIndex: Int? { selectedClip.flatMap { id in entries.firstIndex { $0.id == id } } }

    /// 결과 재생선에서 가장 가까운 마디 줄로 클립을 자른다. 오른쪽 조각을 고른다.
    func splitAtPlayhead() {
        let time = position(.output)
        guard let edit, let split = edit.split(atOutput: time),
              let parts = entries[split.clip].range.split(at: split.bar) else {
            message = AppMessage(kind: .warning, text: String(ui: "재생선 가까이에 자를 마디 줄이 없습니다. 재생선을 클립 안쪽으로 옮긴 뒤 자르세요"))
            return
        }
        message = nil
        pause()
        let right = Entry(range: parts[1])
        change(String(ui: "자르기")) {
            entries[split.clip].range = parts[0]
            entries.insert(right, at: split.clip + 1)
            selectedClip = right.id
        }
        outputPlayhead = split.outputTime
    }

    func remove(_ id: Entry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        // 지운 클립을 골랐으면 그 자리의 다음(없으면 앞) 클립을 고른다(⌫를 이어 누를 수 있게).
        let wasSelected = selectedClip == id
        change(String(ui: "지우기")) {
            entries.remove(at: index)
            if wasSelected { selectedClip = entries.indices.contains(index) ? entries[index].id : entries.last?.id }
        }
    }

    /// 바로 뒤에 같은 구간을 하나 더 둔다(인트로 늘이기). 복사본을 고른다.
    func duplicate(_ id: Entry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let copy = Entry(range: entries[index].range)
        change(String(ui: "복제")) {
            entries.insert(copy, at: index + 1)
            selectedClip = copy.id
        }
    }

    /// 목록에서 앞(−1)·뒤(+1)로 옮긴다. 끝이면 그대로.
    func move(_ id: Entry.ID, by offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(index + offset) else { return }
        change(String(ui: "클립 옮기기")) { entries.swapAt(index, index + offset) }
    }

    /// 끌어 온 클립을 `offset`(놓을 자리 앞 클립 수, 옮기기 전 기준)으로 옮긴다.
    func moveClip(_ id: Entry.ID, toOffset offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(String(ui: "클립 옮기기")) {
            entries.move(fromOffsets: IndexSet(integer: index), toOffset: min(max(offset, 0), entries.count))
            selectedClip = id
        }
    }

    /// 시작 마디: 곡 머리(0마디, 있으면)부터 끝 마디까지
    func setFirst(_ id: Entry.ID, _ bar: Int) {
        guard let layout, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(String(ui: "마디 고치기")) {
            entries[index].range.first = min(max(bar, layout.hasLeadIn ? 0 : 1), entries[index].range.last)
        }
    }

    /// 끝 마디: 시작 마디(적어도 1마디)부터 곡의 마지막 마디까지
    func setLast(_ id: Entry.ID, _ bar: Int) {
        guard let layout, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(String(ui: "마디 고치기")) {
            entries[index].range.last = min(max(bar, entries[index].range.first, 1), layout.count)
        }
    }

    /// 클립 가장자리를 `seconds`만큼 끌면 될 구간(마디 줄에 붙인다). 곡 머리는 맨 앞, 끝에서 잘린 마디는 맨 뒤 클립만.
    func trimmed(_ id: Entry.ID, edge: EditEdge, by seconds: Double) -> BarRange? {
        guard let layout, let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return layout.trimmed(entries[index].range, edge: edge, by: seconds, leading: index == 0, trailing: index == entries.count - 1)
    }

    /// 가장자리를 끌어 다듬은 구간으로 바꾸고 그 클립을 고른다.
    func trim(_ id: Entry.ID, to range: BarRange) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        focus = .output
        change(String(ui: "클립 다듬기")) {
            entries[index].range = range
            selectedClip = id
        }
    }

    /// 고른 클립을 지우고·복제한다(⌫·⌘D).
    func removeSelected() { if let selectedClip { remove(selectedClip) } }
    func duplicateSelected() { if let selectedClip { duplicate(selectedClip) } }

    /// Esc: 고른 클립, 없으면 원곡에서 고른 구간을 놓는다. 놓을 것이 없으면 false.
    @discardableResult
    func clearSelection() -> Bool {
        if selectedClip != nil { selectedClip = nil; return true }
        if selection != nil { selection = nil; return true }
        return false
    }

    /// 목록을 바꾸고 바꾸기 전 상태를 실행 취소에 남긴다.
    private func change(_ name: String, _ body: () -> Void) {
        let before = (entries, selectedClip)
        body()
        guard entries != before.0 else { return }
        registerUndo(entries: before.0, selected: before.1, name: name)
    }

    private func registerUndo(entries old: [Entry], selected: Entry.ID?, name: String) {
        guard let undoManager else { return }
        // 이벤트 단위로 묶지 않는 곳(시험·자가 테스트)에서도 한 번에 하나씩 되돌리게 직접 묶는다.
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        let groupsByEvent = undoManager.groupsByEvent
        if grouping {
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
        }
        undoManager.registerUndo(withTarget: self) { target in
            let current = (target.entries, target.selectedClip)
            target.entries = old
            target.selectedClip = selected
            target.registerUndo(entries: current.0, selected: current.1, name: name)
        }
        undoManager.setActionName(name)
        if grouping {
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = groupsByEvent
        }
        refreshUndo()
    }

    func undo() { undoManager?.undo() }
    func redo() { undoManager?.redo() }

    private func observeUndo() {
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers = [.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup,
                         .NSUndoManagerDidOpenUndoGroup].map { name in
            NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUndo() }
            }
        }
        refreshUndo()
    }

    private func refreshUndo() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }

    private func rebuild() {
        let bars = entries.map(\.range)
        // 재생 중인 결과가 바뀌면 멈춘다(바뀐 결과를 이어 들으려면 다시 재생).
        if playing == .output { pause() }
        if let selectedClip, !entries.contains(where: { $0.id == selectedClip }) { self.selectedClip = nil }
        defer {
            clipLayout = edit?.clips ?? layout.map { TrackEdit.place(bars, in: $0) } ?? []
            outputPlayhead = min(outputPlayhead, edit?.duration ?? 0)
        }
        guard layout != nil, !bars.isEmpty else { edit = nil; carry = nil; planError = nil; outputLayout = nil; return }
        do {
            let edit = try TrackEdit(grid: segments, sourceDuration: duration, bars: bars)
            self.edit = edit
            carry = edit.carry(cues)
            outputLayout = try? BarLayout(grid: [edit.outputGrid], duration: edit.duration)
            planError = nil
        } catch {
            edit = nil
            carry = nil
            outputLayout = nil
            planError = Self.reason(error)
        }
    }

    static func reason(_ error: any Error) -> String {
        if case let DJCError.editRefused(reason) = error { return reason }
        return AppErrorMessage.message(for: error)
    }

    // MARK: - 재생·시킹

    /// 줄의 길이(초). 결과가 없으면 0.
    func length(_ lane: Lane) -> Double {
        lane == .source ? duration : edit?.duration ?? 0
    }

    /// 지금 재생선 위치(재생 중이면 들리는 자리)
    func position(_ lane: Lane) -> Double {
        if playing == lane { return min(playStart + audio.elapsed, playLimit) }
        return lane == .source ? sourcePlayhead : outputPlayhead
    }

    func canPlay(_ lane: Lane) -> Bool {
        isAudioReady && blockedReason == nil && length(lane) > 0
    }

    /// 스페이스바: 재생 중이면 멈추고, 아니면 마지막으로 누른 줄을 재생한다.
    func togglePlay() {
        if playing != nil { pause() } else { play(focus) }
    }

    /// 재생선에서 재생한다. 끝에 있으면 처음부터. `until`(초)에 닿으면 멈춘다(이음새 듣기).
    func play(_ lane: Lane, until: Double? = nil) {
        guard canPlay(lane) else { return }
        focus = lane
        var from = position(lane)
        if from >= length(lane) - 0.01 { from = 0 }
        start(lane, at: from, until: until)
    }

    private func start(_ lane: Lane, at time: Double, until: Double?) {
        stopAudio()
        // 덱과 겹쳐 들리지 않게 덱을 멈춘다.
        if let deck, deck.isPlaying { deck.togglePlay() }
        let rate = audio.sampleRate
        let items: [EditPlaybackItem]
        switch lane {
        case .source:
            items = [EditPlaybackItem(outputFrame: 0, frameCount: Int64((duration * rate).rounded()),
                                      sourceFrame: -Int64((timelineOffset * rate).rounded()))]
        case .output:
            guard let edit else { return }
            items = TrackEdit.playbackItems(edit.frames(sampleRate: rate, sourceOffset: timelineOffset))
        }
        setPlayhead(lane, time)
        guard audio.play(items, from: Int64((time * rate).rounded()), volume: Float(deck?.volume ?? 0.9)) else {
            message = AppMessage(kind: .failure, text: String(ui: "재생하지 못했습니다. 소리 출력 장치를 확인하세요"))
            return
        }
        playStart = time
        playLimit = min(until ?? length(lane), length(lane))
        playing = lane
        // 끝(또는 이음새 듣기 끝)에 닿으면 멈춘다. 확대해 보는 중에 재생선이 보이는 자리 오른쪽 끝을 넘으면 다음 쪽으로 넘긴다
        // (다른 곳을 보고 있으면 끌어오지 않는다).
        playTask = Task { [weak self] in
            var last = time
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, self.playing == lane else { return }
                if !self.audio.isPlaying || self.playStart + self.audio.elapsed >= self.playLimit {
                    self.pause()
                    return
                }
                let now = self.position(lane), end = self.viewport(lane).visible(length: self.extent(lane)).upperBound
                if last <= end, now > end { self.reveal(lane, now) }
                last = now
            }
        }
    }

    /// 멈추고 들리던 자리에 재생선을 둔다.
    func pause() {
        guard let lane = playing else { return }
        let time = position(lane)
        stopAudio()
        setPlayhead(lane, time)
    }

    private func stopAudio() {
        playTask?.cancel()
        playTask = nil
        if playing != nil || audio.isPlaying { audio.stop() }
        playing = nil
        auditioning = nil
    }

    private func setPlayhead(_ lane: Lane, _ time: Double) {
        let time = min(max(time, 0), length(lane))
        if lane == .source { sourcePlayhead = time } else { outputPlayhead = time }
    }

    /// 재생선을 옮긴다(누른 자리·←→·Home·End). 재생 중이면 그 자리에서 잇는다. 보이지 않는 자리면 따라 넘긴다.
    func seek(_ lane: Lane, to time: Double) {
        focus = lane
        if playing == lane {
            start(lane, at: min(max(time, 0), length(lane)), until: nil)
        } else {
            setPlayhead(lane, time)
        }
        reveal(lane, position(lane))
    }

    /// 재생선을 끄는 동안: 소리를 멈췄다가 `endScrub`에서 그 자리부터 잇는다(덱 휠 이동과 같다).
    func scrub(_ lane: Lane, to time: Double) {
        focus = lane
        if playing == lane {
            stopAudio()
            scrubbing = lane
        }
        setPlayhead(lane, time)
    }

    func endScrub() {
        guard let lane = scrubbing else { return }
        scrubbing = nil
        play(lane)
    }

    /// ←→: 마지막으로 누른 줄의 재생선을 앞뒤 마디 줄로(⇧는 4마디).
    func step(bars: Int) {
        guard let layout = focus == .source ? layout : outputLayout else { return }
        seek(focus, to: layout.step(from: position(focus), by: bars))
    }

    /// Home·End
    func jump(toEnd: Bool) {
        seek(focus, to: toEnd ? length(focus) : 0)
    }

    // MARK: - 보기(확대·가로 스크롤)

    func viewport(_ lane: Lane) -> EditViewport {
        lane == .source ? sourceView : outputView
    }

    /// 줄에 그리는 길이(초). 결과는 규칙에 맞지 않아 재생할 수 없는 목록도 클립 자리만큼 그린다.
    func extent(_ lane: Lane) -> Double {
        lane == .source ? duration : clipLayout.last?.outputEnd ?? 0
    }

    /// 가장 가깝게 보는 길이: 2마디(마디 하나를 정확히 고를 만큼)
    var minimumSpan: Double { 2 * (layout?.barLength ?? 2) }

    /// `factor`배 확대한다(1보다 작으면 축소). 기준 자리는 `anchor`(휠·핀치는 포인터 자리),
    /// 없으면 보이는 재생선, 재생선이 보이지 않으면 보이는 구간 가운데.
    func zoom(_ lane: Lane, by factor: Double, around anchor: Double? = nil) {
        let length = extent(lane), visible = viewport(lane).visible(length: length)
        let playhead = position(lane)
        let anchor = anchor ?? (visible.contains(playhead) ? playhead : (visible.lowerBound + visible.upperBound) / 2)
        update(lane) { $0.zoom(by: factor, around: anchor, length: length, minimumSpan: minimumSpan) }
    }

    /// 줄 전체를 폭에 맞춘다.
    func fit(_ lane: Lane) {
        update(lane) { $0.fit() }
    }

    func scroll(_ lane: Lane, by seconds: Double) {
        let length = extent(lane)
        update(lane) { $0.scroll(by: seconds, length: length) }
    }

    func scroll(_ lane: Lane, to time: Double) {
        let length = extent(lane)
        update(lane) { $0.scroll(to: time, length: length) }
    }

    private func reveal(_ lane: Lane, _ time: Double) {
        let length = extent(lane)
        update(lane) { $0.reveal(time, length: length) }
    }

    /// 바뀔 때만 쓴다(보이는 자리를 읽는 줄만 다시 그린다).
    private func update(_ lane: Lane, _ body: (inout EditViewport) -> Void) {
        var view = viewport(lane)
        body(&view)
        guard view != viewport(lane) else { return }
        if lane == .source { sourceView = view } else { outputView = view }
    }

    /// 이음새(`edit.pieces[piece]`의 시작) 앞 2마디부터 뒤 2마디까지 결과를 들어 본다(조각이 짧으면 그 조각 안에서).
    func auditionSeam(_ piece: Int) {
        guard let edit, edit.pieces.indices.contains(piece), piece > 0 else { return }
        let seam = edit.pieces[piece].outputStart, span = 2 * edit.layout.barLength
        let from = max(edit.pieces[piece - 1].outputStart, seam - span)
        let to = min(edit.pieces[piece].outputEnd, seam + span)
        guard canPlay(.output) else { return }
        focus = .output
        start(.output, at: from, until: to)
        reveal(.output, from)
        if playing == .output { auditioning = piece }
    }

    // MARK: - 렌더 → 추가한 곡

    /// 백그라운드에서 렌더하고(진행·취소) 추가한 곡에 넣는다. 파일은 `editsDirectory`(앱은 음악 폴더의 DJCrate 편집본)에 둔다.
    func render() {
        guard canRender, let edit, let carry else { return }
        pause()
        message = nil
        let output = Self.availableURL(in: editsDirectory, name: Self.fileName(for: title))
        let source = source, offset = timelineOffset, home = home, track = row.track, title = title
        renderProgress = 0
        renderTask = Task { [self] in
            defer {
                renderTask = nil
                renderProgress = nil
            }
            do {
                try Task.checkCancellation()
                _ = try await Self.renderFile(edit, source: source, offset: offset, to: output) { [weak self] value in
                    Task { @MainActor in
                        // 끝난 뒤 늦게 온 진행은 버린다.
                        if self?.renderProgress != nil { self?.renderProgress = value }
                    }
                }
                let staged: StagedTrack
                do {
                    staged = try await EditStaging.stage(fileAt: output, edit: edit, cues: carry.placed, source: track, title: title, home: home)
                } catch {
                    try? FileManager.default.removeItem(at: output)
                    throw error
                }
                self.staged = staged
                message = AppMessage(kind: .success, text: String(ui: "편집본을 추가한 곡에 넣었습니다: \(title) · \(edit.duration.clockText) · 큐 \(carry.placed.count)개"))
                onStaged?(staged)
            } catch is CancellationError {
                message = AppMessage(kind: .warning, text: String(ui: "렌더를 취소했습니다. 만들던 파일은 지웠습니다."))
            } catch {
                message = AppMessage(kind: .failure, text: String(ui: "렌더하지 못했습니다. \(Self.reason(error))"))
            }
        }
    }

    func cancelRender() {
        renderTask?.cancel()
    }

    /// 창을 닫을 때: 재생·렌더를 멈추고 메모리에 푼 원곡을 놓는다.
    func close() {
        stopAudio()
        audio.close()
        renderTask?.cancel()
        undoManager?.removeAllActions(withTarget: self)
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers = []
    }

    /// 원본 읽기·파일 쓰기는 메인 액터 밖에서 한다. 부른 작업을 취소하면 렌더도 멈추고 임시 파일을 지운다.
    nonisolated static func renderFile(_ edit: TrackEdit, source: URL, offset: Double, to output: URL,
                                       progress: EditRenderer.Progress? = nil) async throws -> EditRenderer.Result {
        let job = Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            return try EditRenderer.render(edit, source: source, sourceOffset: offset, to: output, progress: progress)
        }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    /// 제목을 파일 이름으로: 경로 글자(/ :)는 바꾸고, 숨김 파일이 되지 않게 앞 점을 뺀다.
    nonisolated static func fileName(for title: String) -> String {
        var name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Edit" : String(name.prefix(120))
    }

    /// 이미 있는 파일은 덮지 않고 " 2", " 3"… 을 붙인다.
    nonisolated static func availableURL(in directory: URL, name: String) -> URL {
        var candidate = directory.appending(path: "\(name).wav")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(name) \(number).wav")
            number += 1
        }
        return candidate
    }
}
