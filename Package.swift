// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "community",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "mm", targets: ["Community"])
    ],
    dependencies: [
        .package(path: "../swift-actor-runtime"),
        .package(path: "../swift-discovery"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
        // gRPC dependencies
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.2.1"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.1.2"),
    ],
    targets: [
        .executableTarget(
            name: "Community",
            dependencies: [
                .product(name: "ActorRuntime", package: "swift-actor-runtime"),
                .product(name: "Discovery", package: "swift-discovery"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                // gRPC dependencies
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            plugins: [
                .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")
            ]
        ),
        .testTarget(
            name: "CommunityTests",
            dependencies: [
                "Community",
                .product(name: "Discovery", package: "swift-discovery"),
                .product(name: "ActorRuntime", package: "swift-actor-runtime"),
            ]
        )
    ]
)
