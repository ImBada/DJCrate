import Foundation

public enum UsbFileSystemKind: Codable, Hashable, Sendable {
    case fat32, fat16, fat12, exfat, hfsPlus, apfs
    case other(String)

    /// 문구에 넣는 이름(번역하지 않는 형식 이름)
    public var displayName: String {
        switch self {
        case .fat32: "FAT32"
        case .fat16: "FAT16"
        case .fat12: "FAT12"
        case .exfat: "exFAT"
        case .hfsPlus: "HFS+"
        case .apfs: "APFS"
        case let .other(name): name
        }
    }
}

public enum UsbPartitionScheme: String, Codable, Sendable {
    case mbr, gpt, apm, none, unknown
}

/// 볼륨을 무엇에 쓰려는지. 읽기는 모든 모양을 받고, 내보내기·고치기는 rekordbox가 쓰는 모양만 받는다.
public enum UsbVolumePurpose: String, Codable, Sendable {
    case export, edit, read
}

/// 마운트된 USB 볼륨 하나의 정보(DiskArbitration·statfs에서 읽는다)
public struct UsbVolumeInfo: Codable, Hashable, Sendable {
    /// 볼륨 마운트 지점 경로
    public var mountPoint: String
    /// 대상 루트 = 마운트 지점
    public var rootIsMountPoint: Bool
    /// 대문자
    public var volumeUUID: String?
    public var name: String
    public var fileSystem: UsbFileSystemKind
    /// DiskArbitration MediaContent: "DOS_FAT_32"(0x0B), "Windows_FAT_32"(0x0C), "DOS_FAT_16" …
    public var partitionContent: String?
    public var partitionScheme: UsbPartitionScheme
    /// 1부터(diskNs1 → 1)
    public var partitionIndex: Int?
    public var sectorSize: Int?
    public var clusterSize: Int?
    /// 내장 여부를 모르면 디스크 이미지가 아닌 한 내장으로 보고 막는다
    public var isInternal: Bool
    public var isNetwork: Bool
    public var isReadOnly: Bool
    public var isRootVolume: Bool
    /// 디스크 이미지임을 확인했을 때만 참. 확인하지 못하면 실물로 본다
    public var isDiskImage: Bool
    /// realpath(3) 결과
    public var diskImagePath: String?
    public var capacity: Int64
    public var available: Int64

    public init(mountPoint: String, rootIsMountPoint: Bool, volumeUUID: String?, name: String, fileSystem: UsbFileSystemKind,
                partitionContent: String?, partitionScheme: UsbPartitionScheme, partitionIndex: Int?, sectorSize: Int?,
                clusterSize: Int?, isInternal: Bool, isNetwork: Bool, isReadOnly: Bool, isRootVolume: Bool,
                isDiskImage: Bool, diskImagePath: String?, capacity: Int64, available: Int64) {
        self.mountPoint = mountPoint
        self.rootIsMountPoint = rootIsMountPoint
        self.volumeUUID = volumeUUID
        self.name = name
        self.fileSystem = fileSystem
        self.partitionContent = partitionContent
        self.partitionScheme = partitionScheme
        self.partitionIndex = partitionIndex
        self.sectorSize = sectorSize
        self.clusterSize = clusterSize
        self.isInternal = isInternal
        self.isNetwork = isNetwork
        self.isReadOnly = isReadOnly
        self.isRootVolume = isRootVolume
        self.isDiskImage = isDiskImage
        self.diskImagePath = diskImagePath
        self.capacity = capacity
        self.available = available
    }
}

public struct UsbVolumeProblem: Codable, Hashable, Sendable {
    /// 영어 고정 식별자
    public var code: String
    /// 이유와 할 일(`String(ui:)`)
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// 어떤 볼륨에 쓸 수 있는지. rekordbox·CDJ가 읽는 모양(MBR 첫 파티션 FAT32, 512바이트 섹터)만 받는다.
public enum UsbVolumePolicy {
    /// FAT32 파티션 형식. rekordbox로 만든 USB는 0x0B(DOS_FAT_32), 디스크 이미지는 0x0C(Windows_FAT_32)가 나온다.
    public static let fat32Contents: Set<String> = ["DOS_FAT_32", "Windows_FAT_32"]

    /// 문제를 판정 순서대로 모두 낸다. 읽기는 모든 모양을 받는다.
    public static func problems(_ volume: UsbVolumeInfo, purpose: UsbVolumePurpose) -> [UsbVolumeProblem] {
        guard purpose != .read else { return [] }
        var problems: [UsbVolumeProblem] = []
        func add(_ code: String, _ message: String) { problems.append(UsbVolumeProblem(code: code, message: message)) }
        let reformat = String(ui: "USB를 MBR·MS-DOS(FAT32)로 포맷한 뒤 다시 시도하세요")

        if !volume.rootIsMountPoint { add("notMountPoint", String(ui: "USB 볼륨의 맨 위 폴더를 고르세요")) }
        if volume.isInternal { add("internal", String(ui: "내장 디스크에는 쓸 수 없습니다. USB를 연결해 고르세요")) }
        if volume.isNetwork { add("network", String(ui: "네트워크 볼륨에는 쓸 수 없습니다. USB를 연결해 고르세요")) }
        if volume.isRootVolume { add("rootVolume", String(ui: "시동 디스크에는 쓸 수 없습니다")) }
        if volume.isReadOnly {
            add("readOnly", String(ui: "USB가 읽기 전용으로 연결됐습니다. 잠금 스위치를 풀고 다시 연결하세요"))
        }
        if volume.partitionScheme != .mbr {
            add("notMBR", purpose == .edit
                ? String(ui: "이 USB 형식(GPT 등)은 아직 고칠 수 없습니다. FAT32·MBR로 포맷한 다른 USB에 새로 내보내세요")
                : reformat)
        }
        if volume.fileSystem != .fat32 || !fat32Contents.contains(volume.partitionContent ?? "") {
            // 파일 시스템은 FAT32인데 파티션 형식이 다르면 파티션 형식 이름을 보여 준다.
            let format = volume.fileSystem == .fat32 ? (volume.partitionContent ?? volume.fileSystem.displayName) : volume.fileSystem.displayName
            add("notFAT32", purpose == .edit
                ? String(ui: "이 USB 형식(\(format))은 아직 고칠 수 없습니다. FAT32로 포맷한 다른 USB에 새로 내보내세요")
                : reformat)
        }
        if volume.partitionIndex != 1 {
            add("notFirstPartition", String(ui: "USB의 첫 번째 파티션만 쓸 수 있습니다. 파티션 하나로 포맷하세요"))
        }
        if volume.sectorSize != 512 {
            add("sectorSize", String(ui: "섹터 크기가 512바이트가 아닌 USB는 아직 쓸 수 없습니다"))
        }
        return problems
    }

    /// 볼륨 문제를 볼륨 범위 막힘으로
    public static func blocks(_ volume: UsbVolumeInfo, purpose: UsbVolumePurpose) -> [UsbBlock] {
        problems(volume, purpose: purpose).map { UsbBlock(code: $0.code, scope: .volume, message: $0.message) }
    }
}
