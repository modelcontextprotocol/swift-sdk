// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VaporMCPExample",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.0.0"),
        .package(path: "../.."),  // MCP Swift SDK
    ],
    targets: [
        .executableTarget(
            name: "VaporMCPExample",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "MCP", package: "mcp-swift-sdk"),
            ],
            path: "Sources"
        )
    ]
)
