// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Base dependencies needed on all platforms
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-system.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
]

// Target dependencies needed on all platforms
var targetDependencies: [Target.Dependency] = [
    .product(name: "SystemPackage", package: "swift-system"),
    .product(name: "Logging", package: "swift-log"),
]

// Add EventSource only on Apple platforms (non-Linux)
#if !os(Linux)
    dependencies.append(
        .package(url: "https://github.com/loopwork-ai/eventsource.git", from: "1.1.0"))
    targetDependencies.append(.product(name: "EventSource", package: "eventsource"))
#endif

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
            targets: ["MCP"])
    ],
    dependencies: dependencies,
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "MCP",
            dependencies: targetDependencies),
        .testTarget(
            name: "MCPTests",
            dependencies: ["MCP"] + targetDependencies),
    ]
)
