import Foundation
import Observation
import RekordboxKit
import SwiftUI

/// 토스트가 닫힌 뒤에도 읽을 마지막 결과. 전체 문구와 백업 위치만 DJCrate 데이터 폴더에 보관한다.
struct WriteResult: Codable, Equatable {
    var kind: AppToast.Kind
    var title: String
    var text: String
    var backups: [URL] = []
    var createdAt = Date.now

    var toast: AppToast {
        AppToast(kind: kind, title: title, detail: "전체 내용과 백업 위치는 ‘마지막 쓰기 결과…’에서 다시 볼 수 있습니다.")
    }

    static func written(_ report: RekordboxWriter.Report, preview: RekordboxWriter.Report) -> Self {
        let groups = [("큐", report.outcomes, preview.outcomes),
                      ("그리드", report.gridOutcomes ?? [], preview.gridOutcomes ?? []),
                      ("분석", report.analysisOutcomes ?? [], preview.analysisOutcomes ?? []),
                      ("게인", report.gainOutcomes ?? [], preview.gainOutcomes ?? [])]
        var lines: [String] = [], summaries: [String] = [], count = 0, blocked = false
        for (label, actual, predicted) in groups {
            let written = actual.filter { $0.status == .written }.count
            if written > 0 { summaries.append("\(label) \(written)곡") }
            let seen = Set(actual.map(\.trackUUID))
            let outcomes = actual + predicted.filter { $0.status != .written && !seen.contains($0.trackUUID) }
            for outcome in outcomes {
                switch outcome.status {
                case .written:
                    count += 1
                    lines.append("• \(outcome.title) — \(label) 반영 완료")
                case .blocked:
                    blocked = true
                    lines.append("• \(outcome.title) — \(label) 쓰지 않음: \(outcome.reason ?? "이유 없음")")
                case .unchanged: lines.append("• \(outcome.title) — \(label) 변경 없음")
                }
            }
        }
        return Self(kind: blocked || count == 0 ? .warning : .success,
                    title: count == 0 ? "rekordbox에 쓴 것이 없습니다" : "rekordbox에 반영했습니다 · " + summaries.joined(separator: " · "),
                    text: lines.joined(separator: "\n"), backups: report.backup.map { [URL(filePath: $0)] } ?? [])
    }

    static func tracks(_ report: RekordboxTrackWriter.Report, preview: RekordboxTrackWriter.Report,
                       adding: Bool, withoutAnalysis: [String: String] = [:], unreadable: [String] = []) -> Self {
        let actual = adding ? report.added : report.deleted
        let predicted = adding ? preview.added : preview.deleted
        let seen = Set(actual.map(\.path))
        let outcomes = actual + predicted.filter { !$0.written && !seen.contains($0.path) }
        var warning = !unreadable.isEmpty
        var lines = outcomes.map { outcome in
            var line = "• \(outcome.title) — "
            if outcome.written {
                line += adding ? "넣기 완료" : "빼기 완료"
                if adding, let reason = withoutAnalysis[outcome.path] {
                    warning = true
                    line += " · 분석 없이 넣음(\(reason)): rekordbox에서 분석하세요"
                }
                if let count = outcome.cuesWritten { line += " · 큐 \(count)개" }
                if let reason = outcome.cueReason {
                    warning = true
                    line += " · 큐는 반영 대기: \(reason)"
                }
            } else {
                warning = true
                line += (adding ? "넣지 않음: " : "빼지 않음: ") + (outcome.reason ?? "이유 없음")
            }
            return line
        }
        lines += unreadable.map { "• 넣지 않음: \($0)" }
        let count = actual.filter(\.written).count
        return Self(kind: warning || count == 0 ? .warning : .success,
                    title: adding ? "rekordbox에 \(count)곡을 넣었습니다" : "rekordbox에서 \(count)곡을 뺐습니다",
                    text: lines.joined(separator: "\n"), backups: report.backup.map { [URL(filePath: $0)] } ?? [])
    }

    static func restored(_ backup: RekordboxWriter.Backup, saved: URL) -> Self {
        let titles = Set((backup.report?.written ?? []).map(\.title)
            + (backup.report?.gridWritten ?? []).map(\.title) + (backup.report?.gainWritten ?? []).map(\.title)
            + (backup.report?.analysisWritten ?? []).map(\.title)
            + (backup.trackReport?.titles ?? []))
        var lines = ["rekordbox 라이브러리 전체를 선택한 백업의 쓰기 전 상태로 되돌렸습니다.",
                     "그때 쓴 초안과 추가 목록도 복원했습니다. 되돌리기 직전 상태는 아래 두 번째 백업에 남아 있습니다."]
        lines += titles.sorted().map { "• \($0)" }
        return Self(kind: .success, title: "rekordbox를 쓰기 전으로 되돌렸습니다", text: lines.joined(separator: "\n"), backups: [backup.url, saved])
    }
}

@MainActor
@Observable
final class WriteResultHistory {
    private(set) var latest: WriteResult?
    private(set) var storageError: String?
    private let url: URL?

    /// nil은 시험용 메모리 저장소다.
    init(url: URL? = nil) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do { latest = try JSONDecoder().decode(WriteResult.self, from: Data(contentsOf: url)) }
        catch { storageError = "지난 결과를 읽지 못했습니다. DJCrate 데이터 폴더의 읽기 권한을 확인하세요: \(error.localizedDescription)" }
    }

    func record(_ result: WriteResult) {
        latest = result
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(result).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            storageError = nil
        } catch {
            storageError = "결과를 파일에 보관하지 못했습니다. 앱을 닫기 전에 내용을 복사하고 DJCrate 데이터 폴더의 쓰기 권한을 확인하세요: \(error.localizedDescription)"
        }
    }
}

struct WriteResultView: View {
    let history: WriteResultHistory
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("마지막 쓰기 결과").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = history.storageError { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    if let result = history.latest {
                        Label(result.title, systemImage: result.kind.icon).font(.headline).foregroundStyle(result.kind.tint)
                        Text(result.createdAt.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.secondary)
                        Text(result.text).frame(maxWidth: .infinity, alignment: .leading)
                        Text("백업 위치").font(.headline)
                        if result.backups.isEmpty { Text("이 결과에 연결된 백업이 없습니다.").foregroundStyle(.secondary) }
                        ForEach(result.backups, id: \.self) { url in
                            Text(url.path).font(.callout.monospaced())
                            Button("Finder에서 백업 보기") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) }
                                .disabled(!FileManager.default.fileExists(atPath: url.path))
                        }
                        if !result.backups.isEmpty { Text("정리되거나 이동한 백업은 열 수 없습니다.").font(.caption).foregroundStyle(.secondary) }
                    } else { Text("아직 보관한 쓰기 결과가 없습니다.") }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 660, height: 500)
    }
}
