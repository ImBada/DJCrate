@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import SwiftUI
import Testing

/// 막힌 초안 복구 시트(#232). 곡·종류·재생 목록을 한 시트의 줄로 보고 줄마다 고른 뒤 한 번에 저장해도,
/// 같은 선택을 예전 연속 창 흐름(`LegacyRecoveryFlow`)으로 한 것과 같은 초안 상태가 되어야 한다.
@MainActor
@Suite("막힌 초안 복구 시트", .serialized)
struct RecoverySheetTests {
    typealias Target = RecoveryScenario.Target

    /// 줄마다 고른 것. 큐 대상을 다시 지정해야 하는 줄(C 큐)의 "내 편집 유지"는 현재 큐를 이어 준 것으로 본다.
    struct Plan: CustomTestStringConvertible {
        var name: String
        var choices: [Target: RecoveryChoice]
        var testDescription: String { name }

        static let mixed = Plan(name: "줄마다 다르게", choices: [
            .draft("A", .tags): .keep, .draft("A", .cues): .useCurrent, .draft("B", .tags): .later, .draft("B", .grid): .keep,
            .draft("C", .cues): .keep, .playlist("P1"): .keep, .playlist("P2"): .useCurrent,
        ])
        static let opposite = Plan(name: "반대로", choices: [
            .draft("A", .tags): .useCurrent, .draft("A", .cues): .keep, .draft("B", .tags): .keep, .draft("B", .grid): .useCurrent,
            .draft("C", .cues): .useCurrent, .playlist("P1"): .useCurrent, .playlist("P2"): .keep,
        ])
        static let allLater = Plan(name: "모두 나중에", choices: Dictionary(uniqueKeysWithValues: RecoveryScenario.allTargets.map { ($0, RecoveryChoice.later) }))
    }

    func model(_ scenario: RecoveryScenario, _ targets: [Target] = RecoveryScenario.allTargets) -> RecoverySheetModel {
        RecoverySheetModel(store: scenario.store, requests: targets.map { Self.request(scenario, $0) },
                           dependencies: .init(home: scenario.home))
    }

    static func request(_ scenario: RecoveryScenario, _ target: Target) -> RecoveryRequest {
        switch target {
        case let .draft(name, kind): .draft(scenario.rows[name]!, kind)
        case let .playlist(id): .playlist(id)
        }
    }

    func line(_ model: RecoverySheetModel, _ scenario: RecoveryScenario, _ target: Target) throws -> RecoveryLine {
        let id = Self.request(scenario, target).id
        return try #require(model.lines.first { $0.id == id }, "줄이 없음: \(target.label)")
    }

    /// 시트에서 계획대로 고른다(대상을 다시 지정해야 하는 줄은 후보를 이어 준다).
    func apply(_ plan: Plan, to model: RecoverySheetModel, _ scenario: RecoveryScenario) throws {
        for target in RecoveryScenario.allTargets {
            let line = try line(model, scenario, target)
            let choice = try #require(plan.choices[target])
            if choice == .keep, let mapping = line.cueMapping {
                for old in mapping.missing {
                    let candidate = try #require(mapping.candidates.first)
                    model.mapCue(old.sourceID!, to: candidate.sourceID, in: line)
                }
            }
            model.choose(choice, for: line)
            #expect(line.choice == choice, "고르지 못함: \(target.label) \(choice)")
        }
    }

    // MARK: - 지금 흐름과 같은 결과

    @Test(arguments: [Plan.mixed, .opposite, .allLater])
    func 줄마다_다르게_고른_결과가_연속_창_흐름과_같다(plan: Plan) async throws {
        let legacy = try await RecoveryScenario.make(), sheet = try await RecoveryScenario.make()
        let initial = sheet.outcome()
        #expect(legacy.outcome() == initial)

        for target in RecoveryScenario.allTargets {
            guard case let .draft(name, kind) = target else { continue }
            try await LegacyRecoveryFlow.recoverDraft(legacy, row: name, kind: kind, choice: try #require(plan.choices[target]))
        }
        try await LegacyRecoveryFlow.recoverPlaylists(legacy, choices: [("P1", try #require(plan.choices[.playlist("P1")])),
                                                                         ("P2", try #require(plan.choices[.playlist("P2")]))])

        let model = model(sheet)
        await model.load()
        #expect(model.lines.count == 7 && model.lines.allSatisfy { $0.phase == .ready })
        try apply(plan, to: model, sheet)
        let saved = await model.save()
        let failures = model.lines.compactMap { line -> String? in
            if case let .failed(reason) = line.phase { "\(line.title) \(line.kindLabel): \(reason)" } else { nil }
        }
        #expect(failures.isEmpty, "저장하지 못한 줄: \(failures)")
        #expect(saved || plan.name == "모두 나중에")

        #expect(sheet.outcome() == legacy.outcome())
        if plan.name == "모두 나중에" {
            #expect(sheet.outcome() == initial, "나중에만 고르면 초안이 그대로여야 한다")
        } else {
            #expect(sheet.outcome() != initial, "고른 줄은 초안이 바뀌어야 한다")
            #expect(model.isClosed)
        }
    }

    // MARK: - 줄과 기본 선택

    @Test func 한_곡_한_종류만_고른_진입은_그_줄만_든_시트다() async throws {
        let scenario = try await RecoveryScenario.make()
        let model = model(scenario, [.draft("A", .tags)])
        await model.load()
        #expect(model.lines.count == 1)
        let line = try line(model, scenario, .draft("A", .tags))
        #expect(line.title == "합성 곡 A" && line.kindLabel == "태그" && line.phase == .ready)
    }

    @Test func 합칠_수_있는_줄은_내_편집_유지가_처음_골라져_있고_합칠_수_없는_줄은_나중에다() async throws {
        let scenario = try await RecoveryScenario.make()
        let model = model(scenario)
        await model.load()
        for target in RecoveryScenario.allTargets where target != .draft("C", .cues) {
            let line = try line(model, scenario, target)
            #expect(line.choice == .keep && line.options == [.keep, .useCurrent, .later], "\(target.label)")
        }
        let blocked = try line(model, scenario, .draft("C", .cues))
        #expect(blocked.choice == .later && blocked.options == [.useCurrent, .later])
        #expect(blocked.keepBlockedReason != nil && blocked.cueMapping?.missing.count == 1)
    }

    @Test func 큐_대상을_모두_이어야_내_편집_유지를_고를_수_있다() async throws {
        let scenario = try await RecoveryScenario.make()
        let target = Target.draft("C", .cues)
        let model = model(scenario, [target])
        await model.load()
        let line = try line(model, scenario, target)
        let mapping = try #require(line.cueMapping)
        let old = try #require(mapping.missing.first?.sourceID)
        #expect(mapping.candidates.compactMap(\.sourceID) == ["cue-c-new"])
        model.choose(.keep, for: line)
        #expect(line.choice == .later, "대상을 잇기 전에는 고를 수 없다")
        model.mapCue(old, to: "cue-c-new", in: line)
        #expect(line.options.contains(.keep) && line.choice == .keep)
        #expect(line.details.contains("직접 지정한 큐 대응:"))
        model.mapCue(old, to: nil, in: line)
        #expect(!line.options.contains(.keep) && line.choice == .later)
        // 후보가 아닌 큐로는 이을 수 없다
        model.mapCue(old, to: "없는 큐", in: line)
        #expect(!line.options.contains(.keep))
        let outcome = scenario.outcome()
        #expect(outcome.cues["C"] == nil, "고르는 동안 초안을 바꾸지 않는다")
    }

    @Test func 줄마다_무엇이_바뀌었는지_한_줄로_보인다() async throws {
        let scenario = try await RecoveryScenario.make()
        let model = model(scenario)
        await model.load()
        func summary(_ target: Target) throws -> String { try line(model, scenario, target).summary }
        #expect(try summary(.draft("A", .tags)).contains("제목") && summary(.draft("A", .tags)).contains("코멘트"))
        #expect(try summary(.draft("A", .cues)) == "rekordbox에서 바뀐 큐: 변경 1")
        #expect(try summary(.draft("B", .tags)).contains("장르") && summary(.draft("B", .tags)).contains("아티스트"))
        #expect(try summary(.draft("B", .grid)) == "rekordbox에서 바뀐 그리드: 120.00 → 160.00 BPM")
        #expect(try summary(.draft("C", .cues)) == "rekordbox에서 바뀐 큐: 추가 1 · 삭제 1")
        #expect(try summary(.playlist("P1")).contains("‘합성 목록 하나’ → ‘외부 이름 하나’"))
        #expect(try line(model, scenario, .playlist("P2")).title == "외부 이름 둘" && line(model, scenario, .playlist("P2")).kindLabel == "재생 목록")
    }

    // MARK: - 저장·취소

    @Test func 취소하면_아무것도_바꾸지_않는다() async throws {
        let scenario = try await RecoveryScenario.make()
        let initial = scenario.outcome()
        let model = model(scenario)
        await model.load()
        try apply(.mixed, to: model, scenario)
        model.cancel()
        #expect(model.isClosed && scenario.outcome() == initial)
        await model.waitUntilClosed()
        let saved = await model.save()
        #expect(!saved && scenario.outcome() == initial, "닫은 시트는 저장하지 않는다")
    }

    @Test func 한_줄이_저장에_실패해도_다른_줄은_저장하고_실패한_줄은_초안을_남긴다() async throws {
        let scenario = try await RecoveryScenario.make()
        let targets: [Target] = [.draft("A", .tags), .draft("B", .grid)]
        let model = model(scenario, targets)
        await model.load()
        let before = try #require(scenario.store.tagDrafts[RecoveryScenario.uuid("A")])
        // 비교하는 사이 rekordbox에서 A의 제목이 또 바뀌었다
        try scenario.fixture.execute("UPDATE djmdContent SET Title = '또 바뀐 제목' WHERE ID = '91'")
        let saved = await model.save()
        #expect(!saved && !model.isClosed)
        #expect(scenario.store.toast?.kind == .warning, "일부만 저장했으면 성공으로 알리지 않는다")
        guard case let .failed(reason) = try line(model, scenario, targets[0]).phase else {
            Issue.record("실패한 줄이 실패로 보이지 않음"); return
        }
        #expect(reason.contains("현재값을 다시 가져오세요"))
        #expect(scenario.store.tagDrafts[RecoveryScenario.uuid("A")] == before)
        #expect(try line(model, scenario, targets[1]).phase == .saved)
        #expect(scenario.outcome().grids["B"] != nil, "다른 줄은 저장했다")
        #expect(!model.canSave)
    }

    @Test func 나중에만_고르면_저장할_수_없다() async throws {
        let scenario = try await RecoveryScenario.make()
        let model = model(scenario, [.draft("A", .tags)])
        await model.load()
        #expect(model.canSave)
        model.choose(.later, for: try line(model, scenario, .draft("A", .tags)))
        #expect(!model.canSave)
    }

    // MARK: - 진입

    @Test func 쓰기_결과의_막힌_초안은_창_없이_시트_하나에_줄로_모인다() async throws {
        let scenario = try await RecoveryScenario.make()
        let prompter = ScriptedPrompter()
        prompter.onReview = { model in
            for line in model.lines { model.choose(line.options.contains(.keep) ? .keep : .later, for: line) }
            _ = await model.save()
        }
        let requests = RecoveryScenario.allTargets.map { Self.request(scenario, $0) }
        await ReflectionCoordinator(host: scenario.store, prompter: prompter).recover(store: scenario.store, requests: requests)
        #expect(prompter.shown.isEmpty, "연속 창이 뜨면 안 된다")
        #expect(prompter.reviewed.count == 1 && prompter.reviewed[0].lines.count == 7)
        #expect(scenario.store.toast?.kind == .success)
        #expect(scenario.store.recoverySheet == nil)
    }

    @Test func 쓰기_결과의_줄은_곡마다_복구할_종류와_막힌_재생_목록이다() async throws {
        let scenario = try await RecoveryScenario.make()
        let targets = ["A", "B", "C"].compactMap { scenario.rows[$0] }
        let ids = ReflectionCoordinator.recoveryRequests(store: scenario.store, targets: targets, playlistsBlocked: true).map(\.id)
        #expect(ids == RecoveryScenario.allTargets.map { Self.request(scenario, $0).id })
        let tracksOnly = ReflectionCoordinator.recoveryRequests(store: scenario.store, targets: targets, playlistsBlocked: false)
        #expect(tracksOnly.count == 5)
        #expect(ReflectionCoordinator.recoveryRequests(store: scenario.store, targets: [], playlistsBlocked: false).isEmpty)
    }

    @Test func 시트_호스트는_자기_창용_시트만_시트로_띄우고_닫으면_내린다() async throws {
        let scenario = try await RecoveryScenario.make()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: Color.clear.modifier(RecoverySheetHost(store: scenario.store, anchor: .library)))
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        func waitUntil(_ condition: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return condition()
        }
        func sheet(_ anchor: RecoverySheetAnchor) -> RecoverySheetModel {
            RecoverySheetModel(store: scenario.store, requests: [Self.request(scenario, .draft("A", .tags))], anchor: anchor,
                               dependencies: .init(home: scenario.home))
        }
        // 곡 편집 창용 시트는 메인 창에 뜨지 않는다.
        let edit = sheet(.editWindow)
        scenario.store.recoverySheet = edit
        try await Task.sleep(for: .milliseconds(400))
        #expect(window.attachedSheet == nil)
        edit.cancel()
        // 메인 창용 시트는 뜨고, 닫으면(취소·창 닫기 어느 쪽이든) 내려간다.
        let main = sheet(.library)
        scenario.store.recoverySheet = main
        #expect(await waitUntil { window.attachedSheet != nil })
        main.cancel()
        #expect(await waitUntil { window.attachedSheet == nil })
        #expect(scenario.store.recoverySheet == nil && main.isClosed)
    }

    @Test func 기본_시트는_스토어에_올리고_닫으면_내린다() async throws {
        let scenario = try await RecoveryScenario.make()
        let model = model(scenario, [.draft("A", .tags)])
        let shown = Task { await AlertPrompter().review(model) }
        await Task.yield()
        #expect(scenario.store.recoverySheet === model)
        model.cancel()
        await shown.value
        #expect(scenario.store.recoverySheet == nil && model.isClosed)
    }
}

/// #232 이전의 곡·종류별 연속 창 흐름의 사본. 창 문구는 빼고, 어느 단추를 누르면 무엇을 저장하는지만 그대로 둔다.
/// 시트가 같은 선택으로 같은 초안 상태를 만드는지 견주는 기준이다(예전 코드는 `git show 468e7b7:Sources/DJCrate/Reflection/…`).
@MainActor
enum LegacyRecoveryFlow {
    /// 곡 하나·종류 하나: "현재값을 가져올까요?" → 비교 창 → (큐 대상 다시 지정 창) → 저장
    static func recoverDraft(_ scenario: RecoveryScenario, row name: String, kind: DraftRecoveryKind, choice: RecoveryChoice) async throws {
        guard choice != .later else { return }
        let remap = name == "C" && kind == .cues && choice == .keep
        let prompter = ScriptedPrompter()
        prompter.choices = remap ? [.confirm, .confirm, .confirm] : choice == .keep ? [.confirm] : [.alternate]
        let store = scenario.store, row = scenario.rows[name]!
        var review = try await store.prepareDraftRecovery(row: row, kind: kind, home: scenario.home)
        let refusal = review.keepRefusal
        let keep = refusal == nil ? try? review.original.resolved(onto: review.current, choice: .keepEditing) : nil
        let missing = missingCueMappings(review)
        var prompt = ReflectionPrompt(title: "비교", text: "", confirm: keep != nil ? "내 편집 유지·재적용" : "현재값 사용",
                                      destructive: keep == nil, alternate: keep != nil ? "현재값 사용" : nil)
        if keep == nil, !missing.isEmpty { prompt.confirm = "큐 대상 다시 지정…"; prompt.alternate = "현재값 사용"; prompt.destructive = false }
        var answer = prompter.choose(prompt)
        if answer == .cancel { return }
        let action: DraftRecoveryChoice
        if keep == nil, !missing.isEmpty, answer == .confirm {
            guard let mappings = chooseCueMappings(review, missing: missing, prompter: prompter) else { return }
            review.cueSourceMappings = mappings
            _ = try review.original.resolved(onto: review.current, choice: .keepEditing, sourceMappings: mappings)
            answer = prompter.choose(ReflectionPrompt(title: "비교", text: "", confirm: "내 편집 유지·재적용", alternate: "현재값 사용"))
            if answer == .cancel { return }
            action = answer == .confirm ? .keepEditing : .useCurrent
        } else {
            action = keep != nil && answer == .confirm ? .keepEditing : .useCurrent
        }
        try await store.applyDraftRecovery(review, choice: action, home: scenario.home)
        #expect(prompter.choices.isEmpty, "예전 흐름이 고른 답을 다 쓰지 않음: \(name) \(kind)")
    }

    private static func missingCueMappings(_ review: DraftRecoveryReview) -> [EditableCue] {
        guard case let .cues(draft) = review.original, case let .cues(current) = review.current else { return [] }
        let sources = Set(current.base.compactMap(\.sourceID))
        return draft.changes.compactMap {
            if case let .modified(old, _) = $0, let source = old.sourceID, !sources.contains(source) { return old }
            return nil
        }
    }

    private static func chooseCueMappings(_ review: DraftRecoveryReview, missing: [EditableCue], prompter: ReflectionPrompter) -> [String: String]? {
        guard case let .cues(draft) = review.original, case let .cues(current) = review.current else { return nil }
        let known = Set(draft.base.compactMap(\.sourceID))
        var mappings: [String: String] = [:]
        for old in missing {
            guard let oldSource = old.sourceID else { return nil }
            let candidates = current.base.filter { cue in
                cue.sourceID.map { !known.contains($0) && !mappings.values.contains($0) } ?? false
            }
            var selected = false
            for (index, candidate) in candidates.enumerated() {
                let prompt = ReflectionPrompt(title: "연결", text: "", confirm: "이 현재 큐에 연결", alternate: index + 1 < candidates.count ? "다음 큐" : nil)
                switch prompter.choose(prompt) {
                case .cancel: return nil
                case .alternate: continue
                case .confirm:
                    mappings[oldSource] = candidate.sourceID
                    selected = true
                }
                if selected { break }
            }
            if !selected { return nil }
        }
        return mappings
    }

    /// 목록마다 창: 앞 목록을 저장한 뒤 다음 목록을 새로 비교한다. 이미 막혀 있지 않으면 건너뛴다.
    static func recoverPlaylists(_ scenario: RecoveryScenario, choices: [(String, RecoveryChoice)]) async throws {
        let store = scenario.store
        for (id, choice) in choices {
            if !store.blockedPlaylistRecoveryIDs.contains(id) { continue }
            let prompter = ScriptedPrompter()
            prompter.choices = [choice == .keep ? .confirm : choice == .useCurrent ? .alternate : .cancel]
            let review = try await store.preparePlaylistRecovery(playlist: id)
            let canReapply = !review.recovery.reapplied.isEmpty
            switch prompter.choose(ReflectionPrompt(title: "비교", text: "", confirm: canReapply ? "다시 적용" : "초안 버리기",
                                                   destructive: !canReapply, alternate: canReapply ? "초안 버리기" : nil, cancel: "선택하지 않고 남기기")) {
            case .cancel: continue
            case .confirm: try await store.applyPlaylistRecovery(review, reapply: canReapply)
            case .alternate: try await store.applyPlaylistRecovery(review, reapply: false)
            }
        }
    }
}
