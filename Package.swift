// swift-tools-version:6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// MARK: - Examples
//
// Compiled with the package so that the code in docs/ cannot drift:
// scripts/weave.swift copies the snippet regions of Examples/Snippets
// into docs/*.md. None of these targets is a product.

let snippetTargets = ["QuickStart", "Server", "Client", "Protocol", "Guides"]

let examples: [Target] =
    snippetTargets.map { name in
        .target(
            name: "\(name)Snippets",
            dependencies: ["MCP", .product(name: "Logging", package: "swift-log")],
            path: "Examples/Snippets/\(name)")
    } + [
        .testTarget(
            name: "SnippetTests",
            dependencies: ["MCP"] + snippetTargets.map { .target(name: "\($0)Snippets") },
            path: "Examples/Tests"
        ),
        .executableTarget(
            name: "HelloServer",
            dependencies: ["MCP"],
            path: "Examples/hello-server"
        ),
        .executableTarget(
            name: "HelloClient",
            dependencies: ["MCP", .product(name: "SystemPackage", package: "swift-system")],
            path: "Examples/hello-client"
        ),
        .executableTarget(
            name: "HTTPServerExample",
            dependencies: [
                "MCP",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Examples/http-server"
        ),
    ]

let package = Package(
    name: "mcp-swift-sdk",
    platforms: [
        .macOS("13.0"),
        .macCatalyst("16.0"),
        .iOS("16.0"),
        .watchOS("9.0"),
        .tvOS("16.0"),
        .visionOS("1.0"),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "MCP",
            targets: ["MCP"]),
        .executable(
            name: "mcp-everything-server",
            targets: ["MCPConformanceServer"]),
        .executable(
            name: "mcp-everything-client",
            targets: ["MCPConformanceClient"]),
        .executable(
            name: "mcp-interop-client",
            targets: ["MCPInteropClient"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.6"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/mattt/eventsource.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "MCP",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(
                    name: "EventSource", package: "eventsource",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .visionOS, .watchOS, .macCatalyst])),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MCPTests",
            dependencies: [
                "MCP",
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(
                    name: "EventSource", package: "eventsource",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .visionOS, .watchOS, .macCatalyst])),
            ]
        ),
        .executableTarget(
            name: "MCPConformanceServer",
            dependencies: [
                "MCP",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "conformance/everything-server"
        ),
        .executableTarget(
            name: "MCPConformanceClient",
            dependencies: [
                "MCP",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "conformance/everything-client"
        ),
        .executableTarget(
            name: "MCPInteropClient",
            dependencies: [
                "MCP",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "interop/swift-client"
        ),
    ] + examples
)
