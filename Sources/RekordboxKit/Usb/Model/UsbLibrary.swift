import DJCDomain
import Foundation

/// USB 라이브러리 형식 중립 모델. OneLibrary·Device Library 두 형식의 칸을 모두 담는다.
/// 한 형식 리더가 만든 모델은 `formats`가 그 형식 하나이고, 그 형식이 담지 않는 칸은 `UsbFieldFormats`의 기본값이다.
/// 배열은 모두 id(또는 자연 키) 오름차순이라 같은 USB를 두 번 읽으면 구조체가 같다.
public struct UsbLibrary: Sendable, Hashable {
    /// 이 모델에 담긴 형식
    public var formats: Set<UsbFormat>
    public var property: UsbProperty
    /// id 오름차순
    public var tracks: [UsbTrack]
    public var artists: [UsbNamedRow]
    public var albums: [UsbAlbum]
    public var genres: [UsbNamedRow]
    public var keys: [UsbNamedRow]
    public var labels: [UsbNamedRow]
    /// id = 로컬 djmdColor.ID, name = Commnt
    public var colors: [UsbNamedRow]
    public var images: [UsbImage]
    public var playlists: [UsbPlaylist]
    public var myTags: [UsbMyTag]
    public var myTagLinks: [UsbMyTagLink]
    public var menuItems: [UsbMenuItem]
    public var categories: [UsbCategory]
    public var sorts: [UsbSort]
    public var histories: [UsbHistory]
    /// 형식·표 번호·산 행 수(모델에 담지 않는 표)
    public var unknownRows: [UsbUnknownRows]
    /// pdb 죽은 행 ID. 지운 ID를 다시 쓰지 않으려고 둔다
    public var deadIDs: [UsbIDKindKey: Set<Int>]
    /// pdb 트랙 행의 상수 칸 관찰값(왕복 검사용)
    public var trackRowExtras: [Int: UsbPdbTrackExtras]

    public init(formats: Set<UsbFormat>, property: UsbProperty, tracks: [UsbTrack] = [], artists: [UsbNamedRow] = [],
                albums: [UsbAlbum] = [], genres: [UsbNamedRow] = [], keys: [UsbNamedRow] = [], labels: [UsbNamedRow] = [],
                colors: [UsbNamedRow] = [], images: [UsbImage] = [], playlists: [UsbPlaylist] = [], myTags: [UsbMyTag] = [],
                myTagLinks: [UsbMyTagLink] = [], menuItems: [UsbMenuItem] = [], categories: [UsbCategory] = [], sorts: [UsbSort] = [],
                histories: [UsbHistory] = [], unknownRows: [UsbUnknownRows] = [], deadIDs: [UsbIDKindKey: Set<Int>] = [:],
                trackRowExtras: [Int: UsbPdbTrackExtras] = [:]) {
        self.formats = formats
        self.property = property
        self.tracks = tracks
        self.artists = artists
        self.albums = albums
        self.genres = genres
        self.keys = keys
        self.labels = labels
        self.colors = colors
        self.images = images
        self.playlists = playlists
        self.myTags = myTags
        self.myTagLinks = myTagLinks
        self.menuItems = menuItems
        self.categories = categories
        self.sorts = sorts
        self.histories = histories
        self.unknownRows = unknownRows
        self.deadIDs = deadIDs
        self.trackRowExtras = trackRowExtras
    }

    public static let empty = UsbLibrary(formats: [], property: UsbProperty())

    /// 한 형식만 본 모델. 쓰기·검증은 늘 이 투영과 비교한다.
    /// 그 형식에 있는 곡·목록·My Tag 연결과 그 형식의 기록·모르는 표만 남기고, 그 형식이 담지 않는 칸은 그 형식 리더의 기본값으로 바꾼다.
    public func projected(to format: UsbFormat) -> UsbLibrary {
        var result = UsbFieldFormats.library.projecting(self, to: format)
        result.formats = [format]
        result.property = UsbFieldFormats.property.projecting(property, to: format)
        result.tracks = tracks.filter { $0.presentIn.contains(format) }.map { track in
            var track = UsbFieldFormats.track.projecting(track, to: format)
            track.presentIn = [format]
            track.deviceFields = track.deviceFields.filter { $0.key == format }
            return track
        }
        result.artists = artists.map { UsbFieldFormats.namedRow.projecting($0, to: format) }
        result.albums = albums.map { UsbFieldFormats.album.projecting($0, to: format) }
        result.genres = genres.map { UsbFieldFormats.namedRow.projecting($0, to: format) }
        result.keys = keys.map { UsbFieldFormats.namedRow.projecting($0, to: format) }
        result.labels = labels.map { UsbFieldFormats.namedRow.projecting($0, to: format) }
        result.colors = colors.map { UsbFieldFormats.namedRow.projecting($0, to: format) }
        result.images = images.map { UsbFieldFormats.image.projecting($0, to: format) }
        result.playlists = playlists.filter { $0.presentIn.contains(format) }.map { playlist in
            var playlist = UsbFieldFormats.playlist.projecting(playlist, to: format)
            playlist.presentIn = [format]
            playlist.sortOrder = playlist.sortOrder.filter { $0.key == format }
            playlist.entries = playlist.entries.filter { $0.key == format }
            return playlist
        }
        result.myTags = myTags.map { UsbFieldFormats.myTag.projecting($0, to: format) }
        result.myTagLinks = myTagLinks.filter { $0.presentIn.contains(format) }.map { link in
            var link = link
            link.presentIn = [format]
            return link
        }
        result.menuItems = menuItems.map { UsbFieldFormats.menuItem.projecting($0, to: format) }
        result.categories = categories.map { UsbFieldFormats.category.projecting($0, to: format) }
        result.sorts = sorts.map { UsbFieldFormats.sort.projecting($0, to: format) }
        result.histories = histories.filter { $0.format == format }
        result.unknownRows = unknownRows.filter { $0.format == format }
        return result
    }

    /// 두 형식을 한 모델로 합친다. 각 입력은 그 형식으로 투영해서 쓴다.
    /// - 한 형식에만 있는 칸은 그 형식 값을 그대로 가진다(비교하지 않는다).
    /// - 두 형식 모두의 칸은 OneLibrary 값이 앞서고, 다르면 불일치로 보고한다.
    /// - 같은 id가 다른 파일을 가리키는 곡, 같은 id인데 이름·부모·종류가 다른 목록은 합치지 않고 OneLibrary 쪽만 남긴다(편집 금지 불일치).
    /// - artist·album 같은 공유 표 행이 한 형식에만 있으면 합집합에 두고 `sharedRowDiffers`로 보고한다.
    public static func merge(oneLibrary: UsbLibrary?, deviceLibrary: UsbLibrary?) -> (UsbLibrary, [UsbFormatMismatch]) {
        guard let oneLibrary else { return (deviceLibrary ?? .empty, []) }
        guard let deviceLibrary else { return (oneLibrary, []) }
        let a = oneLibrary.projected(to: .oneLibrary), b = deviceLibrary.projected(to: .deviceLibrary)
        var mismatches: [UsbFormatMismatch] = []
        var result = UsbLibrary(formats: a.formats.union(b.formats), property: a.property)

        result.tracks = union(a.tracks, b.tracks, id: \.id).map { left, right in
            guard let left, let right else {
                let only = (left ?? right)!
                mismatches.append(.trackOnlyIn(left == nil ? .deviceLibrary : .oneLibrary, id: only.id))
                return only
            }
            guard UsbLayout.nfc(left.path) == UsbLayout.nfc(right.path) else {
                mismatches.append(.trackPathDiffers(id: left.id))
                return left
            }
            let merged = UsbFieldFormats.track.merging(oneLibrary: left, deviceLibrary: right)
            var track = merged.0
            mismatches += merged.differing.map { .trackFieldDiffers(id: left.id, field: $0) }
            track.presentIn = left.presentIn.union(right.presentIn)
            track.deviceFields = left.deviceFields.merging(right.deviceFields) { first, _ in first }
            return track
        }

        result.playlists = union(a.playlists, b.playlists, id: \.id).map { left, right in
            guard let left, let right else {
                let only = (left ?? right)!
                mismatches.append(.playlistOnlyIn(left == nil ? .deviceLibrary : .oneLibrary, id: only.id))
                return only
            }
            guard left.name == right.name, left.parentID == right.parentID, left.attribute == right.attribute else {
                mismatches.append(.playlistConflict(id: left.id))
                return left
            }
            var playlist = UsbFieldFormats.playlist.merging(oneLibrary: left, deviceLibrary: right).0
            playlist.presentIn = left.presentIn.union(right.presentIn)
            playlist.sortOrder = left.sortOrder.merging(right.sortOrder) { first, _ in first }
            playlist.entries = left.entries.merging(right.entries) { first, _ in first }
            if left.entries[.oneLibrary] ?? [] != right.entries[.deviceLibrary] ?? [] {
                mismatches.append(.playlistEntriesDiffer(id: left.id))
            }
            return playlist
        }

        // 공유 표 행에는 형식별 소속이 없어 투영이 거를 수 없다. 한 형식에만 있는 행은 합집합에 두되 불일치로 보고한다
        // (보고하지 않으면 "불일치 없는 USB의 투영 = 한 형식 모델"이 깨진다).
        func shared<Row>(_ table: String, _ left: [Row], _ right: [Row], id: KeyPath<Row, Int>, rules: [UsbFieldRule<Row>]) -> [Row] {
            union(left, right, id: id).map { left, right in
                guard let left, let right else {
                    let only = (left ?? right)!
                    mismatches.append(.sharedRowDiffers(table: table, id: only[keyPath: id]))
                    return only
                }
                let (row, differing) = rules.merging(oneLibrary: left, deviceLibrary: right)
                if !differing.isEmpty { mismatches.append(.sharedRowDiffers(table: table, id: left[keyPath: id])) }
                return row
            }
        }
        result.artists = shared("artist", a.artists, b.artists, id: \.id, rules: UsbFieldFormats.namedRow)
        result.albums = shared("album", a.albums, b.albums, id: \.id, rules: UsbFieldFormats.album)
        result.genres = shared("genre", a.genres, b.genres, id: \.id, rules: UsbFieldFormats.namedRow)
        result.keys = shared("key", a.keys, b.keys, id: \.id, rules: UsbFieldFormats.namedRow)
        result.labels = shared("label", a.labels, b.labels, id: \.id, rules: UsbFieldFormats.namedRow)
        result.colors = shared("color", a.colors, b.colors, id: \.id, rules: UsbFieldFormats.namedRow)
        result.images = shared("image", a.images, b.images, id: \.id, rules: UsbFieldFormats.image)
        result.myTags = shared("myTag", a.myTags, b.myTags, id: \.intID, rules: UsbFieldFormats.myTag)
        result.menuItems = shared("menuItem", a.menuItems, b.menuItems, id: \.id, rules: UsbFieldFormats.menuItem)
        result.categories = shared("category", a.categories, b.categories, id: \.id, rules: UsbFieldFormats.category)
        result.sorts = shared("sort", a.sorts, b.sorts, id: \.id, rules: UsbFieldFormats.sort)

        var links: [UsbMyTagLink] = []
        var linkIndex: [UsbMyTagLink.Key: Int] = [:]
        for link in a.myTagLinks + b.myTagLinks {
            if let index = linkIndex[link.key] {
                links[index].presentIn.formUnion(link.presentIn)
            } else {
                linkIndex[link.key] = links.count
                links.append(link)
            }
        }
        result.myTagLinks = links
        result.histories = a.histories + b.histories
        result.unknownRows = a.unknownRows + b.unknownRows
        result.deadIDs = a.deadIDs.merging(b.deadIDs) { $0.union($1) }
        result.trackRowExtras = a.trackRowExtras.merging(b.trackRowExtras) { _, right in right }

        let (property, differing) = UsbFieldFormats.property.merging(oneLibrary: a.property, deviceLibrary: b.property)
        result.property = property
        mismatches += differing.map { .propertyDiffers(field: $0) }
        return (result.canonicalized(), mismatches)
    }

    /// 배열을 정해진 순서로(같은 내용이면 같은 구조체가 되게)
    public func canonicalized() -> UsbLibrary {
        var result = self
        result.tracks.sort { $0.id < $1.id }
        for path in [\UsbLibrary.artists, \.genres, \.keys, \.labels, \.colors] { result[keyPath: path].sort { $0.id < $1.id } }
        result.albums.sort { $0.id < $1.id }
        result.images.sort { $0.id < $1.id }
        result.playlists.sort { $0.id < $1.id }
        result.myTags.sort { $0.id < $1.id }
        result.myTagLinks.sort { ($0.myTagID, $0.contentID) < ($1.myTagID, $1.contentID) }
        result.menuItems.sort { $0.id < $1.id }
        result.categories.sort { $0.id < $1.id }
        result.sorts.sort { $0.id < $1.id }
        result.histories.sort { ($0.format.order, $0.id) < ($1.format.order, $1.id) }
        result.unknownRows.sort { ($0.format.order, $0.file, $0.tableType) < ($1.format.order, $1.file, $1.tableType) }
        return result
    }

    /// 두 배열을 id로 짝짓는다(왼쪽 순서 뒤에 오른쪽에만 있는 것). 같은 id가 한쪽에 여럿이면 첫 행만 짝짓고 나머지는 따로 둔다.
    static func union<Row>(_ left: [Row], _ right: [Row], id: KeyPath<Row, Int>) -> [(Row?, Row?)] {
        var rightByID: [Int: Row] = [:]
        for row in right where rightByID[row[keyPath: id]] == nil { rightByID[row[keyPath: id]] = row }
        var used: Set<Int> = [], pairs: [(Row?, Row?)] = []
        for row in left {
            let key = row[keyPath: id]
            if !used.contains(key), let match = rightByID[key] {
                used.insert(key)
                pairs.append((row, match))
            } else {
                pairs.append((row, nil))
            }
        }
        var seen: Set<Int> = []
        for row in right {
            let key = row[keyPath: id]
            if used.contains(key), !seen.contains(key) { seen.insert(key); continue }
            pairs.append((nil, row))
        }
        return pairs
    }
}

public struct UsbProperty: Sendable, Hashable, Codable {
    public var deviceName: String
    /// "1000"
    public var dbVersion: String
    public var numberOfContents: Int
    /// "YYYY-MM-DD"
    public var createdDate: String
    public var backgroundColorType: Int
    /// u32 범위(0…4294967295)라 Int32로 줄이지 않는다
    public var myTagMasterDBID: Int64
    /// pdb 표 19 날짜
    public var pdbDate: String?
    /// pdb 표 19 두 번째 문자열
    public var pdbDeviceName: String?

    public init(deviceName: String = "", dbVersion: String = "", numberOfContents: Int = 0, createdDate: String = "",
                backgroundColorType: Int = 0, myTagMasterDBID: Int64 = 0, pdbDate: String? = nil, pdbDeviceName: String? = nil) {
        self.deviceName = deviceName
        self.dbVersion = dbVersion
        self.numberOfContents = numberOfContents
        self.createdDate = createdDate
        self.backgroundColorType = backgroundColorType
        self.myTagMasterDBID = myTagMasterDBID
        self.pdbDate = pdbDate
        self.pdbDeviceName = pdbDeviceName
    }
}

extension UsbMyTag {
    /// 불일치 보고용 id(64비트 그대로)
    var intID: Int { Int(id) }
}

extension UsbMyTagLink {
    struct Key: Hashable { var myTagID: Int64; var contentID: Int }
    var key: Key { Key(myTagID: myTagID, contentID: contentID) }
}

extension UsbFormat {
    /// 정렬 순서(OneLibrary 먼저)
    var order: Int { UsbFormat.allCases.firstIndex(of: self) ?? 0 }
}
