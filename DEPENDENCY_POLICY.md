# Dependency policy

`MCP` is a library that lives in other packages' dependency graphs. Its requirements should
constrain their resolution as little as possible. Related: [VERSIONING.md](VERSIONING.md),
[CONTRIBUTING.md](CONTRIBUTING.md).

## Current dependencies

| Package | Product | Requirement | Used by | Purpose |
|---|---|---|---|---|
| [swift-system](https://github.com/apple/swift-system) | `SystemPackage` | `from: "1.0.0"` | `MCP`, `MCPTests`, `HelloClient` | file descriptors and `Errno` for `StdioTransport` and `MCPError`, where the platform has no `System` module |
| [swift-log](https://github.com/apple/swift-log) | `Logging` | `from: "1.5.0"` | `MCP`, tests, fixtures, examples | `Logger` on every transport, client and server |
| [eventsource](https://github.com/mattt/eventsource) | `EventSource` | `from: "1.1.0"` | `MCP` on Apple platforms only | SSE parsing in `HTTPClientTransport` |
| [swift-crypto](https://github.com/apple/swift-crypto) | `Crypto` | `"3.0.0"..<"5.0.0"` | `MCP` | AES-256-GCM, HKDF-SHA256 and SHA-256 for `requestState` sealing; SHA-256 for PKCE; P-256 for `private_key_jwt` and DPoP proofs |
| [swift-nio](https://github.com/apple/swift-nio) | `NIOCore`, `NIOPosix`, `NIOHTTP1` | `from: "2.65.0"` | `MCPConformanceServer`, `HTTPServerExample` only | HTTP server in the fixture and the example |
| [swift-docc-plugin](https://github.com/swiftlang/swift-docc-plugin) | plugin | `from: "1.4.0"` | none | `swift package generate-documentation` |

Notes:

- swift-nio and swift-docc-plugin are declared only in `Package.swift`. `Package@swift-6.0.swift`
  declares swift-system, swift-log, eventsource and swift-crypto.
- swift-docc-plugin 1.4.0 is the oldest release that works with current DocC: earlier ones pass
  `--index`, which `docc convert` no longer accepts.
- No target of the `MCP` library product depends on swift-nio. HTTP server transports take and
  return `HTTPRequest`/`HTTPResponse`, so applications choose their own HTTP server.
- swift-crypto was added in 0.13.0 for `requestState` sealing
  ([design/mrtr.md](design/mrtr.md)). Its range spans majors 3 and 4; the APIs used (`AES.GCM`,
  `HKDF`, `SHA256`, `SymmetricKey`, `P256.Signing`) exist in both. CI resolves 4.x. OAuth uses
  it for PKCE and `private_key_jwt`, so those work on Linux too.
- `Package.resolved` is committed. It records the versions CI builds with; it does not constrain
  consumers.
- Types from dependencies appear in the public API in two places: `Logger` (swift-log) on every
  transport, and `FileDescriptor` (`System` on Apple platforms, `SystemPackage` elsewhere) in
  `StdioTransport.init(input:output:logger:)`. A major version of either is therefore a breaking
  change for the SDK.

## Criteria for a new dependency

A new dependency of the `MCP` target needs an issue that is approved before the pull request.
The issue answers:

1. What the SDK cannot do without it, and why Foundation, the Swift standard library or an
   existing dependency is not enough.
2. Who maintains it, its release history, and its license (compatible with Apache 2.0 and MIT).
3. Which platforms it supports. It must support every platform in the manifests, or be
   conditional with `.when(platforms:)` as eventsource is.
4. Whether its types would appear in the public API. They should not.
5. What it adds to the dependency graph (transitive packages).

Packages from the Swift project and Apple (`swiftlang/*`, `apple/swift-*`) are preferred.

Dependencies of fixtures, examples and tests follow the same review, with criteria 3 and 4
relaxed.

## Version range rules

- Use `from: "X.Y.Z"` (up to the next major) with the oldest version that provides what the SDK
  uses. Raise the floor only when the SDK starts to need a newer feature or fix.
- Use an explicit range spanning several majors (as for swift-crypto) only when the APIs the SDK
  uses exist unchanged in each of them. CI tests only the version in `Package.resolved`, so build
  against the oldest major by hand when the range or the SDK's use changes.
- No upper bound below the next major unless a release is known to break the SDK.
- No `branch:` or `revision:` requirements, build tools such as swift-docc-plugin included.
  SwiftPM refuses to resolve a version-based requirement on a package whose manifest has a
  branch- or revision-based dependency, so a single one would stop every consumer that depends
  on a released `MCP` version from resolving it. A branch also moves under everyone who builds
  the package.
- Moving a dependency to a new major, or adding one to `MCP`, is a breaking change under
  [VERSIONING.md](VERSIONING.md). Raising a floor within a major is allowed in a minor and is
  listed in the release notes.

## Platform and toolchain floors

From the manifests:

| Platform | Minimum |
|---|---|
| macOS | 13.0 |
| Mac Catalyst | 16.0 |
| iOS | 16.0 |
| watchOS | 9.0 |
| tvOS | 16.0 |
| visionOS | 1.0 |
| Linux | glibc or musl (static Linux SDK) |

| Manifest | swift-tools-version | Contents |
|---|---|---|
| `Package.swift` | 6.1 | library, tests, conformance fixtures, examples, snippet targets |
| `Package@swift-6.0.swift` | 6.0 | library and tests only |

CI builds with Swift 6.1 (Xcode 16.3 on macOS 15, swift 6.1.0 on Ubuntu, the 6.1.2 static Linux
SDK) and with the default Xcode of `macos-latest`. No CI job uses Swift 6.0 tools, so the 6.0
manifest is checked only by hand.

Keep the two manifests' dependency lists for `MCP` and `MCPTests` in sync. A platform floor or
tools version is raised only in a major release.

## Update cadence

- Review dependency updates at least once per minor release cycle, and immediately for a
  security advisory that affects code the SDK uses.
- Update `Package.resolved` with `swift package update` in its own pull request, after a release
  when possible, so the new versions get a full cycle of testing.
- Run `swift build`, `swift test`, and all conformance legs ([conformance/README.md](conformance/README.md))
  before merging a dependency change.
