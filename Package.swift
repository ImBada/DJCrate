// swift-tools-version: 6.2
import PackageDescription

// 의존 방향(위가 아래를 모른다):
//   AnicueApp·anicue(CLI) → AnicueStorage → RekordboxKit → AnicueDomain
//                         → AnicueAnalysis ──────────────→ AnicueDomain
let package = Package(
    name: "anicue",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AnicueDomain", targets: ["AnicueDomain"]),
        .library(name: "RekordboxKit", targets: ["RekordboxKit"]),
        .library(name: "AnicueStorage", targets: ["AnicueStorage"]),
        .library(name: "AnicueAnalysis", targets: ["AnicueAnalysis"]),
        .executable(name: "anicue", targets: ["anicue"]),
        .executable(name: "AnicueApp", targets: ["AnicueApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift", exact: "4.19.0"),
    ],
    targets: [
        // 순수 규칙·모델(입출력 없음)
        .target(name: "AnicueDomain"),
        // rekordbox 형식: SQLCipher DB·ANLZ·XML 읽기/쓰기, 스냅샷, 백업
        .target(
            name: "RekordboxKit",
            dependencies: ["AnicueDomain", .product(name: "SQLCipher", package: "SQLCipher.swift")]
        ),
        // anicue 자신의 파일: 초안·추가한 곡·반영 묶음
        .target(name: "AnicueStorage", dependencies: ["AnicueDomain", "RekordboxKit"]),
        // 소리 분석: 파형·그리드 추정·조성·음량·섹션
        .target(name: "AnicueAnalysis", dependencies: ["AnicueDomain"]),
        .executableTarget(
            name: "anicue",
            dependencies: ["AnicueDomain", "RekordboxKit", "AnicueStorage", "AnicueAnalysis"]
        ),
        .executableTarget(
            name: "AnicueApp",
            dependencies: ["AnicueDomain", "RekordboxKit", "AnicueStorage", "AnicueAnalysis"]
        ),
        // 테스트 재료: 구조만 있는 rekordbox DB, 합성 분석 파일·음원(실데이터 없음)
        .target(
            name: "AnicueTestSupport",
            dependencies: ["AnicueDomain", "RekordboxKit", .product(name: "SQLCipher", package: "SQLCipher.swift")],
            path: "Tests/Support",
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "AnicueDomainTests", dependencies: ["AnicueDomain"]),
        .testTarget(name: "RekordboxKitTests", dependencies: ["RekordboxKit", "AnicueDomain", "AnicueTestSupport"]),
        .testTarget(name: "AnicueAnalysisTests", dependencies: ["AnicueAnalysis", "AnicueDomain", "AnicueTestSupport"]),
        // 앱 화면 모델(덱·목록·반영 흐름)을 가짜 오디오·저장소로 시험한다.
        .testTarget(name: "AnicueAppTests", dependencies: ["AnicueApp", "AnicueDomain", "AnicueTestSupport"]),
    ]
)
