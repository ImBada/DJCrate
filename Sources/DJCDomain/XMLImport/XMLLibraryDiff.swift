import Foundation

/// rekordbox XML과 지금 라이브러리의 차이(#72 가져오기). 읽기만 하고, 고른 차이를 초안으로 만드는 일은 부르는 쪽이 한다.
///
/// - 곡은 파일 경로로 맞춘다(`XMLTrackMatching`). 못 맞춘 곡·여러 곡에 맞는 곡은 비교하지 않고 센다.
/// - 큐: 종류·위치(1ms 미만은 같음)·루프 끝·이름이 모두 같은 큐끼리 짝짓고, 남은 것을 더할 것·뺄 것으로 낸다.
/// - 그리드: XML에 TEMPO가 있을 때만. 첫 구간을 곡 시작 쪽 첫 박으로 당겨(같은 그리드를 다른 박부터 적어도 같게) 비교한다.
/// - 태그: XML에 있는 칸만. 연도·트랙 번호 0은 빈칸, 키는 표기가 달라도 같은 키면 같다.
/// - 재생 목록: 폴더 이름 경로로 맞춘다. 라이브러리에 없는 목록, 곡(맞춘 곡만)·순서가 다른 목록을 낸다.
///   라이브러리에만 있는 목록은 차이로 치지 않는다(가져오기는 지우지 않는다).
public enum XMLLibraryDiff {
    public struct TagChange: Sendable, Hashable {
        public var key: TagFields.Key
        /// 지금 라이브러리 값
        public var library: String
        /// XML 값(초안에 넣을 모양: 키는 Camelot으로 읽을 수 있으면 Camelot, 연도·트랙 번호 0은 빈칸)
        public var xml: String

        public init(key: TagFields.Key, library: String, xml: String) { self.key = key; self.library = library; self.xml = xml }
    }

    public struct CueChange: Sendable, Equatable {
        public var library: [XMLLibrary.Mark]
        public var xml: [XMLLibrary.Mark]
        /// XML에만 있는 큐
        public var added: [XMLLibrary.Mark]
        /// 라이브러리에만 있는 큐
        public var removed: [XMLLibrary.Mark]
    }

    public struct GridChange: Sendable, Equatable, Codable {
        /// 지금 라이브러리 템포 구간(분석 파일이 없으면 빈 배열)
        public var library: [GridSegment]
        public var xml: [GridSegment]
    }

    public struct TrackDiff: Sendable, Equatable {
        public var xmlKey: String
        public var libraryKey: String
        public var path: String
        public var title: String
        public var cues: CueChange?
        public var grid: GridChange?
        public var tags: [TagChange]
    }

    public struct PlaylistChange: Sendable, Equatable {
        public enum Kind: String, Sendable, Codable {
            /// 라이브러리에 없는 목록
            case missing
            /// 곡이나 순서가 다른 목록
            case changed
        }

        public var kind: Kind
        /// 폴더 이름들 + 목록 이름
        public var path: [String]
        /// 라이브러리 목록 ID(`changed`일 때)
        public var libraryID: String?
        /// XML 목록의 곡을 라이브러리 키로(맞춘 곡만, 순서대로)
        public var xmlEntries: [String]
        public var libraryEntries: [String]
        /// 맞추지 못했거나 모호해 뺀 XML 항목 수
        public var unmatchedEntries: Int
    }

    public struct Matching: Sendable, Equatable, Codable {
        public var xmlTracks = 0
        public var matched = 0
        public var unmatched = 0
        public var ambiguous = 0

        public init(xmlTracks: Int = 0, matched: Int = 0, unmatched: Int = 0, ambiguous: Int = 0) {
            self.xmlTracks = xmlTracks; self.matched = matched; self.unmatched = unmatched; self.ambiguous = ambiguous
        }
    }

    public struct Counts: Sendable, Equatable, Codable {
        public var cueTracks = 0
        public var gridTracks = 0
        public var tagTracks = 0
        public var missingPlaylists = 0
        public var changedPlaylists = 0
        /// 같은 경로의 목록이 여럿이거나 폴더·목록이 엇갈려 비교하지 않은 목록
        public var ambiguousPlaylists = 0
        public var libraryOnlyPlaylists = 0
        /// TEMPO가 없어 그리드를 비교하지 않은 XML 곡(맞춘 곡만)
        public var xmlWithoutGrid = 0
    }

    public struct Result: Sendable, Equatable {
        public var matching = Matching()
        public var matches = XMLTrackMatching.Result()
        /// 차이가 있는 곡만, XML 순서
        public var tracks: [TrackDiff] = []
        /// XML 트리 순서
        public var playlists: [PlaylistChange] = []
        public var counts = Counts()

        public var isEmpty: Bool { tracks.isEmpty && playlists.isEmpty }
    }

    /// 1ms 미만의 위치 차이는 같은 큐다(XML은 소수 셋째 자리).
    static let timeTolerance = 0.001

    public static func compute(xml: XMLLibrary, library: XMLLibrary) -> Result {
        var result = Result()
        let matches = XMLTrackMatching.match(xml: xml.tracks, library: library.tracks)
        result.matches = matches
        result.matching = Matching(xmlTracks: xml.tracks.count, matched: matches.matched.count,
                                   unmatched: matches.unmatched.count, ambiguous: matches.ambiguous.count)
        let libraryTracks = Dictionary(library.tracks.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        for track in xml.tracks {
            guard let libraryKey = matches.matched[track.key], let current = libraryTracks[libraryKey] else { continue }
            let cues = cueChange(xml: track.marks, library: current.marks)
            var grid: GridChange?
            if track.tempos.isEmpty {
                result.counts.xmlWithoutGrid += 1
            } else if library.hasGrids, !sameGrid(track.tempos, current.tempos) {
                grid = GridChange(library: current.tempos, xml: track.tempos)
            }
            let tags = tagChanges(xml: track.tags, library: current.tags)
            guard cues != nil || grid != nil || !tags.isEmpty else { continue }
            if cues != nil { result.counts.cueTracks += 1 }
            if grid != nil { result.counts.gridTracks += 1 }
            if !tags.isEmpty { result.counts.tagTracks += 1 }
            result.tracks.append(TrackDiff(xmlKey: track.key, libraryKey: libraryKey, path: current.path ?? track.path ?? "",
                                           title: current.title, cues: cues, grid: grid, tags: tags))
        }
        playlistChanges(xml: xml.lists, library: library.lists, matched: matches.matched, into: &result)
        return result
    }

    // MARK: 큐

    static func sameMark(_ a: XMLLibrary.Mark, _ b: XMLLibrary.Mark) -> Bool {
        guard a.kind == b.kind, a.name == b.name, abs(a.start - b.start) < timeTolerance else { return false }
        switch (a.end, b.end) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) < timeTolerance
        default: return false
        }
    }

    static func cueChange(xml: [XMLLibrary.Mark], library: [XMLLibrary.Mark]) -> CueChange? {
        var remaining = library
        var added: [XMLLibrary.Mark] = []
        for mark in xml {
            if let index = remaining.firstIndex(where: { sameMark($0, mark) }) { remaining.remove(at: index) } else { added.append(mark) }
        }
        guard !added.isEmpty || !remaining.isEmpty else { return nil }
        return CueChange(library: sorted(library), xml: sorted(xml), added: sorted(added), removed: sorted(remaining))
    }

    static func sorted(_ marks: [XMLLibrary.Mark]) -> [XMLLibrary.Mark] {
        func order(_ kind: EditableCue.Kind) -> Int {
            if case let .hot(slot) = kind { return slot } else { return -1 }
        }
        return marks.sorted { ($0.start, order($0.kind)) < ($1.start, order($1.kind)) }
    }

    // MARK: 그리드

    static func sameGrid(_ a: [GridSegment], _ b: [GridSegment]) -> Bool {
        let x = GridSegment.rekordboxNormalized(a), y = GridSegment.rekordboxNormalized(b)
        guard x.count == y.count else { return false }
        return zip(x, y).allSatisfy { p, q in
            abs(p.start - q.start) < timeTolerance && abs(p.bpm - q.bpm) < 0.005 && p.firstBeatNumber == q.firstBeatNumber
        }
    }

    // MARK: 태그

    /// 비교할 모양. 연도·트랙 번호·평점 0은 빈칸, 키는 Camelot으로 읽을 수 있으면 Camelot.
    public static func normalizedTag(_ key: TagFields.Key, _ value: String) -> String {
        switch key {
        case .year, .trackNumber, .rating:
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if let number = Int(trimmed) { return number == 0 ? "" : String(number) }
            return trimmed
        case .musicalKey:
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "" : KeyNotation.camelot(from: trimmed) ?? trimmed
        default:
            return value
        }
    }

    static func tagChanges(xml: [TagFields.Key: String], library: [TagFields.Key: String]) -> [TagChange] {
        TagFields.Key.allCases.compactMap { key in
            guard let value = xml[key] else { return nil }
            let current = library[key] ?? ""
            let incoming = normalizedTag(key, value)
            return normalizedTag(key, current) == incoming ? nil : TagChange(key: key, library: current, xml: incoming)
        }
    }

    // MARK: 재생 목록

    static func flatten(_ nodes: [XMLLibrary.Node], prefix: [String] = []) -> [(path: [String], node: XMLLibrary.Node)] {
        nodes.flatMap { node -> [(path: [String], node: XMLLibrary.Node)] in
            let path = prefix + [node.name]
            return [(path, node)] + flatten(node.children ?? [], prefix: path)
        }
    }

    static func playlistChanges(xml: [XMLLibrary.Node], library: [XMLLibrary.Node], matched: [String: String], into result: inout Result) {
        let xmlNodes = flatten(xml), libraryNodes = flatten(library)
        let libraryByPath = Dictionary(grouping: libraryNodes, by: \.path)
        let xmlPaths = Dictionary(grouping: xmlNodes.filter { !$0.node.isFolder }, by: \.path)
        for (path, node) in xmlNodes where !node.isFolder {
            var unmatched = 0
            let entries = node.entries.compactMap { key -> String? in
                if let libraryKey = matched[key] { return libraryKey }
                unmatched += 1
                return nil
            }
            let candidates = libraryByPath[path] ?? []
            guard xmlPaths[path]?.count == 1, candidates.count <= 1, candidates.first?.node.isFolder != true else {
                result.counts.ambiguousPlaylists += 1
                continue
            }
            if let current = candidates.first?.node {
                guard current.entries != entries else { continue }
                result.counts.changedPlaylists += 1
                result.playlists.append(PlaylistChange(kind: .changed, path: path, libraryID: current.id, xmlEntries: entries,
                                                       libraryEntries: current.entries, unmatchedEntries: unmatched))
            } else {
                result.counts.missingPlaylists += 1
                result.playlists.append(PlaylistChange(kind: .missing, path: path, libraryID: nil, xmlEntries: entries,
                                                       libraryEntries: [], unmatchedEntries: unmatched))
            }
        }
        result.counts.libraryOnlyPlaylists = libraryNodes.filter { !$0.node.isFolder && xmlPaths[$0.path] == nil }.count
    }
}
