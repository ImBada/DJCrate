import Foundation


/// 앱 업데이트(#59)를 설치할 때 앱이 쓰는 중인 것. 앱이 이미 아는 쓰기 잠금 상태에서 만든다.
public struct AppWriteActivity: Equatable, Sendable {
    /// rekordbox 쓰기·복원·iTunes 동기화(쓰기 잠금)
    public var writingRekordbox: Bool
    /// USB 쓰기·되돌리기·회복(진행 중이거나 볼륨을 붙잡은 작업)
    public var writingUsb: Bool

    public init(writingRekordbox: Bool, writingUsb: Bool) {
        self.writingRekordbox = writingRekordbox
        self.writingUsb = writingUsb
    }

    public static let idle = AppWriteActivity(writingRekordbox: false, writingUsb: false)
}

/// 업데이트를 설치하고 앱을 다시 켜도 되는지. 쓰는 중에 앱이 꺼지면 라이브러리나 USB가 반쯤 쓴 채로 남는다.
public enum UpdateInstallDecision: Equatable, Sendable {
    case proceed
    case waitForRekordbox
    case waitForUsb

    /// 미룰 때 사용자에게 알리는 한 줄
    public var waitMessage: String? {
        switch self {
        case .proceed: nil
        case .waitForRekordbox: String(ui: "rekordbox에 쓰는 중이라 업데이트 설치를 미룹니다. 쓰기가 끝나면 이어서 설치합니다")
        case .waitForUsb: String(ui: "USB에 쓰는 중이라 업데이트 설치를 미룹니다. 쓰기가 끝나면 이어서 설치합니다")
        }
    }
}

public enum UpdateInstallPolicy {
    public static func decision(for activity: AppWriteActivity) -> UpdateInstallDecision {
        if activity.writingRekordbox { return .waitForRekordbox }
        if activity.writingUsb { return .waitForUsb }
        return .proceed
    }
}
