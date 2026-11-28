# AGENTS.md

Guidance for AI coding agents, and the humans driving them, working on the Swift SDK for the
[Model Context Protocol](https://modelcontextprotocol.io). Read this file before changing code.
[CLAUDE.md](CLAUDE.md) has the architecture notes (protocol versions, stateless serving, the
request lifecycle, the conformance ratchet).

## Agent Behavior Policy

AI agents should:

- Make atomic, minimal, and reversible changes. Only touch files relevant to the task
- Follow [CONTRIBUTING.md](CONTRIBUTING.md), including its [Coding Style](CONTRIBUTING.md#coding-style),
  and the patterns in neighboring files
- Build and test locally (see [Commands](#commands)) before proposing a commit
- Read the relevant MCP specification section before changing protocol behavior, and match the
  spec's wire format exactly. Use the revision the code serves:
  - Handshake behavior (`initialize`, sessions, server-to-client requests):
    [`2025-11-25`](https://modelcontextprotocol.io/specification/2025-11-25), the newest
    handshake revision
  - Stateless behavior (per-request `_meta`, `server/discover`, input-required results):
    [`2026-07-28`](https://modelcontextprotocol.io/specification/2026-07-28)

  Code that serves both reads `ProtocolProfile` flags (see
  [Follow the MCP Specification](#2-follow-the-mcp-specification)). A change for one revision
  must not change the other unless the task says so. If the task doesn't say which revision it
  targets, ask.
- Call out every change to public API, and keep source compatibility for existing users

Agents must NOT:

- Skip, disable, or weaken tests to make CI pass
- Modify CI workflows, `CODEOWNERS`, `SECURITY.md`, `LICENSE`, or release automation unless
  explicitly asked
- Add package dependencies without explicit approval. When approved, follow
  [DEPENDENCY_POLICY.md](DEPENDENCY_POLICY.md), update `Package.swift` (the only manifest), and
  commit the updated `Package.resolved`
- Edit generated files by hand: `docs/*.md` and `README.md` (from `docs/src/*.src.md` and
  `README.src.md`), the conformance baselines, and `interop/RESULTS.md`
- Commit unrelated formatting changes. `.vscode/settings.json` enables format-on-save, so check the
  diff for reformatted lines outside the change and revert them
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
├── .github/workflows/               # GitHub Actions CI; the jobs call scripts/ci/run-jobs.sh
├── Package.swift                    # The manifest (Swift 6.1 tools): library, fixtures, examples
├── Sources/MCP/                     # The `MCP` library product
│   ├── Base/                          # JSON-RPC types, lifecycle, versioning, errors, `Transport`,
│   │   │                              # wire types of tasks, skills, apps and server cards
│   │   ├── Utilities/                 # Ping, cancellation, progress, `_meta`, `RequestContext`
│   │   ├── Transports/                # stdio, HTTP client, HTTP server (stateful and stateless),
│   │   │                              # Network.framework, in-memory
│   │   └── Authorization/             # OAuth 2.1 client support for `HTTPClientTransport`
│   ├── Client/                        # `Client` actor; client features (sampling, elicitation, roots)
│   ├── Server/                        # `Server` actor; server features (tools, resources, prompts, ...)
│   ├── Extensions/                    # Extensions on Foundation types (e.g. `Data` data URL encoding)
│   └── MCP.docc/                      # DocC catalog
├── Tests/MCPTests/                  # Swift Testing suites
│   └── Helpers/                       # MockTransport, WireExchange (`expectWire`), RawPeer, ...
├── Examples/                        # Hello client and server, HTTP server, doc snippets and SnippetTests
├── conformance/                     # `mcp-everything-client` / `mcp-everything-server` and baselines
├── interop/                         # Interop matrix against the Go and Python SDKs
├── fuzz/                            # libFuzzer targets (a separate package; Linux only)
├── docs/                            # Guides; `docs/src/*.src.md` are the sources
├── design/                          # Design notes
└── scripts/                         # Conformance, interop, docs and CI scripts (`scripts/ci/`)
```

The server-to-client methods (sampling, elicitation, roots) live in `Client/`, because the client
implements them. The server-side methods (tools, resources, prompts, completion, logging) live in
`Server/`.

## Environment & Tooling

- **Language**: Swift 6 with Swift Concurrency. The `MCP` target enables `StrictConcurrency`.
- **Toolchains**: Swift 6.1 or later. CI builds with Swift 6.1 on Linux (RHEL UBI 9 and Ubuntu
  24.04), Xcode 16.3 (Swift 6.1) on `macos-15`, and the default Xcode on `macos-latest`, which
  also runs the tests on an iOS simulator. On macOS, use the toolchain bundled with Xcode.
- **Platforms**: macOS 15+, iOS / Mac Catalyst / tvOS 18+, watchOS 11+, visionOS 2+, and Linux
  (glibc and the static musl SDK). On Linux, install `libcurl4-openssl-dev`. The minimums follow
  [VERSIONING.md](VERSIONING.md#platforms); don't add `@available` checks for releases below them.
- **Dependencies**: `swift-system`, `swift-log`, `swift-crypto`, `Yams` (skill frontmatter),
  `swift-nio` (the conformance server and the HTTP server example), and `swift-docc-plugin`.
- **Tests**: [Swift Testing](https://developer.apple.com/documentation/testing) (`import Testing`).
  Do not add XCTest.
- **Docs**: DocC, built in CI with `--warnings-as-errors` and published on the Swift Package Index.
  Guides in `docs/` are woven from `docs/src/*.src.md` and the compiled snippets in
  `Examples/Snippets/` by `scripts/weave.swift`.
- **Conformance**: [`modelcontextprotocol/conformance`](https://github.com/modelcontextprotocol/conformance),
  pinned in `scripts/conformance-harness/`, which needs Node.js 22.

## Commands

<!-- BEGIN: AGENT_COMMANDS -->

```bash
# Build and test (the CI `build-test` job)
swift build
swift test

# Targeted tests
swift test --filter CompletionTests                                    # One suite
swift test --filter "CompletionTests/testPromptReferenceEncodingDecoding" # One test

# Documentation (the CI `docs` job; must pass with no warnings)
swift package generate-documentation --target MCP --warnings-as-errors
swift scripts/doc-coverage.swift   # every public declaration has a doc comment
swift scripts/weave.swift          # regenerate docs/*.md and README.md; --check in CI

# Conformance tests (needs Node.js; builds both executables first)
scripts/run-conformance.sh --spec-version 2025-11-25   # Handshake wire
scripts/run-conformance.sh --spec-version 2026-07-28   # Stateless wire
scripts/run-conformance.sh                             # Default wire, extension scenarios included
scripts/run-conformance.sh --mode server               # Server only, on http://localhost:3001/mcp

# The CI jobs (scripts/ci/jobs), on macOS or in a Linux container
scripts/ci/run-jobs.sh 'conformance-.*'
scripts/ci-linux.sh build-test
```

<!-- END: AGENT_COMMANDS -->

Before you open a PR, run at least `swift build` and `swift test`. If you touched doc comments on
public symbols or guides, also run the documentation commands. If you touched protocol behavior,
transports, or `conformance/`, also run the conformance tests, and `scripts/run-interop.sh --check`
for transport changes.

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

The SDK follows [Semantic Versioning](https://semver.org) as [VERSIONING.md](VERSIONING.md)
defines it: from 1.0.0, a breaking change to the public API needs a major release. The CI
`api-breakage` job compares the public API with the newest release.

- Before changing anything `public`, search for its usage in `Sources/`, `Tests/`, `Examples/`,
  `conformance/`, `interop/`, `docs/src/`, and `README.src.md`.
- Prefer additive changes. Give new initializer parameters and new properties defaults, so existing
  call sites still compile.
- To replace an API, keep the old one as a deprecated shim that forwards to the new one:

```swift
/// The newest handshake revision.
@available(*, deprecated, renamed: "latestHandshake", message: "The newest revision is Version.stateless[0]")
public static var latest: String { latestHandshake }
```

- Every public enum is frozen, extensible, or an open type, as
  [VERSIONING.md](VERSIONING.md#enums-and-open-types) decides. Follow that rule for new enums.
- Keep implementation details `internal`. Use `package` only when another target in this package
  needs the symbol.
- Wire format is public API too. Changing a `CodingKeys` raw value or an encode/decode rule can
  break interoperability with other MCP SDKs.

### 2. Follow the MCP Specification

- `Base/Versioning.swift` lists the revisions the SDK implements: `Version.handshake` (served
  through `initialize`, newest `2025-11-25`), `Version.stateless` (`2026-07-28`, served per
  request), and `Version.supported`, both. Don't add a revision until the SDK implements it.
  Adding one also requires updating `VersioningTests` and `ProtocolProfile`.
- Code that differs per revision reads `ProtocolProfile` flags (`Version.profile(for:)`). Don't
  compare version strings.
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
- A change that implements a SEP updates its row in the "SEP coverage" table of
  [ROADMAP.md](ROADMAP.md).

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
  appended. `Server.start` registers default handlers (`initialize`, `ping`, `server/discover`,
  `subscriptions/listen`, `logging/setLevel`), and `withTasks(_:)` and
  `withSkills(_:listInResources:)` register those of their feature; an application handler for
  the same method replaces the default.

### 4. Concurrency

- `Client`, `Server`, and every `Transport` are actors. Data types are `Sendable` value types.
- Capture `self` weakly in handlers that `Client` or `Server` store on themselves (for example the
  default handlers registered in `Server.swift`), and throw when it is gone. The actor owns those
  closures, so a strong capture is a retain cycle that keeps every started server alive. Keep
  `[weak self]` in callbacks handed to other objects too, such as `NWConnection` handlers in
  `NetworkTransport`.
- Avoid `@unchecked Sendable`, `nonisolated(unsafe)`, and `@preconcurrency`. Use them only where a
  type is provably serialized by an actor or a lock, and document why next to the declaration (see
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
| POSIX I/O (`StdioTransport`)             | `#if canImport(Darwin) \|\| canImport(Glibc) \|\| canImport(Musl)` |
| `System` vs `SystemPackage`              | `#if canImport(System)`                                            |
| Secure Enclave keys (DPoP)               | `#if canImport(CryptoKit)`; other hashing and signing use `Crypto` |
| Starting a process (`Process`)           | `#if !(os(iOS) \|\| os(tvOS) \|\| os(watchOS) \|\| os(visionOS))`  |

The doc snippets that start a process also hand its pipes to `StdioTransport` as `System`
`FileDescriptor`s, so they gate on `#if canImport(System) && os(macOS)` and compile on macOS
only.

`HTTPClientTransport` streams SSE through the same code on every platform. If a change can affect
Linux, call that out in the PR and run `scripts/ci-linux.sh build-test` if you can, because CI is
the only Linux check most contributors get.

### 6. Testing Requirements

- Every new feature and every bug fix MUST come with tests. A bug fix needs a regression test that
  fails without the fix.
- Tests live in `Tests/MCPTests/`, one file per feature area (`ToolTests.swift`,
  `HTTPClientTransportTests.swift`, ...). Add to the existing file when there is one. Snippet
  tests live in `Examples/Tests/`.
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

- **Wire format**: assert on the encoded JSON, not only on a decode round-trip, so a symmetric
  encode/decode bug can't pass. Golden wire tests use `expectWire` and `WireExchange`
  (`Tests/MCPTests/Helpers/WireExchange.swift`).
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

The default client connects at 2026-07-28 when the server serves it. A test of handshake
behavior pins the client to it with `configuration: .handshake`
(`Tests/MCPTests/Helpers/HandshakeConfiguration.swift`).

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
  `conformance/everything-client/main.swift` (`scenarioHandlers`) or `conformance/everything-server/`.
  A change that fixes or breaks a scenario regenerates the affected baseline
  (`conformance/baseline*.yml`) with `--update-baseline` in the same change. Don't add entries to
  a baseline to hide a failure you introduced.

### 7. Documentation

- Update the guides (`docs/src/*.src.md`) and `README.src.md` when you add or change user-facing
  API, then run `swift scripts/weave.swift` and commit the sources and the output together. Code
  in the guides comes from the snippet targets in `Examples/Snippets/`, which `swift build`
  compiles and `SnippetTests` runs.
- A breaking change updates [docs/migration.md](docs/migration.md) (through its source) and
  [CHANGELOG.md](CHANGELOG.md).
- Keep doc comments accurate when behavior changes. A stale comment is a bug.
