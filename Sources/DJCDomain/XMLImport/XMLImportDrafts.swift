import Foundation

/// rekordbox XML 가져오기(#72): 고른 차이를 DJCrate 초안으로 만든다. rekordbox에는 쓰지 않는다(쓰기는 기존 반영 흐름이 한다).
///
/// - 초안의 base는 지금 라이브러리 상태다(큐는 지금 큐, 그리드는 분석 파일의 박, 태그는 지금 곡 정보, 재생 목록은 지금 목록).
/// - 기존 초안이 있는 곡·목록은 덮지 않고 이유와 함께 건너뛴다(`skipped`).
/// - 초안이 담지 못하는 차이(곡 길이 밖 큐, 메모리 큐 10개 초과, 1A~12B가 아닌 키, 쓰기 규칙을 확인하지 않은 칸 등)는 빼고 손실로 센다(`losses`).
/// - 같은 큐는 지금 행을 그대로 두어 XML에 없는 칸(활성 루프·박 루프 크기)을 잃지 않는다.
public enum XMLImportDrafts {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case cue, grid, tag, playlist

        public var label: String {
            switch self {
            case .cue: String(ui: "큐")
            case .grid: String(ui: "그리드")
            case .tag: String(ui: "태그")
            case .playlist: String(ui: "재생 목록")
            }
        }
    }

    /// 초안으로 만들 차이
    public struct Selection: Sendable, Equatable {
        public var kinds: Set<Kind> = Set(Kind.allCases)
        /// 고른 곡(라이브러리 키). nil이면 차이가 있는 모든 곡.
        public var trackKeys: Set<String>?
        /// 고른 재생 목록(경로). nil이면 차이가 있는 모든 목록.
        public var playlistPaths: Set<[String]>?
        /// 종류별로 고른 곡(라이브러리 키). 적힌 종류는 이 곡만, 적히지 않은 종류는 `trackKeys`를 따른다(미리 보기 탭마다 고르기).
        public var tracksByKind: [Kind: Set<String>] = [:]

        public init(kinds: Set<Kind> = Set(Kind.allCases), trackKeys: Set<String>? = nil, playlistPaths: Set<[String]>? = nil,
                    tracksByKind: [Kind: Set<String>] = [:]) {
            self.kinds = kinds; self.trackKeys = trackKeys; self.playlistPaths = playlistPaths; self.tracksByKind = tracksByKind
        }

        public func includes(_ kind: Kind, track key: String) -> Bool {
            guard kinds.contains(kind) else { return false }
            if let chosen = tracksByKind[kind] { return chosen.contains(key) }
            return trackKeys?.contains(key) ?? true
        }

        public static let all = Selection()
    }

    /// 곡 하나의 지금 라이브러리 상태
    public struct TrackSource: Sendable {
        public var track: Track
        public var cues: [Cue]
        /// 분석 파일의 박 격자. 없으면 nil.
        public var grid: BeatGrid?
        /// 살아 있는 재생 목록에 들었는지(태그 칸별 쓰기 범위)
        public var inPlaylist: Bool
        /// 이미 초안이 있는 종류
        public var existing: Set<Kind>

        public init(track: Track, cues: [Cue], grid: BeatGrid?, inPlaylist: Bool, existing: Set<Kind>) {
            self.track = track; self.cues = cues; self.grid = grid; self.inPlaylist = inPlaylist; self.existing = existing
        }
    }

    public struct Note: Sendable, Equatable {
        public var kind: Kind
        /// 곡이면 라이브러리 키
        public var libraryKey: String?
        /// 곡 제목이나 목록 경로
        public var subject: String
        public var reason: String

        public init(kind: Kind, libraryKey: String?, subject: String, reason: String) {
            self.kind = kind; self.libraryKey = libraryKey; self.subject = subject; self.reason = reason
        }
    }

    public struct Plan: Sendable, Equatable {
        public var cueDrafts: [CueDraft] = []
        public var gridDrafts: [GridDraft] = []
        public var tagDrafts: [TagDraft] = []
        /// 기존 재생 목록 초안에 편집을 더한 것. 더한 편집이 없으면 nil.
        public var playlistDraft: PlaylistDraft?
        /// 편집한 재생 목록 수
        public var playlistLists = 0
        /// 기존 초안이 있어 건너뛴 것
        public var skipped: [Note] = []
        /// 초안이 담지 못해 뺀 차이
        public var losses: [Note] = []

        public var isEmpty: Bool { cueDrafts.isEmpty && gridDrafts.isEmpty && tagDrafts.isEmpty && playlistDraft == nil }
    }

    public static func plan(diff: XMLLibraryDiff.Result, selection: Selection, sources: [String: TrackSource],
                            layout: PlaylistLayout, playlistDraft: PlaylistDraft) -> Plan {
        var plan = Plan()
        for change in diff.tracks {
            let wanted = Kind.allCases.filter { kind in
                guard selection.includes(kind, track: change.libraryKey) else { return false }
                switch kind {
                case .cue: return change.cues != nil
                case .grid: return change.grid != nil
                case .tag: return !change.tags.isEmpty
                case .playlist: return false
                }
            }
            guard !wanted.isEmpty else { continue }
            guard let source = sources[change.libraryKey] else {
                for kind in wanted {
                    plan.skipped.append(Note(kind: kind, libraryKey: change.libraryKey, subject: change.title,
                                             reason: String(ui: "곡을 라이브러리에서 찾지 못했습니다. 스냅샷을 새로 뜬 뒤 다시 가져오세요")))
                }
                continue
            }
            for kind in wanted {
                if source.existing.contains(kind) {
                    plan.skipped.append(Note(kind: kind, libraryKey: change.libraryKey, subject: change.title, reason: existingReason(kind)))
                    continue
                }
                func loss(_ reason: String) {
                    plan.losses.append(Note(kind: kind, libraryKey: change.libraryKey, subject: change.title, reason: reason))
                }
                switch kind {
                case .cue: if let cues = change.cues, let draft = cueDraft(cues, source: source, loss: loss) { plan.cueDrafts.append(draft) }
                case .grid: if let grid = change.grid, let draft = gridDraft(grid, source: source, loss: loss) { plan.gridDrafts.append(draft) }
                case .tag: if let draft = tagDraft(change.tags, source: source, loss: loss) { plan.tagDrafts.append(draft) }
                case .playlist: break
                }
            }
        }
        if selection.kinds.contains(.playlist) {
            let changes = diff.playlists.filter { selection.playlistPaths?.contains($0.path) ?? true }
            playlists(changes, layout: layout, draft: playlistDraft, into: &plan)
        }
        return plan
    }

    public static func existingReason(_ kind: Kind) -> String {
        switch kind {
        case .cue: String(ui: "이 곡에 큐 초안이 이미 있어 덮지 않았습니다. 그 초안을 쓰거나 버린 뒤 다시 가져오세요")
        case .grid: String(ui: "이 곡에 그리드 초안이 이미 있어 덮지 않았습니다. 그 초안을 쓰거나 버린 뒤 다시 가져오세요")
        case .tag: String(ui: "이 곡에 태그 초안이 이미 있어 덮지 않았습니다. 그 초안을 쓰거나 버린 뒤 다시 가져오세요")
        case .playlist: String(ui: "이 목록에 재생 목록 초안이 이미 있어 덮지 않았습니다. 그 초안을 쓰거나 버린 뒤 다시 가져오세요")
        }
    }

    // MARK: 큐

    static func mark(of cue: EditableCue) -> XMLLibrary.Mark {
        XMLLibrary.Mark(kind: cue.kind, start: cue.time, end: cue.loop?.end, name: cue.name)
    }

    static func cueDraft(_ change: XMLLibraryDiff.CueChange, source: TrackSource, loss: (String) -> Void) -> CueDraft? {
        var draft = CueDraft(trackUUID: source.track.uuid, rekordboxCues: source.cues)
        var remaining = draft.base
        var kept: [EditableCue] = [], added: [XMLLibrary.Mark] = []
        for mark in change.xml {
            if let index = remaining.firstIndex(where: { XMLLibraryDiff.sameMark(Self.mark(of: $0), mark) }) {
                kept.append(remaining.remove(at: index))
            } else {
                added.append(mark)
            }
        }
        let duration = Double(source.track.lengthSeconds)
        var cues = kept
        for mark in XMLLibraryDiff.sorted(added) {
            if mark.start < 0 || mark.start > duration || (mark.end ?? 0) > duration {
                loss(String(ui: "곡 길이를 벗어난 큐는 넣지 않았습니다"))
                continue
            }
            switch mark.kind {
            case .memory:
                if cues.filter({ $0.kind == .memory }).count >= CueDraft.memoryLimit {
                    loss(String(ui: "메모리 큐는 곡당 \(CueDraft.memoryLimit)개까지라 넘는 큐는 넣지 않았습니다"))
                    continue
                }
            case .hot:
                if cues.contains(where: { $0.kind == mark.kind }) {
                    loss(String(ui: "같은 핫큐 슬롯 \(mark.kind.slotLetter ?? "")에 큐가 여럿이라 하나만 넣었습니다"))
                    continue
                }
            }
            cues.append(EditableCue(kind: mark.kind, time: mark.start, name: mark.name, loop: mark.end.map { EditableCue.Loop(end: $0) }))
        }
        draft.cues = cues.sorted { $0.time < $1.time }
        return draft.hasChanges ? draft : nil
    }

    // MARK: 그리드

    static func gridDraft(_ change: XMLLibraryDiff.GridChange, source: TrackSource, loss: (String) -> Void) -> GridDraft? {
        guard let grid = source.grid, !grid.beats.isEmpty else {
            loss(String(ui: "분석 파일의 그리드가 없는 곡은 그리드 초안을 만들 수 없습니다. rekordbox에서 트랙 분석을 먼저 한 뒤 다시 가져오세요"))
            return nil
        }
        let duration = Double(source.track.lengthSeconds)
        guard GridEditEligibility.reconstructionErrorMilliseconds(of: grid, duration: duration) <= 2 else {
            loss(String(ui: "이 곡의 그리드는 구간으로 다룰 수 없어 그리드 초안을 만들지 않았습니다. 덱에서 그리드를 직접 고치세요"))
            return nil
        }
        let segments = change.xml.sorted { $0.start < $1.start }
        let valid = !segments.isEmpty && segments.allSatisfy {
            $0.start.isFinite && $0.start < duration && GridDraft.bpmRange.contains($0.bpm) && (1...4).contains($0.firstBeatNumber)
        } && zip(segments, segments.dropFirst()).allSatisfy { $0.start < $1.start }
        guard valid else {
            loss(String(ui: "XML 그리드의 BPM·박 번호·시작이 쓸 수 있는 범위를 벗어나 그리드 초안을 만들지 않았습니다"))
            return nil
        }
        var draft = GridDraft(trackUUID: source.track.uuid, grid: grid)
        draft.segments = segments
        return draft.hasChanges ? draft : nil
    }

    // MARK: 태그

    static func tagDraft(_ changes: [XMLLibraryDiff.TagChange], source: TrackSource, loss: (String) -> Void) -> TagDraft? {
        var draft = TagDraft(track: source.track)
        for change in changes {
            var value = change.xml
            switch change.key {
            case .musicalKey:
                guard value.isEmpty || KeyNotation.normalizedCamelotName(value) != nil else {
                    loss(String(ui: "키 \(value)는 1A~12B로 읽을 수 없어 넣지 않았습니다"))
                    continue
                }
                value = value.isEmpty ? "" : KeyNotation.normalizedCamelotName(value) ?? value
            case .rating:
                guard let accepted = TrackRating.accepted(value) else {
                    loss(String(ui: "평점 \(value)는 별 0~5개로 읽을 수 없어 넣지 않았습니다"))
                    continue
                }
                value = accepted
            case .title:
                guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                    loss(String(ui: "빈 제목은 넣지 않았습니다"))
                    continue
                }
            case .year, .trackNumber:
                guard value.isEmpty || (Int(value).map { $0 >= 0 } ?? false) else {
                    loss(String(ui: "\(change.key.label) \(value)는 0 이상의 숫자가 아니라 넣지 않았습니다"))
                    continue
                }
            default:
                break
            }
            if let reason = TagWriteScope.blockReason(keys: [change.key], state: source.track.dataStatus, inPlaylist: source.inPlaylist) {
                loss(reason)
                continue
            }
            draft.fields[change.key] = value
        }
        guard draft.hasChanges else { return nil }
        guard draft.issues.isEmpty else {
            for issue in draft.issues { loss(issue) }
            return nil
        }
        return draft
    }

    // MARK: 재생 목록

    static func ref(_ layoutID: String) -> PlaylistRef {
        if layoutID == PlaylistLayout.root { return .root }
        return layoutID.hasPrefix("new:") ? .new(String(layoutID.dropFirst(4))) : .id(layoutID)
    }

    static func playlists(_ changes: [XMLLibraryDiff.PlaylistChange], layout: PlaylistLayout, draft initial: PlaylistDraft,
                          into plan: inout Plan) {
        var draft = initial
        var edited = 0
        // 새 목록·폴더는 부모 맨 위에 생기므로, 뒤 목록부터 만들어 XML 순서를 지킨다.
        let ordered = changes.filter { $0.kind == .changed } + changes.filter { $0.kind == .missing }.reversed()
        for change in ordered {
            let subject = change.path.joined(separator: " / ")
            func note(_ reason: String) { plan.losses.append(Note(kind: .playlist, libraryKey: nil, subject: subject, reason: reason)) }
            var trial = draft
            do {
                switch change.kind {
                case .changed:
                    guard let id = change.libraryID, let item = layout.item(id), item.holdsTracks else {
                        note(String(ui: "목록을 라이브러리에서 찾지 못했습니다. 스냅샷을 새로 뜬 뒤 다시 가져오세요"))
                        continue
                    }
                    if draft.base[id] != nil || draft.steps.contains(where: { $0.edit.playlist == .id(id) }) {
                        plan.skipped.append(Note(kind: .playlist, libraryKey: nil, subject: subject, reason: existingReason(.playlist)))
                        continue
                    }
                    guard item.trackIDs == change.libraryEntries else {
                        note(String(ui: "비교하지 않은 곡(스트리밍·지운 곡)이 든 목록이라 바꾸지 않았습니다. rekordbox에서 직접 고치세요"))
                        continue
                    }
                    if !item.entries.isEmpty { try trial.append(.removeTracks(playlist: .id(id), entries: item.entries), rekordbox: layout) }
                    if !change.xmlEntries.isEmpty { try trial.append(.addTracks(playlist: .id(id), contentIDs: change.xmlEntries), rekordbox: layout) }
                case .missing:
                    var projected = trial.project(onto: layout).layout
                    var parent = PlaylistLayout.root
                    var blocked = false
                    for name in change.path.dropLast() {
                        let same = projected.children(of: parent).filter { $0.name == name }
                        if same.count == 1, same[0].isFolder {
                            parent = same[0].id
                        } else if same.isEmpty {
                            let key = UUID().uuidString
                            projected = try trial.append(.create(key: key, name: name, isFolder: true, parent: ref(parent)), rekordbox: layout)
                            parent = PlaylistRef.new(key).layoutID
                        } else {
                            blocked = true
                            break
                        }
                    }
                    guard !blocked, let name = change.path.last else {
                        note(String(ui: "이름이 같은 폴더가 여럿이거나 목록과 겹쳐 어느 폴더에 만들지 모릅니다. rekordbox에서 이름을 정리한 뒤 다시 가져오세요"))
                        continue
                    }
                    if projected.children(of: parent).contains(where: { $0.name == name }) {
                        plan.skipped.append(Note(kind: .playlist, libraryKey: nil, subject: subject,
                                                 reason: String(ui: "같은 이름의 목록이 재생 목록 초안에 이미 있어 덮지 않았습니다")))
                        continue
                    }
                    let key = UUID().uuidString
                    try trial.append(.create(key: key, name: name, isFolder: false, parent: ref(parent)), rekordbox: layout)
                    if !change.xmlEntries.isEmpty { try trial.append(.addTracks(playlist: .new(key), contentIDs: change.xmlEntries), rekordbox: layout) }
                }
            } catch let blocked as PlaylistLayout.Blocked {
                note(blocked.reason)
                continue
            } catch {
                note(String(describing: error))
                continue
            }
            draft = trial
            edited += 1
        }
        plan.playlistLists = edited
        plan.playlistDraft = edited > 0 ? draft : nil
    }
}
