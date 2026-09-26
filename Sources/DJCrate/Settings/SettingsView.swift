import AppKit
import DJCDomain
import SwiftUI

/// 설정 창(⌘,). 값은 덱 모델에 바로 묶여 덱 화면과 함께 바뀌고, 바꾸면 곧바로 저장된다.
/// 새 설정 묶음은 `SettingsTab`과 아래 `TabView`에 함께 더한다.
struct SettingsView: View {
    @Bindable var deck: DeckModel
    @State private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("일반", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsView(deck: deck)
            }
            Tab("덱", systemImage: "dial.medium", value: SettingsTab.deck) {
                DeckSettingsView(deck: deck)
            }
            Tab("단축키", systemImage: "keyboard", value: SettingsTab.shortcuts) {
                ShortcutSettingsView(deck: deck)
            }
            Tab("파형", systemImage: "waveform", value: SettingsTab.waveform) {
                Form {
                    Picker("색 모드", selection: $deck.waveformColorMode) {
                        ForEach(WaveformColorMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("덱의 확대·전체 파형과 곡 목록 미리 보기에 함께 적용합니다.")
                        .foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
                .frame(width: 520, height: 180)
            }
        }
        .background(SettingsWindow.Tracker())
    }
}

enum SettingsTab: Hashable {
    case general, deck, shortcuts, waveform
}

/// 지금 열린 설정 창. 설정 창도 주 창이 될 수 있어서, KeyRouter가 이 창의 키(단축키 기록 등)를 덱으로 보내지 않게 한다.
@MainActor
enum SettingsWindow {
    static weak var current: NSWindow?

    struct Tracker: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { TrackingView() }
        func updateNSView(_ nsView: NSView, context: Context) {}

        private final class TrackingView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let window { SettingsWindow.current = window }
            }
        }
    }
}

// MARK: - 일반

struct GeneralSettingsView: View {
    @Bindable var deck: DeckModel

    var body: some View {
        Form {
            Section {
                Picker("재생을 멈춘 뒤 오디오 엔진 끄기", selection: $deck.idleSeconds) {
                    ForEach(SettingKeys.idleSecondsChoices, id: \.self) { seconds in
                        Text(Self.durationText(seconds)).tag(seconds)
                    }
                }
            } header: {
                Text("오디오")
            } footer: {
                Text("짧을수록 쉬는 동안 CPU를 덜 쓰고, 길수록 멈춘 뒤 CUE·재생이 바로 소리 납니다.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // 묶음 폼은 스크롤 뷰라 내용 높이를 스스로 알리지 않는다. 설정 창 높이를 탭마다 정한다.
        .frame(width: 520, height: 180)
    }

    static func durationText(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds))초" : "\(Int(seconds / 60))분"
    }
}

// MARK: - 덱

struct DeckSettingsView: View {
    @Bindable var deck: DeckModel

    var body: some View {
        Form {
            Section("재생") {
                Toggle("키 고정(템포를 바꿔도 음정 유지)", isOn: $deck.keyLock)
                LabeledContent("메트로놈 소리 크기") {
                    HStack {
                        Slider(value: $deck.metronomeVolume, in: 0...1)
                            .frame(width: 180)
                        Text("\(Int((deck.metronomeVolume * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            Section("편집") {
                Toggle("퀀타이즈(큐·루프를 비트 그리드의 박에 맞춤)", isOn: $deck.quantize)
                Toggle("그리드를 고칠 때 큐도 함께 옮기기(핫큐·메모리 큐·루프)", isOn: $deck.carryCues)
                Toggle("메모리 큐 제안 보이기(섹션 경계)", isOn: $deck.showSuggestions)
            }
            Section("게인") {
                Toggle("오토게인(곡마다 목표 음량에 맞춤)", isOn: $deck.autoGain)
                Toggle("rekordbox 값 사용", isOn: $deck.useRekordboxGain)
                    .disabled(!deck.autoGain)
                Picker("목표 음량", selection: $deck.gainTarget) {
                    ForEach(SettingKeys.gainTargetChoices, id: \.self) { Text(String(format: "%.0f LUFS", $0)).tag($0) }
                }
                .disabled(!deck.autoGain)
                Toggle("피크 보호(0dBFS를 넘지 않을 만큼만 올림)", isOn: $deck.peakProtection)
                    .disabled(!deck.autoGain)
            }
            Section {
                HStack {
                    Spacer()
                    Button("기본값으로 되돌리기") { deck.resetDeckSettings() }
                }
            } footer: {
                Text("덱에서 바로 만지는 볼륨·확대·트림은 그대로 둡니다.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
    }
}
