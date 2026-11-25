# Quick start

This guide installs the SDK, builds a stdio server with one tool and a client
that calls it, and then serves the same tool over HTTP. Every code block comes
from a compiled example in [`Examples/`](../Examples).

## Installation

The package requires Swift 6.0 or later. `Package.swift` needs Swift 6.1
tools; `Package@swift-6.0.swift` serves Swift 6.0 tools with the `MCP`
library only. The minimum platforms are macOS 13, iOS 16, Mac Catalyst 16,
watchOS 9, tvOS 16 and visionOS 1. On Linux, the stdio transport needs glibc
or musl.

Add the package and the `MCP` product to `Package.swift`. While the package is
0.x, a minor release may break source compatibility
([VERSIONING.md](../VERSIONING.md)), so depend on a release with
`.upToNextMinor(from:)`, or use `branch:` to track a branch:

```swift
dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.13.0"))
],
targets: [
    .executableTarget(
        name: "MyServer",
        dependencies: [.product(name: "MCP", package: "swift-sdk")]
    )
]
```

The library depends on swift-system, swift-log and swift-crypto.

## A stdio server

A `Server` holds the server's name, version and capabilities, and one handler
per method. This server declares the `tools` capability and handles
`tools/list` and `tools/call`. It then runs over standard input and output
until standard input closes
([`Examples/hello-server/main.swift`](../Examples/hello-server/main.swift)):

%include Examples/hello-server/main.swift hello-server

- `withMethodHandler(_:handler:)` registers one handler per method type. The
  handler receives the decoded parameters and returns the result.
- Throwing an `MCPError` sends a JSON-RPC error. A tool failure that the model
  should see is a result with `isError: true` instead; see [server.md](server.md#errors-and-iserror).
- `start(transport:)` connects the transport and returns. The server handles
  messages in a background task; `waitUntilCompleted()` waits until that task
  ends.
- The server serves both protocol eras: `initialize` clients and stateless
  2026-07-28 clients. See [protocol_versions.md](protocol_versions.md).

A stdio server must not write anything else to standard output. Log to
standard error; see [troubleshooting.md](troubleshooting.md).

## A stdio client

A client usually starts the server as a subprocess and talks to it through
pipes. `StdioTransport` takes the two file descriptors to use
([`Examples/hello-client/main.swift`](../Examples/hello-client/main.swift)).
First, start the server:

%include Examples/hello-client/main.swift hello-client-spawn

Then connect, list the tools and call `greet`:

%include Examples/hello-client/main.swift hello-client

- `connect(transport:)` opens the protocol connection. With the default
  configuration it sends `server/discover` and connects at 2026-07-28. A
  server that does not serve 2026-07-28 gets `initialize` and
  `notifications/initialized` instead.
- `listTools()` and `callTool(name:arguments:meta:)` return the request's
  result: `ListTools.Result` and `CallTool.Result`. See [client.md](client.md).
- `FileDescriptor` comes from `System` on Apple platforms and from
  `SystemPackage` (swift-system) elsewhere.

Finally, disconnect and close the server's standard input, so that the server
exits:

%include Examples/hello-client/main.swift hello-client-exit

## Running the examples

The package builds both examples. `HelloClient` starts the server binary given
as its first argument, or the `HelloServer` executable in its own directory:

```console
$ swift build --product HelloServer
$ swift build --product HelloClient
$ $(swift build --show-bin-path)/HelloClient $(swift build --show-bin-path)/HelloServer
Tools: greet
Hello, Swift!
```

The client exits with status 0.

## In one process

`InMemoryTransport.createConnectedPair()` connects a client and a server in the
same process, without pipes. Tests use it; see [testing.md](testing.md).
`makeGreetServer()` builds the server from above without starting it:

%include Examples/Snippets/QuickStart/QuickStart.swift in-process

## Over HTTP

The SDK's HTTP server transports do not open sockets. Your HTTP server
converts each request to an `HTTPRequest`, passes it to the transport's
`handleRequest(_:)`, and writes the `HTTPResponse` back.

`StatelessHTTPServerTransport` serves 2026-07-28 clients: each request is a
self-contained POST, and one `Server` serves every client:

%include Examples/Snippets/QuickStart/QuickStart.swift http-server

`HTTPClientTransport` connects to a Streamable HTTP endpoint. The client
discovers 2026-07-28 with `server/discover` and falls back to `initialize` for
older servers:

%include Examples/Snippets/QuickStart/QuickStart.swift http-client

Clients that use `initialize` expect a session: route them to a
`StatefulHTTPServerTransport`, one per session. A stateless transport answers
their requests without one; see [rough_edges.md](rough_edges.md#server-api). [protocol.md](protocol.md) describes the
transports and the routing, and
[`Examples/http-server/main.swift`](../Examples/http-server/main.swift) is a
complete server built on SwiftNIO.

## Next steps

- [server.md](server.md): tools, resources, prompts, completion, logging.
- [client.md](client.md): calling servers, and handling sampling, elicitation
  and roots.
- [protocol.md](protocol.md): lifecycle, transports, authorization,
  cancellation and progress.
- [protocol_versions.md](protocol_versions.md): the two protocol eras.
- [testing.md](testing.md): testing servers and clients.
- [troubleshooting.md](troubleshooting.md): logging and common failures.
