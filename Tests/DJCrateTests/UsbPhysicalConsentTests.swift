@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// 시험용 목록 파일: 메모리에만 두고 고친 차례를 적는다(실제 DJCrate 데이터 폴더를 읽거나 쓰지 않는다)
final class FakePhysicalLists: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: UsbPhysicalLists.Loaded
    private var log: [String] = []

    init(_ loaded: UsbPhysicalLists.Loaded = UsbTestData.lists()) { self.loaded = loaded }

    var current: UsbPhysicalLists.Loaded { lock.withLock { loaded } }
    var calls: [String] { lock.withLock { log } }

    var io: UsbPhysicalListIO {
        UsbPhysicalListIO(allow: { [self] volume in
            lock.withLock {
                log.append("allow \(volume.name)")
                loaded.allow.insert(volume.volumeUUID!.uppercased())
            }
        }, revoke: { [self] uuid in
            lock.withLock {
                log.append("revoke")
                loaded.allow.remove(uuid.uppercased())
            }
        }, deny: { [self] volume in
            lock.withLock {
                log.append("deny \(volume.name)")
                loaded.deny.insert(volume.volumeUUID!.uppercased())
                loaded.allow.remove(volume.volumeUUID!.uppercased())
            }
        })
    }
}

@MainActor
@Suite("실물 USB 쓰기 허용·금지(사이드바)")
struct UsbPhysicalConsentTests {
    let physical = FakeUsbVolume.physicalFAT32()
    let image = FakeUsbVolume.diskImageFAT32()
    let prompter = ScriptedPrompter()
    let host = FakeUsbWriteHost()

    func setUp(_ volumes: [UsbVolumeInfo], lists: FakePhysicalLists, switchOn: Bool = true,
               policy: UsbReadPolicy = .all) async -> (UsbStore, UsbPhysicalConsent) {
        let usbHost = FakeUsbHost(volumes)
        for volume in volumes { usbHost.serve(volume, library: UsbTestData.library()) }
        let usb = UsbStore(host: usbHost, readPolicy: policy, localLibrary: { nil }, physicalLists: { lists.current })
        usb.isScratchMount = { _ in true }
        usb.physicalWriteEnabled = switchOn
        await usb.refresh()
        return (usb, UsbPhysicalConsent(usb: usb, host: host, prompter: prompter, io: lists.io))
    }

    @Test("쓰기 허용: 묻고, 누르면 목록에 더하고 다시 읽어 메뉴·막힘이 바뀐다")
    func allowAsksThenAdds() async {
        let lists = FakePhysicalLists()
        let (usb, consent) = await setUp([physical], lists: lists)
        let key = physical.usbKey
        #expect(usb.physicalMenu(key) == UsbPhysicalMenu(isDenied: false, isAllowed: false, consentBlock: nil, switchOn: true))
        #expect(usb.physicalWriteBlock(physical)?.contains("djc usb-allow") == true)
        prompter.answer = false
        await consent.allow(key)
        #expect(lists.calls.isEmpty)
        #expect(prompter.shown.last?.title == "‘DJCPHYS’에 쓰기를 허용할까요?")
        #expect(prompter.shown.last?.confirm == "쓰기 허용")
        prompter.answer = true
        await consent.allow(key)
        #expect(lists.calls == ["allow DJCPHYS"])
        #expect(usb.physicalMenu(key)?.isAllowed == true)
        #expect(usb.physicalWriteBlock(physical) == nil)
        #expect(host.toast?.title == "이 USB에 쓰기를 허용했습니다")
        await consent.revoke(key)
        #expect(lists.calls.last == "revoke")
        #expect(usb.physicalMenu(key)?.isAllowed == false)
    }

    @Test("실험실 스위치가 꺼져 있으면 허용 창에 켜라고 적고, 허용해도 쓰기는 막힌다")
    func allowWithSwitchOff() async {
        let lists = FakePhysicalLists()
        let (usb, consent) = await setUp([physical], lists: lists, switchOn: false)
        await consent.allow(physical.usbKey)
        #expect(prompter.shown.last?.details.first == "쓰려면 설정 › 실험실의 ‘실물 USB 쓰기’도 켜야 합니다")
        #expect(usb.physicalMenu(physical.usbKey)?.isAllowed == true)
        #expect(usb.physicalWriteBlock(physical)
            == "실물 USB 쓰기가 꺼져 있습니다. 앱은 설정 › 실험실에서 켜고, djc는 --allow-physical을 준 뒤 다시 시도하세요")
    }

    @Test("rekordbox USB 모양이 아니거나 USB 메모리가 아니면 허용 창 대신 이유를 알리고 목록을 고치지 않는다")
    func allowRefusedShape() async {
        let lists = FakePhysicalLists()
        let ssd = FakeUsbVolume.externalSSD()
        let (usb, consent) = await setUp([ssd], lists: lists)
        #expect(usb.physicalMenu(ssd.usbKey)?.consentBlock
            == "USB 메모리가 아닌 디스크(외장 SSD 등)에는 쓰지 않습니다. rekordbox용 USB 메모리를 연결하세요")
        await consent.allow(ssd.usbKey)
        #expect(lists.calls.isEmpty)
        #expect(prompter.shown.last?.title == "이 USB에는 쓰기를 허용할 수 없습니다")
        #expect(prompter.shown.last?.confirm == nil)
    }

    @Test("쓰기 금지 목록에 넣기: 묻고(파괴 동작 표시), 넣은 뒤에는 읽지 않고 메뉴도 없다")
    func denyAsksThenHides() async {
        let lists = FakePhysicalLists()
        let (usb, consent) = await setUp([physical], lists: lists)
        await consent.deny(physical.usbKey)
        #expect(prompter.shown.last?.destructive == true)
        #expect(lists.calls == ["deny DJCPHYS"])
        #expect(usb.refusals[physical.usbKey] == "denylisted")
        #expect(usb.physicalMenu(physical.usbKey)?.isDenied == true)
        #expect(UsbSidebarModel.volumes(usb).first?.status == "쓰기 금지 볼륨")
    }

    @Test("목록 파일을 고치지 못하면 이유를 알리고 성공 토스트를 띄우지 않는다(그 사이 다른 USB가 붙음·목록 파일 깨짐)")
    func listFailureInformsWithoutToast() async {
        let lists = FakePhysicalLists()
        var (_, consent) = await setUp([physical], lists: lists)
        let unreadable = UsbBlock(code: "listUnreadable", scope: .volume, message: "목록이 깨짐")
        consent.io = UsbPhysicalListIO(allow: { _ in throw UsbError.readFailed(detail: "volumeChanged") },
                                       revoke: { _ in throw UsbError.writeRefused([unreadable]) },
                                       deny: { _ in throw UsbError.writeRefused([unreadable]) })
        await consent.allow(physical.usbKey)
        #expect(prompter.shown.last?.title == "쓰기를 허용하지 않았습니다")
        #expect(prompter.shown.last?.text == "그 사이 다른 USB가 연결됐습니다. USB를 다시 읽은 뒤 고르세요")
        #expect(prompter.shown.last?.critical == true)
        await consent.deny(physical.usbKey)
        #expect(prompter.shown.last?.text == "목록이 깨짐")
        await consent.revoke(physical.usbKey)
        #expect(prompter.shown.last?.title == "쓰기 허용을 거두지 못했습니다")
        #expect(host.toast == nil)
    }

    @Test("디스크 이미지에는 허용·금지 메뉴가 없다(허용 없이 시험 쓰기를 한다)")
    func diskImageHasNoMenu() async {
        let (usb, _) = await setUp([image], lists: FakePhysicalLists())
        #expect(usb.physicalMenu(image.usbKey) == nil)
        #expect(usb.physicalWriteBlock(image) == nil)
    }

    @Test("디스크 이미지만 읽는 실행(시험)은 스위치를 켜도 실물 쓰기를 열지 않는다")
    func diskImagesOnlyKeepsSwitchOff() async {
        let lists = FakePhysicalLists(UsbPhysicalLists.Loaded(allow: [FakeUsbVolume.physicalUUID], deny: [UsbTestData.otherUUID],
                                                              denyStatus: .init(fixedLocation: .ok, fixedEntryCount: 1, userData: .missing),
                                                              allowState: .ok))
        let (usb, _) = await setUp([image], lists: lists, policy: .diskImagesOnly)
        #expect(!usb.physicalGate.isOpen)
        #expect(!SystemUsbWriteService.physicalWriteSwitch(policy: .diskImagesOnly,
                                                           settings: SettingsStore(defaults: Self.defaults(on: true), persist: true)))
    }

    @Test("쓰기 창구의 스위치는 설정 › 실험실 값을 따른다(자가 테스트는 설정을 읽지 않아 늘 끔)")
    func serviceSwitchFollowsSetting() {
        #expect(SystemUsbWriteService.physicalWriteSwitch(policy: .all, settings: SettingsStore(defaults: Self.defaults(on: true), persist: true)))
        #expect(!SystemUsbWriteService.physicalWriteSwitch(policy: .all, settings: SettingsStore(defaults: Self.defaults(on: false), persist: true)))
        #expect(!SystemUsbWriteService.physicalWriteSwitch(policy: .all, settings: SettingsStore(defaults: Self.defaults(on: true), persist: false)))
    }

    @Test("설정을 켜고 끄면 저장하고 USB 절의 막힘 판정에 바로 쓴다(기본 끔)")
    func libraryStoreToggle() async {
        let defaults = Self.defaults(on: nil)
        let store = LibraryStore(settings: SettingsStore(defaults: defaults, persist: true), resultHistory: WriteResultHistory(url: nil),
                                 saveTagDrafts: { _ in }, playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil,
                                 stagingSaver: { _ in })
        #expect(store.physicalUsbWrite == false)
        let (usb, _) = await setUp([physical], lists: FakePhysicalLists(), switchOn: false)
        store.usb = usb
        store.physicalUsbWrite = true
        #expect(usb.physicalWriteEnabled)
        #expect(defaults.bool(forKey: SettingKeys.labPhysicalUsbWrite.name))
        store.physicalUsbWrite = false
        #expect(!usb.physicalWriteEnabled)
    }

    @Test("편집 막힘 미리 판정: 스위치를 켜고 허용한 USB는 흐름 편집을 받고, 흐름 밖 규칙(곡 정보 갱신)은 막는다")
    func editBlockReasonWithOpenGate() {
        let library = UsbEditTestData.mixedLibrary()
        let gate = FakeUsbVolume.gate(allow: [FakeUsbVolume.physicalUUID], physicalEnabled: true)
        func reason(_ edit: UsbLibraryEdit) -> String? {
            UsbEditActions.blockReason(edit, volume: physical, library: library, info: nil, isScratchMount: { _ in false }, physicalGate: gate)
        }
        #expect(reason(.addTracks(localContentIDs: ["11"], playlist: nil)) == nil)
        #expect(reason(.removeTracks(usbContentIDs: [1])) == nil)
        #expect(reason(.playlist(edit: .rename(playlist: .id("4"), name: "새 이름"))) == nil)
        #expect(reason(.refreshTracks(usbContentIDs: [1], parts: [.cues])) == "확인하지 않은 규칙(USB 안 곡 정보 갱신)이 필요해 이 USB에 쓸 수 없습니다")
        // 허용하지 않은 USB
        let unallowed = UsbEditActions.blockReason(.removeTracks(usbContentIDs: [1]), volume: physical, library: library, info: nil,
                                                   isScratchMount: { _ in false }, physicalGate: FakeUsbVolume.gate(physicalEnabled: true))
        #expect(unallowed?.contains("‘이 USB에 쓰기 허용…’") == true)
    }

    static func defaults(on: Bool?) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "djc.test.physical.\(UUID())")!
        if let on { defaults.set(on, forKey: SettingKeys.labPhysicalUsbWrite.name) }
        return defaults
    }
}
