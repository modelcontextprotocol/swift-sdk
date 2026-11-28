// swift-tools-version:5.4

// Fuzz targets for the SDK's parsers, built with libFuzzer. Linux only: the
// Xcode toolchain has no libFuzzer. Run them with scripts/ci/fuzz.sh, which
// passes the sanitizer flags to every module so that MCP is instrumented too.
//
// Tools version 5.4 on purpose: from 5.5 on, SwiftPM renames the entry point of
// executables, and the libFuzzer runtime brings its own `main`.

import PackageDescription

let mcp: Target.Dependency = .product(name: "MCP", package: "mcp-swift-sdk")

let package = Package(
    name: "mcp-fuzz",
    platforms: [.macOS("15.0")],
    // The name keeps the identity independent of the checkout directory.
    dependencies: [.package(name: "mcp-swift-sdk", path: "..")],
    targets: [
        .executableTarget(name: "FuzzDecode", dependencies: [mcp]),
        .executableTarget(name: "FuzzSSE", dependencies: [mcp]),
        .executableTarget(name: "FuzzStatelessHTTP", dependencies: [mcp]),
        .executableTarget(name: "FuzzStatefulHTTP", dependencies: [mcp]),
        .executableTarget(name: "FuzzFrontmatter", dependencies: [mcp]),
    ]
)
