// swift-tools-version: 6.2
import PackageDescription

// 의존 방향(위가 아래를 모른다):
//   DJCrate(앱)·djc(CLI) → DJCStorage → RekordboxKit → DJCDomain
//                         → DJCAnalysis ──────────────→ DJCDomain
let package = Package(
    name: "DJCrate",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "DJCDomain", targets: ["DJCDomain"]),
        .library(name: "RekordboxKit", targets: ["RekordboxKit"]),
        .library(name: "DJCStorage", targets: ["DJCStorage"]),
        .library(name: "DJCAnalysis", targets: ["DJCAnalysis"]),
        .executable(name: "djc", targets: ["djc"]),
        .executable(name: "DJCrate", targets: ["DJCrate"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift", exact: "4.19.0"),
    ],
    targets: [
        // 순수 규칙·모델(입출력 없음)
        .target(name: "DJCDomain"),
        // rekordbox 형식: SQLCipher DB·ANLZ·XML 읽기/쓰기, 스냅샷, 백업
        .target(
            name: "RekordboxKit",
            dependencies: ["DJCDomain", .product(name: "SQLCipher", package: "SQLCipher.swift")]
        ),
        // DJCrate 자신의 파일: 초안·추가한 곡·반영 묶음
        .target(name: "DJCStorage", dependencies: ["DJCDomain", "RekordboxKit"]),
        // 소리 분석: 파형·그리드 추정·조성·음량·섹션
        .target(name: "DJCAnalysis", dependencies: ["DJCDomain"]),
        // 명령줄 도구
        .executableTarget(
            name: "djc",
            dependencies: ["DJCDomain", "RekordboxKit", "DJCStorage", "DJCAnalysis"]
        ),
        // macOS 앱
        .executableTarget(
            name: "DJCrate",
            dependencies: ["DJCDomain", "RekordboxKit", "DJCStorage", "DJCAnalysis"]
        ),
        // 테스트 재료: 구조만 있는 rekordbox DB, 합성 분석 파일·음원(실데이터 없음)
        .target(
            name: "DJCTestSupport",
            dependencies: ["DJCDomain", "RekordboxKit", .product(name: "SQLCipher", package: "SQLCipher.swift")],
            path: "Tests/Support",
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "DJCDomainTests", dependencies: ["DJCDomain"]),
        .testTarget(name: "RekordboxKitTests", dependencies: ["RekordboxKit", "DJCDomain", "DJCTestSupport"]),
        .testTarget(name: "DJCAnalysisTests", dependencies: ["DJCAnalysis", "DJCDomain", "DJCTestSupport"]),
        // 앱 화면 모델(덱·목록·반영 흐름)을 가짜 오디오·저장소로 시험한다.
        .testTarget(name: "DJCrateTests", dependencies: ["DJCrate", "DJCDomain", "DJCStorage", "DJCTestSupport"]),
    ]
)
