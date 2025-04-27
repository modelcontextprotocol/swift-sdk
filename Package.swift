// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "mcp-swift-sdk",
    platforms: [
        .macOS(.v14),
        .macCatalyst(.v17),
        .iOS(.v17),
        .watchOS(.v10),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "MCP",
            targets: ["MCP", "SchemaMCP"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-system.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/ajevans99/swift-json-schema", from: "0.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "MCP",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/MCP"
        ),
        .testTarget(
            name: "MCPTests",
            dependencies: [
                "MCP",
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/MCPTests"
        ),
        .target(
            name: "SchemaMCP",
            dependencies: [
                "MCP",
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
            ],
            path: "SchemaMCP/Sources"
        ),
        .testTarget(
            name: "SchemaMCPTests",
            dependencies: [
                "MCP",
                "SchemaMCP",
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
            ],
            path: "SchemaMCP/Tests"
        ),
    ]
)
