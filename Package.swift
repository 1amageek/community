// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "community",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "mm", targets: ["CommunityCLI"]),
        .library(name: "CommunityCore", targets: ["CommunityCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-peer", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "CommunityCore",
            dependencies: [
                .product(name: "PeerNode", package: "swift-peer"),
            ]
        ),
        .executableTarget(
            name: "CommunityCLI",
            dependencies: [
                "CommunityCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "CommunityTests",
            dependencies: [
                "CommunityCore",
                .product(name: "PeerNode", package: "swift-peer"),
            ]
        )
    ]
)
