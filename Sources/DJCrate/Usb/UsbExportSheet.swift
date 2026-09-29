import DJCDomain
import DJCStorage
import RekordboxKit
import SwiftUI

/// 미리 보기 요약(시트·확인 창이 보인다). 곡 제목·경로는 담지 않는다
struct UsbExportSummary: Equatable, Sendable {
    /// 막힘 code 하나와 그 대상 수(같은 곡·목록은 한 번)
    struct BlockCount: Equatable, Sendable {
        /// 무엇을 막는지: 곡·재생 목록은 빼고 쓰고, 그 밖(볼륨·형식·파일)은 쓰기를 멈춘다
        enum Kind: Equatable, Sendable { case track, playlist, stopping }

        var code: String
        var message: String
        var count: Int
        var kind: Kind
    }

    struct RuleCount: Equatable, Sendable {
        var rule: UsbProvisionalRule
        /// 규칙이 걸린 곡 수(곡 단위가 아니면 0)
        var count: Int
    }

    var trackCount: Int
    var playlistCount: Int
    /// 빼고 쓰는 곡 수(같은 곡은 한 번)
    var blockedTrackCount: Int
    /// 빼고 쓰는 재생 목록 수(같은 목록은 한 번)
    var blockedPlaylistCount: Int
    /// 막힘 code별 수(처음 나온 순서)
    var blockCounts: [BlockCount]
    /// 쓰기를 멈추는 막힘(볼륨·형식·파일 단위)의 문구
    var stopping: [String]
    var stoppingCodes: [String]
    /// 확인 안 된 규칙(이름 순)
    var rules: [RuleCount]
    var requiredBytes: Int64
    var availableBytes: Int64
    /// 준비한 변경 묶음이 있는지(막는 것이 없을 때만 있다)
    var hasChanges: Bool
    /// 디스크 이미지(시험 볼륨)
    var isTestVolume: Bool

    init(trackCount: Int, playlistCount: Int, blocks: [UsbBlock], ruleCounts: [UsbProvisionalRule: Int], requiredRules: Set<UsbProvisionalRule>,
         requiredBytes: Int64, availableBytes: Int64, hasChanges: Bool, isTestVolume: Bool) {
        self.trackCount = trackCount
        self.playlistCount = playlistCount
        var order: [String] = [], targets: [String: Set<UsbBlock.Scope>] = [:], messages: [String: String] = [:]
        var tracks: Set<String> = [], playlists: Set<String> = [], stopping: [String] = [], codes: [String] = []
        for block in blocks {
            if targets[block.code] == nil { order.append(block.code) }
            targets[block.code, default: []].insert(block.scope)
            if messages[block.code] == nil { messages[block.code] = block.message }
            switch block.scope {
            case let .track(id): tracks.insert(id)
            case let .playlist(id): playlists.insert(id)
            case .volume, .format, .file:
                if !stopping.contains(block.message) { stopping.append(block.message) }
                if !codes.contains(block.code) { codes.append(block.code) }
            }
        }
        blockCounts = order.map { code in
            let scopes = targets[code] ?? []
            // 한 code가 여러 단위에 걸리면 곡 → 재생 목록 → 멈춤 순으로 본다
            let kind: BlockCount.Kind = if scopes.contains(where: { if case .track = $0 { true } else { false } }) {
                .track
            } else if scopes.contains(where: { if case .playlist = $0 { true } else { false } }) {
                .playlist
            } else {
                .stopping
            }
            return BlockCount(code: code, message: messages[code] ?? "", count: scopes.count, kind: kind)
        }
        blockedTrackCount = tracks.count
        blockedPlaylistCount = playlists.count
        self.stopping = stopping
        stoppingCodes = codes
        rules = requiredRules.sorted { $0.rawValue < $1.rawValue }.map { RuleCount(rule: $0, count: ruleCounts[$0] ?? 0) }
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
        self.hasChanges = hasChanges
        self.isTestVolume = isTestVolume
    }

    init(preview: UsbExportPreview, volume: UsbVolumeInfo) {
        self.init(trackCount: preview.plan.tracks.count, playlistCount: preview.plan.playlists.count, blocks: preview.blocks,
                  ruleCounts: preview.ruleCounts, requiredRules: preview.requiredRules, requiredBytes: preview.requiredBytes,
                  availableBytes: preview.availableBytes, hasChanges: preview.changes != nil, isTestVolume: volume.isDiskImage)
    }

    var isShortOfSpace: Bool { stoppingCodes.contains("insufficientSpace") || requiredBytes > availableBytes }
    var isPhysicalDisabled: Bool { stoppingCodes.contains("physicalDisabled") }
    var canWrite: Bool { stopping.isEmpty && hasChanges && trackCount > 0 && !isShortOfSpace }

    /// "필요 공간 N MB · 여유 M MB"(필요는 올림, 여유는 내림 — 쓰기 절차의 용량 확인과 같은 쪽으로)
    var spaceText: String {
        let megabyte: Int64 = 1024 * 1024
        return String(ui: "필요 공간 \((requiredBytes + megabyte - 1) / megabyte)MB · 여유 \(availableBytes / megabyte)MB")
    }
}

/// 내보내기 시트에서 고르는 것(순수): 형식·원본(목록 트리·고른 곡)·미리 보기. 고르는 것이 바뀌면 앞의 미리 보기를 버린다
struct UsbExportSheetModel: Equatable {
    /// 원본 목록 트리 한 줄
    struct Row: Equatable, Identifiable {
        var id: String
        var name: String
        var depth: Int
        var isFolder: Bool
        /// 인텔리전트 재생 목록(규칙을 확인하지 않아 내보내지 않는다)
        var isSmart: Bool
        var trackCount: Int
    }

    let volume: UsbVolumeInfo
    private(set) var formats: Set<UsbFormat> = UsbFormat.defaultSet
    private(set) var playlistIDs: Set<String> = []
    /// 곡 목록에서 고른 로컬 곡(ContentID, 목록 순서)
    let selectedTrackIDs: [String]
    var includesSelectedTracks = false {
        didSet { if includesSelectedTracks != oldValue { summary = nil } }
    }
    var summary: UsbExportSummary?

    init(volume: UsbVolumeInfo, selectedTrackIDs: [String]) {
        self.volume = volume
        self.selectedTrackIDs = selectedTrackIDs
    }

    var isTestVolume: Bool { volume.isDiskImage }

    /// 형식을 켜고 끈다. 마지막 하나는 끌 수 없다
    mutating func setFormat(_ format: UsbFormat, on: Bool) {
        var next = formats
        if on { next.insert(format) } else { next.remove(format) }
        guard !next.isEmpty, next != formats else { return }
        formats = next
        summary = nil
    }

    mutating func setPlaylist(_ id: String, selected: Bool) {
        let changed = selected ? playlistIDs.insert(id).inserted : playlistIDs.remove(id) != nil
        if changed { summary = nil }
    }

    func isSelected(_ id: String) -> Bool { playlistIDs.contains(id) }

    /// 고른 폴더 안에 있어 폴더가 함께 넘기는 목록
    func isCovered(_ id: String, layout: PlaylistLayout) -> Bool {
        layout.ancestors(of: id).contains { $0.id != id && playlistIDs.contains($0.id) }
    }

    /// 세션에 넘길 선택(트리 순서, 고른 폴더 안의 목록은 폴더가 품는다). 고른 것이 없으면 nil
    func selection(layout: PlaylistLayout) -> UsbSelection? {
        let playlists = layout.outline.map(\.id).filter { playlistIDs.contains($0) && !isCovered($0, layout: layout) }
        let tracks = includesSelectedTracks ? selectedTrackIDs : []
        switch (playlists.isEmpty, tracks.isEmpty) {
        case (true, true): return nil
        case (false, true): return .playlists(playlists)
        case (true, false): return .tracks(tracks)
        case (false, false): return .both(playlists: playlists, tracks: tracks)
        }
    }

    func canPreview(layout: PlaylistLayout) -> Bool { selection(layout: layout) != nil }

    /// 미리 보기를 본 뒤 그대로 쓸 수 있는지
    var canWrite: Bool { summary?.canWrite == true }

    /// 스냅샷의 목록 트리 → 줄(초안으로 만든 새 목록은 스냅샷에 없어 뺀다)
    static func rows(_ layout: PlaylistLayout) -> [Row] {
        func walk(_ parent: String, depth: Int) -> [Row] {
            layout.children(of: parent).filter { !$0.isNew }.flatMap { item in
                [Row(id: item.id, name: item.name, depth: depth, isFolder: item.isFolder, isSmart: item.isSmart,
                     trackCount: item.isFolder ? 0 : item.entries.count)]
                    + (item.isFolder ? walk(item.id, depth: depth + 1) : [])
            }
        }
        return walk(PlaylistLayout.root, depth: 0)
    }
}

/// "USB로 내보내기…" 시트: 대상 볼륨 · 형식 · 원본(목록 트리·고른 곡) · 미리 보기(곡·목록 수, 공간, 막힘 이유별 수).
/// 쓰기는 시트를 닫은 뒤 코디네이터가 확인 창부터 이어 한다
struct UsbExportSheet: View {
    let store: LibraryStore
    let usb: UsbStore
    let request: UsbExportSheetRequest
    @State private var model: UsbExportSheetModel
    @State private var isPreviewing = false
    @Environment(\.dismiss) private var dismiss

    init(store: LibraryStore, usb: UsbStore, request: UsbExportSheetRequest) {
        self.store = store
        self.usb = usb
        self.request = request
        let tracks = store.selectedRows.filter { !$0.isStaged && !$0.track.isStreaming }.map(\.track.id)
        // 연 때의 볼륨으로 그린다(볼륨이 빠지면 UsbStore가 시트를 닫는다)
        var model = UsbExportSheetModel(volume: request.volume, selectedTrackIDs: tracks)
        // 다시 미리 보기면 그때 고른 것을 되살린다
        if let job = request.job {
            for format in UsbFormat.allCases { model.setFormat(format, on: job.formats.contains(format)) }
            for id in job.selection.playlistIDs { model.setPlaylist(id, selected: true) }
            model.includesSelectedTracks = !job.selection.trackIDs.isEmpty && job.selection.trackIDs == tracks
            // 그때와 같은 것을 고른 경우에만 그 미리 보기를 보인다(곡 선택이 바뀌었으면 다시 미리 본다)
            if model.selection(layout: store.rekordboxPlaylists) == job.selection { model.summary = request.summary }
        }
        _model = State(initialValue: model)
    }

    private var layout: PlaylistLayout { store.rekordboxPlaylists }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            formatsSection
            sourceSection
            previewSection
            HStack {
                Spacer()
                Button(.ui("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(.ui("미리 보기")) { Task { await preview() } }
                    .disabled(isPreviewing || !model.canPreview(layout: layout))
                Button(.ui("USB에 쓰기…")) { write() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isPreviewing || !model.canWrite)
            }
        }
        .padding(20)
        .frame(width: 520)
        .frame(minHeight: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.ui("USB로 내보내기")).font(.title3.weight(.semibold))
            HStack(spacing: 6) {
                Label {
                    Text(verbatim: model.volume.name)
                } icon: {
                    Image(systemName: "externaldrive")
                }
                if model.isTestVolume {
                    Text(.ui("시험 볼륨"))
                        .font(.caption)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var formatsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.ui("형식")).font(.headline)
            HStack(spacing: 16) {
                ForEach(UsbFormat.allCases, id: \.self) { format in
                    Toggle(isOn: Binding(get: { model.formats.contains(format) }, set: { model.setFormat(format, on: $0) })) {
                        Text(verbatim: format.displayName)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.ui("원본")).font(.headline)
            List {
                ForEach(UsbExportSheetModel.rows(layout)) { row in
                    let covered = model.isCovered(row.id, layout: layout)
                    Toggle(isOn: Binding(get: { covered || model.isSelected(row.id) }, set: { model.setPlaylist(row.id, selected: $0) })) {
                        Label {
                            Text(verbatim: row.name).lineLimit(1)
                        } icon: {
                            Image(systemName: row.isFolder ? "folder" : row.isSmart ? "gearshape" : "music.note.list")
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.leading, CGFloat(row.depth) * 16)
                    .disabled(covered || row.isSmart)
                    .help(row.isSmart ? String(ui: "인텔리전트 재생 목록은 내보내지 않습니다") : row.name)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 160)
            Toggle(isOn: $model.includesSelectedTracks) {
                Text(.ui("곡 목록에서 고른 곡 \(model.selectedTrackIDs.count)개도 넣기"))
            }
            .toggleStyle(.checkbox)
            .disabled(model.selectedTrackIDs.isEmpty)
        }
    }

    @ViewBuilder private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.ui("미리 보기")).font(.headline)
            if isPreviewing {
                ProgressView().controlSize(.small)
            } else if let summary = model.summary {
                Text(.ui("곡 \(summary.trackCount)개 · 재생 목록 \(summary.playlistCount)개 · 빼고 쓰는 곡 \(summary.blockedTrackCount)개"))
                Text(verbatim: summary.spaceText)
                    .foregroundStyle(summary.isShortOfSpace ? UIColors.warning.color : Color.secondary)
                ForEach(summary.stopping, id: \.self) { message in
                    Label { Text(verbatim: message) } icon: { Image(systemName: WarningMark.symbol) }
                        .foregroundStyle(UIColors.warning.color)
                }
                ForEach(UsbWriteCoordinator.blockLines(summary), id: \.self) { line in
                    Text(verbatim: line).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(.ui("형식과 원본을 고른 뒤 미리 보기를 누르세요")).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func job() -> UsbExportJob? {
        guard let snapshot = store.snapshotURL, let selection = model.selection(layout: layout) else { return nil }
        let volume = usb.volume(request.volumeKey) ?? model.volume
        return UsbExportJob(database: snapshot, share: RekordboxShare.directory, volume: volume, selection: selection,
                            formats: model.formats, snapshotTime: nil)
    }

    private func preview() async {
        guard let job = job(), let coordinator = store.usbCoordinator else { return }
        isPreviewing = true
        defer { isPreviewing = false }
        let summary = await coordinator.preview(job)
        // 기다리는 동안 고른 것이 바뀌었으면 버린다
        if self.job() == job { model.summary = summary }
    }

    private func write() {
        guard let job = job(), let summary = model.summary, let coordinator = store.usbCoordinator else { return }
        dismiss()
        Task { await coordinator.export(job, reusing: summary) }
    }
}

/// USB에 쓰는 동안 창 전체를 덮는다: 단계·파일 수·바이트, DB 교체 전까지만 취소
struct UsbWritingOverlay: View {
    @Environment(\.textScale) private var textScale
    let model: UsbWriteProgressModel
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
            VStack(spacing: 10) {
                if let fraction = model.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().controlSize(.regular)
                }
                Text(verbatim: model.title).font(.scaled(.body, textScale).weight(.semibold))
                if let phase = model.phase {
                    Text(verbatim: [phase, model.items, model.bytes].compactMap { $0 }.joined(separator: " · "))
                        .font(.scaled(.caption, textScale).monospacedDigit())
                }
                Text(.ui("끝날 때까지 USB를 뽑지 마세요"))
                    .font(.scaled(.caption, textScale)).foregroundStyle(.secondary)
                if model.showsCancel {
                    Button(.ui("취소"), action: onCancel).keyboardShortcut(.cancelAction)
                }
            }
            .frame(minWidth: 280)
            .padding(.horizontal, 28).padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        }
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
