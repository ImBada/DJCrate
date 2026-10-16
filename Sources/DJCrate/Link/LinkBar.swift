import DJCApplication
import DJCDomain
import SwiftUI
import UniformTypeIdentifiers

/// 창 아래 LINK 막대(#272). 네트워크에 Pro DJ Link 장치가 보이면 왼쪽에 LINK 단추가 뜨고, 누르면 오른쪽에 장치를 늘어놓는다.
/// 연결을 켜면 DJCrate 라이브러리를 CDJ에 내어 주고(#273), 곡 목록의 곡을 플레이어 칸에 놓으면 그 플레이어에 싣는다(#274).
/// 장치가 없으면 아무것도 그리지 않아 창 높이를 차지하지 않는다. 이 막대만 모델을 읽어 장치가 바뀌어도 본문을 다시 계산하지 않는다.
struct LinkBar: View {
    let model: LinkBarModel

    var body: some View {
        if model.isVisible {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 10) {
                    LinkToggle(isOn: model.isExpanded, blockReason: model.blockReason, toggle: { model.toggle() })
                    if model.isExpanded, model.blockReason == nil {
                        LinkConnectButton(connection: model.connection, text: model.connectionText,
                                          toggle: { model.toggleConnection() })
                    }
                    if model.showsDevices {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(model.devices) { device in
                                    LinkDeviceTile(device: device, isMounted: model.isMounted(device),
                                                   onDrop: model.acceptsDrop(device) ? { @MainActor contentID in model.drop(contentID: contentID, on: device) } : nil)
                                }
                            }
                        }
                        .scrollIndicators(.never)
                    } else if model.isExpanded, let reason = model.blockReason {
                        Text(verbatim: reason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(height: 48)
            }
            .background(.bar)
        }
    }
}

/// LINK 단추. 쓸 수 없으면(rekordbox 켜짐) 흐리게 두고, 누르면 장치 대신 이유를 보인다.
private struct LinkToggle: View {
    let isOn: Bool
    let blockReason: String?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 1) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 13, weight: .semibold))
                Text(.ui("LINK"))
                    .font(.system(size: 10, weight: .bold))
            }
            .frame(width: 44, height: 34)
            .foregroundStyle(isOn && blockReason == nil ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 6).fill(isOn && blockReason == nil ? Color.accentColor : Color.secondary.opacity(0.15)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .opacity(blockReason == nil ? 1 : 0.5)
        .help(blockReason ?? String(ui: "네트워크의 Pro DJ Link 장치를 보입니다"))
        .accessibilityLabel(Text(.ui("LINK")))
        .accessibilityValue(blockReason ?? (isOn ? String(ui: "펼침") : String(ui: "접힘")))
    }
}

/// 연결 단추: 켜면 DJCrate 라이브러리를 CDJ에 내어 준다(네트워크에 참여한다)
private struct LinkConnectButton: View {
    let connection: LinkBarModel.Connection
    let text: String?
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { connection != .off }, set: { _ in toggle() })) {
                Text(.ui("라이브러리 내어 주기"))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(connection == .connecting)
            .help(String(ui: "켜면 CDJ의 LINK 화면에서 DJCrate 라이브러리를 고르고, 곡을 플레이어 칸에 놓아 실을 수 있습니다"))
            if let text {
                Text(verbatim: text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .fixedSize()
    }
}

/// 장치 하나. 덱이 있는 장치(플레이어)는 번호를 크게 보이고, 연결을 켰으면 곡을 놓을 자리가 된다(#274).
struct LinkDeviceTile: View {
    let device: LinkDevice
    /// DJCrate 라이브러리를 마운트했는지(곡을 실을 수 있는지)
    var isMounted = false
    /// 곡을 놓았을 때(rekordbox 곡 ID). nil이면 놓을 수 없다
    var onDrop: (@MainActor @Sendable (String) -> Void)?
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(device.kind))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            if device.hasDeck {
                Text(device.number, format: .number)
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
            }
            Text(verbatim: device.name)
                .font(.system(size: 12))
                .lineLimit(1)
            if isMounted {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .help(String(ui: "DJCrate 라이브러리를 열었습니다"))
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: device.hasDeck ? 150 : 110, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(isTargeted ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                                                                lineWidth: isTargeted ? 2 : 1))
        .help(Text(verbatim: "\(device.name) · \(device.number) · \(device.address)"))
        .accessibilityElement(children: .combine)
        .onDrop(of: onDrop == nil ? [] : [DeckDragType.track], isTargeted: $isTargeted) { providers in
            guard let onDrop else { return false }
            return LinkTrackDrop.read(providers, then: onDrop)
        }
    }

    static func symbol(_ kind: LinkDevice.Kind) -> String {
        switch kind {
        case .player: "opticaldiscdrive"
        case .mixer: "slider.vertical.3"
        case .rekordbox: "laptopcomputer"
        case .other: "questionmark.circle"
        }
    }
}
