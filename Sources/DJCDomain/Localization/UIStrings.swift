import Foundation
import Synchronization

/// 사용자에게 보이는 문구를 찾을 String Catalog 번들.
/// 앱은 시작할 때 자기 카탈로그(`Sources/DJCrate/Resources/Localizable.xcstrings`)로 정한다.
/// CLI·테스트는 정하지 않아 원문(한국어)이 그대로 나온다. 하위 모듈이 자기 번들을 두지 않는 까닭은
/// 번들이 없는 곳(PATH에 복사한 djc 등)에서 `Bundle.module`이 멈추기 때문이다.
public enum UIStrings {
    private static let storage = Mutex<Bundle>(.main)

    public static var bundle: Bundle {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

extension String {
    /// 카탈로그에서 찾은 문구. 원문(키)은 한국어이고, 번역이 없으면 원문이 그대로 나온다.
    /// 키는 컴파일러가 뽑아 `scripts/i18n.swift`가 카탈로그와 맞춘다(docs/i18n.md).
    public init(ui value: String.LocalizationValue) {
        self.init(localized: value, bundle: UIStrings.bundle)
    }
}

extension LocalizedStringResource {
    /// SwiftUI 제목 인자(Text·Button·Label·Toggle·help·accessibilityLabel…)에 넣는 문구.
    public static func ui(_ value: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(value, bundle: UIStrings.bundle)
    }
}
