# MCP Swift SDK

A Swift SDK for the [Model Context Protocol](https://modelcontextprotocol.io)
(MCP): clients, servers and transports for building tools, prompts and
resources that language-model applications can use.

## Protocol versions

The SDK serves two protocol eras at once:

| Era | Revisions | How a connection starts |
|---|---|---|
| Handshake | 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05 | `initialize`, then a session |
| Stateless | 2026-07-28 | none: each request carries its version and client capabilities in `_meta`; clients use `server/discover` |

A `Server` serves both by default. A `Client` sends `server/discover` and
connects at 2026-07-28, and falls back to `initialize` for older servers;
`Client.Configuration(protocolMode: .handshake)` keeps the handshake. See
[docs/protocol_versions.md](docs/protocol_versions.md).

At 2026-07-28 the SDK supports server discovery, SEP-2243 request headers,
`subscriptions/listen` notification streams, multi round-trip requests with
sealed `requestState`, result caching hints, and the tasks extension; tasks
also work at 2025-11-25. Servers serve skills (SEP-2640), and clients load them
verified, at every revision. The conformance tier score
is 100% for clients and servers at 2025-11-25 and 2026-07-28; see
[ROADMAP.md](ROADMAP.md).

## Requirements

- Swift 6.1 or later (Xcode 16.3 or later).
- macOS 15, iOS 18, Mac Catalyst 18, watchOS 11, tvOS 18, visionOS 2, or Linux
  with glibc or musl. For older deployment targets (macOS 13 or 14; iOS, Mac
  Catalyst or tvOS 16 or 17; watchOS 9 or 10; visionOS 1), stay on 0.12
  ([platform policy](VERSIONING.md#platforms)).

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMajor(from: "1.0.0"))
],
targets: [
    .target(name: "MyTarget", dependencies: [.product(name: "MCP", package: "swift-sdk")])
]
```

## A server in 30 lines

This server has one tool and runs over stdio
([Examples/hello-server/main.swift](Examples/hello-server/main.swift)):

%include Examples/hello-server/main.swift hello-server

A client calls it the same way in either era:

%include Examples/Snippets/QuickStart/QuickStart.swift in-process

Run the hello examples:

```bash
swift build --product HelloServer && swift build --product HelloClient
"$(swift build --show-bin-path)/HelloClient" "$(swift build --show-bin-path)/HelloServer"
```

## Documentation

The [documentation index](docs/README.md) lists every feature. Start with:

- [Quick start](docs/quick_start.md): stdio and HTTP servers and clients.
- [Base protocol](docs/protocol.md): lifecycle, transports, notification
  streams, authorization, security, utilities.
- [Server features](docs/server.md): tools, prompts, resources, notifications,
  multi round-trip requests, tasks, skills, caching, logging, handler context.
- [Client features](docs/client.md): tools, roots, sampling, elicitation,
  tasks, skills, subscriptions, cancellation, errors.
- [Testing](docs/testing.md) and [troubleshooting](docs/troubleshooting.md).
- [Migration guide](docs/migration.md) and [rough edges](docs/rough_edges.md).

API reference: `swift package generate-documentation --target MCP`.

## Examples

[`Examples/`](Examples) holds runnable programs and the sources of every
code block in the docs:

| Target | What it shows |
|---|---|
| `HelloServer`, `HelloClient` | A stdio server with one tool, and a client that starts it as a subprocess |
| `HTTPServerExample` | One HTTP endpoint for both eras: stateful sessions and stateless requests |
| `*Snippets`, `SnippetTests` | The doc snippets, compiled and tested with the package |

## Repository layout

| Path | Contents |
|---|---|
| `Sources/MCP` | The library |
| `Tests/MCPTests` | Unit and integration tests |
| `docs/` | Guides, generated from `docs/src` by `swift scripts/weave.swift` |
| `design/` | Design notes: the overall design and one note per feature |
| `Examples/` | Runnable examples and doc snippets |
| `conformance/` | Fixtures and baselines for the [MCP conformance suite](https://github.com/modelcontextprotocol/conformance) |
| `interop/` | Interop matrix against the Go and Python SDKs, and its [results](interop/RESULTS.md) |
| `scripts/` | Conformance and interop runners, conformance scorer, docs weaver |

## Project

- [Roadmap](ROADMAP.md)
- [Changelog](CHANGELOG.md)
- [Versioning](VERSIONING.md)
- [Dependency policy](DEPENDENCY_POLICY.md)
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)

## License

This project is licensed under Apache 2.0 for new contributions, with existing
code under MIT. See [LICENSE](LICENSE).
