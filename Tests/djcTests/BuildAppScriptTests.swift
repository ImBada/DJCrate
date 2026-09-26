import Foundation
import Testing

@Suite("앱 빌드 스크립트")
struct BuildAppScriptTests {
    @Test(arguments: ["none", "found", "override"])
    func 서명_인증서_유무와_관계없이_설치까지_진행한다(_ identity: String) throws {
        let result = try run(identity: identity, install: true)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.installed)
        #expect(result.output.contains("설치:"))
        #expect(result.signatures.contains(identity == "none" ? "--sign - " : "--sign TEST_IDENTITY "))
    }

    @Test func 설치_인자가_없으면_번들만_만든다() throws {
        let result = try run(identity: "none", install: false)
        #expect(result.status == 0, "\(result.output)")
        #expect(!result.installed)
        #expect(result.output.contains("만듦:"))
    }

    @Test func 서명_실패시_설치하지_않는다() throws {
        let result = try run(identity: "override", install: true, signingFails: true)
        #expect(result.status != 0)
        #expect(!result.installed)
        #expect(result.signatures.contains("--sign TEST_IDENTITY "))
    }

    @Test func 번들에도_덱_드래그_형식을_선언한다() throws {
        let result = try run(identity: "none", install: false)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.exportedTypes.contains("com.djcrate.deck-track"))
    }

    private func run(identity: String, install: Bool, signingFails: Bool = false) throws
        -> (status: Int32, output: String, installed: Bool, signatures: String, exportedTypes: [String]) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "djc-build-script-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func file(_ path: String, _ text: String = "합성 파일") throws {
            let url = root.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "scripts/build-app.sh")
        try file("scripts/build-app.sh", String(contentsOf: source, encoding: .utf8))
        let info = source.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources/DJCrate/Info.plist")
        try file("Sources/DJCrate/Info.plist", String(contentsOf: info, encoding: .utf8))
        for path in [".build/release/DJCrate", ".build/release/SQLCipher.framework/SQLCipher",
                     ".build/release/DJCrate_DJCrate.bundle/Contents/Resources/ko.lproj/InfoPlist.strings",
                     "LICENSE", "THIRD_PARTY_NOTICES.md"] { try file(path) }
        // 빌드·키체인·서명은 가짜 도구로 실행하고 설치 대상도 임시 폴더로 돌린다.
        try file("bin/tool", #"""
        #!/bin/zsh
        set -e
        case "${0:t}" in
          swift|install_name_tool) exit 0 ;;
          git) echo 17 ;;
          security)
            if [[ "$DJC_TEST_IDENTITY" == found ]]; then
              echo '  1) TEST_IDENTITY "Apple Development: Synthetic"'
            else
              echo '     0 valid identities found'
            fi ;;
          codesign)
            print -r -- "$*" >> "$DJC_TEST_ROOT/signatures"
            [[ "$DJC_TEST_SIGN_FAIL" != 1 ]] ;;
          plutil) /usr/bin/plutil "$@" ;;
          mktemp) /bin/mkdir -p "$DJC_TEST_ROOT/icon-temp"; echo "$DJC_TEST_ROOT/icon-temp" ;;
          iconutil) /usr/bin/touch "$5" ;;
          cp|rm|mkdir)
            args=()
            for arg in "$@"; do
              case "$arg" in
                /Applications|"$HOME/Applications") arg="$DJC_TEST_ROOT/installed" ;;
                /Applications/DJCrate.app|"$HOME/Applications/DJCrate.app") arg="$DJC_TEST_ROOT/installed/DJCrate.app" ;;
              esac
              args+=("$arg")
            done
            "/bin/${0:t}" "${args[@]}" ;;
          *) exit 99 ;;
        esac
        """#)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "bin/tool").path)
        for tool in ["swift", "git", "security", "codesign", "plutil", "mktemp", "iconutil", "install_name_tool", "cp", "rm", "mkdir"] {
            try fm.createSymbolicLink(atPath: root.appending(path: "bin/\(tool)").path, withDestinationPath: "tool")
        }
        let process = Process(), output = Pipe()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = [root.appending(path: "scripts/build-app.sh").path] + (install ? ["--install"] : [])
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = root.appending(path: "bin").path + ":/usr/bin:/bin"
        environment["DJC_TEST_ROOT"] = root.path
        environment["DJC_TEST_IDENTITY"] = identity
        environment["DJC_TEST_SIGN_FAIL"] = signingFails ? "1" : "0"
        environment["DJC_SIGN_IDENTITY"] = identity == "override" ? "TEST_IDENTITY" : nil
        process.environment = environment
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let signatures = (try? String(contentsOf: root.appending(path: "signatures"), encoding: .utf8)) ?? ""
        let bundleInfo = NSDictionary(contentsOf: root.appending(path: "dist/DJCrate.app/Contents/Info.plist"))
        let declarations = bundleInfo?["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []
        return (process.terminationStatus, text,
                fm.fileExists(atPath: root.appending(path: "installed/DJCrate.app/Contents/MacOS/DJCrate").path), signatures,
                declarations.compactMap { $0["UTTypeIdentifier"] as? String })
    }
}
