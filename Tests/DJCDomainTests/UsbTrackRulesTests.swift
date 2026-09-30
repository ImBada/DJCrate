import DJCDomain
import Foundation
import Testing

@Suite("USB 곡 칸·문자열 규칙")
struct UsbTrackRulesTests {
    let none = UsbTrackMetadataFlags()

    @Test("순수 ASCII 126자는 괜찮고 127자부터 pdbLongAscii")
    func ascii126NotFlagged_127Flagged() {
        #expect(UsbTrackRules.pdbStringRules([String(repeating: "a", count: 126)]).isEmpty)
        #expect(UsbTrackRules.pdbStringRules([String(repeating: "a", count: 127)]) == [.pdbLongAscii])
        #expect(UsbTrackRules.pdbStringRules(["short", String(repeating: "b", count: 300)]) == [.pdbLongAscii])
        #expect(UsbTrackRules.longAsciiThreshold == 127)
    }

    @Test("ASCII가 아닌 글자가 섞이면 길어도 괜찮다")
    func nonASCII200NotFlagged() {
        #expect(UsbTrackRules.pdbStringRules([String(repeating: "é", count: 200)]).isEmpty)
        #expect(UsbTrackRules.pdbStringRules([String(repeating: "a", count: 199) + "한"]).isEmpty)
        #expect(UsbTrackRules.pdbStringRules([]).isEmpty)
    }

    @Test("MP3·M4A·FLAC 밖의 음원 형식은 fileTypeUnverified")
    func fileTypeUnverified() {
        #expect(UsbTrackRules.rules(fileType: 11, metadata: none, pdbStrings: []) == [.fileTypeUnverified])
        #expect(UsbTrackRules.rules(fileType: 12, metadata: none, pdbStrings: []) == [.fileTypeUnverified])
        for fileType in [1, 4, 5] {
            #expect(UsbTrackRules.rules(fileType: fileType, metadata: none, pdbStrings: []).isEmpty)
        }
    }

    @Test("빈 값으로만 본 곡 정보 칸에 값이 있으면 metadataSeenEmptyOnly")
    func metadataFlags() {
        let setters: [(inout UsbTrackMetadataFlags) -> Void] = [
            { $0.hasLabel = true }, { $0.hasRemixer = true }, { $0.hasOriginalArtist = true }, { $0.hasLyricist = true },
            { $0.hasColor = true }, { $0.hasRating = true }, { $0.hasSubtitle = true }, { $0.hasSearchString = true },
            { $0.isCompilation = true },
        ]
        for set in setters {
            var flags = UsbTrackMetadataFlags()
            set(&flags)
            #expect(flags.hasAny)
            #expect(UsbTrackRules.rules(fileType: 1, metadata: flags, pdbStrings: []) == [.metadataSeenEmptyOnly])
        }
        #expect(!none.hasAny)
    }

    @Test("곡·목록 문자열 판정은 한 함수")
    func pdbStringRulesSharedFunction() {
        let long = String(repeating: "a", count: 127)
        #expect(UsbTrackRules.pdbStringRules([long]) == [.pdbLongAscii])
        #expect(UsbTrackRules.rules(fileType: 1, metadata: none, pdbStrings: [long]) == UsbTrackRules.pdbStringRules([long]))
        #expect(UsbTrackRules.rules(fileType: 11, metadata: none, pdbStrings: [long]) == [.fileTypeUnverified, .pdbLongAscii])
    }

    @Test("음원 형식 번호 → 확장자(모르면 nil)")
    func knownFileTypes() {
        #expect(UsbTrackRules.knownFileTypes[1] == "mp3")
        #expect(UsbTrackRules.knownFileTypes[4] == "m4a")
        #expect(UsbTrackRules.knownFileTypes[5] == "flac")
        #expect(UsbTrackRules.knownFileTypes[11] == "wav")
        #expect(UsbTrackRules.knownFileTypes[12] == "aiff")
        #expect(UsbTrackRules.knownFileTypes[3] != nil)
        #expect(UsbTrackRules.knownFileTypes[6] != nil)
        for unknown in [0, 2, 25, 26, 99] {
            #expect(UsbTrackRules.knownFileTypes[unknown] == nil)
        }
    }
}
