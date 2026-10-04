import Foundation

/// 파형·분석(섹션·그리드 추정·크로마)·음량 캐시의 위치. 뿌리 하나(`DJCIdentity.dataDirectory`)에서만 파생한다.
/// `DJC_HOME`이 없을 때의 이름·배치는 설치한 앱이 쓰던 그대로다(바꾸면 쌓아 둔 캐시를 잃는다).
public struct DJCCachePaths: Sendable, Equatable {
    public var root: URL

    public init(root: URL) { self.root = root }

    /// 이 프로세스의 캐시 위치(`DJC_HOME`이 있으면 그 아래)
    public static var current: DJCCachePaths { DJCCachePaths(root: DJCIdentity.dataDirectory) }

    public var waveforms: URL { root.appending(path: "waveforms") }
    /// 섹션 분석 JSON과 하위 `grid-estimates/`·`chroma/`
    public var analysis: URL { root.appending(path: "analysis") }
    public var loudness: URL { root.appending(path: "loudness.json") }
}
