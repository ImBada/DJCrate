// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "anicue",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AnicueCore", targets: ["AnicueCore"]),
        .executable(name: "anicue", targets: ["anicue"]),
        .executable(name: "AnicueApp", targets: ["AnicueApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift", exact: "4.19.0"),
    ],
    targets: [
        .target(
            name: "AnicueCore",
            dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")]
        ),
        .executableTarget(
            name: "anicue",
            dependencies: ["AnicueCore"]
        ),
        .executableTarget(
            name: "AnicueApp",
            dependencies: ["AnicueCore"]
        ),
        .testTarget(
            name: "AnicueCoreTests",
            dependencies: ["AnicueCore"]
        ),
    ]
)
