import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// USB 라이브러리 명령(읽기·계획·내보내기·고치기·회복)
enum UsbCommands {
    static let all: [Command] = [
        Command("usb-restore", String(ui: "--volume <마운트> [--backup <폴더>] [--discard-device-changes] [--confirm <볼륨 이름>] [--dry-run]"),
                String(ui: "USB에 쓴 것을 그 쓰기 전 백업으로 되돌린다(그 뒤 기기가 바꾼 것이 있으면 막는다)"), { try await restore($0) }),
        Command("usb-recover", String(ui: "--volume <마운트> [--discard-temp] [--confirm <볼륨 이름>]"),
                String(ui: "끝나지 않은 USB 쓰기를 마저 쓰거나 되돌린다"), { try await recover($0) }),
    ]

    /// `usb-restore` 인자
    struct RestoreRequest: Equatable {
        var volume: String
        var backup: String?
        var discardDeviceChanges: Bool
        var confirmName: String?
        var dryRun: Bool
    }

    /// `usb-recover` 인자
    struct RecoverRequest: Equatable {
        var volume: String
        var discardTemp: Bool
        var confirmName: String?
    }

    static func restoreRequest(_ args: [String]) throws -> RestoreRequest {
        let volume = try volumeArgument(args)
        try rejectPhysicalAllowance(args)
        return RestoreRequest(volume: volume, backup: try optionalValue("--backup", in: args),
                              discardDeviceChanges: args.contains("--discard-device-changes"),
                              confirmName: try optionalValue("--confirm", in: args), dryRun: args.contains("--dry-run"))
    }

    static func recoverRequest(_ args: [String]) throws -> RecoverRequest {
        let volume = try volumeArgument(args)
        try rejectPhysicalAllowance(args)
        return RecoverRequest(volume: volume, discardTemp: args.contains("--discard-temp"), confirmName: try optionalValue("--confirm", in: args))
    }

    static func restore(_ args: [String], paths: @autoclosure () -> UsbWritePaths = .default) async throws {
        let request = try restoreRequest(args)
        let report = try UsbWriter.restore(root: UsbRoot(URL(filePath: request.volume)), paths: paths(),
                                           backup: request.backup.map { URL(filePath: $0) }, guard: .system,
                                           discardDeviceChanges: request.discardDeviceChanges, confirmName: request.confirmName,
                                           dryRun: request.dryRun)
        printReport(report)
    }

    static func recover(_ args: [String], paths: @autoclosure () -> UsbWritePaths = .default) async throws {
        let request = try recoverRequest(args)
        let report = try UsbWriter.recover(root: UsbRoot(URL(filePath: request.volume)), paths: paths(), guard: .system,
                                           discardTemp: request.discardTemp, confirmName: request.confirmName)
        printReport(report)
    }

    /// 값이 있어야 하는 선택 인자. 이름만 있고 값이 없거나 값 자리에 다른 인자가 오면 사용법
    static func optionalValue(_ flag: String, in args: [String]) throws -> String? {
        guard args.contains(flag) else { return nil }
        guard let text = value(after: flag, in: args), !text.hasPrefix("--"), !text.isEmpty else { throw UsageError() }
        return text
    }

    /// 되돌리기·회복은 확인 안 된 규칙을 풀 일이 없다. 실물 볼륨 규칙을 풀려는 인자는 이유와 함께 거부한다
    static func rejectPhysicalAllowance(_ args: [String]) throws {
        _ = try UsbRuleCheck.parseAllowList(value(after: "--allow-provisional", in: args) ?? "")
    }

    /// `--volume` 값. rekordbox 라이브러리·DJCrate 데이터 폴더는 USB로 받지 않는다(문자열로 먼저 보고, 그 안은 열지 않는다)
    static func volumeArgument(_ args: [String]) throws -> String {
        guard let volume = value(after: "--volume", in: args), !volume.hasPrefix("--"), !volume.isEmpty else { throw UsageError() }
        let absolute = volume.hasPrefix("/") ? volume : FileManager.default.currentDirectoryPath + "/" + volume
        let live = [NSHomeDirectory() + "/Library/Pioneer", LibrarySnapshot.rekordboxDirectory.path, DJCIdentity.supportDirectory.path]
        let candidates = [(absolute as NSString).standardizingPath]
            + (live.contains { absolute.hasPrefix($0) } ? [] : [UsbScratchPath.realPath(absolute)].compactMap { $0 })
        for path in candidates where live.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            throw UsbError.writeRefused([UsbBlock(code: "liveLibrary", scope: .volume,
                                                  message: String(ui: "rekordbox 라이브러리나 DJCrate 데이터 폴더는 USB가 아닙니다. USB 볼륨의 맨 위 폴더를 주세요"))])
        }
        return volume
    }

    static func printReport(_ report: UsbWriteReport) {
        for line in reportLines(report) { print(line) }
    }

    /// 보고 줄. USB 경로가 붙은 알림은 같은 이유끼리 수로만 적는다(분석 파일·음원 경로는 찍지 않는다)
    static func reportLines(_ report: UsbWriteReport) -> [String] {
        let outcome = switch report.outcome {
        case .dryRun: String(ui: "미리 보기만 했습니다(USB는 그대로)")
        case .written: String(ui: "썼습니다")
        case .rolledBack: String(ui: "쓰기 전 상태로 되돌렸습니다")
        case .restoreFailed: String(ui: "되돌리지 못했습니다")
        case .restorePending: String(ui: "rekordbox가 켜져 있어 되돌리기를 미뤘습니다")
        case .recovered: String(ui: "끊긴 쓰기를 마저 썼습니다")
        case .restored: String(ui: "쓰기 전 백업으로 되돌렸습니다")
        case .needsReplan: String(ui: "USB가 기기에서 바뀌어 이어 쓰지 않았습니다. 지금 USB 상태로 다시 미리 보기한 뒤 쓰세요")
        }
        // 저널이 없던 회복(session 없음)은 한 일이 없다: 마저 썼다고 하지 않는다
        var lines = [report.outcome == .recovered && report.session.isEmpty ? String(ui: "결과: 회복할 쓰기가 없습니다")
            : String(ui: "결과: \(outcome)")]
        if let backup = report.backup { lines.append(String(ui: "백업: \(backup)")) }
        if report.filesCreated + report.filesOverwritten + report.filesRemoved > 0 {
            lines.append(String(ui: "파일: 만든 것 \(report.filesCreated)개 · 덮어쓴 것 \(report.filesOverwritten)개 · 지운 것 \(report.filesRemoved)개"))
        }
        var counts: [(head: String, count: Int)] = []
        for note in report.notes {
            // 끝에 USB 상대 경로가 붙은 알림만 묶는다(오류 이유 등은 그대로)
            guard let range = note.range(of: ": "),
                  ["contents/", "pioneer/"].contains(where: { note[range.upperBound...].lowercased().hasPrefix($0) }) else {
                lines.append(note)
                continue
            }
            let head = String(note[..<range.lowerBound])
            if let index = counts.firstIndex(where: { $0.head == head }) { counts[index].count += 1 } else { counts.append((head, 1)) }
        }
        for (head, count) in counts { lines.append(String(ui: "\(head) (\(count)개)")) }
        return lines
    }
}
