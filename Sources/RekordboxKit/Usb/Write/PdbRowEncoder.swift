import DJCDomain
import Foundation

/// 쪽에 넣을 행 하나
struct PdbEncodedRow: Sendable, Hashable {
    /// 할당 크기(L)까지 0으로 채운 바이트
    var bytes: Data
    /// 0x02에 index_shift(자리 × 0x20)를 쓰는 행(subtype이 있는 행)
    var hasIndexShift: Bool
    /// 문자열 인코더가 낸 확인 안 된 규칙(버리지 않고 모은다)
    var rules: Set<UsbProvisionalRule>
}

/// 행을 만들 수 없는 이유. 작성기가 막힘(`UsbError.writeRefused`)으로 바꾼다
enum PdbRowError: Error, Equatable {
    /// 칸 크기에 들어가지 않는 값(칸 이름)
    case valueOutOfRange(String)
    /// 빈 쪽에도 들어가지 않는 행
    case rowTooLarge
    /// 가까운 모양(u8 오프셋)에 들어가지 않는 행. 먼 오프셋 모양은 쓰지 않는다
    case farOffset
    /// ASCII가 아닌 ISRC(특수형에 담을 수 없음)
    case isrcNotASCII
}

/// 고정 칸 뒤에 문자열을 붙여 가며 행 하나를 만든다
struct PdbRowBytes {
    private(set) var bytes: Data
    private(set) var rules: Set<UsbProvisionalRule> = []
    private(set) var kinds: [PdbStringKind] = []
    /// 붙인 문자열마다 align4(길이)의 합(오프셋 문자열 행의 할당 크기 계산용)
    private(set) var alignedStrings = 0

    init(count: Int) {
        bytes = Data(count: count)
    }

    mutating func u8(_ value: Int, at offset: Int, _ field: String) throws {
        guard (0...0xFF).contains(value) else { throw PdbRowError.valueOutOfRange(field) }
        bytes[offset] = UInt8(value)
    }

    mutating func u16(_ value: Int, at offset: Int, _ field: String) throws {
        guard (0...0xFFFF).contains(value) else { throw PdbRowError.valueOutOfRange(field) }
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8(value >> 8)
    }

    mutating func u32(_ value: Int64, at offset: Int, _ field: String) throws {
        guard (0...0xFFFF_FFFF).contains(value) else { throw PdbRowError.valueOutOfRange(field) }
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    /// id 칸(nil = 0)
    mutating func reference(_ value: Int?, at offset: Int, _ field: String) throws {
        try u32(Int64(value ?? 0), at: offset, field)
    }

    /// 0 바이트를 덧붙인다(고정 자리 사이의 빈 칸)
    mutating func pad(_ count: Int) {
        bytes.append(Data(count: count))
    }

    /// 문자열을 끝에 붙이고 행 시작 기준 오프셋을 돌려준다. UTF-16(ISRC 특수형 포함)은 4바이트 경계로 앞을 0으로 채우고,
    /// 짧은 ASCII는 앞 문자열 바로 뒤에 붙인다.
    @discardableResult
    mutating func append(_ encoded: PdbStringEncoder.Encoded) -> Int {
        if encoded.needsAlignment { pad((4 - bytes.count % 4) % 4) }
        let offset = bytes.count
        bytes.append(encoded.bytes)
        rules.formUnion(encoded.rules)
        kinds.append(encoded.kind)
        alignedStrings += PdbRowSize.align4(encoded.bytes.count)
        return offset
    }

    /// 할당 크기까지 0으로 채운 행
    func row(size: Int, hasIndexShift: Bool) -> PdbEncodedRow {
        precondition(size >= bytes.count, "할당 크기는 행 바이트보다 작을 수 없다")
        var data = bytes
        data.append(Data(count: size - bytes.count))
        return PdbEncodedRow(bytes: data, hasIndexShift: hasIndexShift, rules: rules)
    }

    /// 단순 행(마지막 문자열 끝을 4바이트 경계로)
    func simpleRow() -> PdbEncodedRow {
        row(size: PdbRowSize.align4(bytes.count), hasIndexShift: false)
    }

    /// 오프셋 문자열 행: align4(고정 칸) + Σ align4(문자열 길이) + 4
    func offsetRow(header: Int) -> PdbEncodedRow {
        row(size: PdbRowSize.align4(header) + alignedStrings + 4, hasIndexShift: true)
    }
}

/// 행 할당 크기(L). 쓰기 전에 곡을 막을지 판단하는 데 쓴다(쓰기 계획·편집).
/// rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
public enum PdbRowSize {
    /// 쪽 머리 뒤 힙과 행 인덱스가 쓸 수 있는 바이트(4096 − 0x28)
    public static let pageCapacity = PdbPage.size - PdbPage.heapStart
    /// 가까운 모양(u8 오프셋) 아티스트·앨범·태그 행의 최대 할당 크기. 넘으면 먼 오프셋 모양이라 쓰지 않는다
    public static let nearShapeLimit = 255

    /// 트랙 행: 0x88 + Σ align4(문자열 21개 길이) + 4
    public static func track(_ track: UsbTrack, library: UsbLibrary) -> Int {
        PdbRowEncoder.trackSize(PdbRowEncoder.trackStrings(track))
    }

    /// 아티스트 행: align4(0x0A) + align4(이름 길이) + 4
    public static func artist(name: String) -> Int {
        align4(PdbRowEncoder.artistHeader) + align4(PdbStringEncoder.encoded(name).bytes.count) + 4
    }

    /// 앨범 행: align4(0x16) + align4(이름 길이) + 4
    public static func album(name: String) -> Int {
        align4(PdbRowEncoder.albumHeader) + align4(PdbStringEncoder.encoded(name).bytes.count) + 4
    }

    /// My Tag 행: align4(0x1F) + align4(이름 길이) + align4(빈 문자열) + 4
    public static func tag(name: String) -> Int {
        align4(PdbRowEncoder.tagHeader) + align4(PdbStringEncoder.encoded(name).bytes.count) + 4 + 4
    }

    /// 빈 쪽 하나에 들어가는지: L + 행 인덱스 한 자리(6바이트) ≤ 4056
    public static func fitsEmptyPage(rowSize: Int) -> Bool {
        rowSize + PdbPage.indexSize(slots: 1) <= pageCapacity
    }

    static func align4(_ value: Int) -> Int {
        (value + 3) / 4 * 4
    }
}

/// 모델 행 → pdb 행 바이트. 칸 자리는 `docs/usb-internals.md` §3.
/// rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
enum PdbRowEncoder {
    // MARK: 관찰 고정값

    static let trackSubtype = 0x0024
    static let trackBitmask: Int64 = 0x000C_0700
    static let trackU5 = 0x0029
    static let trackU7 = 3
    static let trackHeader = 0x88
    static let artistHeader = 0x0A
    static let albumHeader = 0x16
    static let tagHeader = 0x1F
    static let myTagPropertyHeader = 0x22
    static let propertyRowSize = 40
    /// 표 19 버전 문자열
    static let propertyVersion = "1000"
    /// 행 머리 뒤에 오는 이름 앞 바이트(아티스트 0x08·앨범 0x14·태그 0x1C)
    static let nameMarker = 0x03

    // MARK: tracks(0)

    /// 트랙 문자열 21개(번호 순)
    static func trackStrings(_ track: UsbTrack) -> [PdbStringEncoder.Encoded] {
        let values: [String] = [
            track.isrc, track.lyricist, track.informationUpdateCount, track.analysisDataUpdateCount, track.cueUpdateCount, "",
            track.kuvoDeliver ? "ON" : "", track.hotCueAutoLoad ? "ON" : "", "", "", track.dateCreated, track.releaseDate, track.subtitle, "",
            track.analysisDataPath, track.dateAdded, track.comment, track.title, "", track.fileName, track.path,
        ]
        return values.enumerated().map { index, value in
            index == 0 ? PdbStringEncoder.encodedISRC(value) : PdbStringEncoder.encoded(value)
        }
    }

    static func trackSize(_ strings: [PdbStringEncoder.Encoded]) -> Int {
        trackHeader + strings.reduce(0) { $0 + PdbRowSize.align4($1.bytes.count) } + 4
    }

    /// 트랙 행과 문자열 21개의 모양
    static func track(_ track: UsbTrack) throws -> (row: PdbEncodedRow, kinds: [PdbStringKind]) {
        let strings = trackStrings(track)
        guard strings[0].kind != .utf16LE else { throw PdbRowError.isrcNotASCII }
        let device = track.deviceFields[.deviceLibrary]
        var row = PdbRowBytes(count: trackHeader)
        try row.u16(trackSubtype, at: 0x00, "subtype")
        try row.u32(trackBitmask, at: 0x04, "bitmask")
        try row.u32(Int64(track.sampleRate), at: 0x08, "sampleRate")
        try row.reference(track.composerID, at: 0x0C, "composerID")
        try row.u32(track.fileSize, at: 0x10, "fileSize")
        try row.u32(track.masterContentId, at: 0x14, "masterContentId")
        try row.u32(track.masterDbId, at: 0x18, "masterDbId")
        try row.reference(track.imageID, at: 0x1C, "imageID")
        try row.reference(track.keyID, at: 0x20, "keyID")
        try row.reference(track.originalArtistID, at: 0x24, "originalArtistID")
        try row.reference(track.labelID, at: 0x28, "labelID")
        try row.reference(track.remixerID, at: 0x2C, "remixerID")
        try row.u32(Int64(track.bitrate), at: 0x30, "bitrate")
        try row.u32(Int64(track.trackNo), at: 0x34, "trackNo")
        try row.u32(Int64(track.bpmx100), at: 0x38, "bpmx100")
        try row.reference(track.genreID, at: 0x3C, "genreID")
        try row.reference(track.albumID, at: 0x40, "albumID")
        try row.reference(track.artistID, at: 0x44, "artistID")
        try row.u32(Int64(track.id), at: 0x48, "id")
        try row.u16(track.discNo, at: 0x4C, "discNo")
        try row.u16(device?.playCount ?? track.djPlayCount, at: 0x4E, "playCount")
        try row.u16(track.releaseYear, at: 0x50, "releaseYear")
        try row.u16(track.bitDepth, at: 0x52, "bitDepth")
        try row.u16(track.lengthSeconds, at: 0x54, "lengthSeconds")
        try row.u16(trackU5, at: 0x56, "u5")
        try row.u8(track.colorID, at: 0x58, "colorID")
        try row.u8(device?.rating ?? track.rating, at: 0x59, "rating")
        try row.u16(track.fileType, at: 0x5A, "fileType")
        try row.u16(trackU7, at: 0x5C, "u7")
        for (index, string) in strings.enumerated() {
            let offset = row.append(string)
            try row.u16(offset, at: 0x5E + 2 * index, "string\(index)")
        }
        return (row.row(size: trackSize(strings), hasIndexShift: true), row.kinds)
    }

    // MARK: export 표

    /// genres(1)·labels(4)·artwork(13): u32 id, 문자열 @0x04
    static func idName(id: Int, name: String) throws -> PdbEncodedRow {
        var row = PdbRowBytes(count: 4)
        try row.u32(Int64(id), at: 0, "id")
        row.append(PdbStringEncoder.encoded(name))
        return row.simpleRow()
    }

    /// artists(2), subtype 0x0060: u32 id @0x04, 0x03 @0x08, u8 이름 오프셋 @0x09
    static func artist(_ artist: UsbNamedRow) throws -> PdbEncodedRow {
        var row = PdbRowBytes(count: artistHeader)
        try row.u16(0x0060, at: 0, "subtype")
        try row.u32(Int64(artist.id), at: 0x04, "id")
        try row.u8(nameMarker, at: 0x08, "marker")
        let nameOffset = row.append(PdbStringEncoder.encoded(artist.name))
        try row.u8(nameOffset, at: 0x09, "nameOffset")
        return try near(row.offsetRow(header: artistHeader))
    }

    /// albums(3), subtype 0x0080: u32 앨범 아티스트 @0x08, u32 id @0x0C, 0x03 @0x14, u8 이름 오프셋 @0x15
    static func album(_ album: UsbAlbum) throws -> PdbEncodedRow {
        var row = PdbRowBytes(count: albumHeader)
        try row.u16(0x0080, at: 0, "subtype")
        try row.reference(album.artistID, at: 0x08, "artistID")
        try row.u32(Int64(album.id), at: 0x0C, "id")
        try row.u8(nameMarker, at: 0x14, "marker")
        let nameOffset = row.append(PdbStringEncoder.encoded(album.name))
        try row.u8(nameOffset, at: 0x15, "nameOffset")
        return try near(row.offsetRow(header: albumHeader))
    }

    /// keys(5): u32 id, u32 id, 문자열 @0x08
    static func key(_ key: UsbNamedRow) throws -> PdbEncodedRow {
        var row = PdbRowBytes(count: 8)
        try row.u32(Int64(key.id), at: 0, "id")
        try row.u32(Int64(key.id), at: 4, "id")
        row.append(PdbStringEncoder.encoded(key.name))
        return row.simpleRow()
    }

    /// colors(6): u32 0, u8 id, u16 id, u8 0, 문자열 @0x08
    static func color(_ color: UsbNamedRow) throws -> PdbEncodedRow {
        var row = PdbRowBytes(count: 8)
        try row.u8(color.id, at: 4, "id")
        try row.u16(color.id, at: 5, "id")
        row.append(PdbStringEncoder.encoded(color.name))
        return row.simpleRow()
    }

    /// playlist_tree(7): u32 parent, u32 0, u32 sort_order, u32 id, u32 is_folder, 문자열 @0x14
    static func playlistTree(id: Int, name: String, parentID: Int, sortOrder: Int, isFolder: Bool) throws -> PdbEncodedRow {
        var row = PdbRowBytes(count: 0x14)
        try row.u32(Int64(parentID), at: 0, "parentID")
        try row.u32(Int64(sortOrder), at: 0x08, "sortOrder")
        try row.u32(Int64(id), at: 0x0C, "id")
        try row.u32(isFolder ? 1 : 0, at: 0x10, "isFolder")
        row.append(PdbStringEncoder.encoded(name))
        return row.simpleRow()
    }

    /// playlist_entries(8): u32 entry_index(1부터), u32 track_id, u32 playlist_id
    static func playlistEntry(index: Int, trackID: Int, playlistID: Int) throws -> PdbEncodedRow {
        var row = PdbRowBytes(count: 12)
        try row.u32(Int64(index), at: 0, "entryIndex")
        try row.u32(Int64(trackID), at: 4, "trackID")
        try row.u32(Int64(playlistID), at: 8, "playlistID")
        return row.row(size: 12, hasIndexShift: false)
    }

    /// columns(16): u16 id, u16 kind(Class + 256), U+FFFA/B로 감싼 UTF-16 이름 @0x04
    static func column(_ item: UsbMenuItem) throws -> PdbEncodedRow {
        var row = PdbRowBytes(count: 4)
        try row.u16(item.id, at: 0, "id")
        try row.u16(item.kind, at: 2, "kind")
        row.append(PdbStringEncoder.encodedMenuName(item.name))
        return row.simpleRow()
    }

    /// category(17): u16 menuItemID, u16 id, u8 InfoOrder, u8 Disable, u16 Seq
    static func category(_ category: UsbCategory) throws -> PdbEncodedRow {
        var row = PdbRowBytes(count: 8)
        try row.u16(category.menuItemID, at: 0, "menuItemID")
        try row.u16(category.id, at: 2, "id")
        try row.u8(category.infoOrder ?? 0, at: 4, "infoOrder")
        try row.u8(categoryDisable(category), at: 5, "disable")
        try row.u16(category.sequenceNo, at: 6, "sequenceNo")
        return row.row(size: 8, hasIndexShift: false)
    }

    /// sort(18): u16 menuItemID, u16 id, u8 Disable, u8 Seq, u16 0
    static func sort(_ sort: UsbSort) throws -> PdbEncodedRow {
        var row = PdbRowBytes(count: 8)
        try row.u16(sort.menuItemID, at: 0, "menuItemID")
        try row.u16(sort.id, at: 2, "id")
        try row.u8(sortDisable(sort), at: 4, "disable")
        try row.u8(sort.sequenceNo, at: 5, "sequenceNo")
        return row.row(size: 8, hasIndexShift: false)
    }

    /// Disable이 없는 카테고리(OneLibrary에서 온 행)는 보임에서 정한다
    static func categoryDisable(_ category: UsbCategory) -> Int {
        category.disable ?? (category.isVisible ? 0 : 1)
    }

    /// Disable이 없는 정렬은 보조 칸 2, 숨김 1, 보임 0
    static func sortDisable(_ sort: UsbSort) -> Int {
        sort.disable ?? (sort.isSelectedAsSubColumn ? 2 : (sort.isVisible ? 0 : 1))
    }

    /// 표 19(subtype 0x0280, 40바이트): u32 곡 수 @0x04, 날짜 짧은 ASCII @0x0C, 버전·두 번째 문자열 오프셋 @0x17·@0x18
    static func property(trackCount: Int, date: String) throws -> PdbEncodedRow {
        guard date.utf8.count == 10, date.utf8.allSatisfy({ $0 < 0x80 }) else { throw PdbRowError.valueOutOfRange("pdbDate") }
        var row = PdbRowBytes(count: 0x0C)
        try row.u16(0x0280, at: 0, "subtype")
        try row.u32(Int64(trackCount), at: 0x04, "trackCount")
        row.append(PdbStringEncoder.encoded(date))
        row.pad(2)
        let versionOffset = row.append(PdbStringEncoder.encoded(propertyVersion))
        let nameOffset = row.append(PdbStringEncoder.encoded(""))
        try row.u8(versionOffset, at: 0x17, "versionOffset")
        try row.u8(nameOffset, at: 0x18, "nameOffset")
        return row.row(size: propertyRowSize, hasIndexShift: true)
    }

    // MARK: exportExt 표

    /// tags(3), subtype 0x0680: u32 부모 @0x0C, u32 순서 @0x10, u32 id @0x14, 분류면 u32 0x01000000 @0x18,
    /// 0x03 @0x1C, u8 이름 오프셋 @0x1D, u8 두 번째 문자열('') 오프셋 @0x1E
    static func tag(_ tag: UsbMyTag) throws -> PdbEncodedRow {
        var row = PdbRowBytes(count: tagHeader)
        try row.u16(0x0680, at: 0, "subtype")
        try row.u32(tag.parentID, at: 0x0C, "parentID")
        try row.u32(Int64(tag.sequenceNo), at: 0x10, "sequenceNo")
        try row.u32(tag.id, at: 0x14, "id")
        try row.u32(tag.isCategory ? 0x0100_0000 : 0, at: 0x18, "isCategory")
        try row.u8(nameMarker, at: 0x1C, "marker")
        let nameOffset = row.append(PdbStringEncoder.encoded(tag.name))
        let secondOffset = row.append(PdbStringEncoder.encoded(""))
        guard secondOffset <= 0xFF else { throw PdbRowError.farOffset }
        try row.u8(nameOffset, at: 0x1D, "nameOffset")
        try row.u8(secondOffset, at: 0x1E, "secondOffset")
        return try near(row.offsetRow(header: tagHeader))
    }

    /// exportExt 표 7(subtype 0x0700, 60바이트): u32 myTagMasterDBID @0x18, 0x03 @0x1C, 빈 문자열 다섯의 오프셋 @0x1D–0x21
    static func myTagProperty(masterDBID: Int64) throws -> PdbEncodedRow {
        var row = PdbRowBytes(count: myTagPropertyHeader)
        try row.u16(0x0700, at: 0, "subtype")
        try row.u32(masterDBID, at: 0x18, "myTagMasterDBID")
        try row.u8(nameMarker, at: 0x1C, "marker")
        for index in 0..<5 {
            let offset = row.append(PdbStringEncoder.encoded(""))
            try row.u8(offset, at: 0x1D + index, "stringOffset")
        }
        return row.offsetRow(header: myTagPropertyHeader)
    }

    /// 가까운 모양의 한계를 넘는 행은 먼 오프셋 모양이 필요해 쓰지 않는다
    static func near(_ row: PdbEncodedRow) throws -> PdbEncodedRow {
        guard row.bytes.count <= PdbRowSize.nearShapeLimit else { throw PdbRowError.farOffset }
        return row
    }
}
