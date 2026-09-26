@testable import DJCrate
import Foundation
import Testing

/// 앱 카탈로그가 번들에 언어별로 들어가는지. 시스템 언어와 관계없이 언어 폴더를 골라 찾는다.
@Suite("앱 문구 카탈로그")
struct LocalizationCatalogTests {
    private func lookup(_ key: String, in language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { return nil }
        let value = bundle.localizedString(forKey: key, value: "\u{0}", table: nil)
        return value == "\u{0}" ? nil : value
    }

    @Test(arguments: ["en", "ja"])
    func 영어_일본어_번역이_번들에_들어간다(language: String) throws {
        let value = try #require(lookup("설정…", in: language))
        #expect(!value.isEmpty)
        #expect(value != "설정…")
    }

    @Test func 개발_빌드도_macOS_언어_목록을_가진다() throws {
        // 실행 파일에 넣은 Info.plist(Package.swift의 -sectcreate)와 같은 파일이다.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/DJCrate/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url))
        #expect(plist["CFBundleDevelopmentRegion"] as? String == "en")
        #expect(plist["CFBundleLocalizations"] as? [String] == ["ko", "en", "ja"])
    }
}
