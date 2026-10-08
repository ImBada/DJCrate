@testable import DJCrate
import DJCDomain
import DJCStorage
import Testing

@Suite("USB의 rekordbox 동기화 선택 우선순위")
struct UsbSyncNativeSelectionTests {
    private let localDBID: Int64 = 42
    private let native = ITunesSyncSelection(selectedIDs: ["itunes:DJ"])
    private let app = ITunesSyncSelection(selectedIDs: ["local-list"])

    private func preferences(fingerprint: String?, dbid: Int64 = 42) -> UsbSyncPreferences {
        UsbSyncPreferences(volumeKey: "synthetic", localDBID: dbid, selection: app, syncPlaylists: false,
                           nativeSelectionFingerprint: fingerprint)
    }

    @Test("기존 앱 설정에 지문이 없으면 USB에 저장된 선택과 켜짐을 채택한다")
    func legacyPreferencesFollowNativeSelection() {
        let choice = UsbSyncPreferenceChoice.resolve(preferences: preferences(fingerprint: nil), localDBID: localDBID,
                                                     hasNativeFiles: true, fingerprint: "native-first",
                                                     nativeSelection: native, nativeEnabled: true,
                                                     fallbackSelection: ITunesSyncSelection())
        #expect(choice.selection == native)
        #expect(choice.enabled)
        #expect(!choice.usesSavedPreferences)
    }

    @Test("USB 원본 지문이 같으면 아직 쓰지 않은 앱 선택을 유지한다")
    func unchangedNativeSelectionKeepsUnsavedAppSelection() {
        let choice = UsbSyncPreferenceChoice.resolve(preferences: preferences(fingerprint: "native-first"), localDBID: localDBID,
                                                     hasNativeFiles: true, fingerprint: "native-first",
                                                     nativeSelection: native, nativeEnabled: true,
                                                     fallbackSelection: ITunesSyncSelection())
        #expect(choice.selection == app)
        #expect(!choice.enabled)
        #expect(choice.usesSavedPreferences)
    }

    @Test("rekordbox가 USB 선택을 바꾸면 앱의 옛 선택보다 새 원본을 우선한다")
    func changedNativeSelectionReplacesOldAppPreferences() {
        let choice = UsbSyncPreferenceChoice.resolve(preferences: preferences(fingerprint: "old"), localDBID: localDBID,
                                                     hasNativeFiles: true, fingerprint: "new",
                                                     nativeSelection: native, nativeEnabled: true,
                                                     fallbackSelection: app)
        #expect(choice.selection == native)
        #expect(choice.enabled)
        #expect(!choice.usesSavedPreferences)
    }

    @Test("두 형식 충돌로 지문을 만들 수 없으면 nil끼리 같다고 앱 선택을 채택하지 않는다")
    func conflictingFilesNeverMatchNilFingerprint() {
        let choice = UsbSyncPreferenceChoice.resolve(preferences: preferences(fingerprint: nil), localDBID: localDBID,
                                                     hasNativeFiles: true, fingerprint: nil,
                                                     nativeSelection: native, nativeEnabled: true,
                                                     fallbackSelection: app)
        #expect(choice.selection == native)
        #expect(!choice.usesSavedPreferences)
    }

    @Test("선택 파일이 없는 기존 DJCrate USB는 저장된 앱 선택을 이어 쓴다")
    func noNativeFilesKeepsExistingAppSelection() {
        let choice = UsbSyncPreferenceChoice.resolve(preferences: preferences(fingerprint: nil), localDBID: localDBID,
                                                     hasNativeFiles: false, fingerprint: nil,
                                                     nativeSelection: native, nativeEnabled: true,
                                                     fallbackSelection: ITunesSyncSelection())
        #expect(choice.selection == app)
        #expect(!choice.enabled)
        #expect(choice.usesSavedPreferences)
    }

    @Test("다른 로컬 DB에서 저장한 앱 선택은 지문이 같아도 쓰지 않는다")
    func differentLocalDatabaseRejectsSavedSelection() {
        let choice = UsbSyncPreferenceChoice.resolve(preferences: preferences(fingerprint: "same", dbid: 99), localDBID: localDBID,
                                                     hasNativeFiles: true, fingerprint: "same",
                                                     nativeSelection: native, nativeEnabled: true,
                                                     fallbackSelection: app)
        #expect(choice.selection == native)
        #expect(!choice.usesSavedPreferences)
    }

    @Test("USB 켜짐을 확인하지 못하면 현재 화면 값을 참으로 바꾸지 않는다")
    func unknownEnabledStateKeepsTheCurrentControl() {
        let choice = UsbSyncPreferenceChoice.resolve(preferences: nil, localDBID: localDBID,
                                                     hasNativeFiles: true, fingerprint: "same",
                                                     nativeSelection: native, nativeEnabled: nil,
                                                     fallbackSelection: app, currentEnabled: false)
        #expect(choice.selection == native)
        #expect(!choice.enabled)
    }
}
