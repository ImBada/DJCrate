@testable import DJCrate
import AppKit
import DJCDomain
import DJCTestSupport
import Foundation
import SwiftUI
import Testing

@MainActor
@Suite("반영 — 알림·진행 표시 배치", .serialized)
struct ReflectionLayoutTests {
    /// 경고 알림(주황 아이콘·테두리)이 그려진 줄들. 이미지 좌표는 위에서 아래로 증가한다.
    private static func orangeRows(in view: NSView) throws -> (rows: [Int], height: Int) {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var rows: [Int] = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.7, color.greenComponent > 0.2, color.greenComponent < 0.8, color.blueComponent < 0.3 {
                    rows.append(y)
                }
            }
        }
        return (rows, bitmap.pixelsHigh)
    }

    /// 아래쪽에 뜨되 창 끝에 붙어 잘리지 않는다(#122).
    private static func isAtBottom(_ shot: (rows: [Int], height: Int)) -> Bool {
        !shot.rows.isEmpty && shot.rows.reduce(0, +) / max(shot.rows.count, 1) > shot.height / 2 && (shot.rows.max() ?? .max) < shot.height - 8
    }

    @Test(arguments: ["light", "dark"]) func 결과_알림은_최소_창의_detail_아래쪽에_보인다(_ appearance: String) async throws {
        _ = NSApplication.shared
        // 시험 프로세스 공용 defaults(swiftpm-testing-helper)에는 이전 실행·다른 워크트리가 남긴 창 배치 값(사이드바·툴바)이 있다.
        // 화면이 그 값에 따라 달라지지 않게 배치 값을 시험 전용 저장소로 고정하고, 공용 툴바 설정은 시험 동안 비웠다 되돌린다.
        let defaults = UserDefaults(suiteName: "djc.test.reflection-layout.\(UUID())")!
        defaults.set(false, forKey: SettingKeys.sidebarVisible.name)
        let toolbarKey = "NSToolbar Configuration main"
        let savedToolbar = UserDefaults.standard.object(forKey: toolbarKey)
        UserDefaults.standard.removeObject(forKey: toolbarKey)
        defer { UserDefaults.standard.set(savedToolbar, forKey: toolbarKey) }

        // detail을 안내 뷰(.idle)가 아니라 창을 채우는 덱·곡 목록(.loaded, 합성 곡)으로 두어 알림이 창 아래쪽에 붙게 한다.
        let fixture = try RekordboxFixture()
        for index in 1...5 {
            var track = TrackSpec(id: String(100 + index))
            track.title = "합성 곡 \(index)"
            try fixture.add(track)
        }
        let store = LibraryStore(settings: SettingsStore(defaults: defaults, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }))
        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        store.toast = AppToast(kind: .warning, title: "배치 시험 결과", detail: "합성 데이터로 확인합니다")
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck).defaultAppStorage(defaults))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.orderFront(nil)
        defer { window.close() }
        // 고정 시간 대신, 알림이 들어오는 애니메이션과 배치가 끝나 알림이 아래쪽에 자리 잡은 모양이 두 번 연달아 보일 때까지 기다린다.
        // 부하로 느려져도 같은 결과가 나오게 시간이 아니라 횟수로만 끊고(끝내 자리 잡지 않으면 아래 검사가 마지막 모양으로 실패한다), 검사 내용은 그대로다.
        // 한 번 확인에 0.4초쯤 걸려, 잘못 붙은 알림은 80번(30~40초) 뒤에 실패로 끝난다.
        var shot = try Self.orangeRows(in: controller.view)
        var settled = 0
        for _ in 0..<80 where settled < 2 {
            try await Task.sleep(for: .milliseconds(50))
            window.contentView?.layoutSubtreeIfNeeded()
            shot = try Self.orangeRows(in: controller.view)
            settled = Self.isAtBottom(shot) ? settled + 1 : 0
        }
        #expect(!shot.rows.isEmpty)
        #expect(shot.rows.reduce(0, +) / max(shot.rows.count, 1) > shot.height / 2)
        #expect((shot.rows.max() ?? .max) < shot.height - 8)
    }

    /// 넓은 창에서도 진행 카드는 막대가 남는 폭을 다 차지하지 않고 문구에 맞는 폭(최대 폭 안)으로 뜬다(#122).
    @Test(arguments: [1.0, 1.4]) func 진행_카드는_넓은_창에서도_최대_폭_안에_뜬다(_ scale: Double) {
        _ = NSApplication.shared
        func width(_ stage: WriteStage) -> Double {
            let card = WritingStageCard(stage: stage, onCancel: {}).environment(\.textScale, scale)
            return NSHostingController(rootView: card).sizeThatFits(in: CGSize(width: 1800, height: 900)).width
        }
        let preview = width(WriteStage(String(ui: "미리 보기 2/2단계 · 바꿀 내용을 검사하는 중…"), completed: 1, total: 2, cancellable: true))
        let writing = width(WriteStage(String(ui: "rekordbox에 쓰는 중…")))
        // 내용 최대 폭 400pt(글자 배율만큼) + 좌우 여백 28pt씩
        let limit = TextScale.length(400, scale: scale) + 56
        #expect(preview <= limit)
        #expect(writing <= limit)
        // 막대가 있어도 단계 문구가 한 줄 이상 읽히는 폭은 남긴다.
        #expect(preview >= TextScale.length(240, scale: scale))
    }

    /// 문구가 최소 폭보다 짧아도 표시와 글자는 카드 가운데에 모인다(왼쪽에 붙어 치우쳐 보였다, #148).
    @Test(arguments: ["light", "dark"]) func 진행_카드의_표시와_글자는_카드_가운데에_있다(_ appearance: String) throws {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: WritingStageCard(stage: .reloadingLibrary, onCancel: {}))
        view.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        func brightness(_ x: Int, _ y: Int) -> Double? {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { return nil }
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        // 좌우 여백(28pt) 안쪽 한 점을 카드 바탕으로 보고, 바탕과 밝기가 크게 다른 점(글자·표시)의 가로 범위를 잰다.
        let background = try #require(brightness(4, bitmap.pixelsHigh / 2))
        var columns: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let value = brightness(x, y), abs(value - background) > 0.3 { columns.append(x) }
            }
        }
        let left = try #require(columns.min()), right = try #require(columns.max())
        let offset = Double(left + right) / 2 - Double(bitmap.pixelsWide) / 2
        #expect(abs(offset) <= Double(bitmap.pixelsWide) * 0.02, "내용 가운데가 카드 가운데에서 \(offset)px 벗어남")
    }

    /// 최대 폭을 넘는 긴 문구(번역·큰 글자)는 잘리지 않고 최대 폭에서 줄을 바꿔 카드가 높아진다.
    @Test func 진행_카드의_긴_문구는_최대_폭에서_줄을_바꾼다() {
        _ = NSApplication.shared
        func size(_ text: String) -> CGSize {
            NSHostingController(rootView: WritingStageCard(stage: WriteStage(text, completed: 1, total: 2), onCancel: {}))
                .sizeThatFits(in: CGSize(width: 1800, height: 900))
        }
        let short = size("짧은 단계")
        let long = size(String(repeating: "아주 긴 단계 문구 ", count: 8))
        #expect(abs(long.width - (400 + 56)) < 1)
        #expect(long.height > short.height)
    }
}
