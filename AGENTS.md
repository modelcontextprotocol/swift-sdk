# AGENTS.md

Guidance for AI coding agents, and the humans driving them, working on the Swift SDK for the
[Model Context Protocol](https://modelcontextprotocol.io). Read this file before changing code.

## Agent Behavior Policy

AI agents should:

- Make atomic, minimal, and reversible changes. Only touch files relevant to the task
- Follow [CONTRIBUTING.md](CONTRIBUTING.md), including its [Coding Style](CONTRIBUTING.md#coding-style),
  and the patterns in neighboring files
- Build and test locally (see [Commands](#commands)) before proposing a commit
- Read the relevant [MCP specification](https://modelcontextprotocol.io/specification/2026-07-28)
  section before changing protocol behavior, and match the spec's wire format exactly
- Call out every change to public API, and keep source compatibility for existing users

Agents must NOT:

- Skip, disable, or weaken tests to make CI pass
- Modify CI workflows, `CODEOWNERS`, `SECURITY.md`, `LICENSE`, or release automation unless
  explicitly asked
- Add package dependencies without explicit approval. When approved, update **both**
  `Package.swift` and `Package@swift-6.0.swift`, and commit the updated `Package.resolved`
- Reformat files they are not otherwise changing. The repository has no formatter configuration, so
  project-wide formatting produces noisy diffs
- Commit secrets, credentials, or changes to git config
- Post issues, PRs, or review comments to GitHub without a human reviewing them first
- Describe security vulnerabilities in public issues, PRs, or commit messages. See
  [SECURITY.md](SECURITY.md)

If a task needs a new public API, an architectural change, or behavior outside the MCP specification,
stop and tell the user it needs discussion first (see
[Before You Start](CONTRIBUTING.md#before-you-start)).

## Repository Map

```
swift-sdk/
├── .agents/                         # Shared agent development skills (see .agents/README.md)
├── .github/workflows/               # GitHub Actions CI
├── Package.swift                    # Manifest for Swift 6.1+ (library + conformance executables)
├── Package@swift-6.0.swift          # Manifest for Swift 6.0 (library and tests only)
├── conformance-baseline.yml         # Expected conformance failures (keep empty when possible)
├── scripts/                         # Helper scripts (local conformance runs)
├── Sources/
│   ├── MCP/                         # The `MCP` library product
│   │   ├── Base/                      # Core JSON-RPC types, lifecycle, versioning, errors, `Transport`
│   │   │   ├── Utilities/             # Ping, cancellation, progress, `_meta`, `RequestContext`
│   │   │   ├── Transports/            # stdio, HTTP client, HTTP server, Network.framework, in-memory
│   │   │   └── Authorization/         # OAuth 2.1 client support for `HTTPClientTransport`
│   │   ├── Client/                    # `Client` actor; client features (sampling, elicitation, roots)
│   │   ├── Server/                    # `Server` actor; server features (tools, resources, prompts, ...)
│   │   └── Extensions/                # Extensions on Foundation types (e.g. `Data` data URL encoding)
│   └── MCPConformance/              # `mcp-everything-client` / `mcp-everything-server` executables
└── Tests/MCPTests/                  # Swift Testing suites
    └── Helpers/MockTransport.swift    # Scriptable mock transport
```

The server-to-client methods (sampling, elicitation, roots) live in `Client/`, because the client
implements them. The server-side methods (tools, resources, prompts, completion, logging) live in
`Server/`.

## Environment & Tooling

- **Language**: Swift 6 with Swift Concurrency. The `MCP` target enables `StrictConcurrency`.
- **Toolchains**: CI builds with Swift 6.1 on Linux, Xcode 16.3 (Swift 6.1) on `macos-15`, and the
  default Xcode on `macos-latest`. On macOS, use the toolchain bundled with Xcode.
- **Platforms**: macOS 13+, iOS / Mac Catalyst / tvOS 16+, watchOS 9+, visionOS 1+, and Linux
  (glibc and the static musl SDK). On Linux, install `libcurl4-openssl-dev`.
- **Dependencies**: `swift-system`, `swift-log`, `eventsource` (Apple platforms only), `swift-nio`
  (conformance server only), and `swift-docc-plugin`.
- **Tests**: [Swift Testing](https://developer.apple.com/documentation/testing) (`import Testing`).
  Do not add XCTest.
- **Docs**: DocC, built in CI with `--warnings-as-errors` and published on the Swift Package Index.
- **Conformance**: [`modelcontextprotocol/conformance`](https://github.com/modelcontextprotocol/conformance),
  which needs Node.js and `npx`.

## Commands

<!-- BEGIN: AGENT_COMMANDS -->

```bash
# Build and test (the CI `test` job)
swift build
swift test

# Targeted tests
swift test --filter CompletionTests                                    # One suite
swift test --filter "CompletionTests/testPromptReferenceEncodingDecoding" # One test

# Documentation (must build with no warnings)
swift package generate-documentation --target MCP --warnings-as-errors

# Conformance tests (needs Node.js; builds both executables first)
scripts/run-conformance.sh                # Client and server
scripts/run-conformance.sh --mode client  # Client only
scripts/run-conformance.sh --mode server  # Server only, on http://localhost:3001/mcp
```

<!-- END: AGENT_COMMANDS -->

Before you open a PR, run at least `swift build` and `swift test`. If you touched doc comments on
public symbols, also build the documentation. If you touched protocol behavior, transports, or
`Sources/MCPConformance/`, also run the conformance tests.

## Development Workflow

**Before making changes**:

1. Read the code you are changing, its tests, and the matching spec section.
2. Check the [Core Development Principles](#core-development-principles) below.
3. Run the relevant tests first, so you know their baseline state.

**Commits and PRs**: follow
[CONTRIBUTING.md](CONTRIBUTING.md#commit-messages-and-pr-descriptions). Write imperative subjects,
explain the root cause and spec or RFC section in the body, keep PRs small, and disclose AI
assistance.

## Core Development Principles

### 1. Maintain Stable Public Interfaces ⚠️ CRITICAL

The SDK follows [Semantic Versioning](https://semver.org). Before 1.0, minor releases may break API,
but breakage must be deliberate and called out in the PR.

- Before changing anything `public`, search for its usage in `Sources/`, `Tests/`, `README.md`, and
  `Sources/MCPConformance/`.
- Prefer additive changes. Give new initializer parameters and new properties defaults, so existing
  call sites still compile.
- To replace an API, keep the old one as a deprecated shim that forwards to the new one:

```swift
/// Deprecated compatibility factory for older call sites that used `.text("...")`.
@available(*, deprecated, message: "Use .text(text:annotations:_meta:) instead.")
public static func text(_ text: String, metadata: Metadata? = nil) -> Self {
    .text(text: text, annotations: nil, _meta: metadata)
}
```

- Keep implementation details `internal`. Use `package` only when another target in this package
  needs the symbol.
- Wire format is public API too. Changing a `CodingKeys` raw value or an encode/decode rule can
  break interoperability with other MCP SDKs.

### 2. Follow the MCP Specification

- The SDK implements protocol versions up to `2025-11-25`, listed in `Version.supported`
  (`Base/Versioning.swift`). Don't add a newer version until the SDK implements it. Adding a version
  also requires updating `VersioningTests`.
- Link each type to its spec section in its doc comment, using the revision the code implements:

```swift
/// To discover available tools, clients send a `tools/list` request.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/tools/#listing-tools
```

- Use spec field names as wire keys, including `_meta`. Decode leniently: use `decodeIfPresent` with
  sensible defaults for optional fields, so messages from other implementations still parse.
- Gate capability-dependent behavior through the existing `validateServerCapability` /
  `validateClientCapability` helpers. Don't add ad-hoc checks.
- Cite RFC sections in comments when implementing HTTP or OAuth behavior, for example
  `// RFC 6749 §2.3.1`.

### 3. Defining Protocol Messages

A request method is a caseless `enum` that conforms to `Method`. Its `Parameters` and `Result` are
`Hashable, Codable, Sendable` structs:

❌ **Bad:**

```swift
public struct ListWidgetsRequest: Codable {
    var method = "widgets/list"
    var cursor: String?
}
```

✅ **Good:**

```swift
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/...
public enum ListWidgets: Method {
    public static let name = "widgets/list"

    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        public let cursor: String?

        public init() { self.cursor = nil }
        public init(cursor: String) { self.cursor = cursor }
    }

    public struct Result: Hashable, Codable, Sendable {
        public let widgets: [Widget]
        public let nextCursor: String?
        public var _meta: Metadata?

        public init(widgets: [Widget], nextCursor: String? = nil, _meta: Metadata? = nil) { ... }
    }
}

public struct WidgetListChangedNotification: Notification {
    public static let name: String = "notifications/widgets/list_changed"
}
```

- Use `Empty` (the default) or `public typealias Parameters = Empty` for methods without
  parameters. Conform `Parameters` to `NotRequired` when clients may omit `params` entirely.
- Expose `_meta` as `public var _meta: Metadata?`, with a `_meta: Metadata? = nil` initializer
  parameter.
- Group related types in a namespace `enum` when a feature has many types (see `Sampling`,
  `Elicitation`).
- Add a typed convenience method to `Client` or `Server` that callers use instead of building
  requests by hand. Requests are sent with `try await send(request).value`.
- Server handlers are registered with `withMethodHandler(_:handler:)`, which replaces any existing
  handler for that method. Notification handlers registered with `onNotification(_:handler:)` are
  appended. `Server.start` registers default `Initialize` and `Ping` handlers.

### 4. Concurrency

- `Client`, `Server`, and every `Transport` are actors. Data types are `Sendable` value types.
- Don't capture `[weak self]` in closures and tasks owned by an actor. Capture what the closure
  needs, or rely on the actor's own lifecycle.
- Avoid `@unchecked Sendable`, `nonisolated(unsafe)`, and `@preconcurrency`. Use them only where a
  type is provably serialized by an actor, and document why next to the declaration (see
  `OAuthAuthorizer`).
- Don't block threads. Don't use `DispatchSemaphore` or busy-waiting in library code.
- New transports conform to `Transport` (`public actor`) with `public nonisolated let logger: Logger`.
  They must finish their `receive()` stream on disconnect.

### 5. Platform Compatibility

The library builds on every Apple platform and on Linux, including the static Linux SDK. Gate
platform-specific code with `canImport` checks where possible, and follow the existing gates:

| Concern                                  | Gate                                                               |
| ---------------------------------------- | ------------------------------------------------------------------ |
| `Network.framework` (`NetworkTransport`) | `#if canImport(Network)`                                           |
| `URLSession` on Linux                    | `#if canImport(FoundationNetworking)`                              |
| SSE streaming (`EventSource`)            | `#if !os(Linux)` (the package links it on Apple platforms only)    |
| POSIX I/O (`StdioTransport`)             | `#if canImport(Darwin) \|\| canImport(Glibc) \|\| canImport(Musl)` |
| `System` vs `SystemPackage`              | `#if canImport(System)`                                            |
| PKCE S256 hashing                        | `#if canImport(CryptoKit)`                                         |

If a change can affect Linux, call that out in the PR, because CI is the only Linux check most
contributors get.

### 6. Testing Requirements

- Every new feature and every bug fix MUST come with tests. A bug fix needs a regression test that
  fails without the fix.
- Tests live in `Tests/MCPTests/`, one file per feature area (`ToolTests.swift`,
  `HTTPClientTransportTests.swift`, ...). Add to the existing file when there is one.
- Use Swift Testing: a `@Suite("Readable Name") struct`, and `@Test("Readable description")` on each
  test. Assert with `#expect` / `#require`, and use `Issue.record` for unreachable paths.

```swift
@Suite("Tool Tests")
struct ToolTests {
    @Test("ListTools result round-trips with _meta")
    func testListToolsResultRoundTrip() throws {
        let meta = Metadata(additionalFields: ["vendor.example/key": .string("value")])
        let result = ListTools.Result(tools: [], _meta: meta)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ListTools.Result.self, from: data)
        #expect(decoded == result)
    }
}
```

- **Wire format**: assert on the encoded JSON (`JSONSerialization`), not only on a decode
  round-trip, so a symmetric encode/decode bug can't pass.
- **Client/server behavior**: use a real pair over `InMemoryTransport`:

```swift
let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
let server = Server(name: "test", version: "1.0", capabilities: .init(tools: .init()))
await server.withMethodHandler(ListTools.self) { _ in .init(tools: []) }
try await server.start(transport: serverTransport)

let client = Client(name: "test", version: "1.0")
_ = try await client.connect(transport: clientTransport)
// ... exercise and assert ...
await client.disconnect()
await server.stop()
```

Use `MockTransport` (`Tests/MCPTests/Helpers/`) when you need to script exact messages or inspect
what was sent.

- **Assert real behavior**: test what the SDK did, not state that a mock set itself.
- **No fixed sleeps for synchronization.** Wait for a condition with a deadline:

❌ **Bad:**

```swift
try await Task.sleep(for: .milliseconds(500))
#expect(mockConnection.state == .cancelled)
```

✅ **Good:**

```swift
let deadline = ContinuousClock.now + .seconds(3)
while mockConnection.state != .cancelled && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(50))
}
#expect(mockConnection.state == .cancelled)
```

- **Shared global state**: the HTTP and OAuth tests share `MockURLProtocol`. Put new tests in a
  `.serialized` suite with the `.httpClientTransportSetup` trait, or use the key-isolated helpers
  in `OAuthComponentTestHelpers.swift`. Mirror the existing `#if swift(>=6.1)`,
  `canImport(FoundationNetworking)`, and `canImport(Network)` gates.
- **Conformance**: for protocol features, add or update a scenario in
  `Sources/MCPConformance/Client/main.swift` (`scenarioHandlers`) or `Server/main.swift`. Don't add
  entries to `conformance-baseline.yml` to hide a failure you introduced.

### 7. Documentation

- Update `README.md` when you add or change user-facing API. Its examples must compile against the
  current API.
- Keep doc comments accurate when behavior changes. A stale comment is a bug.
