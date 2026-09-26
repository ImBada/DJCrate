import AVFoundation
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation
import Observation

/// 편집 창의 미리 듣기 재생기. 실제는 `AudioFilePreviewPlayer`, 시험에서는 가짜로 바꾼다.
@MainActor
protocol EditPreviewPlayer: AnyObject {
    var isPlaying: Bool { get }
    /// 재생 중인 파일 안의 위치(초)
    var currentTime: Double { get }
    func play(_ url: URL, volume: Float) throws
    func stop()
}

/// 곡 편집 창(#80): 덱에 올린 곡에서 마디 구간을 쌓고 → 미리 듣고 → 렌더해 추가한 곡에 넣는다.
///
/// 원곡의 그리드·큐·길이는 창을 열 때 덱에서 읽어 둔다(덱과 같은 rekordbox 시간축). 규칙은 `TrackEdit`(순수)이 정하고,
/// 렌더는 `EditRenderer`, 넣기는 `EditStaging`이 한다. 미리 듣기는 들을 부분만 임시 파일로 렌더해 재생한다
/// (이음새는 앞뒤 2마디만이라 곧바로 나오고, 섞는 소리까지 결과물과 같다). 원본 음원·rekordbox에는 쓰지 않는다.
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

    enum Preview: Equatable {
        case all
        /// 이음새 뒤 구간의 목록 순서(`EditSeam.index`)
        case seam(Int)
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
    @ObservationIgnored let player: any EditPreviewPlayer

    var entries: [Entry] = [] { didSet { if entries != oldValue { rebuild() } } }
    /// "여기서 N마디"의 N
    var barsToAdd = 16
    /// 새 곡 제목(태그 초안)이자 파일 이름
    var title: String
    /// 덱에 다른 곡이 올라가 있을 때 "여기서"로 쓰는 위치. 창의 원곡 줄을 눌러 정한다.
    var cursor: Double = 0
    private(set) var edit: TrackEdit?
    /// 목록이 규칙에 맞지 않을 때 이유와 할 일(렌더를 막는다)
    private(set) var planError: String?
    private(set) var carry: CueCarry?
    private(set) var seams: [EditSeam] = []
    var message: AppMessage?

    private(set) var preview: Preview?
    private(set) var isPreparingPreview = false
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// 같은 구간을 다시 들으면 렌더한 파일을 다시 쓴다(창을 닫으면 지운다).
    @ObservationIgnored private var previewFiles: [[BarRange]: URL] = [:]
    /// 마지막 전체 미리 듣기의 구간. 전체는 길어서 새로 만들면 이전 것을 지운다.
    @ObservationIgnored private var lastAllPreview: [BarRange]?

    /// 렌더 진행(0~1). nil이 아니면 렌더 중이다.
    private(set) var renderProgress: Double?
    private(set) var staged: StagedTrack?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored var onStaged: ((StagedTrack) -> Void)?

    /// 덱에 곡이 다 올라와(초안·그리드를 읽음) 편집 창을 열 수 있는지
    static func canOpen(_ deck: DeckModel) -> Bool {
        deck.row != nil && deck.draft != nil && !deck.isWriteLocked
    }

    init?(deck: DeckModel, entries: [BarRange] = [], player: any EditPreviewPlayer = AudioFilePreviewPlayer(),
          home: URL = DJCPaths.userData) {
        guard let row = deck.row else { return nil }
        self.row = row
        self.deck = deck
        self.player = player
        self.home = home
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
            reason = "스트리밍 곡은 편집할 수 없습니다. 파일로 된 곡을 고르세요"
        } else if !FileManager.default.fileExists(atPath: source.path) {
            reason = "음원 파일이 없습니다. 외장 드라이브가 연결됐는지 확인하세요"
        } else if !deck.canPlay {
            reason = "이 파일 형식은 읽지 못해 편집할 수 없습니다. MP3·AAC·WAV·AIFF·FLAC 곡을 고르세요"
        } else if segments.isEmpty {
            reason = "그리드가 없습니다. 덱에서 추정 그리드를 적용하거나 rekordbox에서 트랙 분석을 한 뒤 편집하세요"
        } else if let blocked = deck.gridEditBlockedReason {
            reason = blocked
        } else {
            do { layout = try BarLayout(grid: segments, duration: duration) } catch { reason = Self.reason(error) }
        }
        self.layout = layout
        blockedReason = reason
        cursor = deck.currentTime
        // 지난 실행에서 남은 미리 듣기 파일
        try? FileManager.default.removeItem(at: previewDirectory)
        self.entries = entries.map { Entry(range: $0) }
        rebuild()
    }

    var previewDirectory: URL { home.appending(path: "edit-previews") }
    var editsDirectory: URL { home.appending(path: "edits") }

    /// 덱에 이 곡이 올라가 있다(재생 위치를 "여기서"로 쓴다)
    var isDeckOnTrack: Bool { deck?.row?.id == row.id }

    var canRender: Bool { blockedReason == nil && edit != nil && renderProgress == nil }

    // MARK: - 구간 목록

    /// 창의 원곡 줄에서 위치를 찍는다. 덱에 같은 곡이 있으면 덱도 그 자리로 옮긴다(들으면서 고른다).
    /// 끄는 동안 덱은 소리를 멈췄다가 손을 멈추면 그 자리에서 이어 재생한다(덱 휠 이동과 같다).
    func place(at time: Double) {
        cursor = min(max(time, 0), duration)
        if isDeckOnTrack { deck?.scrubCoalesced(to: cursor) }
    }

    /// 재생 위치(덱에 다른 곡이 있으면 창에서 찍은 위치)가 든 마디부터 N마디를 목록 끝에 더한다.
    func addHere() {
        guard let layout else { return }
        let time = isDeckOnTrack ? deck?.currentTime ?? cursor : cursor
        guard let range = layout.range(from: time, length: barsToAdd, leading: entries.isEmpty) else {
            message = AppMessage(kind: .warning, text: "곡 끝이라 고를 마디가 없습니다. 재생 위치를 앞으로 옮긴 뒤 더하세요")
            return
        }
        message = nil
        entries.append(Entry(range: range))
    }

    func remove(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
    }

    /// 바로 뒤에 같은 구간을 하나 더 둔다(인트로 늘이기).
    func duplicate(_ id: Entry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.insert(Entry(range: entries[index].range), at: index + 1)
    }

    /// 목록에서 앞(−1)·뒤(+1)로 옮긴다. 끝이면 그대로.
    func move(_ id: Entry.ID, by offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(index + offset) else { return }
        entries.swapAt(index, index + offset)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
    }

    /// 시작 마디: 곡 머리(0마디, 있으면)부터 끝 마디까지
    func setFirst(_ id: Entry.ID, _ bar: Int) {
        guard let layout, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].range.first = min(max(bar, layout.hasLeadIn ? 0 : 1), entries[index].range.last)
    }

    /// 끝 마디: 시작 마디(적어도 1마디)부터 곡의 마지막 마디까지
    func setLast(_ id: Entry.ID, _ bar: Int) {
        guard let layout, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].range.last = min(max(bar, entries[index].range.first, 1), layout.count)
    }

    private func rebuild() {
        let bars = entries.map(\.range)
        seams = BarRange.seams(in: bars)
        guard layout != nil, !bars.isEmpty else { edit = nil; carry = nil; planError = nil; return }
        do {
            let edit = try TrackEdit(grid: segments, sourceDuration: duration, bars: bars)
            self.edit = edit
            carry = edit.carry(cues)
            planError = nil
        } catch {
            edit = nil
            carry = nil
            planError = Self.reason(error)
        }
    }

    static func reason(_ error: any Error) -> String {
        if case let DJCError.editRefused(reason) = error { return reason }
        return AppErrorMessage.message(for: error)
    }

    // MARK: - 미리 듣기

    func previewSeam(_ index: Int) {
        guard let seam = seams.first(where: { $0.index == index }) else { return }
        startPreview(.seam(index), bars: seam.preview)
    }

    func previewAll() {
        startPreview(.all, bars: entries.map(\.range))
    }

    /// 듣는 중이면 멈추고, 아니면 듣는다.
    func togglePreview(_ kind: Preview) {
        if preview == kind { stopPreview(); return }
        switch kind {
        case .all: previewAll()
        case .seam(let index): previewSeam(index)
        }
    }

    func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        player.stop()
        preview = nil
        isPreparingPreview = false
    }

    /// 미리 듣는 위치를 편집 결과(출력) 시각으로. 이음새 미리 듣기는 그 이음새 앞 몇 마디부터다.
    func previewOutputTime(_ time: Double) -> Double? {
        guard let preview, let edit, let layout else { return nil }
        switch preview {
        case .all:
            return time
        case .seam(let index):
            guard let order = seams.firstIndex(where: { $0.index == index }), edit.pieces.indices.contains(order + 1),
                  let tail = seams[order].preview.first else { return nil }
            return edit.pieces[order + 1].outputStart - (layout.end(ofBar: tail.last) - layout.start(ofBar: tail.first)) + time
        }
    }

    private func startPreview(_ kind: Preview, bars: [BarRange]) {
        stopPreview()
        guard blockedReason == nil, !bars.isEmpty else { return }
        let edit: TrackEdit
        do {
            edit = try TrackEdit(grid: segments, sourceDuration: duration, bars: bars)
        } catch {
            message = AppMessage(kind: .warning, text: Self.reason(error))
            return
        }
        // 덱과 겹쳐 들리지 않게 덱을 멈춘다.
        if let deck, deck.isPlaying { deck.togglePlay() }
        preview = kind
        let cached = previewFiles[bars].flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        isPreparingPreview = cached == nil
        let url = cached ?? previewDirectory.appending(path: "preview-\(UUID().uuidString).wav")
        let source = source, offset = timelineOffset, player = player
        let volume = Float(deck?.volume ?? 0.9)
        previewTask = Task {
            do {
                if cached == nil {
                    _ = try await Self.renderFile(edit, source: source, offset: offset, to: url)
                    previewFiles[bars] = url
                    if kind == .all {
                        if let old = lastAllPreview, old != bars, let file = previewFiles.removeValue(forKey: old) {
                            try? FileManager.default.removeItem(at: file)
                        }
                        lastAllPreview = bars
                    }
                }
                try Task.checkCancellation()
                isPreparingPreview = false
                try player.play(url, volume: volume)
                while player.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
                if preview == kind { preview = nil }
            } catch is CancellationError {
            } catch {
                isPreparingPreview = false
                preview = nil
                message = AppMessage(kind: .failure, text: "미리 듣기를 만들지 못했습니다. \(Self.reason(error))")
            }
        }
    }

    // MARK: - 렌더 → 추가한 곡

    /// 백그라운드에서 렌더하고(진행·취소) 추가한 곡에 넣는다. 파일은 DJCrate 데이터 폴더의 edits 아래에 둔다.
    func render() {
        guard canRender, let edit, let carry else { return }
        stopPreview()
        message = nil
        let output = Self.availableURL(in: editsDirectory, name: Self.fileName(for: title))
        let source = source, offset = timelineOffset, home = home, track = row.track, title = title
        renderProgress = 0
        renderTask = Task {
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
                message = AppMessage(kind: .success, text: "편집본을 추가한 곡에 넣었습니다: \(title) · \(edit.duration.clockText) · 큐 \(carry.placed.count)개")
                onStaged?(staged)
            } catch is CancellationError {
                message = AppMessage(kind: .warning, text: "렌더를 취소했습니다. 만들던 파일은 지웠습니다.")
            } catch {
                message = AppMessage(kind: .failure, text: "렌더하지 못했습니다. \(Self.reason(error))")
            }
        }
    }

    func cancelRender() {
        renderTask?.cancel()
    }

    /// 창을 닫을 때: 미리 듣기·렌더를 멈추고 임시 파일을 지운다.
    func close() {
        stopPreview()
        renderTask?.cancel()
        for url in previewFiles.values { try? FileManager.default.removeItem(at: url) }
        previewFiles = [:]
        lastAllPreview = nil
        try? FileManager.default.removeItem(at: previewDirectory)
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

/// 미리 듣기 파일을 처음부터 끝까지 재생한다.
@MainActor
final class AudioFilePreviewPlayer: EditPreviewPlayer {
    private var player: AVAudioPlayer?

    var isPlaying: Bool { player?.isPlaying ?? false }
    var currentTime: Double { player?.currentTime ?? 0 }

    func play(_ url: URL, volume: Float) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.volume = volume
        player.prepareToPlay()
        guard player.play() else { throw DJCError.editRefused("미리 듣기를 재생하지 못했습니다. 소리 출력 장치를 확인하세요") }
        self.player = player
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
