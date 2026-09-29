@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

extension UsbTestData {
    /// 수정 미리 보기 요약(지어낸 값)
    static func editSummary(editCount: Int = 3, outcomes: [Int: UsbEditSummary.Outcome]? = nil, stopping: [String] = [],
                            skipped: [UsbEditSummary.Count] = [], formats: [UsbEditSummary.FormatResult]? = nil, removals: Int = 0,
                            deferred: [String] = [], notes: [String] = [], rules: [UsbProvisionalRule] = [], hasChanges: Bool = true,
                            testVolume: Bool = true, formatDrift: Bool = false) -> UsbEditSummary {
        UsbEditSummary(editCount: editCount, outcomes: outcomes ?? Dictionary(uniqueKeysWithValues: (1...max(editCount, 1)).map { ($0, .written) }),
                       stopping: stopping, skipped: skipped,
                       formats: formats ?? [.init(format: .oneLibrary, written: true, blocked: nil), .init(format: .deviceLibrary, written: true, blocked: nil)],
                       removals: removals, deferred: deferred, notes: notes, warnings: [], rules: rules, hasChanges: hasChanges,
                       isTestVolume: testVolume, formatDrift: formatDrift)
    }
}

@MainActor
@Suite("USB 쓰기 대기(UsbPendingView)")
struct UsbPendingTests {
    let image = FakeUsbVolume.diskImageFAT32(name: "B13T")
    let service = FakeUsbWriteService()
    let host = FakeUsbWriteHost()
    let prompter = ScriptedPrompter()
    let drafts = FileManager.default.temporaryDirectory.appending(path: "djc-usbpending-\(UUID().uuidString)")

    var key: String { image.usbKey }

    func cleanUp() { try? FileManager.default.removeItem(at: drafts) }

    @Test("대기 목록은 편집마다 설명과 막힘(미리 판정·미리 보기 결과)을 보이고, USB 전체 막힘이면 쓰기를 막는다")
    func pendingListShowsEditsAndBlocks() throws {
        let library = UsbEditTestData.mixedLibrary()
        let edits: [UsbLibraryEdit] = [
            .addTracks(localContentIDs: ["11", "12"], playlist: .id("10")),
            .removeTracks(usbContentIDs: [2]),
            .playlist(edit: .addTracks(playlist: .id("4"), contentIDs: ["1"])),
            .playlist(edit: .create(key: "k1", name: "새 목록", isFolder: false, parent: .id("5"))),
            .playlist(edit: .rename(playlist: .new("k1"), name: "또 새 이름")),
            .playlist(edit: .removeTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 2, contentID: "1")])),
            .refreshTracks(usbContentIDs: [1, 3], parts: [.info]),
            .playlist(edit: .reorder(playlist: .id("10"), index: 1)),
            .playlist(edit: .delete(playlist: .id("5"))),
        ]
        let blockReason: (UsbLibraryEdit) -> String? = { UsbEditActions.blockReason($0, volume: image, library: library, info: nil) }
        let waiting = UsbPendingModel(volumeName: "B13T", isConnected: true, edits: edits, library: library, summary: nil, busy: false,
                                      blockReason: blockReason)
        #expect(waiting.rows.map(\.text) == [
            "곡 2개 더하기 · ‘시험 목록’에 넣기",
            "곡 1개 USB에서 빼기",
            "‘다름’에 곡 1개 넣기",
            "새 재생 목록 ‘새 목록’ · ‘폴더’ 안",
            "이름 바꾸기: ‘새 목록’ → ‘또 새 이름’",
            "‘시험 목록’에서 곡 1개 빼기",
            "곡 2개 로컬 변경 반영",
            "순서 바꾸기: ‘시험 목록’",
            "지우기: ‘폴더’",
        ])
        #expect(waiting.rows.map(\.id) == Array(1...9))
        let differ = "이 재생 목록은 두 형식의 곡 목록이 달라 곡을 고칠 수 없습니다. 이름·위치만 바꿀 수 있습니다"
        // 미리 보기 전: 막힐 편집만 이유를 단다
        #expect(waiting.rows[2].status == .expectedBlock(differ))
        #expect(waiting.rows.filter { $0.status != .waiting }.count == 1)
        #expect(waiting.canWrite)
        #expect(waiting.canPreview)
        #expect(waiting.summaryLines.isEmpty)

        // 미리 보기 뒤: 편집별 결과, 빼고 쓰는 곡·형식별 결과·지울 파일·미룸
        var outcomes = Dictionary(uniqueKeysWithValues: (1...9).map { ($0, UsbEditSummary.Outcome.written) })
        outcomes[3] = .blocked(differ)
        outcomes[8] = .unchanged
        outcomes[2] = .deferred("Device Library가 막혀 파일 지우기를 미뤘습니다")
        let summary = UsbTestData.editSummary(editCount: 9, outcomes: outcomes,
                                              skipped: [.init(message: "rekordbox 분석이 스냅샷 뒤에 바뀌었습니다. 새 스냅샷을 뜬 뒤 다시 시도하세요", count: 1)],
                                              formats: [.init(format: .oneLibrary, written: true, blocked: nil),
                                                        .init(format: .deviceLibrary, written: false, blocked: "CDJ가 쓴 기록·목록이 있어 Device Library는 아직 고칠 수 없습니다")],
                                              removals: 4, deferred: ["Device Library가 막혀 파일 지우기를 미뤘습니다"],
                                              notes: ["USB가 그 사이 바뀌어 다시 계획했습니다"], formatDrift: true)
        let previewed = UsbPendingModel(volumeName: "B13T", isConnected: true, edits: edits, library: library, summary: summary, busy: false,
                                        blockReason: blockReason)
        #expect(previewed.rows[0].status == .written)
        #expect(previewed.rows[1].status == .deferred("Device Library가 막혀 파일 지우기를 미뤘습니다"))
        #expect(previewed.rows[2].status == .blocked(differ))
        #expect(previewed.rows[7].status == .unchanged)
        #expect(previewed.rows[2].statusText == "막힘: \(differ)")
        #expect(previewed.rows[7].statusText == "바꿀 것 없음")
        #expect(previewed.rows[0].statusText == "쓸 예정")
        let lines = previewed.summaryLines
        #expect(lines.contains("쓸 편집 7건 · 막힌 편집 1건 · 바꿀 것 없는 편집 1건"))
        #expect(lines.contains("빼고 쓰는 곡 1개:"))
        #expect(lines.contains("• rekordbox 분석이 스냅샷 뒤에 바뀌었습니다. 새 스냅샷을 뜬 뒤 다시 시도하세요 (1)"))
        #expect(lines.contains("OneLibrary: 고침"))
        #expect(lines.contains("Device Library: 고치지 않음 — CDJ가 쓴 기록·목록이 있어 Device Library는 아직 고칠 수 없습니다"))
        #expect(lines.contains("USB에서 지울 파일 4개"))
        #expect(lines.contains("파일 지우기를 미룸: Device Library가 막혀 파일 지우기를 미뤘습니다"))
        #expect(lines.contains("Device Library를 고치지 못해 두 형식의 곡이 달라집니다. 다음부터 이 USB를 고치려면 rekordbox에서 다시 내보내세요"))
        #expect(lines.contains("USB가 그 사이 바뀌어 다시 계획했습니다"))
        #expect(previewed.canWrite)

        // USB 전체 막힘: 쓰기를 막고 이유를 보인다
        let stopped = UsbPendingModel(volumeName: "B13T", isConnected: true, edits: edits, library: library,
                                      summary: UsbTestData.editSummary(editCount: 9, stopping: ["두 형식의 곡 번호가 달라 고칠 수 없습니다. rekordbox에서 다시 내보내세요"],
                                                                       hasChanges: false),
                                      busy: false, blockReason: blockReason)
        #expect(!stopped.canWrite)
        #expect(stopped.writeHelp == "두 형식의 곡 번호가 달라 고칠 수 없습니다. rekordbox에서 다시 내보내세요")
        // 쓰는 중·빈 초안
        let busy = UsbPendingModel(volumeName: "B13T", isConnected: true, edits: edits, library: library, summary: nil, busy: true,
                                   blockReason: blockReason)
        #expect(!busy.canWrite && !busy.canPreview && busy.writeHelp == "USB에 쓰는 중입니다. 쓰기가 끝난 뒤 다시 시도하세요")
        let empty = UsbPendingModel(volumeName: "B13T", isConnected: true, edits: [], library: library, summary: nil, busy: false,
                                    blockReason: blockReason)
        #expect(!empty.canWrite && empty.writeHelp == "쓸 편집이 없습니다. 곡 목록·사이드바에서 USB 편집을 더하세요")
    }

    @Test("USB에 쓰기…는 코디네이터 흐름(미리 보기 → 확인 → 쓰기 → 토스트)을 타고, 쓴 뒤 초안 수를 다시 읽는다")
    func writeDraftUsesCoordinator() async throws {
        defer { cleanUp() }
        let usbHost = FakeUsbHost([image])
        usbHost.serve(image, library: UsbTestData.library())
        let usb = UsbTestData.store(usbHost)
        usb.writeService = service
        usb.draftDirectory = drafts
        await usb.refresh()
        let actions = UsbEditActions(usb: usb, host: host, prompter: prompter, namePrompter: ScriptedNamePrompter())
        await actions.append(.removeTracks(usbContentIDs: [2]), to: key)
        await actions.append(.playlist(edit: .rename(playlist: .id("10"), name: "새 이름")), to: key)
        await actions.append(.playlist(edit: .addTracks(playlist: .id("10"), contentIDs: ["9"])), to: key)
        #expect(usb.draftCounts[key] == 3)

        var outcomes: [Int: UsbEditSummary.Outcome] = [1: .written, 2: .written, 3: .blocked("대상이 USB에서 사라졌습니다. USB를 다시 읽은 뒤 고치세요")]
        let summary = UsbTestData.editSummary(editCount: 3, outcomes: outcomes, removals: 3, rules: [.editRemoveTracks])
        let drafts = drafts, key = key
        service.update {
            $0.editSummary = summary
            // 실제 세션처럼 막힌 편집만 초안에 남긴다
            $0.onWriteEdit = {
                let store = UsbDraftStore(directory: drafts)
                if var draft = try? store.load(volumeKey: key), draft.edits.count == 3 {
                    draft.edits = [draft.edits[2]]
                    try? store.save(draft)
                }
            }
            $0.editWriteProgress = [UsbProgress(phase: .files, completedItems: 1, totalItems: 2, cancellable: true)]
        }
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter, isRekordboxRunning: { false })
        let database = URL(filePath: "/tmp/djc-fixture/m.db"), share = URL(filePath: "/tmp/djc-fixture/share")

        // 확인 창에서 취소하면 쓰지 않는다
        prompter.answer = false
        await coordinator.writeDraft(volumeKey: key, database: database, share: share, snapshotTime: "2026-01-01T00:00:00Z")
        #expect(service.current.calls == ["draftBase", "previewEdit"])
        let confirm = try #require(prompter.shown.last)
        #expect(confirm.title == "USB에 편집 2건을 쓸까요?")
        #expect(confirm.confirm == "USB에 쓰기")
        #expect(confirm.text == "B13T의 rekordbox 라이브러리를 고칩니다. 쓰기 전에 Mac에 백업하고 쓴 뒤 USB에서 다시 읽어 확인합니다. 끝날 때까지 USB를 뽑지 마세요.")
        #expect(confirm.details.contains("시험 볼륨(디스크 이미지)입니다"))
        #expect(confirm.details.contains("막힌 편집 1건(초안에 남깁니다):"))
        #expect(confirm.details.contains("• 편집 3: 대상이 USB에서 사라졌습니다. USB를 다시 읽은 뒤 고치세요"))
        #expect(confirm.details.contains("USB에서 지울 파일 3개"))
        #expect(confirm.details.contains("확인 안 된 규칙 1개:"))
        #expect(service.current.editJobs.last?.database == database)
        #expect(service.current.editJobs.last?.share == share)
        #expect(service.current.editJobs.last?.snapshotTime == "2026-01-01T00:00:00Z")
        #expect(service.current.editJobs.last?.volume == image)
        #expect(usb.busyVolumes.isEmpty && usb.activeWrite == nil)

        // 확인하면 쓰고, 끝나면 토스트([꺼내기])와 남은 초안 수
        prompter.answer = true
        await coordinator.writeDraft(volumeKey: key, database: database, share: share)
        #expect(service.current.calls == ["draftBase", "previewEdit", "previewEdit", "writeEdit"])
        #expect(host.toast?.title == "USB에 편집 2건을 썼습니다")
        #expect(host.toast?.detail == "B13T · 막힌 편집 1건은 초안에 남겼습니다")
        #expect(host.toast?.action == .ejectUsb(volumeKey: key))
        #expect(usb.draftCounts[key] == 1)
        #expect(usb.busyVolumes.isEmpty && usb.activeWrite == nil)

        // 대기 목록에서 방금 본 미리 보기는 다시 보지 않는다
        await coordinator.writeDraft(volumeKey: key, database: database, share: share, reusing: summary)
        #expect(service.current.calls.suffix(2) == ["writeEdit", "writeEdit"])

        // USB 전체 막힘이면 쓰지 않고 이유를 알린다
        outcomes = [1: .blocked("x")]
        service.update { $0.editSummary = UsbTestData.editSummary(editCount: 1, outcomes: outcomes, stopping: ["두 형식의 곡 번호가 달라 고칠 수 없습니다. rekordbox에서 다시 내보내세요"], hasChanges: false) }
        let before = service.current.calls.count
        await coordinator.writeDraft(volumeKey: key, database: database, share: share)
        #expect(service.current.calls.count == before + 1)
        #expect(prompter.shown.last?.title == "USB에 쓸 수 없습니다")
        #expect(prompter.shown.last?.text == "두 형식의 곡 번호가 달라 고칠 수 없습니다. rekordbox에서 다시 내보내세요")

        // 쓸 것이 없으면(모두 막힘·바꿀 것 없음) 쓰지 않고 알린다
        service.update { $0.editSummary = UsbTestData.editSummary(editCount: 1, outcomes: [1: .unchanged], hasChanges: false) }
        await coordinator.writeDraft(volumeKey: key, database: database, share: share)
        #expect(!service.current.calls.suffix(1).contains("writeEdit"))
        #expect(prompter.shown.last?.title == "USB에 쓸 것이 없습니다")

        // rekordbox가 켜져 있으면 미리 보기도 하지 않는다
        let calls = service.current.calls.count
        let running = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter, isRekordboxRunning: { true })
        await running.writeDraft(volumeKey: key, database: database, share: share)
        #expect(await running.previewDraft(volumeKey: key, database: database, share: share) == nil)
        #expect(service.current.calls.count == calls)
    }
}
