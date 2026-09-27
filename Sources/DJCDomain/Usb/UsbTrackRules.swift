import Foundation

/// 곡 정보 칸 중 rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)에서 빈 값으로만 본 칸에 값이 있는지
public struct UsbTrackMetadataFlags: Codable, Sendable, Hashable {
    public var hasLabel = false
    public var hasRemixer = false
    public var hasOriginalArtist = false
    public var hasLyricist = false
    public var hasColor = false
    public var hasRating = false
    public var hasSubtitle = false
    public var hasSearchString = false
    public var isCompilation = false

    public init(hasLabel: Bool = false, hasRemixer: Bool = false, hasOriginalArtist: Bool = false, hasLyricist: Bool = false,
                hasColor: Bool = false, hasRating: Bool = false, hasSubtitle: Bool = false, hasSearchString: Bool = false,
                isCompilation: Bool = false) {
        self.hasLabel = hasLabel
        self.hasRemixer = hasRemixer
        self.hasOriginalArtist = hasOriginalArtist
        self.hasLyricist = hasLyricist
        self.hasColor = hasColor
        self.hasRating = hasRating
        self.hasSubtitle = hasSubtitle
        self.hasSearchString = hasSearchString
        self.isCompilation = isCompilation
    }

    public var hasAny: Bool {
        hasLabel || hasRemixer || hasOriginalArtist || hasLyricist || hasColor || hasRating || hasSubtitle || hasSearchString
            || isCompilation
    }
}

/// 곡 칸·문자열 → 확인 안 된 규칙
public enum UsbTrackRules {
    /// 짧은 ASCII 문자열 머리 ((n+1)<<1)+1 이 u8에 들어가는 한계는 n ≤ 126. 그보다 긴 ASCII는 긴 머리로 써야 한다.
    public static let longAsciiThreshold = 127

    /// 로컬 djmdContent.FileType → USB 파일 확장자. 모르면 nil(내보내지 않는다).
    /// 1 MP3, 3 MP4(AAC), 4 M4A, 5 FLAC, 6 M4A(ALAC), 11 WAV, 12 AIFF. 25·26(스트리밍)은 파일이 없다.
    public static let knownFileTypes: [Int: String] = [1: "mp3", 3: "mp4", 4: "m4a", 5: "flac", 6: "m4a", 11: "wav", 12: "aiff"]

    /// 골든에서 본 음원 형식(MP3·M4A·FLAC)
    static let verifiedFileTypes: Set<Int> = [1, 4, 5]

    public static func rules(fileType: Int, metadata: UsbTrackMetadataFlags, pdbStrings: [String]) -> Set<UsbProvisionalRule> {
        var rules = pdbStringRules(pdbStrings)
        if !verifiedFileTypes.contains(fileType) { rules.insert(.fileTypeUnverified) }
        if metadata.hasAny { rules.insert(.metadataSeenEmptyOnly) }
        return rules
    }

    /// pdb에 문자열로 들어가는 값 중 순수 ASCII이고 127자 이상인 것이 있으면 [.pdbLongAscii].
    /// 곡 문자열·경로·파일 이름·아티스트·앨범 이름·재생 목록 이름 모두 이 함수로 판정한다.
    public static func pdbStringRules(_ strings: [String]) -> Set<UsbProvisionalRule> {
        let long = strings.contains { text in
            text.unicodeScalars.count >= longAsciiThreshold && text.unicodeScalars.allSatisfy { $0.value < 0x80 }
        }
        return long ? [.pdbLongAscii] : []
    }
}
