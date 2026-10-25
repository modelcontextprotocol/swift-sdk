# Testing

This guide shows how to test servers and clients without processes or
sockets: in-memory transport pairs, handlers called directly, both protocol
eras, and HTTP transports driven with `HTTPRequest` values. It ends with the
conformance suite. The tests shown here are in
[`Examples/Tests/GuidesSnippetTests.swift`](../Examples/Tests/GuidesSnippetTests.swift)
and use Swift Testing.

## In-memory pairs

`InMemoryTransport.createConnectedPair()` returns two paired transports, one
for the client and one for the server. Messages go directly from one actor to
the other, in order. A helper that starts a server and connects a client:

%include Examples/Snippets/Guides/Testing.swift testing-pair

A test with it:

%include Examples/Tests/GuidesSnippetTests.swift testing-in-memory-test

- Start the server before the client connects. A transport drops messages
  that arrive before it is connected.
- `client.disconnect()` ends the server's message loop: the server's transport
  finishes with `MCPError.connectionClosed`. `server.stop()` also closes open
  `subscriptions/listen` streams.
- Pass a `Logger` to `createConnectedPair(logger:)` to see the messages'
  sizes in the test output; see [troubleshooting.md](troubleshooting.md#transport-loggers).
- Each test should build its own server: a `Server` accepts `initialize` only
  once.

## Testing handlers directly

A handler is a closure from parameters to a result. Written as a function, it
can be registered and also called directly:

%include Examples/Snippets/Guides/Testing.swift testing-handler-function

%include Examples/Tests/GuidesSnippetTests.swift testing-handler-test

`Server.currentHandlerContext` is `nil` in a direct call, and
`Server.HandlerContext` has no public initializer. Test handlers that read the
context, or that return input-required results, through a connection.

## Testing both eras

A `Server` serves both eras by default. Parameterize a test over the client's
protocol mode to cover both: `.handshake` connects with `initialize`, and
`.automatic` connects at 2026-07-28 to a default server.

%include Examples/Tests/GuidesSnippetTests.swift testing-both-eras

The eras differ in ways that tests should cover when a server relies on them:

- Server-to-client requests (`requestSampling`, `requestElicitation`,
  `listRoots`) fail at 2026-07-28 with -32600. Input-required results work in
  both eras.
- Methods of capabilities the server does not declare are -32601 at
  2026-07-28.
- Log notifications at 2026-07-28 depend on the client's
  `Configuration.logLevel`.
- List-changed notifications at 2026-07-28 arrive only on listen streams,
  which the client opens in the background.

[protocol_versions.md](protocol_versions.md) lists every difference.

## HTTP transports without sockets

The HTTP server transports take an `HTTPRequest` and return an
`HTTPResponse`, so a test can call `handleRequest(_:)` directly. A request at
2026-07-28 needs the `_meta` envelope and the headers a client sends:

%include Examples/Snippets/Guides/Testing.swift testing-http-request

%include Examples/Tests/GuidesSnippetTests.swift testing-http-test

- `StatelessHTTPServerTransport.handleRequest(_:)` returns when the server
  answers, so the server must be started first.
- When a handler sends notifications for its request and the request accepts
  `text/event-stream`, the response is `.stream`: iterate the stream to read
  the SSE events, ending with the response.
- The default validation pipeline checks `Host` and `Origin` only when they
  are present, so a test needs neither.
- `StatefulHTTPServerTransport` answers the first POST, `initialize`, with an
  `Mcp-Session-Id` header. Later requests must send it, and POST responses
  are SSE streams. `Tests/MCPTests/HTTPServerTransportTests.swift` has
  examples.
- To test `HTTPClientTransport` without a server, pass a
  `URLSessionConfiguration` whose `protocolClasses` contains a `URLProtocol`
  subclass that answers the requests.

## Wire-level checks

To assert on the exact messages, wrap a transport and record what it sends
and receives. [troubleshooting.md](troubleshooting.md#recording-the-messages) has such a wrapper,
`WireLog`. For a single exchange, send raw JSON on the client end of an
in-memory pair with `send(_:)` and read the reply from `receive()`.

## Running the snippet tests

The examples are compiled with the package, and their tests are in the
`SnippetTests` target:

```console
$ swift build --build-tests
$ swift test --skip-build --filter "GuidesSnippetTests"
```

`swift scripts/weave.swift --check` fails when a file in `docs/` is out of date
with its source in `docs/src/` or a snippet, or when a link is broken.

## The conformance suite

The SDK is tested against the
[MCP conformance suite](https://github.com/modelcontextprotocol/conformance).
`scripts/run-conformance.sh` builds the fixtures `mcp-everything-client` and
`mcp-everything-server` (sources in [`conformance/`](../conformance)) and runs
the harness `@modelcontextprotocol/conformance@0.2.0-alpha.11`. The harness
and its dependency tree are pinned by
[`scripts/conformance-harness/package-lock.json`](../scripts/conformance-harness/package-lock.json)
and installed with `npm ci` into `.build/conformance-harness`; set
`CONFORMANCE_PKG` to run another harness version through `npx` instead. It
needs Node.js. When the default npm registry requires credentials,
`export npm_config_registry=https://registry.npmjs.org`.

```console
$ scripts/run-conformance.sh --spec-version 2025-11-25
$ scripts/run-conformance.sh --spec-version 2026-07-28
$ scripts/run-conformance.sh
$ scripts/run-conformance.sh --requirements 2026-07-28
```

| Leg | Selects | Baseline |
|---|---|---|
| `--spec-version 2025-11-25` | every scenario, at the handshake wire | `conformance/baseline.2025-11-25.yml` |
| `--spec-version 2026-07-28` | every scenario, at the stateless wire | `conformance/baseline.2026-07-28.yml` |
| no option | every scenario, at the harness's default wire; the only leg with extension scenarios such as `tasks-*` | `conformance/baseline.yml` |
| `--requirements <revision>` | the frozen requirement set of the tier check | none; any scored failure fails |

Each baseline lists the known failures, one `<scenario>:<check-id>` entry per
failing check, or a bare `<scenario>` for a scenario that failed without
checks. A run fails on a failure that is not listed, and on a listed entry
that now passes. After a fix, regenerate the baseline with
`--update-baseline` in the same change; baselines are generated, not edited.

A `--requirements` leg also prints the tier score: a scenario passes when it
has at least one successful check and no failed check.

Options:

| Option | Meaning |
|---|---|
| `--mode client\|server\|both` | Which fixture to test; default `both`. |
| `--bin-path <dir>` | Use fixtures already built in `<dir>`, such as `$(swift build --show-bin-path)`. |
| `--port <n>` | The server fixture's port; default 3001. It serves `/mcp`. |
| `--output-dir <dir>` | Results and logs; default `.build/conformance`. |
| `--solo-attempts <n>` | Re-run each unexpected failure and each stale baseline entry alone up to `n` times before failing; default 1. A stale entry that also passes alone fails the leg. |
| `--update-baseline` | Regenerate the leg's baseline instead of checking it. |

The output of a leg is in `.build/conformance/<leg>/`: the harness logs
`client.log` and `server.log`, the server fixture's own output in
`server-fixture.log`, and the per-scenario results in `client/` and `server/`.

`scripts/tests/run-conformance-test.sh` checks the exit status of the runner
and the scorer with a fake harness; it needs Node.js and no network.
