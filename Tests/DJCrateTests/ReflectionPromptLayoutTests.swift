@testable import DJCrate
import AppKit
@testable import RekordboxKit
import Testing

@MainActor
@Suite("반영 확인 창 목록")
struct ReflectionPromptLayoutTests {
    typealias Fixture = ReflectionCoordinatorTests

    func detailText(_ prompt: ReflectionPrompt) throws -> String {
        _ = NSApplication.shared
        let alert = AlertPrompter().makeAlert(prompt)
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        let textView = try #require(scroll.documentView as? NSTextView)
        #expect(scroll.hasVerticalScroller && !scroll.hasHorizontalScroller)
        #expect(scroll.frame.height <= 240)
        #expect(!textView.isEditable)
        return textView.string
    }

    @Test func 목록이_없으면_기존_알림을_유지하고_짧은_목록은_작게_보인다() throws {
        _ = NSApplication.shared
        let plain = AlertPrompter().makeAlert(ReflectionPrompt(title: "알림", text: "안내"))
        #expect(plain.accessoryView == nil)
        let short = AlertPrompter().makeAlert(ReflectionPrompt(title: "알림", text: "안내", details: ["• 시험 곡"]))
        let scroll = try #require(short.accessoryView as? NSScrollView)
        #expect(scroll.frame.height < 100)
    }

    @Test func 연동_안내는_경로만_본문에_두고_단계는_스크롤로_보여_준다() throws {
        _ = NSApplication.shared
        let url = URL(filePath: "/tmp/djc-layout/djcrate-rekordbox.xml")
        let alert = RekordboxLink.setupAlert(for: url)
        #expect(alert.informativeText.components(separatedBy: "\n").count == 2)
        #expect(alert.informativeText.contains(url.path))
        #expect(!alert.informativeText.contains("1. rekordbox"))
        #expect(alert.buttons.map(\.title) == ["확인", "Finder에서 보기"])
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        let textView = try #require(scroll.documentView as? NSTextView)
        #expect(scroll.frame.height <= 240)
        #expect(textView.string.contains("1. rekordbox") && textView.string.contains("2. 트리에"))
        #expect(textView.string.contains("Import To Collection") && textView.string.contains("라이브러리 백업"))
    }

    @Test func XML_반영이_막힌_곡은_이유를_생략하지_않는다() throws {
        let plans = (1...100).map { index in
            var plan = Reflection.plan(track: Fixture.row("xml-\(index)").track, rawCues: [], cueDraft: nil, gridDraft: nil)
            plan.blockers = ["막힌 이유"]
            return plan
        }
        let prompt = ReflectionPanels.blockedPrompt(plans)
        #expect(prompt.text.count < 180)
        #expect(try detailText(prompt).components(separatedBy: "\n")
            == (1...100).map { "• 곡 xml-\($0): 막힌 이유" })
        let empty = ReflectionPanels.blockedPrompt([])
        #expect(empty.text == "고른 곡에 rekordbox와 다른 큐·그리드 초안이 없습니다.")
        #expect(empty.details.isEmpty)
    }

    /// 막힘이 없으면 곡이 많아도 묻지 않고 모두 쓴다(#210). 곡마다의 결과는 쓰기 결과에 남는다.
    @Test func 그리드와_게인_각_100곡은_막힘이_없으면_묻지_않고_모두_쓴다() async throws {
        let host = FakeReflectionHost(), prompter = ScriptedPrompter()
        host.preview = .success(Fixture.preview(cues: [],
            grids: (1...100).map { Fixture.outcome("grid-\($0)", .written, added: 64) },
            gains: (1...100).map { Fixture.outcome("gain-\($0)", .written, added: -250) }))
        await ReflectionCoordinator(host: host, prompter: prompter, isRekordboxRunning: { false })
            .write(rows: [Fixture.row("grid-1")])
        #expect(prompter.shown.isEmpty)
        #expect(host.wrote?.grids.count == 100 && host.wrote?.gains.count == 100 && host.locks == [true, false])
        let lines = try #require(host.resultHistory.latest).text.components(separatedBy: "\n")
        #expect(lines.contains("• 곡 grid-100 — 그리드 쓰기 완료") && lines.contains("• 곡 gain-100 — 게인 쓰기 완료"))
    }

    @Test func 쓰지_않는_이유는_끝까지_보이고_쓰는_곡_줄은_넣지_않는다() throws {
        let preview = Fixture.preview(
            cues: (1...100).map { Fixture.outcome("cue-\($0)", .written) }
                + (1...100).map { Fixture.outcome("blocked-\($0)", .blocked, reason: "분석 전") },
            analyses: (1...100).map { Fixture.outcome("analysis-\($0)", .written, added: 96) })
        let prompt = ReflectionCoordinator.confirmation(preview.report)
        #expect(prompt.text.count < 180)
        let lines = try detailText(prompt).components(separatedBy: "\n")
        #expect(lines == ["쓰지 않는 것 100:"] + (1...100).map { "• 곡 blocked-\($0): 분석 전" })
        #expect(!lines.contains { $0.hasPrefix("… 외") })
    }

    @Test func 넣기와_빼기는_100곡과_제외_이유를_생략하지_않는다() throws {
        let outcomes = (1...100).map { Fixture.track("track-\($0)") }
            + (1...100).map { Fixture.track("blocked-\($0)", written: false, reason: "막힌 이유") }
        var deleted = RekordboxTrackWriter.Report(dryRun: true)
        deleted.deleted = outcomes
        let prompts = [
            ReflectionCoordinator.addConfirmation(Fixture.addPreview(outcomes)),
            ReflectionCoordinator.deleteConfirmation(.init(report: deleted, contentIDs: [])),
        ]
        for prompt in prompts {
            #expect(prompt.text.count < 180)
            let lines = try detailText(prompt).components(separatedBy: "\n")
            for index in 1...100 {
                // 넣기는 빠지는 것이 없는 곡의 줄을 넣지 않는다(#210). 빼기는 뺄 곡을 모두 보인다.
                #expect(lines.contains("• 곡 track-\(index)") == (prompt.confirm == "rekordbox에서 빼기"))
                #expect(lines.contains("• 곡 blocked-\(index): 막힌 이유"))
            }
            #expect(!lines.contains { $0.hasPrefix("… 외") })
        }
    }

    @Test func 되돌리기는_경고_본문을_유지하고_100곡을_목록에_보여_준다() throws {
        let report = Fixture.preview(cues: (1...100).map { Fixture.outcome("restore-\($0)", .written) }).report
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/layout-test"), createdAt: .now, isWrite: true, report: report)
        let prompt = ReflectionCoordinator.restoreConfirmation(backup, changedSince: true)
        #expect(!prompt.text.contains("곡 restore-"))
        #expect(prompt.text.contains("복원하면 그 변경도 함께 사라집니다"))
        #expect(prompt.critical && prompt.destructive)
        let lines = try detailText(prompt).components(separatedBy: "\n")
        for index in 1...100 { #expect(lines.contains("• 곡 restore-\(index)")) }
    }

    @Test func 모두_막힌_경우도_전체_이유를_스크롤로_확인한다() async throws {
        let host = FakeReflectionHost(), prompter = ScriptedPrompter()
        host.preview = .success(Fixture.preview(cues: (1...100).map {
            Fixture.outcome("blocked-\($0)", .blocked, reason: "막힌 이유")
        }))
        let tracks = (1...100).map { Fixture.track("blocked-\($0)", written: false, reason: "막힌 이유") }
        host.addPreview = .success(Fixture.addPreview(tracks))
        var deleted = RekordboxTrackWriter.Report(dryRun: true)
        deleted.deleted = tracks
        host.deletePreview = .success(.init(report: deleted, contentIDs: []))
        let coordinator = ReflectionCoordinator(host: host, prompter: prompter, isRekordboxRunning: { false })
        await coordinator.write(rows: [Fixture.row("blocked-1")])
        await coordinator.addTracks(rows: [Fixture.row("djc-blocked-1")])
        await coordinator.deleteTracks(rows: [Fixture.row("blocked-1")])
        #expect(prompter.shown.count == 3)
        for prompt in prompter.shown {
            #expect(prompt.text.count < 180 && prompt.confirm == nil)
            #expect(try detailText(prompt).components(separatedBy: "\n")
                == (1...100).map { "• 곡 blocked-\($0): 막힌 이유" })
        }
        #expect(host.resultHistory.latest?.text.contains("곡 blocked-100") == true)
        #expect(host.wrote == nil && host.added == nil && host.deleted == nil)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func 긴_제목_100곡도_창과_버튼이_화면_안에_있다(appearance: NSAppearance.Name) throws {
        _ = NSApplication.shared
        let preview = Fixture.preview(cues: [], grids: [Fixture.outcome("쓰는 곡", .written)] + (1...100).map {
            Fixture.outcome("\($0) " + String(repeating: "긴 제목 ", count: 30), .blocked, reason: "막힌 이유")
        })
        let alert = AlertPrompter().makeAlert(ReflectionCoordinator.confirmation(preview.report))
        alert.window.appearance = NSAppearance(named: appearance)
        alert.layout()
        let screen = try #require(alert.window.screen ?? NSScreen.main)
        #expect(alert.window.frame.height < screen.visibleFrame.height)
        #expect(alert.window.frame.width < screen.visibleFrame.width)
        let content = try #require(alert.window.contentView)
        for button in alert.buttons {
            #expect(content.bounds.contains(button.convert(button.bounds, to: content)))
        }
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        let textView = try #require(scroll.documentView as? NSTextView)
        #expect(scroll.frame.height <= 240)
        #expect(textView.frame.height > scroll.contentSize.height)
        #expect(scroll.contentView.bounds.minY == 0)
        textView.scrollRangeToVisible(NSRange(location: textView.string.utf16.count - 1, length: 1))
        #expect(scroll.contentView.bounds.minY > 0)
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        #expect(alert.buttons.last?.keyEquivalent == "\u{1b}")
    }

    @Test func 읽기_전용_목록이_기본_버튼의_입력_초점을_빼앗지_않는다() throws {
        _ = NSApplication.shared
        let prompt = ReflectionPrompt(title: "목록 시험", text: "안내", confirm: "쓰기",
                                      details: (1...200).map { "• 시험 곡 \($0)" })
        let alert = AlertPrompter().makeAlert(prompt)
        alert.layout()
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        let textView = try #require(scroll.documentView as? NSTextView)
        #expect(!textView.acceptsFirstResponder)
        #expect(scroll.contentView.bounds.minY == 0)
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        #expect(alert.buttons.last?.keyEquivalent == "\u{1b}")
    }
}
