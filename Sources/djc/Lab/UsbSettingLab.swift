import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// USB 기기 설정 파일 실험. 읽는 USB 폴더와 쓰는 출력 폴더는 임시 폴더 아래만 받는다.
enum UsbSettingLab {
    static let all: [Command] = [
        Command("setting-check", "<PIONEER 폴더>",
                "USB 설정 파일 셋(MYSETTING·MYSETTING2·DJMMYSETTING)의 크기·길이 칸·CRC를 확인한다(임시 폴더 아래 사본만)",
                UsbSettingLab.checkCommand),
        Command("setting-export", "--local <rekordbox 설정 폴더> --out <빈 폴더>",
                "로컬 설정 파일 셋을 내보내기 모양으로 옮긴다(아는 새 칸만 채우고 CRC 다시). 로컬은 세 파일만 읽는다",
                UsbSettingLab.exportCommand),
    ]

    struct CheckResult {
        var lines: [String]
        /// 적힌 CRC와 계산한 CRC가 같은 파일 수
        var crcMatched: Int
        /// 검증을 모두 통과한 파일 수
        var valid: Int
    }

    struct CheckFailed: Error, CustomStringConvertible {
        let valid: Int, total: Int
        var description: String { "설정 파일 \(total)개 중 \(total - valid)개가 검증에 실패했습니다" }
    }

    static func checkCommand(_ args: [String]) async throws {
        guard args.count >= 2 else { throw UsageError() }
        let result = try check(folder: args[1])
        result.lines.forEach { print($0) }
        if result.valid < DeviceSettingFile.Kind.exported.count {
            throw CheckFailed(valid: result.valid, total: DeviceSettingFile.Kind.exported.count)
        }
    }

    static func exportCommand(_ args: [String]) async throws {
        guard let local = value(after: "--local", in: args), let out = value(after: "--out", in: args) else { throw UsageError() }
        try export(local: local, out: out).forEach { print($0) }
    }

    /// 세 파일 이름만 연다(폴더를 훑지 않는다). 파일도 임시 폴더 아래의 보통 파일일 때만 읽는다.
    static func check(folder: String) throws -> CheckResult {
        let root = try UsbScratchPath.check(folder, as: .existingDirectory)
        var result = CheckResult(lines: [], crcMatched: 0, valid: 0)
        for kind in DeviceSettingFile.Kind.exported {
            let name = kind.fileName
            let path: String
            do {
                path = try UsbScratchPath.check(root + "/" + name, as: .existingFile)
            } catch let UsbError.pathRefused(_, reason) {
                result.lines.append("\(name): " + (reason == "notFound" ? "없음" : "읽지 않음(\(reason))"))
                continue
            }
            let data = try Data(contentsOf: URL(filePath: path))
            if let pair = DeviceSettingFile.crcPair(kind: kind, bytes: data), pair.stored == pair.computed { result.crcMatched += 1 }
            do {
                let file = try DeviceSettingFile(kind: kind, bytes: data)
                result.valid += 1
                let fields = DeviceSettingField.all.compactMap { field in file.value(field).map { "\(field.name)=\(hex($0))" } }
                result.lines.append("\(name): 맞음 · \(data.count)바이트 · \(file.brand) / \(file.software) / \(file.version) · "
                    + "CRC \(hex(file.storedCRC))(\(kind.crcIncludesHeader ? "파일 처음부터" : "본문")) · " + fields.joined(separator: " "))
            } catch let error as DeviceSettingError {
                result.lines.append("\(name): 어긋남 · \(data.count)바이트 · \(error)")
            }
        }
        result.lines.append("CRC \(result.crcMatched)/\(DeviceSettingFile.Kind.exported.count) 맞음")
        return result
    }

    /// `--out`을 먼저 확인한 뒤에만 로컬 파일을 연다. 검증에 실패한 파일은 만들지 않고 이유를 적는다.
    static func export(local: String, out: String) throws -> [String] {
        let target = try UsbScratchPath.check(out, as: .outputDirectory)
        if !FileManager.default.fileExists(atPath: target) {
            try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
        }
        let folder = URL(filePath: local, directoryHint: .isDirectory)
        var lines: [String] = []
        for kind in DeviceSettingFile.Kind.exported {
            let name = kind.fileName
            do {
                let (source, output) = try DeviceSettingPatch.readForExport(localFile: folder.appending(path: name))
                try output.bytes.write(to: URL(filePath: target).appending(path: name), options: .withoutOverwriting)
                let changed = zip(source.bytes, output.bytes).enumerated()
                    .filter { $0.element.0 != $0.element.1 && $0.offset < output.bytes.count - 4 }
                    .map { "\(hex($0.offset)) \(hex($0.element.0))→\(hex($0.element.1))" }
                lines.append("\(name): 만듦 · " + (changed.isEmpty ? "바꾼 칸 없음" : "바꾼 칸 " + changed.joined(separator: ", ") + " · CRC 다시 계산"))
            } catch {
                lines.append("\(name): 만들지 않음 · \(error)")
            }
        }
        return lines
    }

    static func hex(_ value: some BinaryInteger) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return "0x" + (text.count % 2 == 1 ? "0" : "") + text
    }
}
