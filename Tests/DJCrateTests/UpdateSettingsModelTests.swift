import DJCDomain
@testable import DJCrate
import Foundation
import Testing

/// 앱 자동 업데이트(#59): 설정 › 업데이트 화면 모델. 업데이트 도구(Sparkle 연결)는 가짜로 바꿔 넣는다.
@MainActor
@Suite("설정 업데이트")
struct UpdateSettingsModelTests {
    final class FakeUpdater: UpdaterControl {
        var automaticallyChecks = true
        var automaticallyDownloads = false
        var canCheck = true
        var lastCheckDate: Date?
        var onChange: (() -> Void)?
        private(set) var checks = 0
        func checkForUpdates() { checks += 1 }
    }

    @Test func 업데이트_도구의_값을_보이고_바꾸면_도구에_쓴다() {
        let updater = FakeUpdater()
        let model = UpdateSettingsModel(updater: updater, version: AppVersion(short: "0.1.1", build: "512"))
        #expect(model.isAvailable)
        #expect(model.versionText == "0.1.1 (512)")
        #expect(model.automaticallyChecks)
        #expect(!model.automaticallyDownloads)
        model.automaticallyDownloads = true
        #expect(updater.automaticallyDownloads)
        model.automaticallyChecks = false
        #expect(!updater.automaticallyChecks)
        // 자동 확인을 끄면 자동 설치는 의미가 없어 막는다(값은 그대로 둔다)
        #expect(!model.canChangeAutomaticDownloads)
    }

    @Test func 지금_확인은_확인할_수_있을_때만_부른다() {
        let updater = FakeUpdater()
        let model = UpdateSettingsModel(updater: updater, version: AppVersion(short: "0.1.1", build: "512"))
        model.checkNow()
        #expect(updater.checks == 1)
        updater.canCheck = false
        updater.onChange?()
        #expect(!model.canCheck)
        model.checkNow()
        #expect(updater.checks == 1)
    }

    @Test func 도구가_알린_변화를_다시_읽는다() {
        let updater = FakeUpdater()
        let model = UpdateSettingsModel(updater: updater, version: AppVersion(short: "0.1.1", build: "512"))
        #expect(model.lastCheckDate == nil)
        let checked = Date(timeIntervalSince1970: 1_800_000_000)
        updater.lastCheckDate = checked
        updater.automaticallyDownloads = true
        updater.onChange?()
        #expect(model.lastCheckDate == checked)
        #expect(model.automaticallyDownloads)
    }

    @Test func 업데이트_도구가_없으면_막고_이유를_보인다() {
        let model = UpdateSettingsModel(updater: nil, version: AppVersion(short: "0.1", build: "1"))
        #expect(!model.isAvailable)
        #expect(!model.canCheck)
        #expect(model.unavailableReason != nil)
        model.checkNow()
        model.automaticallyChecks = true
    }

    @Test func 정보_파일_주소와_공개_키가_모두_있어야_업데이트를_켠다() {
        #expect(UpdateFeedConfig.isConfigured(["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "abc="]))
        #expect(!UpdateFeedConfig.isConfigured(["SUFeedURL": "https://example.com/appcast.xml"]))
        #expect(!UpdateFeedConfig.isConfigured(["SUFeedURL": "", "SUPublicEDKey": "abc="]))
        #expect(!UpdateFeedConfig.isConfigured([:]))
    }

    @Test func 앱의_쓰기_상태를_업데이트_판정에_넘긴다() {
        let store = LibraryStore.test()
        #expect(store.writeActivity == .idle)
        store.setWriteLock(true, deck: false)
        #expect(store.writeActivity == AppWriteActivity(writingRekordbox: true, writingUsb: false))
        store.setWriteLock(false, deck: false)
        #expect(store.writeActivity == .idle)
    }
}
