// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DriftCorrect",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DCCore", targets: ["DCCore"]),
        .library(name: "DCApple", targets: ["DCApple"]),
        .executable(name: "dc", targets: ["dc"]),
        .executable(name: "DriftCorrectApp", targets: ["DriftCorrectApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // Platform-neutral core: file formats, exact CPU algorithms, pipelines.
        .target(
            name: "DCCore",
            dependencies: [.product(name: "Yams", package: "Yams")],
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        // Apple-only acceleration: Metal compute backend and VideoToolbox HEVC writer.
        .target(
            name: "DCApple",
            dependencies: ["DCCore"],
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .executableTarget(
            name: "dc",
            dependencies: [
                "DCCore", "DCApple",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "DriftCorrectApp",
            dependencies: ["DCCore", "DCApple"]
        ),
        .testTarget(
            name: "DCCoreTests",
            dependencies: ["DCCore"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "DCAppleTests",
            dependencies: ["DCCore", "DCApple"]
        ),
    ]
)
