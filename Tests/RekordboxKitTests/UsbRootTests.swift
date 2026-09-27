import DJCDomain
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

@Suite("USB 루트 순회")
struct UsbRootTests {
    @Test("열지 않는 경로는 내려가지도 열지도 않는다")
    func walkSkipsNeverReadWithoutOpening() throws {
        let fixture = UsbTreeFixture()
        defer { fixture.remove() }
        fixture.write("PIONEER/rekordbox/export.pdb", "pdb")
        fixture.write("PIONEER/extracted/GCRED.DAT", "SECRET")
        fixture.write("PIONEER/CDP/x", "SECRET")
        fixture.write("PIONEER/djprofile.nxs", "SECRET")
        // 권한을 모두 빼 둔다. 열거나 내려가면 EACCES로 실패하므로 안 열었다는 증거가 된다.
        let locked = ["PIONEER/extracted/GCRED.DAT", "PIONEER/CDP/x", "PIONEER/djprofile.nxs", "PIONEER/extracted", "PIONEER/CDP"]
        for path in locked { #expect(chmod(fixture.url(path).path, 0) == 0) }
        defer {
            for path in locked.reversed() { chmod(fixture.url(path).path, 0o755) }
        }

        let entries = try UsbTree.walk(fixture.root)
        #expect(entries.map(\.relativePath) == ["PIONEER", "PIONEER/rekordbox", "PIONEER/rekordbox/export.pdb"])
        let print = try UsbTree.fingerprint(fixture.root)
        #expect(Array(print.files.keys) == ["PIONEER/rekordbox/export.pdb"])
        #expect(!UsbTree.render(print).contains("SECRET"))
        // 열지 않는 경로 아래에서 시작해도 거부한다.
        #expect(throws: UsbError.self) { try UsbTree.walk(fixture.root, under: "PIONEER/extracted") }
    }

    @Test("경로는 NFC로 낸다")
    func walkReturnsNFCPaths() throws {
        let fixture = UsbTreeFixture()
        defer { fixture.remove() }
        let nfd = "Contents/Cafe\u{301}/Cafe\u{301}.mp3"
        fixture.write(nfd, "audio")
        let paths = try UsbTree.walk(fixture.root).map(\.relativePath)
        #expect(paths == ["Contents", "Contents/Caf\u{E9}", "Contents/Caf\u{E9}/Caf\u{E9}.mp3"])
        #expect(paths.allSatisfy { $0 == $0.precomposedStringWithCanonicalMapping })
        #expect(try UsbTree.fingerprint(fixture.root).files.keys.first == "Contents/Caf\u{E9}/Caf\u{E9}.mp3")
    }

    @Test("macOS가 만드는 폴더는 뺀다")
    func systemIgnoredExcluded() throws {
        let fixture = UsbTreeFixture()
        defer { fixture.remove() }
        fixture.write(".fseventsd/0000", "log")
        fixture.write(".Spotlight-V100/Store-V2/x", "index")
        fixture.mkdir(".Trashes")
        fixture.write("PIONEER/rekordbox/exportLibrary.db", "db")
        let paths = try UsbTree.walk(fixture.root).map(\.relativePath)
        #expect(paths == ["PIONEER", "PIONEER/rekordbox", "PIONEER/rekordbox/exportLibrary.db"])
    }

    @Test("AppleDouble은 세기만 하고 해시하지 않는다")
    func appleDoubleCountedNotHashed() throws {
        let fixture = UsbTreeFixture()
        defer { fixture.remove() }
        fixture.write("Contents/a.mp3", "a")
        fixture.write("Contents/._a.mp3", "xattr")
        fixture.write("._Contents", "xattr")
        let print = try UsbTree.fingerprint(fixture.root)
        #expect(Set(print.files.keys) == ["Contents/a.mp3"])
        #expect(print.appleDoubleCount == 2)
        let all = try UsbTree.fingerprint(fixture.root, hashAppleDouble: true)
        #expect(Set(all.files.keys) == ["Contents/a.mp3", "Contents/._a.mp3", "._Contents"])
        // 해시하지 않으면 크기만 남긴다.
        let sizes = try UsbTree.fingerprint(fixture.root, hashing: false)
        #expect(sizes.files["Contents/a.mp3"] == UsbTreeStamp(size: 1, sha256: nil))
        #expect(print.files["Contents/a.mp3"]?.sha256 == fixture.tree()["Contents/a.mp3"])
    }

    @Test("심볼릭 링크는 따라가지 않는다")
    func symlinkNotFollowed() throws {
        let fixture = UsbTreeFixture()
        let outside = UsbTreeFixture()
        defer { fixture.remove(); outside.remove() }
        outside.write("secret/file.txt", "OUTSIDE")
        fixture.write("Contents/a.mp3", "a")
        fixture.symlink("Contents/linkdir", to: outside.url("secret").path)
        fixture.symlink("Contents/linkfile", to: outside.url("secret/file.txt").path)
        let entries = try UsbTree.walk(fixture.root)
        #expect(entries.map(\.relativePath) == ["Contents", "Contents/a.mp3", "Contents/linkdir", "Contents/linkfile"])
        let links = entries.filter(\.isSymlink)
        #expect(links.map(\.relativePath) == ["Contents/linkdir", "Contents/linkfile"])
        #expect(links.allSatisfy { !$0.isDirectory })
        let print = try UsbTree.fingerprint(fixture.root)
        #expect(print.files["Contents/linkfile"]?.sha256 == nil)
        #expect(print.files["Contents/linkdir/file.txt"] == nil)
    }

    @Test("상대 경로는 열지 않는 곳·상위 폴더·절대 경로를 거부한다")
    func urlForRejectsNeverReadAndDotDot() throws {
        let root = UsbRoot(URL(filePath: "/private/tmp/djc-usbroot-fixture"))
        #expect(try root.url(for: "PIONEER/rekordbox/export.pdb").path == "/private/tmp/djc-usbroot-fixture/PIONEER/rekordbox/export.pdb")
        #expect(try root.url(for: "").path == root.url.path)
        for bad in ["PIONEER/extracted/GCRED.DAT", "pioneer/cdp", "PIONEER/djprofile.nxs", "./PIONEER/extracted/x",
                    "PIONEER/./djprofile.nxs", "../x", "Contents/../../x", "/etc/hosts"] {
            #expect(throws: UsbError.self, "\(bad)") { try root.url(for: bad) }
        }
    }

    @Test("출력 형식은 경로 순이고 시각이 없다")
    func renderFormat() {
        let files: [String: UsbTreeStamp] = [
            "b/2.mp3": .init(size: 20, sha256: "bb"),
            "a/1.mp3": .init(size: 10, sha256: "aa"),
            "B/0.mp3": .init(size: 5, sha256: nil),
        ]
        #expect(UsbTree.render((files: files, appleDoubleCount: 3)) == """
            -  5  B/0.mp3
            aa  10  a/1.mp3
            bb  20  b/2.mp3
            # appledouble 3
            """)
        #expect(UsbTree.render((files: [:], appleDoubleCount: 0)) == "# appledouble 0")
    }
}
