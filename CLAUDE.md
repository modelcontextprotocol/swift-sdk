# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is the official [Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)
for the [Model Context Protocol](https://modelcontextprotocol.io) (MCP). The package (`mcp-swift-sdk`)
exposes a single library product, `MCP`, implementing both client and server sides of the protocol
against the [2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25) and 2026-07-28 MCP
specifications. See `README.md`
for full API usage examples (client/server setup, transports, tools/resources/prompts, sampling,
elicitation, OAuth authorization).

## Common Commands

```bash
swift build -v                          # build the package
swift test -v                           # run the full MCPTests suite
swift test --filter ClientTests         # run one test class
swift test --filter ClientTests/testX   # run one test method

# Conformance suite executables (built by scripts/run-conformance.sh)
swift build --product mcp-everything-client
swift build --product mcp-everything-server

# DocC build; every public declaration needs a doc comment
swift package generate-documentation --target MCP --warnings-as-errors
swift scripts/doc-coverage.swift

# libFuzzer targets in fuzz/ (Linux only), 60 s per target; for longer runs:
# scripts/ci-linux.sh -- scripts/ci/fuzz.sh <seconds per target>
scripts/ci-linux.sh fuzz
```

`Package.swift` requires Swift 6.1 tools, the minimum for 1.x; there is no second manifest.

## Architecture

**`Sources/MCP/Base/`** — protocol-level building blocks, transport-agnostic:
- `Messages.swift` defines the generic JSON-RPC envelope (`Request<M>`, `Response<M>`,
  `Notification<M>`) keyed by a `Method` protocol with associated `Parameters`/`Result` types.
  New MCP methods are added by defining a type conforming to `Method`, not by extending the
  envelope types.
- `Value.swift` is the dynamic JSON value type used wherever the spec allows arbitrary JSON
  (tool arguments, resource metadata, etc).
- `Transport.swift` defines the `Transport` protocol — implementations must be `Actor`s and
  expose `connect()`/`disconnect()`/`send(_:)`/`receive()` (an `AsyncThrowingStream<Data, Error>`).
- `Transports/` holds the concrete transports: `StdioTransport`, `HTTPClientTransport`,
  `HTTPServer/{Stateless,Stateful}HTTPServerTransport` (with a request validation pipeline in
  `HTTPRequestValidation.swift`), `InMemoryTransport` (same-process, used heavily in tests), and
  `NetworkTransport` (Apple platforms only, Network.framework).
- `MCPRequestHeaders.swift` implements SEP-2243 (`Mcp-Method`/`Mcp-Name`/`Mcp-Param-*`).
- `Authorization/` implements OAuth 2.1 client-side flows: discovery (RFC 9728/8414), dynamic
  client registration (RFC 7591), PKCE, token endpoint calls, `private_key_jwt` assertions, the
  RFC 7523 jwt-bearer grant (`assertionProvider`, no DCR, no retry), RFC 8693 token exchange
  (`OAuthTokenExchange`), `OAuthConfiguration.enterpriseManaged(...)` (SEP-990) and DPoP
  (`OAuthConfiguration.dpop`, `OAuthDPoP.swift`, any `DPoPSigningKey`). The transport sets
  `authorizationHeaders(for:method:)` after `requestModifier` and passes every response to
  `didReceiveResponse(headers:for:)` (DPoP nonces).
  This is opt-in — wired in via an `OAuthAuthorizer` passed to `HTTPClientTransport`.
- `Utilities/` holds cross-cutting concerns used by both Client and Server: `Cancellation`,
  `Progress`, `Ping`, and `RequestContext` (the client's handle on a pending request: id and
  task). Handler context is `Server.currentHandlerContext` (task-local).

**`Sources/MCP/Client/Client.swift`** — `Client` is an `actor`. Owns the transport, drives
`initialize`/capability negotiation, and dispatches outgoing requests/notifications. Also registers
handlers for the server-initiated request types (sampling, elicitation, roots) since MCP allows
some requests to flow server→client.

**`Sources/MCP/Server/Server.swift`** — `Server` is an `actor`. Owns capability negotiation and
handler registration (`withMethodHandler`). `Tools.swift`, `Resources.swift`, `Prompts.swift`,
`Completion.swift` and `Logging.swift` define the `Method` types and their wire models.
`Configuration.strict` controls whether the server rejects requests from a client that hasn't sent
`initialize` yet.

**`conformance/everything-{client,server}`** — two executables (`MCPConformanceClient`, `MCPConformanceServer`)
that implement the "everything" reference client/server used by the
`modelcontextprotocol/conformance` test suite in CI. Not part of the `MCP` library product.

**`Examples/`** — `HelloServer`, `HelloClient`, `HTTPServerExample` and the doc snippet targets
(`*Snippets`, tests in `SnippetTests`). `docs/*.md` and `README.md` are generated from
`docs/src/*.src.md` and `README.src.md` by `swift scripts/weave.swift` (`--check` in CI);
never edit the generated files.

**`Tests/MCPTests/`** — one test file per source area; most transport/client/server tests run
against `InMemoryTransport` or `Helpers/MockTransport.swift` rather than real sockets/processes.

## Protocol versions

`Sources/MCP/Base/Versioning.swift` is the single source of truth:

- `Version.handshake` (newest first) are the revisions served through `initialize`;
  `Version.stateless` (`2026-07-28`) are served per request with `_meta`.
- `Version.supported` (both lists) and `Version.latestHandshake` (2025-11-25, what `initialize`
  requests) are explicit. `latest` is not `max()`. `Version.negotiate` only ever returns a
  handshake revision. `StatefulHTTPServerTransport` validates against `Version.handshake`.
- `Version.profile(for:)` returns a `ProtocolProfile` (`usesInitializeHandshake`,
  `usesRequestMeta`, `usesResultType`, `usesSessions`, `allowsServerRequests`,
  `usesSubscriptionsListen`, `usesStandardHeaders`, `allowsPrimingEvents`). Code that
  differs per revision reads these flags instead of comparing version strings.

Stateless serving: `Server.handleRequest` classifies each request with
`StatelessRequests.classify` (`Server/StatelessRequests.swift`) from `_meta`; stateless
requests get removed-method/undeclared-capability -32601, `HandlerContext` client fields,
log gating, result annotation (`resultType`, serverInfo, cache hints). `server/discover`
is a default handler. `StatelessHTTPServerTransport` rewrites JSON-RPC ids per exchange,
checks header vs `_meta` version, maps error codes to HTTP status, and streams related
notifications as SSE. Route with `HTTPRequest.statelessProtocolVersion`; the stateful
transport answers such requests with -32022 (handshake versions only).

Client: `Client.Configuration.protocolMode` (`.automatic` default, `.handshake`,
`.stateless(v)`); `.automatic` retries once on -32022 and falls back to `initialize` on
other MCP errors; `.stateless(v)` never retries. Tests that exercise the handshake pin
`.handshake` (`Tests/MCPTests/Helpers/HandshakeConfiguration.swift`). `send` stamps the `_meta` envelope when
`isStateless`. Request lifecycle: `register` puts a `ResponseSlot` in `pendingRequests` before
`send` returns and `transmit` sends from a task (`unsentRequests`); `withBatch` uses the same
path. Handlers run off the receive loop: notification handlers run one at a time on the
inbound queue; responses are delivered at once, except that a response waits for queued
progress notifications of its own request (`progressTokens`, `parkedResponses`; requests sent
from a notification handler never wait, via the `isHandlingNotification` task-local). The
client handles `notifications/cancelled` and the listen acknowledgement itself in the receive
loop (`handleBuiltIn`). Server-to-client requests run in `incomingRequests` tasks, at most
`maxConcurrentServerRequests` at once (64 more queued), refused at 2026-07-28 and for a
duplicate id. Cancelling the task that awaits `RequestContext.value` cancels the request. `HTTPClientTransport` takes `MCP-Protocol-Version` from the message `_meta`,
delivers JSON-RPC error bodies of non-2xx replies, and `useStatelessProtocol(_:)` drops the
session and GET stream. A handshake POST stream that ends before its response is resumed
with a GET carrying that stream's own `Last-Event-ID` (-32603 when it cannot be); at
2026-07-28 it fails at once. `HTTPClientTransport.defaultConfiguration` allows 64
connections per host: server-to-client replies need a connection while each call holds
one. The conformance client picks the mode from `MCP_CONFORMANCE_PROTOCOL_VERSION`.

Request headers (SEP-2243): `MCPRequestHeaders` (`Base/Transports/MCPRequestHeaders.swift`)
holds the codec and `x-mcp-header` rules. `HTTPClientTransport` adds `Mcp-Method`/`Mcp-Name`
when the version's profile `usesStandardHeaders`; `Client` mirrors `Mcp-Param-*` from
tool schemas cached on `tools/list`. `StatelessHTTPServerTransport` checks
`Mcp-Method`/`Mcp-Name`; `Server` checks `Mcp-Param-*` against the `tools/list` handler's
schema and drops tools with invalid annotations at stateless. Stateless HTTP tests must
send these headers (the `statelessRequest` test helper derives them).

Listen streams (SEP-2575): `Server.serveListen` is the built-in `subscriptions/listen`
handler (`listeners` registry; ack first; events from `notify`, which sends list-changed and
resource-updated notifications on the connection only for initialize sessions).
`withSubscriptionAuthorizer` narrows or refuses filters; `notify(_:to:)` targets callers;
`maxSubscriptionStreams` / `maxResourceSubscriptions` cap streams and URIs.
`StatelessHTTPServerTransport` restores the client id in `subscriptionId`, cancels a request
whose SSE consumer goes away, refuses listen without SSE (406) and sends `: keep-alive`
comments. `Client.listen(_:)` returns a `Subscription`; the client keeps one background
stream (`refreshNotificationStream`) for list-changed handlers and `subscribeToResource` URIs,
replaced after the successor's ack and reopened with backoff when it fails.

Other 2026-07-28 foundations: `MCPError` has `data` plus `resourceNotFound(uri:)`
(-32602), `headerMismatch` (-32020), `missingRequiredClientCapabilities` (-32021),
`unsupportedProtocolVersion` (-32022); `Request._meta` / `Message._meta` merge into
`params._meta` (`MetaKey` + typed `Metadata` accessors in `MetaKeys.swift`);
`extensions`/`experimental` on both capability structs; `ResultType`, `CacheScope`,
`CacheableResult` (`Results.swift`). Golden wire tests use `Tests/MCPTests/Helpers/WireExchange.swift`.

## Conformance: the baseline ratchet

`scripts/run-conformance.sh` is the single entry point for CI and developer machines. It
runs `@modelcontextprotocol/conformance` pinned exactly to `0.2.0-alpha.12` (2026-07-28 exists
only in the `0.2.0-alpha.*` line). The harness and its dependency tree are locked by
`scripts/conformance-harness/package-lock.json` and installed with `npm ci` into
`.build/conformance-harness`; `CONFORMANCE_PKG` runs another version through `npx`. To bypass
a private npm registry, `export npm_config_registry=https://registry.npmjs.org`.

```bash
scripts/run-conformance.sh --spec-version 2025-11-25   # stateful handshake wire
scripts/run-conformance.sh --spec-version 2026-07-28   # stateless per-request _meta wire
scripts/run-conformance.sh                             # bare leg, harness default wire
scripts/run-conformance.sh --requirements 2026-07-28   # tier score (frozen requirement set)
```

Flags: `--mode client|server|both`, `--update-baseline`, `--bin-path <dir>` (skip `swift build`;
use `$(swift build --show-bin-path)`), `--port`, `--output-dir` (default `.build/conformance`),
`--solo-attempts` (re-run unexpected failures alone before failing).

### Legs and baselines

Every leg runs `--suite all`, which includes `pending` and `draft` scenarios.

| Leg | Baseline |
|---|---|
| `--spec-version 2025-11-25` | `conformance/baseline.2025-11-25.yml` |
| `--spec-version 2026-07-28` | `conformance/baseline.2026-07-28.yml` |
| bare (default wire) | `conformance/baseline.yml`; the only leg that reaches extension scenarios (`tasks-*`, the skills `sep-2640-*` and the `auth/` extensions) |
| `--requirements <rev>` | none; scores the frozen set `conformance tier-check` uses |

Baselines are generated, not hand-edited (`--update-baseline`, via
`scripts/conformance-baseline.mjs`). Entries are `<scenario>:<check-id>` (no space after the
colon), or a bare `<scenario>` for a scenario that failed without producing a failing check.

The harness fails a run on an **unexpected failure** (unlisted) and on a **stale entry**
(listed but now passing). `WARNING` counts as a failure; `SKIPPED` and `INFO` do not. Fixing
conformance therefore forces a baseline regeneration in the same change, and entries only go
down.

The tier score passes a scenario when it has at least one `SUCCESS` and no `FAILURE` check
(`scripts/conformance-score.mjs`). Tier 1 needs 100% for every claimed revision.

Since alpha.11 every scenario carries a `wire-schema-valid` check: every message the SDK sends
is validated against the negotiated revision's JSON schema. alpha.12 validates a
`resultType: "task"` result only as a generic result (not against `CallToolResult`), gives
server scenarios a 30 s timeout, and adds the skills scenarios (`sep-2640-*`; they SKIP until
a fixture declares `io.modelcontextprotocol/skills`).

## The 2026-07-28 upgrade

2026-07-28 is brutally breaking. It removes the `initialize`/`notifications/initialized`
handshake, `Mcp-Session-Id`, `ping`, `logging/setLevel`,
`resources/subscribe`/`unsubscribe`, SSE resumability (`Last-Event-ID`), the HTTP GET
endpoint, and all server-initiated requests. It adds `server/discover`,
`subscriptions/listen`, a required `resultType` on every result, `CacheableResult`
(`ttlMs`/`cacheScope`), per-request `_meta` protocol version and capabilities, and
renumbered error codes.

The SDK stays dual-era: a request carrying `io.modelcontextprotocol/protocolVersion` in
`_meta` is served at 2026-07-28; anything else uses the legacy handshake.

## Multi round-trip requests (SEP-2322)

`tools/call`, `prompts/get` and `resources/read` handlers may return
`.inputRequired(requests, requestState:)`.
- Server (`serveRoundTrips` in Server.swift): seals and verifies `requestState` at stateless
  (`RequestStateBoundary`, AES-GCM, failure -32602). It rejects content + input (-32603) and
  undeclared capabilities (-32021). For handshake clients it bridges by sending the requests
  itself, up to 10 rounds.
- Client: `send(_:)` loops through `resolveInputRequests` with the registered
  sampling/elicitation/roots handlers (`Configuration.multiRoundTrip`).

## Tasks (SEP-1686, SEP-2663)

One model, two wire forms (`design/tasks.md`): v1 at 2025-11-25 (`task` param, `tasks/result`,
`tasks/list`) and v2, the `io.modelcontextprotocol/tasks` extension at 2026-07-28 (server
decides, outcome inlined in `tasks/get`, `tasks/update`). `Base/TaskTypes.swift` has the wire
types; `TaskSnapshot`'s internal `generation` picks the encoding.
- Server: `withTasks(manager)`; a `tools/call` handler returns `runAsTask { task in ... }`.
  `Server/TaskManager.swift`: `TaskManager` (work, limits, principal, input exchanges, ordered
  observers) over a `TaskStore`. `Server.taskRuntime` reads `execution.taskSupport` from the
  `tools/list` handler (`ToolInfo`, one pass per call) and refuses before the handler (-32601 v1, -32021
  v2). Capabilities are derived (`advertisedCapabilities`); `execution` is stripped except at
  2025-11-25. v1 `tasks/result` delivers input on its own stream with related-task `_meta`.
- Client: `Configuration.tasks` (`nil` = no tasks); `callTool` drives a task
  (`ClientTasks.swift`, `TaskHandle`); v1 augmentation from `toolTaskSupport`.
- Tests: `Tests/MCPTests/TaskTests.swift`; the default conformance leg's `tasks-*` scenarios;
  the interop `tasks` profile (Swift and TypeScript at 2025-11-25).

## Interop

`scripts/run-interop.sh [--update-results | --check]` runs the Swift, Go and Python SDKs' clients and
servers against each other (profiles basic, advanced, connect, session, tasks), in both eras, over
HTTP and stdio, and writes `.build/interop/report.md` (`--update-results` copies it to
`interop/RESULTS.md`; `--check` fails when the result rows differ from it, via
`interop/report.py --expect`). The other SDKs are pinned releases: `interop/go-client/go.mod`,
`interop/python-client/requirements.in` (hashed lock `requirements.txt`, example servers
checked against `examples.sha256`) and `interop/ts-client/package.json` (`npm ci` from
`package-lock.json`); no local checkouts. The TypeScript SDK (2025-11-25 only) runs the tasks
profile: `ts-client/client.mjs` and a task server, `ts-client/server.mjs`, on its SEP-1686
runtime. The drivers in `interop/{swift-client,go-client,python-client,ts-client}` take the same
flags and checks; keep them in step. Findings: `interop/README.md`.

## CI

One job list, two runners. `scripts/ci/jobs` lists every job as
`<id> <gate|advisory> <script> [args]`; `scripts/ci/<script>.sh` is the job (`build-test`,
`docs`, `conformance` (flags of run-conformance.sh), `interop`). `scripts/ci/run-jobs.sh
[--gate|--advisory] [--strict] [--timeout m] [id-regex...]` runs a selection and prints a
summary. Add or change a job there, not in a runner.

- **GitHub Actions** (`.github/workflows/ci.yml`): Linux jobs use
  `swift:6.1-rhel-ubi9` and `swift:6.1-noble`.
- **Desk**: `scripts/ci/run-jobs.sh` on macOS; `scripts/ci-linux.sh <job>|all|--shell` on Linux
  through Apple's `container` (`brew install container && container system start`).
  `scripts/ci/deps-linux.sh` installs Node, Go, uv and ps (dnf or apt) into a derived image;
  `/w/.build` is a named volume (`--build-volume`, `--seed-from`), the package caches a
  directory on the Mac; `--session` keeps a container up between runs, `--source` runs another
  worktree, `-- <command>` any command; results go to `.build/linux/<image>-<arch>/`
  (`.build/linux/<volume>/` with another `--build-volume`);
  `--job-timeout` (default 30 min) stops a hung job.

Linux and macOS pass the same jobs: baselines and `interop/RESULTS.md` are shared, and every
job gates on both (`advisory` exists for a known Linux-only failure; none today).
`HTTPClientTransport` has one code path: `ResponseBody` (`URLSession.bytes(for:)` on Apple
platforms, a `StreamingSessionDelegate` data task on swift-corelibs-foundation) and the
internal `ServerSentEventParser`. On Linux, `URLProtocol` mocks see
`httpAdditionalHeaders` because the SDK copies them into the request
(`addingAdditionalHeaders(of:)`), and a mock must not call its client after `stopLoading()`
(corelibs traps). What differs by design is in `design/linux.md`.

## Conformance fixtures

`conformance/everything-{client,server}` build `mcp-everything-client` and
`mcp-everything-server`. The server listens on port 3001 (`--port` to override) at
`/mcp`. These exist only to be driven by the harness; keep them faithful to the SDK's
real API rather than special-casing them to pass a scenario.
