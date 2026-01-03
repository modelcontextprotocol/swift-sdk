// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HummingbirdMCPExample",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(path: "../.."),  // MCP Swift SDK
    ],
    targets: [
        .executableTarget(
            name: "HummingbirdMCPExample",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "MCP", package: "mcp-swift-sdk"),
            ],
            path: "Sources"
        )
    ]
)
