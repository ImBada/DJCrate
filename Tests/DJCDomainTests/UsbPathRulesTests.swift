import DJCDomain
import Foundation
import Testing

@Suite("USB 경로 성분·파일 이름 규칙")
struct UsbPathRulesTests {
    func folder(_ name: String?) -> UsbPathRules.Named {
        UsbPathRules.folderComponent(name, unknown: "UnknownArtist")
    }

    @Test("이름은 NFC로 맞춘다")
    func nfcApplied() {
        let named = folder("Cafe\u{0301} Bar")
        #expect(named.value == "Caf\u{00E9} Bar")
        #expect(named.value.unicodeScalars.count == 8)
        #expect(named.rules.isEmpty)
        #expect(UsbPathRules.fileName("Cafe\u{0301}.mp3").value == "Caf\u{00E9}.mp3")
    }

    @Test(": 와 / 는 _로 바꾸고 규칙이 없다")
    func colonAndSlashToUnderscore() {
        let named = folder("A:B/C")
        #expect(named.value == "A_B_C")
        #expect(named.rules.isEmpty)
        let file = UsbPathRules.fileName("x:y/z.mp3")
        #expect(file.value == "x_y_z.mp3")
        #expect(file.rules.isEmpty)
    }

    @Test("나머지 금지 글자와 제어 문자는 _로 바꾸고 forbiddenCharacters")
    func forbiddenOthersFlagged() {
        for character in ["?", "*", "\"", "<", ">", "\\", "|", "\u{0001}", "\u{001F}", "\u{007F}"] {
            let named = folder("A\(character)B")
            #expect(named.value == "A_B", "\(character.unicodeScalars.first!.value)")
            #expect(named.rules == [.forbiddenCharacters])
            let file = UsbPathRules.fileName("A\(character)B.mp3")
            #expect(file.value == "A_B.mp3")
            #expect(file.rules == [.forbiddenCharacters])
        }
    }

    @Test("끝의 점 하나는 자르기 전에 _로 바꾼다")
    func trailingDotBeforeTruncate() {
        #expect(folder("Name.").value == "Name_")
        #expect(folder("Name.").rules.isEmpty)
        // 48자 안의 점은 자른 뒤 끝에 와도 _가 아니라 지운다
        let long = String(repeating: "a", count: 47) + ".bc"
        #expect(folder(long).value == String(repeating: "a", count: 47))
    }

    @Test("앞 48 스칼라로 자른다")
    func truncate48Scalars() {
        let named = folder(String(repeating: "a", count: 49))
        #expect(named.value == String(repeating: "a", count: 48))
        #expect(named.rules.isEmpty)
        #expect(folder(String(repeating: "가", count: 60)).value == String(repeating: "가", count: 48))
    }

    @Test("자른 뒤 끝의 공백·점을 지운다")
    func trailingSpaceDotStrippedAfterTruncate() {
        let named = folder(String(repeating: "a", count: 47) + " b")
        #expect(named.value == String(repeating: "a", count: 47))
        let dots = folder(String(repeating: "a", count: 46) + ". b")
        #expect(dots.value == String(repeating: "a", count: 46))
    }

    @Test("자르지 않아도 끝의 공백은 지운다")
    func untruncatedTrailingSpaceStripped() {
        #expect(folder("Name ").value == "Name")
        #expect(folder("Name   ").value == "Name")
        #expect(folder("Name ").rules.isEmpty)
    }

    @Test("비었거나 공백·점뿐이면 Unknown")
    func emptyToUnknown() {
        for name in [nil, "", "   ", "...", " . "] as [String?] {
            let named = folder(name)
            #expect(named.value == "UnknownArtist", "\(String(describing: name))")
            #expect(named.rules == [.emptyArtistAlbum])
        }
        #expect(UsbPathRules.folderComponent(nil, unknown: "UnknownAlbum").value == "UnknownAlbum")
    }

    @Test("보충 평면 글자는 스칼라 단위로 잘라 깨지지 않는다")
    func supplementaryNotSplit() {
        let name = String(repeating: "a", count: 46) + "😀🎵🎶🎧"
        #expect(name.unicodeScalars.count == 50)
        let named = folder(name)
        #expect(named.value == String(repeating: "a", count: 46) + "😀🎵")
        #expect(named.value.unicodeScalars.count == 48)
        #expect(named.value.utf16.count == 50)
        #expect(named.rules == [.supplementaryCharacters])
        // 자르지 않으면 규칙이 없다
        #expect(folder("A😀").rules.isEmpty)
    }

    @Test("앞 공백은 그대로 두고 leadingSpace")
    func leadingSpaceKept() {
        let named = folder(" Name")
        #expect(named.value == " Name")
        #expect(named.rules == [.leadingSpace])
        let file = UsbPathRules.fileName(" x.mp3")
        #expect(file.value == " x.mp3")
        #expect(file.rules == [.leadingSpace])
    }

    @Test("긴 파일 이름은 줄기만 잘라 확장자를 남긴다")
    func fileNameStemTruncationKeepsExtension() {
        let file = UsbPathRules.fileName(String(repeating: "s", count: 60) + ".mp3")
        #expect(file.value == String(repeating: "s", count: 44) + ".mp3")
        #expect(file.value.unicodeScalars.count == 48)
        #expect(file.rules == [.fileNameTruncation])
        // 자른 줄기 끝의 공백은 지운다
        let spaced = UsbPathRules.fileName(String(repeating: "s", count: 43) + " " + String(repeating: "t", count: 16) + ".mp3")
        #expect(spaced.value == String(repeating: "s", count: 43) + ".mp3")
        // 48자 이하면 줄기 끝 공백·점도 그대로
        #expect(UsbPathRules.fileName("abc .mp3").value == "abc .mp3")
        #expect(UsbPathRules.fileName("abc..mp3").value == "abc..mp3")
        #expect(UsbPathRules.fileName("abc .mp3").rules.isEmpty)
    }

    @Test("확장자 없는 파일 이름")
    func fileNameNoExtension() {
        #expect(UsbPathRules.fileName("README").value == "README")
        #expect(UsbPathRules.fileName("README").rules.isEmpty)
        let long = UsbPathRules.fileName(String(repeating: "n", count: 60))
        #expect(long.value == String(repeating: "n", count: 48))
        #expect(long.rules == [.fileNameTruncation])
    }

    @Test("번호를 붙여도 48 스칼라 안")
    func withSuffixFits48() {
        #expect(UsbPathRules.withSuffix("x.mp3", number: 2) == "x (2).mp3")
        #expect(UsbPathRules.withSuffix("README", number: 3) == "README (3)")
        let full = String(repeating: "s", count: 44) + ".mp3"
        let two = UsbPathRules.withSuffix(full, number: 2)
        #expect(two == String(repeating: "s", count: 40) + " (2).mp3")
        #expect(two.unicodeScalars.count == 48)
        let ninetyNine = UsbPathRules.withSuffix(full, number: 99)
        #expect(ninetyNine == String(repeating: "s", count: 39) + " (99).mp3")
        // 자른 줄기 끝 공백은 지운다
        let spaced = String(repeating: "s", count: 39) + " " + "tttt.mp3"
        #expect(UsbPathRules.withSuffix(spaced, number: 2) == String(repeating: "s", count: 39) + " (2).mp3")
    }

    @Test("Contents 경로는 성분 규칙을 모은다")
    func contentsPathJoinsComponents() {
        let path = UsbPathRules.contentsPath(artist: "Artist", album: nil, fileName: "a?b.mp3")
        #expect(path.value == "/Contents/Artist/UnknownAlbum/a_b.mp3")
        #expect(path.rules == [.emptyArtistAlbum, .forbiddenCharacters])
        let plain = UsbPathRules.contentsPath(artist: "A", album: "B", fileName: "f.flac")
        #expect(plain.value == "/Contents/A/B/f.flac")
        #expect(plain.rules.isEmpty)
    }
}
