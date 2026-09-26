import Foundation

/// anicue에 추가했지만 아직 rekordbox 컬렉션에 없는 곡.
///
/// 파일 태그로 기본 정보를 채우고, 분석으로 BPM·그리드 초안을 만든 뒤 rekordbox XML로 내보낸다.
/// 초안(그리드·큐)은 rekordbox 곡과 같은 저장소를 쓰며 rekordbox 시간축으로 저장된다.
public struct StagedTrack: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "anicue-\(uuid)" }
    public var uuid: String
    public var path: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var genre: String?
    public var composer: String?
    public var year: Int?
    public var trackNumber: Int?
    public var comment: String
    public var duration: Double
    /// 그리드 추정이 끝나면 채운다(첫 템포 구간).
    public var bpm: Double?
    /// 추정이 믿을 만한지(아니면 확인 필요 표시).
    public var gridConfident: Bool?
    public var addedOn: String
    /// rekordbox로 가져온 뒤 확인 결과(새 스냅샷에서 같은 경로의 곡을 찾아 그리드를 비교)
    public var importCheck: ImportCheck?

    public struct ImportCheck: Codable, Sendable, Hashable {
        public enum Result: String, Codable, Sendable {
            /// 보낸 그리드와 rekordbox에 들어간 그리드가 같다
            case matched
            /// 박 위치가 어긋난다(시간축 규칙 확인 필요)
            case shifted
            /// rekordbox가 그리드를 다시 분석해 BPM·구간이 바뀌었다
            case reanalyzed
            /// 아직 rekordbox가 분석하지 않았다
            case pending
            /// 보낸 그리드가 없었다
            case noGrid
        }
        public var result: Result
        /// 곡 가운데에서 rekordbox 박과 보낸 박의 최대 차이(ms)
        public var maxDeviationMs: Double?
        public var rekordboxBPM: Double?
        public var checkedOn: String

        public init(result: Result, maxDeviationMs: Double? = nil, rekordboxBPM: Double? = nil, checkedOn: String) {
            self.result = result
            self.maxDeviationMs = maxDeviationMs
            self.rekordboxBPM = rekordboxBPM
            self.checkedOn = checkedOn
        }

        /// 보낸 템포 구간(rekordbox 시간축)과 rekordbox에 들어간 그리드를 비교한다(곡 앞뒤 5%는 뺀다).
        public static func compare(sent rawSegments: [GridSegment], imported: BeatGrid?, duration: Double, checkedOn: String) -> ImportCheck {
            let sent = GridSegment.rekordboxNormalized(rawSegments)
            guard !sent.isEmpty else { return ImportCheck(result: .noGrid, checkedOn: checkedOn) }
            guard let imported, !imported.beats.isEmpty else { return ImportCheck(result: .pending, checkedOn: checkedOn) }
            let ours = GridDraft(trackUUID: "", base: [], segments: sent).grid(duration: duration + 1)
            var worst = 0.0
            for beat in imported.beats where beat.time > duration * 0.05 && beat.time < duration * 0.95 {
                let i = ours.firstIndex(atOrAfter: beat.time)
                let near = [i - 1, i].filter { ours.beats.indices.contains($0) }.map { abs(ours.beats[$0].time - beat.time) }
                worst = max(worst, near.min() ?? 1)
            }
            let rbBPM = imported.beats.first?.bpm
            let bpmChanged = rbBPM.map { abs($0 - sent[0].bpm) >= 0.01 } ?? false
            let result: Result = bpmChanged ? .reanalyzed : (worst * 1000 <= 3 ? .matched : .shifted)
            return ImportCheck(result: result, maxDeviationMs: worst * 1000, rekordboxBPM: rbBPM, checkedOn: checkedOn)
        }
    }

    public init(uuid: String = UUID().uuidString.lowercased(), path: String, title: String, artist: String? = nil,
                album: String? = nil, genre: String? = nil, composer: String? = nil, year: Int? = nil,
                trackNumber: Int? = nil, comment: String = "", duration: Double, addedOn: String) {
        self.uuid = uuid; self.path = path; self.title = title; self.artist = artist; self.album = album
        self.genre = genre; self.composer = composer; self.year = year; self.trackNumber = trackNumber
        self.comment = comment; self.duration = duration; self.addedOn = addedOn
    }

    /// 목록·덱이 rekordbox 곡과 같은 방식으로 다룰 수 있는 모양.
    public var track: Track {
        Track(id: id, uuid: uuid, title: title, artist: artist, album: album, albumArtist: nil, genre: genre,
              composer: composer, releaseYear: year, trackNumber: trackNumber, key: nil, bpm: bpm,
              lengthSeconds: Int(duration.rounded()), folderPath: path, comment: comment, importedOn: addedOn,
              analysisDataPath: nil, imagePath: nil, isDeleted: false)
    }
}
