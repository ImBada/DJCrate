import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// USB 라이브러리 읽기 실험(사본만 연다). 받는 경로는 임시 폴더 아래만이고, 출력에는 글자 칸 값을 찍지 않는다.
enum UsbReadLab {
    static let all: [Command] = [
        Command("onelib-sql", "<exportLibrary.db> <SELECT…|PRAGMA…>",
                "임시 폴더의 OneLibrary를 임시 사본으로 떠서 읽기 전용 질의(인증값 차단)", UsbReadLab.oneLibrarySQL),
        Command("usb-diff", "--onelibrary <USB 폴더 A> <USB 폴더 B> [--ignore-anlz-folder] [--ignore-ids] [--skip <표,…>]",
                "두 USB 폴더를 사본으로 떠서 모델을 표·칸 단위로 비교(값은 찍지 않음)", UsbReadLab.usbDiff),
    ]

    /// 임시 폴더 아래 OneLibrary 파일에 읽기 전용 질의. 원본 대신 사이드카까지 같이 뜬 임시 사본을 연다.
    static func oneLibrarySQL(_ args: [String]) async throws {
        guard args.count > 2 else { throw UsageError() }
        let database = try UsbScratchPath.check(args[1], as: .existingFile)
        let sql = args[2]
        guard isAllowedQuery(sql) else { print("허용하지 않는 쿼리"); return }
        let work = FileManager.default.temporaryDirectory.appending(path: "djc-onelib-sql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let copy = try UsbSnapshot.copyDatabase(URL(filePath: database), into: work)
        let db = try CipherDatabase.diagnostic(path: copy.path, key: .passphrase(RekordboxKey.oneLibrary()))
        defer { db.close() }
        try db.query(sql) { row in print((Int32(0)..<Int32(row.count)).map { row.string($0) ?? "nil" }.joined(separator: " | ")) }
    }

    /// SELECT와 키가 아닌 PRAGMA만. 인증값 표 이름이 들어 있으면 받지 않는다(연결의 authorizer도 한 번 더 막는다).
    /// PRAGMA는 이름으로 본다(`key`·`rekey`·`hexkey`는 막고 `table_info(key)`는 받는다).
    static func isAllowedQuery(_ sql: String) -> Bool {
        let lower = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !CipherDatabase.isCredentialIdentifier(lower) else { return false }
        if lower.hasPrefix("select") { return true }
        guard lower.hasPrefix("pragma") else { return false }
        let name = lower.dropFirst("pragma".count).drop { $0.isWhitespace }.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        return !name.isEmpty && !name.contains("key")
    }

    /// 두 USB 폴더(임시 폴더 아래 사본·디스크 이미지 마운트 지점)의 모델 비교
    static func usbDiff(_ args: [String]) async throws {
        var positional: [String] = [], oneLibrary = false
        var options = UsbLibraryDiff.Options(formats: [.oneLibrary])
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--onelibrary": oneLibrary = true
            case "--ignore-anlz-folder": options.ignoreAnalysisFolder = true
            case "--ignore-ids": options.ignoreIDs = true
            case "--skip":
                guard index + 1 < args.count else { throw UsageError() }
                index += 1
                options.skipTables = Set(args[index].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            default: positional.append(args[index])
            }
            index += 1
        }
        guard oneLibrary, positional.count == 2 else { throw UsageError() }
        let roots = try positional.map { try UsbScratchPath.check($0, as: .existingDirectory) }
        let work = FileManager.default.temporaryDirectory.appending(path: "djc-usb-diff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        var libraries: [UsbLibrary] = []
        for (side, root) in zip(["a", "b"], roots) {
            let snapshot = try UsbSnapshot.take(root: UsbRoot(URL(filePath: root)), into: work.appending(path: side))
            guard let copy = snapshot.oneLibrary else {
                print("\(side == "a" ? "A" : "B")에 OneLibrary(exportLibrary.db)가 없다")
                return
            }
            libraries.append(try OneLibraryReader.read(copyAt: copy))
        }
        let result = UsbLibraryDiff.compare(libraries[0], libraries[1], options: options)
        render(result).forEach { print($0) }
    }

    /// 표마다 "표 N/N행 일치, 다른 칸: 칸이름×수", 마지막 줄 "차이 <합계>". 값·제목은 넣지 않는다.
    static func render(_ result: (summaries: [UsbLibraryDiff.TableSummary], differences: [UsbLibraryDiff.Difference])) -> [String] {
        result.summaries.map { summary in
            let fields = summary.differingFields.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
            return "\(summary.table) \(summary.matchedRows)/\(max(summary.leftRows, summary.rightRows))행 일치"
                + (fields.isEmpty ? "" : ", 다른 칸: " + fields.joined(separator: ", "))
        } + ["차이 \(result.differences.count)"]
    }
}
