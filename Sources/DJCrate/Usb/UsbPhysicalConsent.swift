import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 사이드바 볼륨 메뉴의 실물 쓰기 항목 상태(실물 볼륨만)
struct UsbPhysicalMenu: Equatable {
    /// 쓰기 금지 목록에 있음(허용·금지 메뉴를 모두 숨긴다)
    var isDenied: Bool
    /// 이 USB에 쓰기를 허용함
    var isAllowed: Bool
    /// 허용할 수 없는 까닭(rekordbox USB 모양·USB 메모리 조건). 허용할 수 있으면 nil
    var consentBlock: String?
    /// 설정 › 실험실 "실물 USB 쓰기"가 켜져 있음
    var switchOn: Bool
}

/// 쓰기 허용·금지 목록 파일을 고치는 창구. 모두 메인 액터 밖에서 부른다. 앱은 `system`, 시험은 가짜
struct UsbPhysicalListIO: Sendable {
    var allow: @Sendable (UsbVolumeInfo) throws -> Void
    var revoke: @Sendable (String) throws -> Void
    var deny: @Sendable (UsbVolumeInfo) throws -> Void

    /// 사이드바가 들고 있던 볼륨 정보는 앞선 훑기 때 것이라, 고치기 직전에 그 자리의 볼륨을 다시 본다(그 사이 다른 USB가 붙었으면 고치지 않는다)
    static let system = UsbPhysicalListIO(
        allow: { try UsbPhysicalLists.allow(try UsbRead.currentVolume(matching: $0)) },
        revoke: { try UsbPhysicalLists.revoke(uuid: $0) },
        deny: { try UsbPhysicalLists.deny(try UsbRead.currentVolume(matching: $0)) })
}

/// 실물 USB 쓰기 허용(사용자 동의)·허용 거두기·쓰기 금지 목록에 넣기. 목록 파일만 고치고 USB에는 쓰지 않는다.
/// 고친 뒤에는 USB를 다시 훑어 사이드바·막힘 판정이 새 목록을 쓰게 한다
@MainActor
struct UsbPhysicalConsent {
    let usb: UsbStore
    let host: any UsbWriteHost
    var prompter: any ReflectionPrompter = AlertPrompter()
    var io: UsbPhysicalListIO = .system

    /// 이 USB에 쓰기를 허용할지 묻고, 누르면 허용 목록에 더한다
    func allow(_ volumeKey: String) async {
        guard let volume = usb.volume(volumeKey), let menu = usb.physicalMenu(volumeKey), !menu.isDenied else { return }
        if let reason = menu.consentBlock {
            _ = prompter.show(ReflectionPrompt(title: String(ui: "이 USB에는 쓰기를 허용할 수 없습니다"), text: reason))
            return
        }
        guard prompter.show(Self.allowPrompt(volume, switchOn: menu.switchOn)) else { return }
        guard await run(String(ui: "쓰기를 허용하지 않았습니다"), { [io] in try io.allow(volume) }) else { return }
        if usb.physicalMenu(volumeKey)?.isAllowed == true {
            host.toast = AppToast(kind: .success, title: String(ui: "이 USB에 쓰기를 허용했습니다"), detail: volume.name, isUsb: true)
        }
    }

    /// 쓰기 허용을 거둔다(묻지 않는다 — 쓰지 않게 되는 쪽이라)
    func revoke(_ volumeKey: String) async {
        guard let volume = usb.volume(volumeKey), let uuid = volume.volumeUUID else { return }
        guard await run(String(ui: "쓰기 허용을 거두지 못했습니다"), { [io] in try io.revoke(uuid) }) else { return }
        host.toast = AppToast(kind: .success, title: String(ui: "이 USB의 쓰기 허용을 거뒀습니다"), detail: volume.name, isUsb: true)
    }

    /// 쓰기 금지 목록에 넣을지 묻고, 누르면 넣는다(빼는 메뉴는 없다)
    func deny(_ volumeKey: String) async {
        guard let volume = usb.volume(volumeKey) else { return }
        guard prompter.show(Self.denyPrompt(volume)) else { return }
        guard await run(String(ui: "쓰기 금지 목록에 넣지 못했습니다"), { [io] in try io.deny(volume) }) else { return }
        host.toast = AppToast(kind: .success, title: String(ui: "쓰기 금지 목록에 넣었습니다"), detail: volume.name, isUsb: true)
    }

    /// 목록 파일 고치기(메인 액터 밖) → 실패는 알림 → 다시 훑기. 고쳤으면 true
    private func run(_ failure: String, _ body: @escaping @Sendable () throws -> Void) async -> Bool {
        let result = await Task.detached(priority: .userInitiated) { Result { try body() } }.value
        if case let .failure(error) = result {
            let text: String
            if case let UsbError.writeRefused(blocks)? = error as? UsbError, let first = blocks.first {
                text = first.message
            } else if case UsbError.readFailed(detail: "volumeChanged")? = error as? UsbError {
                text = String(ui: "그 사이 다른 USB가 연결됐습니다. USB를 다시 읽은 뒤 고르세요")
            } else {
                text = AppErrorMessage.message(for: error)
            }
            _ = prompter.show(ReflectionPrompt(title: failure, text: text, critical: true))
            await usb.refresh()
            return false
        }
        await usb.refresh()
        return true
    }

    static func allowPrompt(_ volume: UsbVolumeInfo, switchOn: Bool) -> ReflectionPrompt {
        var details = [String(ui: "USB를 다시 포맷하면 다시 허용해야 합니다")]
        if !switchOn { details.insert(String(ui: "쓰려면 설정 › 실험실의 ‘실물 USB 쓰기’도 켜야 합니다"), at: 0) }
        return ReflectionPrompt(title: String(ui: "‘\(volume.name)’에 쓰기를 허용할까요?"),
                                text: String(ui: "DJCrate가 이 USB의 rekordbox 라이브러리를 만들고 고칠 수 있게 됩니다. 쓰기마다 바꿀 파일을 Mac에 백업하고, 쓴 뒤 USB에서 다시 읽어 확인합니다. 실물 USB 쓰기는 아직 실험 기능입니다."),
                                confirm: String(ui: "쓰기 허용"), details: details)
    }

    static func denyPrompt(_ volume: UsbVolumeInfo) -> ReflectionPrompt {
        ReflectionPrompt(title: String(ui: "‘\(volume.name)’을 쓰기 금지 목록에 넣을까요?"),
                         text: String(ui: "DJCrate가 이 USB에 다시는 쓰지 않고 읽지도 않습니다. 목록에서 빼려면 DJCrate 데이터 폴더의 usb-physical-deny.json을 직접 고쳐야 합니다."),
                         confirm: String(ui: "쓰기 금지 목록에 넣기"), destructive: true)
    }
}

extension LibraryStore {
    /// 실물 USB 쓰기 허용·금지(사이드바 USB 절이 붙은 뒤에만)
    var usbConsent: UsbPhysicalConsent? {
        usb.map { UsbPhysicalConsent(usb: $0, host: self) }
    }
}
