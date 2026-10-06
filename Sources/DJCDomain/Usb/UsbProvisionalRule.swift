import Foundation

/// rekordbox 실험으로 아직 확인하지 않은 USB 쓰기 규칙.
/// 계획이 이 규칙을 필요로 하면 실물 USB에는 쓰지 않는다(디스크 이미지 시험은 된다).
/// rawValue는 계획·초안에 저장되고 CLI `--allow-provisional`로 받으므로 바꾸지 않는다.
public enum UsbProvisionalRule: String, CaseIterable, Codable, Sendable, Hashable {
    case physicalVolume
    case analysisFolderNaming, analysisSlotCollision
    case playlistSiblingBase, playlistFolderRow, myTagLinks, myTagMasterDBID
    case artworkFolderSplit, artworkMissing
    case fileNameTruncation, forbiddenCharacters, pathCollision, emptyArtistAlbum, supplementaryCharacters, leadingSpace
    case cueSeekFields, cueVariant, fileTypeUnverified, metadataSeenEmptyOnly
    case pdbLongAscii, pdbFarOffsetRows
    case carriedDeviceRows
    case settingFiles
    case pdbRegeneratedEdit, trackRemovalFiles
    case editRefreshTracks, editRemoveTracks, editAddTracks, editPlaylists
    case deviceLibraryMigration

    /// 실험(rekordbox 캡처 → 사본 재현 → 칸 단위 일치 → 골든 테스트)으로 확인한 규칙만 여기에 더한다. 처음에는 비어 있다.
    public static let confirmed: Set<UsbProvisionalRule> = []

    public var isConfirmed: Bool { Self.confirmed.contains(self) }

    /// 실물 쓰기를 연 볼륨(`UsbPhysicalWriteGate.isOpen`)에서 풀리는 규칙: 내보내기·수정·옮기기 흐름 자체의 바탕 규칙이다.
    /// 이 흐름은 디스크 이미지에서 전 과정(쓰기 → 다시 읽기 검증 → `usb-rebuild`·`usb-diff --ignore-ids` 차이 0 → 되돌리기)을 확인했다(#41·#46).
    /// rekordbox 실험으로 확인한 것(`confirmed`)은 아니다 — 실기기 확인은 사용자가 실험실 스위치를 켜고 한다.
    /// 곡 내용에 따라 붙는 규칙(큐 모양·이름 글자·앨범아트 등)은 여기 넣지 않는다(실물에서는 CLI `--allow-provisional`로만 푼다)
    public static let openOnPhysical: Set<UsbProvisionalRule> = [
        .analysisFolderNaming, .playlistSiblingBase, .playlistFolderRow,
        .editAddTracks, .editRemoveTracks, .editPlaylists, .trackRemovalFiles, .pdbRegeneratedEdit,
        .deviceLibraryMigration,
    ]

    /// 디스크 이미지에서도 막는 규칙. 기기가 남긴 기록을 옮기는 방법을 정하기 전까지는 이미지에도 쓰지 않는다.
    public var blocksEvenOnDiskImage: Bool { self == .carriedDeviceRows }

    /// `--allow-provisional`로 풀 수 없는 규칙(실물 쓰기 관문으로만 푼다)
    public var isGateOnly: Bool { self == .physicalVolume }

    /// 한 줄 설명: 무엇이 확인되지 않았는지
    public var summary: String {
        switch self {
        case .physicalVolume: String(ui: "디스크 이미지가 아닌 실물 USB에 쓰기")
        case .analysisFolderNaming: String(ui: "USB 분석 파일 폴더 이름을 짓는 규칙")
        case .analysisSlotCollision: String(ui: "분석 파일 폴더 이름이 겹칠 때의 처리")
        case .playlistSiblingBase: String(ui: "같은 폴더 안 재생 목록 순서 번호의 시작값")
        case .playlistFolderRow: String(ui: "재생 목록 폴더 행의 칸 값")
        case .myTagLinks: String(ui: "My Tag와 곡의 연결")
        case .myTagMasterDBID: String(ui: "My Tag의 마스터 DB ID 칸")
        case .artworkFolderSplit: String(ui: "앨범아트 파일을 폴더로 나누는 규칙")
        case .artworkMissing: String(ui: "앨범아트가 없는 곡의 처리")
        case .fileNameTruncation: String(ui: "긴 파일 이름을 줄이는 규칙")
        case .forbiddenCharacters: String(ui: "파일 이름에 쓸 수 없는 글자를 바꾸는 규칙")
        case .pathCollision: String(ui: "USB에서 같은 경로가 되는 곡 파일 이름의 처리")
        case .emptyArtistAlbum: String(ui: "아티스트·앨범이 빈 곡의 폴더 경로")
        case .supplementaryCharacters: String(ui: "이모지 등 보충 평면 글자가 든 이름")
        case .leadingSpace: String(ui: "빈칸으로 시작하는 이름")
        case .cueSeekFields: String(ui: "이 음원 형식에서 큐의 탐색 위치 칸")
        case .cueVariant: String(ui: "색·루프 등 확인하지 않은 모양의 큐")
        case .fileTypeUnverified: String(ui: "확인하지 않은 음원 형식")
        case .metadataSeenEmptyOnly: String(ui: "빈 값으로만 본 곡 정보 칸")
        case .pdbLongAscii: String(ui: "Device Library의 긴 ASCII 문자열")
        case .pdbFarOffsetRows: String(ui: "Device Library 행 안의 먼 문자열 위치")
        case .carriedDeviceRows: String(ui: "USB에 있던 기기 기록 행을 옮기는 방법")
        case .settingFiles: String(ui: "기기 설정 파일 쓰기")
        case .pdbRegeneratedEdit: String(ui: "USB를 고칠 때 Device Library를 다시 만드는 방법")
        case .trackRemovalFiles: String(ui: "USB에서 뺀 곡의 파일 정리")
        case .editRefreshTracks: String(ui: "USB 안 곡 정보 갱신")
        case .editRemoveTracks: String(ui: "USB에서 곡 빼기")
        case .editAddTracks: String(ui: "USB에 곡 더하기")
        case .editPlaylists: String(ui: "USB 재생 목록 고치기")
        case .deviceLibraryMigration: String(ui: "Device Library에서 OneLibrary를 만드는 칸 대응")
        }
    }
}
