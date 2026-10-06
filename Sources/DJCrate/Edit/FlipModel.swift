import AVFoundation
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation
import Observation

/// Flip 결과 창: 덱에서 기록한 Flip(`FlipRecording`)을 편집본으로 보여 주고 → 들어 보고 → 렌더해 추가한 곡에 넣는다.
///
/// 원곡의 그리드·큐·길이는 창을 열 때 덱에서 읽어 둔다(덱과 같은 rekordbox 시간축). 결과 시간표는 `FlipEdit`(순수)이 정하고,
/// 재생은 곡 편집 창과 같은 창 전용 재생기(`EditAudio`, 덱과 따로)가 원곡을 메모리에 풀어 렌더하지 않고 바로 낸다.
/// 렌더는 `EditRenderer`, 넣기는 `EditStaging`이 한다. 원본 음원·rekordbox에는 쓰지 않는다.
@MainActor
@Observable
final class FlipModel {
    let row: TrackRow
    let source: URL
    let flip: FlipEdit
    /// 결과에 남은 점프 수(루프 되풀이 한 바퀴도 하나)
    let jumpCount: Int
    /// 출력 그리드. 원곡 그리드를 옮길 수 없으면 비어 있다(`gridNotice`).
    let grid: [GridSegment]
    let gridNotice: String?
    let carry: CueCarry
    let timelineOffset: Double
    let sourceDuration: Double
    let waveform: Waveform?
    let home: URL
    let editsDirectory: URL
    @ObservationIgnored weak var deck: DeckModel?
    @ObservationIgnored let audio: any EditAudio

    /// 새 곡 제목(태그 초안)이자 파일 이름
    var title: String
    var message: AppMessage?

    // MARK: 재생

    private(set) var isAudioReady = false
    /// 멈춘 동안의 재생선. 재생 중 위치는 `position`으로 읽는다(매 프레임 바뀌어 관찰하지 않는다).
    private(set) var playhead: Double = 0
    private(set) var playing = false
    @ObservationIgnored private var playStart: Double = 0
    @ObservationIgnored private var playTask: Task<Void, Never>?
    /// 재생선을 끄는 동안 멈춘 재생(손을 떼면 그 자리에서 잇는다)
    @ObservationIgnored private var scrubbing = false

    // MARK: 렌더

    /// 렌더 진행(0~1). nil이 아니면 렌더 중이다.
    private(set) var renderProgress: Double?
    private(set) var staged: StagedTrack?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored var onStaged: ((StagedTrack) -> Void)?

    /// - Parameter edits: 렌더한 편집본을 둘 폴더. 없으면 `home` 아래 `edits`(테스트용). 앱은 `DJCPaths.editOutput`을 준다.
    /// - Throws: 결과를 만들 수 없을 때(점프가 없음·곡 정보 없음) 이유와 할 일(`DJCError.editRefused`)
    init(deck: DeckModel, recording: FlipRecording, audio: any EditAudio = EditAudioPlayer(),
         home: URL = DJCPaths.userData, edits: URL? = nil) throws {
        guard let row = deck.row else {
            throw DJCError.editRefused(String(ui: "덱에 곡이 없습니다. 곡을 불러온 뒤 Flip을 기록하세요"))
        }
        let source = URL(filePath: row.track.folderPath)
        guard !row.track.isStreaming, FileManager.default.fileExists(atPath: source.path) else {
            throw DJCError.editRefused(String(ui: "음원 파일이 없습니다. 외장 드라이브가 연결됐는지 확인하세요"))
        }
        let flip = try FlipEdit(recording, sourceDuration: deck.duration)
        self.row = row
        self.source = source
        self.flip = flip
        self.deck = deck
        self.audio = audio
        self.home = home
        editsDirectory = edits ?? home.appending(path: "edits")
        jumpCount = flip.pieces.count - 1
        timelineOffset = deck.timelineOffset
        sourceDuration = deck.duration
        waveform = deck.waveform
        title = "\(row.title) (Flip)"
        carry = flip.carry(deck.draft?.cues ?? [])
        let segments = deck.gridDraft?.segments ?? []
        if segments.isEmpty {
            grid = []
            gridNotice = String(ui: "원곡에 그리드가 없어 그리드 없이 넣습니다. 추가한 곡에서 그리드를 추정하세요")
        } else if deck.gridEditBlockedReason != nil {
            grid = []
            gridNotice = String(ui: "원곡 그리드를 정확히 옮길 수 없어(다이내믹 그리드 등) 그리드 없이 넣습니다. 추가한 곡에서 그리드를 추정하세요")
        } else {
            grid = flip.outputGrid(segments)
            gridNotice = nil
        }
        audio.prepare(url: source) { [weak self] ready in
            self?.isAudioReady = ready
            if !ready {
                self?.message = AppMessage(kind: .warning, text: String(ui: "원곡을 메모리에 풀지 못해 창에서 재생할 수 없습니다(20분 넘는 곡 등). 렌더한 뒤 덱에서 들어 보세요"))
            }
        }
    }

    var duration: Double { flip.duration }

    var canRender: Bool { renderProgress == nil }

    // MARK: - 재생·시킹

    /// 지금 재생선 위치(재생 중이면 들리는 자리)
    var position: Double {
        playing ? min(playStart + audio.elapsed, duration) : playhead
    }

    var canPlay: Bool { isAudioReady && duration > 0 }

    func togglePlay() {
        if playing { pause() } else { play() }
    }

    /// 재생선에서 재생한다. 끝에 있으면 처음부터.
    func play() {
        guard canPlay else { return }
        var from = position
        if from >= duration - 0.01 { from = 0 }
        start(at: from)
    }

    private func start(at time: Double) {
        stopAudio()
        // 덱과 겹쳐 들리지 않게 덱을 멈춘다.
        if let deck, deck.isPlaying { deck.togglePlay() }
        let rate = audio.sampleRate
        let items = TrackEdit.playbackItems(flip.frames(sampleRate: rate, sourceOffset: timelineOffset))
        playhead = min(max(time, 0), duration)
        guard audio.play(items, from: Int64((playhead * rate).rounded()), volume: Float(deck?.volume ?? 0.9)) else {
            message = AppMessage(kind: .failure, text: String(ui: "재생하지 못했습니다. 소리 출력 장치를 확인하세요"))
            return
        }
        playStart = playhead
        playing = true
        // 끝에 닿으면 멈춘다.
        playTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, self.playing else { return }
                if !self.audio.isPlaying || self.playStart + self.audio.elapsed >= self.duration {
                    self.pause()
                    return
                }
            }
        }
    }

    /// 멈추고 들리던 자리에 재생선을 둔다.
    func pause() {
        guard playing else { return }
        let time = position
        stopAudio()
        playhead = min(max(time, 0), duration)
    }

    private func stopAudio() {
        playTask?.cancel()
        playTask = nil
        if playing || audio.isPlaying { audio.stop() }
        playing = false
    }

    /// 재생선을 옮긴다(누른 자리·Home·End). 재생 중이면 그 자리에서 잇는다.
    func seek(to time: Double) {
        if playing { start(at: time) } else { playhead = min(max(time, 0), duration) }
    }

    /// 재생선을 끄는 동안: 소리를 멈췄다가 `endScrub`에서 그 자리부터 잇는다.
    func scrub(to time: Double) {
        if playing {
            stopAudio()
            scrubbing = true
        }
        playhead = min(max(time, 0), duration)
    }

    func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        play()
    }

    /// 출력 시각이 든 조각(`flip.pieces`의 순서)
    func pieceIndex(atOutput time: Double) -> Int? {
        flip.pieces.firstIndex { time < $0.outputEnd } ?? (flip.pieces.isEmpty ? nil : flip.pieces.count - 1)
    }

    // MARK: - 렌더 → 추가한 곡

    /// 백그라운드에서 렌더하고(진행·취소) 추가한 곡에 넣는다. 파일은 `editsDirectory`(앱은 음악 폴더의 DJCrate 편집본)에 둔다.
    func render() {
        guard canRender else { return }
        pause()
        message = nil
        let output = TrackEditModel.availableURL(in: editsDirectory, name: TrackEditModel.fileName(for: title))
        let flip = flip, grid = grid, cues = carry.placed, source = source, offset = timelineOffset
        let home = home, track = row.track, title = title
        renderProgress = 0
        renderTask = Task { [self] in
            defer {
                renderTask = nil
                renderProgress = nil
            }
            do {
                try Task.checkCancellation()
                _ = try await Self.renderFile(flip, source: source, offset: offset, to: output) { [weak self] value in
                    Task { @MainActor in
                        // 끝난 뒤 늦게 온 진행은 버린다.
                        if self?.renderProgress != nil { self?.renderProgress = value }
                    }
                }
                let staged: StagedTrack
                do {
                    staged = try await EditStaging.stage(fileAt: output, grid: grid, cues: cues, source: track, title: title, home: home)
                } catch {
                    try? FileManager.default.removeItem(at: output)
                    throw error
                }
                self.staged = staged
                message = AppMessage(kind: .success, text: String(ui: "Flip 편집본을 추가한 곡에 넣었습니다: \(title) · \(flip.duration.clockText) · 큐 \(cues.count)개"))
                onStaged?(staged)
            } catch is CancellationError {
                message = AppMessage(kind: .warning, text: String(ui: "렌더를 취소했습니다. 만들던 파일은 지웠습니다."))
            } catch {
                message = AppMessage(kind: .failure, text: String(ui: "렌더하지 못했습니다. \(TrackEditModel.reason(error))"))
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
    }

    /// 원본 읽기·파일 쓰기는 메인 액터 밖에서 한다. 부른 작업을 취소하면 렌더도 멈추고 임시 파일을 지운다.
    nonisolated static func renderFile(_ flip: FlipEdit, source: URL, offset: Double, to output: URL,
                                       progress: EditRenderer.Progress? = nil) async throws -> EditRenderer.Result {
        let job = Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            return try EditRenderer.render(flip, source: source, sourceOffset: offset, to: output, progress: progress)
        }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
}
