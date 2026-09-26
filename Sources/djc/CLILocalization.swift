import DJCDomain
import Foundation

enum CLILocalization {
    static func language(override: String?, preferredLanguages: [String]) -> String {
        let override = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = override.flatMap { $0.isEmpty ? nil : [$0] } ?? preferredLanguages
        for candidate in candidates {
            let language = candidate.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            if let language, ["ko", "en", "ja"].contains(language) { return language }
        }
        return "en"
    }

    static func configure() {
        let language = language(override: ProcessInfo.processInfo.environment["DJC_LANG"], preferredLanguages: Locale.preferredLanguages)
        UIStrings.locale = Locale(identifier: language)
        // PATH에 옮길 때 실행 파일 옆의 리소스 번들도 함께 둔다. 번들이 빠져도 원문으로 실행한다.
        let directory = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() ?? Bundle.main.bundleURL
        guard let bundle = Bundle(url: directory.appending(path: "DJCrate_djc.bundle")),
              let path = bundle.path(forResource: language, ofType: "lproj"), let localized = Bundle(path: path) else { return }
        UIStrings.bundle = localized
    }
}
