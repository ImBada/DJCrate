import RekordboxKit
import AnicueAnalysis
import AnicueDomain
import AnicueStorage
import AVFoundation
import Foundation

/// 소리 분석 실험과 시간 측정.
enum AudioLab {
    static let all: [Command] = [
        Command("mockup-data", nil, "디자인 시안용 실데이터(JSON)", AudioLab.mockupData),
        Command("bench-load", nil, "DB 읽기·분류·파싱 시간", AudioLab.benchLoad),
        Command("bench-waveform", nil, "파형 분석 시간", AudioLab.benchWaveform),
        Command("loudness", nil, "파일의 BS.1770 통합 음량·피크·클리핑 흔적(개발용)", AudioLab.loudness),
        Command("key-eval", nil, "조표 흐름 추정의 주 조표를 rekordbox 키와 비교(읽기 전용)", AudioLab.keyEval),
    ]

    static func mockupData(_ args: [String]) async throws {
        guard args.count > 1, let out = value(after: "--out", in: args) else { throw UsageError() }
        try await exportMockupData(args[1], to: URL(filePath: out), snapshotPath: value(after: "--db", in: args))
    }

    static func benchLoad(_ args: [String]) async throws {
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let clock = ContinuousClock()
        var library: RekordboxLibrary!
        let tLoad = try clock.measure { library = try RekordboxLibrary.load(snapshot: snapshot) }
        var classified = 0
        let tClassify = clock.measure { for t in library.tracks { if CommentClassifier.classify(t.comment) == .convention { classified += 1 } } }
        let tParse = clock.measure { for t in library.tracks { _ = ConventionParser.parse(t.comment) } }
        let tReport = clock.measure { _ = LibraryReport(library: library) }
        let tTree = clock.measure { _ = PlaylistNode.tree(library.playlists) }
        print("DB 읽기 \(tLoad) · 분류 \(tClassify) · 파싱 \(tParse) · 현황 집계 \(tReport) · 플레이리스트 트리 \(tTree) · 곡 \(library.tracks.count)")
    }

    static func benchWaveform(_ args: [String]) async throws {
        guard args.count > 1 else { return }
        let clock = ContinuousClock()
        var w: Waveform!
        let t = try clock.measure { w = try WaveformAnalyzer.analyze(fileAt: URL(filePath: args[1])) }
        print("파형 \(t) · \(w.count)칸 · \(Int(w.duration))초")
        if let out = value(after: "--out", in: args) { try JSONEncoder().encode(w).write(to: URL(filePath: out)) }
    }

    /// 파일의 BS.1770 통합 음량·피크·클리핑 흔적(개발용)
    static func loudness(_ args: [String]) async throws {
        for path in args.dropFirst() {
            let file = try AVAudioFile(forReading: URL(filePath: path))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { continue }
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            let channels = (0..<Int(buffer.format.channelCount)).map { UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: frames) }
            let started = Date()
            let l = Loudness.measure(channels: channels, sampleRate: buffer.format.sampleRate)
            print(String(format: "%.2f LUFS · 피크 %.2f dBFS · 클리핑 %d · %.0fms · %@", l.integrated ?? -999, l.peak, l.clippedRuns,
                         Date().timeIntervalSince(started) * 1000, (path as NSString).lastPathComponent))
        }
    }

    /// 조표 흐름 추정의 주 조표를 rekordbox 키와 비교(읽기 전용). --penalty로 전환 벌점 조정
    static func keyEval(_ args: [String]) async throws {
        let library = try RekordboxLibrary.load(snapshot: value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest())
        let limit = Int(value(after: "--limit", in: args) ?? "") ?? 40
        let penalties = (value(after: "--penalty", in: args) ?? "2").split(separator: ",").compactMap { Double($0) }
        var candidates = library.tracks.filter { !$0.isStreaming && KeyAnalyzer.signature(camelot: $0.key ?? "") != nil && FileManager.default.fileExists(atPath: $0.folderPath) }
        candidates.shuffle()
        var exact = [Int](repeating: 0, count: penalties.count), fifth = exact, modulated = exact, total = 0, examples: [String] = []
        // --train N: 앞 N곡으로 음 분포를 학습하고 나머지로 평가한다.
        let trainCount = Int(value(after: "--train", in: args) ?? "") ?? 0
        if trainCount > 0 {
            var majorSum = [Double](repeating: 0, count: 12), minorSum = majorSum, counts = [0, 0]
            for track in candidates.prefix(trainCount) {
                guard let rb = KeyAnalyzer.signature(camelot: track.key ?? ""),
                      let file = try? AVAudioFile(forReading: URL(filePath: track.folderPath)),
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                      (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { continue }
                let frames = Int(buffer.frameLength)
                let channels = (0..<Int(buffer.format.channelCount)).map { UnsafeBufferPointer(start: data[$0], count: frames) }
                let chroma = KeyAnalyzer.chroma(channels: channels, sampleRate: buffer.format.sampleRate)
                let tonic = rb.minor ? (rb.signature + 9) % 12 : rb.signature
                let v = KeyAnalyzer.rotatedTotal(chroma: chroma, tonic: tonic)
                if rb.minor { for i in 0..<12 { minorSum[i] += v[i] }; counts[1] += 1 } else { for i in 0..<12 { majorSum[i] += v[i] }; counts[0] += 1 }
            }
            let learned = KeyAnalyzer.Profiles(major: majorSum.map { $0 / Double(max(counts[0], 1)) }, minor: minorSum.map { $0 / Double(max(counts[1], 1)) })
            KeyAnalyzer.profiles = learned
            print("학습: 장조 \(counts[0])곡 · 단조 \(counts[1])곡")
            print("  장조:", learned.major.map { String(format: "%.4f", $0) }.joined(separator: ", "))
            print("  단조:", learned.minor.map { String(format: "%.4f", $0) }.joined(separator: ", "))
            candidates.removeFirst(min(trainCount, candidates.count))
        }
        for track in candidates.prefix(limit) {
            guard let file = try? AVAudioFile(forReading: URL(filePath: track.folderPath)),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { continue }
            let frames = Int(buffer.frameLength)
            let channels = (0..<Int(buffer.format.channelCount)).map { UnsafeBufferPointer(start: data[$0], count: frames) }
            let chroma = KeyAnalyzer.chroma(channels: channels, sampleRate: buffer.format.sampleRate)
            let grid = RekordboxShare.analysisURL(track.analysisDataPath).flatMap { try? BeatGrid.load(anlz: $0) }
            let windows = KeyAnalyzer.windows(grid: grid, duration: Double(frames) / buffer.format.sampleRate)
            guard let rb = KeyAnalyzer.signature(camelot: track.key ?? "") else { continue }
            total += 1
            for (i, penalty) in penalties.enumerated() {
                let result = KeyAnalyzer.segments(chroma: chroma, windows: windows, switchPenalty: penalty,
                                                  minWindows: Int(value(after: "--min", in: args) ?? "") ?? 12)
                guard let main = result.main else { continue }
                let diff = (KeyAnalyzer.camelotNumber(signature: main) - KeyAnalyzer.camelotNumber(signature: rb.signature) + 12) % 12
                if diff == 0 { exact[i] += 1 }
                if diff == 1 || diff == 11 { fifth[i] += 1 }
                if result.segments.count > 1 {
                    modulated[i] += 1
                    if i == 0, examples.count < 12 {
                        let flow = result.segments.map { String(format: "%@ %.0f~%.0f초", KeyAnalyzer.camelot(signature: $0.signature, minor: rb.minor), $0.start, $0.end) }
                        examples.append("\(track.title.prefix(24)) (rekordbox \(track.key ?? "")): " + flow.joined(separator: " → "))
                    }
                }
            }
        }
        for (i, penalty) in penalties.enumerated() {
            print(String(format: "벌점 %.1f · %d곡 · 주 조표 일치 %d (%.0f%%) · 5도 이웃 %d · 전조 있음 %d곡", penalty, total, exact[i],
                         Double(exact[i]) / Double(max(total, 1)) * 100, fifth[i], modulated[i]))
        }
        examples.forEach { print("  ", $0) }
    }

    // MARK: - 도움

    /// 디자인 시안에 넣을 실제 데이터. 앨범 커버 이미지는 넣지 않는다.
    static func exportMockupData(_ id: String, to out: URL, snapshotPath: String?) async throws {
        let snapshot = try snapshotPath.map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        guard let track = library.tracks.first(where: { $0.id == id }) else { print("트랙 없음: \(id)"); return }
        let url = URL(filePath: track.folderPath)
        let analysis = try await PartAnalyzer.analyze(fileAt: url, cacheKey: track.uuid)
        let waveform = try WaveformAnalyzer.analyze(fileAt: url)
        let cues = library.cues(for: track).sorted { $0.inMsec < $1.inMsec }
        let hotA = cues.first { $0.hotCueSlot == "A" }.map { Double($0.inMsec) / 1000 } ?? 60
        let zoomStart = max(0, hotA - 12), zoomEnd = zoomStart + 24

        func row(_ t: Track) -> [String: Any] {
            let manual = library.cues(for: t).filter { !$0.isAutoGenerated }.count
            // 목록용 미니 개요 파형(160칸)과 큐 위치
            var mini: [String: Any] = [:]
            if !t.isStreaming, let w = try? WaveformAnalyzer.analyze(fileAt: URL(filePath: t.folderPath)).downsampled(to: 160) {
                mini = ["low": w.low, "mid": w.mid, "high": w.high, "duration": w.duration]
            }
            let cuePoints = library.cues(for: t).filter { !$0.isAutoGenerated }.map {
                ["time": Double($0.inMsec) / 1000, "slot": $0.hotCueSlot.map(String.init) ?? ""] as [String: Any]
            }
            return ["mini": mini, "cuePoints": cuePoints, "title": t.title, "artist": t.artist ?? "", "album": t.album ?? "", "comment": t.comment,
                    "class": CommentClassifier.classify(t.comment).rawValue, "imported": t.importedOn ?? "",
                    "plays": library.playCounts[t.id, default: 0], "bpm": t.bpm ?? 0, "key": t.key ?? "",
                    "cues": library.cues(for: t).isEmpty ? "none" : (manual > 0 ? "manual \(manual)" : "auto"),
                    "length": t.lengthSeconds]
        }
        // 목록: 선택 곡 + 규칙 코멘트 곡 + 2025~26 빈 코멘트 로컬 파일
        let local = library.tracks.filter { !$0.isStreaming }
        let convention = local.filter { CommentClassifier.classify($0.comment) == .convention && library.playCounts[$0.id, default: 0] > 3 }
            .sorted { $0.uuid < $1.uuid }.prefix(8)
        let backlog = local.filter { $0.comment.isEmpty && ["2025", "2026"].contains($0.importYear ?? "") }
            .sorted { $0.uuid < $1.uuid }.prefix(8)
        let parsed = ConventionParser.parse(track.comment)

        let energies = PartLabeler.energies(analysis)
        let lo = energies.map(\.score).filter(\.isFinite).min() ?? 0, hi = energies.map(\.score).filter(\.isFinite).max() ?? 1
        let overview = waveform.downsampled(to: 900)
        let zoom = waveform.slice(from: zoomStart, to: zoomEnd)
        let payload: [String: Any] = [
            "track": row(track).merging([
                "parsed": [
                    "prefix": parsed?.prefix.rawValue ?? "", "work": parsed?.workName ?? "",
                    "usage": parsed?.usages.map { $0.kind.rawValue + ($0.numbers.isEmpty ? "" : " " + $0.numbers.map(String.init).joined(separator: ",")) } ?? [],
                ],
                "duration": analysis.duration,
            ]) { a, _ in a },
            "library": [row(track)] + convention.map(row) + backlog.map(row),
            "counts": ["live": library.tracks.count, "backlog": backlog.count],
            "analysis": [
                "bpm": analysis.bpm ?? 0, "bars": analysis.bars.count,
                "key": analysis.keys.first?.name ?? "",
                "sections": energies.map { ["start": $0.span.start, "end": $0.span.end,
                                            "energy": hi > lo && $0.score.isFinite ? ($0.score - lo) / (hi - lo) : 0,
                                            "vocal": $0.vocal] },
                "barTimes": analysis.bars,
                "labels": PartLabeler.label(analysis).map { ["label": $0.label.rawValue, "time": $0.time] },
                "suggestions": MemoryCueSuggester.suggestions(analysis, existing: cues.map { Double($0.inMsec) / 1000 }),
            ],
            "cues": cues.map { ["slot": $0.hotCueSlot.map(String.init) ?? "", "time": Double($0.inMsec) / 1000,
                                "memory": $0.isMemoryCue, "auto": $0.isAutoGenerated] },
            "waveform": [
                "overview": ["rate": overview.rate, "low": overview.low, "mid": overview.mid, "high": overview.high],
                "zoom": ["start": zoomStart, "rate": zoom.rate, "low": zoom.low, "mid": zoom.mid, "high": zoom.high],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: out)
        print("\(out.path) (\(data.count / 1024)KB) · 파형 \(waveform.count)칸 · 확대 \(Int(zoomStart))~\(Int(zoomEnd))초")
    }
}
