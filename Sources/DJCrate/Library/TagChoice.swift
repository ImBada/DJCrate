import AppKit
import DJCDomain
import SwiftUI

/// 글자 대신 고르기로 고치는 태그 칸(키·평점·곡 색)의 규칙: 고를 수 있는 값, 보일 글자, 붙여넣기에서 받는 값, 고칠 수 있는 곡.
/// 곡 목록·태그 시트·인스펙터가 함께 쓴다. 키의 고르기 규칙은 `KeyPicker`, 평점·곡 색은 #65.
enum TagChoice {
    static let keys: Set<TagFields.Key> = [.musicalKey, .rating, .color]

    struct Option: Equatable {
        /// 초안에 넣을 값(빈칸 = 없음)
        let value: String
        let title: String
        /// 고를 수 없는 현재 값(옛 표기 키 등)은 보이기만 한다
        var enabled = true
    }

    /// 고르기 목록: 맨 앞은 없음. 키는 Camelot 24개(옛 표기 현재값은 맨 앞에 고를 수 없게), 평점은 별 1~5개, 곡 색은 rekordbox 색 순서.
    static func options(_ key: TagFields.Key, current: String, colors: [TrackColor]) -> [Option] {
        var options: [Option] = []
        switch key {
        case .musicalKey:
            if !current.isEmpty, !KeyNotation.camelotNames.contains(current) { options.append(Option(value: current, title: current, enabled: false)) }
            options.append(Option(value: "", title: String(ui: "없음")))
            options += KeyNotation.camelotNames.map { Option(value: $0, title: $0) }
        case .rating:
            options.append(Option(value: "", title: String(ui: "없음")))
            options += TrackRating.choices.map { Option(value: $0, title: TrackRating.stars($0)) }
        case .color:
            // 읽은 값이 rekordbox 여덟 색 밖이면(모르는 번호) 맨 앞에 고를 수 없게 보인다
            if !current.isEmpty, !TrackColor.ids.contains(current) {
                options.append(Option(value: current, title: TrackColor.name(of: current, in: colors), enabled: false))
            }
            options.append(Option(value: "", title: String(ui: "없음")))
            options += colors.filter { TrackColor.ids.contains($0.id) }.map { Option(value: $0.id, title: $0.name) }
        default: break
        }
        return options
    }

    /// 칸·시트에 보일 글자(평점은 별, 곡 색은 이름). 다른 칸은 값 그대로다.
    static func display(_ key: TagFields.Key, _ value: String, colors: [TrackColor]) -> String {
        switch key {
        case .rating: TrackRating.stars(value)
        case .color: TrackColor.name(of: value, in: colors)
        default: value
        }
    }

    /// VoiceOver가 읽을 글자(별 대신 "별 3개")
    static func spoken(_ key: TagFields.Key, _ value: String, colors: [TrackColor]) -> String {
        guard key == .rating else { return display(key, value, colors: colors) }
        return Int(value).map { String(ui: "별 \($0)개") } ?? String(ui: "없음")
    }

    /// 시트 붙여넣기·채우기에서 받는 값(키: Camelot 이름, 평점: "3"·"★★★", 곡 색: 번호·색 이름). 받지 못하면 nil(그 칸은 건너뛴다).
    static func accepted(_ key: TagFields.Key, _ text: String, colors: [TrackColor]) -> String? {
        switch key {
        case .musicalKey: KeyPicker.accepted(text)
        case .rating: TrackRating.accepted(text)
        case .color: TrackColor.accepted(text, in: colors)
        default: text
        }
    }

    /// 건너뛴 칸 안내(시트 붙여넣기·채우기)
    static func skippedMessage(_ key: TagFields.Key, count: Int) -> String {
        switch key {
        case .rating: String(ui: "평점 칸 \(count)칸은 별 1~5개가 아니어서 건너뜀")
        case .color: String(ui: "곡 색 칸 \(count)칸은 rekordbox 색이 아니어서 건너뜀")
        default: String(ui: "키 칸 \(count)칸은 1A~12B가 아니어서 건너뜀")
        }
    }

    /// 고르기에서 고른 값을 초안에 넣을 곡: 그 칸을 고칠 수 없는 곡(USB·스트리밍, 평점·곡 색은 추가한 곡·확인 밖 곡)은 뺀다.
    static func targets(_ key: TagFields.Key, _ rows: [TrackRow]) -> [TrackRow] {
        rows.filter { TrackListTagEditing.unavailableReason($0, key: key) == nil }
    }

    // MARK: 곡 색 표시

    /// rekordbox 곡 색의 화면 색(색 번호별). rekordbox XML 형식 문서의 곡 색(`Colour`) 값과 같은 순서(Pink·Red·Orange·Yellow·Green·Aqua·Blue·Purple)다.
    static func swatch(_ id: String) -> NSColor? {
        let rgb: [String: Int] = ["1": 0xFF007F, "2": 0xFF0000, "3": 0xFFA500, "4": 0xFFFF00, "5": 0x00FF00, "6": 0x25FDE9, "7": 0x0000FF, "8": 0x660099]
        return rgb[id].map { NSColor(srgbRed: CGFloat($0 >> 16 & 0xFF) / 255, green: CGFloat($0 >> 8 & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1) }
    }

    @MainActor private static var swatchImages: [String: NSImage] = [:]

    /// 메뉴·고르기에 넣는 색 점(템플릿이 아니라 색이 그대로 보인다). 테두리를 그어 밝은 색(Yellow)도 흰 바탕에서 보이게 한다.
    @MainActor static func swatchImage(_ id: String, size: CGFloat = 10) -> NSImage? {
        let key = "\(id)|\(size)"
        if let image = swatchImages[key] { return image }
        guard let color = swatch(id) else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            color.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        image.isTemplate = false
        swatchImages[key] = image
        return image
    }

    /// 고르기 메뉴. 지금 값에 체크하고(여러 값이면 아무 항목에도), 고를 수 없는 현재 값은 맨 앞에 흐리게 보인다.
    /// - Parameter represented: 항목마다 `representedObject`로 둘 값(고른 값을 받는다)
    @MainActor static func menu(_ key: TagFields.Key, current: (value: String, mixed: Bool), colors: [TrackColor], targetCount: Int,
                                action: Selector, target: AnyObject, represented: (String) -> Any) -> NSMenu {
        let menu = NSMenu(title: key.label)
        menu.autoenablesItems = false
        for option in options(key, current: current.mixed ? "" : current.value, colors: colors) {
            let item = NSMenuItem(title: option.title, action: option.enabled ? action : nil, keyEquivalent: "")
            item.target = target
            item.isEnabled = option.enabled
            if key == .color { item.image = swatchImage(option.value) }
            if key == .rating { item.setAccessibilityLabel(spoken(key, option.value, colors: colors)) }
            if targetCount > 1 { item.toolTip = String(ui: "고른 \(targetCount)곡에 모두 적용합니다") }
            item.representedObject = represented(option.value)
            item.state = !current.mixed && current.value == option.value ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}
