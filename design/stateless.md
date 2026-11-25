# Stateless requests (2026-07-28)

## Context

Protocol 2026-07-28 removes the connection lifecycle. There is no `initialize`, no
`notifications/initialized`, no `Mcp-Session-Id`, no `ping`, no `logging/setLevel`, no
`resources/subscribe`/`unsubscribe`, no standalone GET stream, no `Last-Event-ID` resumption and no
server-to-client request. Each request carries its protocol version, client capabilities,
optional client info and optional log level in `params._meta`. Clients learn about a server with
`server/discover`. Every result carries `resultType`, and cacheable results carry `ttlMs` and
`cacheScope` (SEP-2549).

The SDK must serve these requests and keep serving 2025-11-25 and earlier clients. The general
model is in [design.md](design.md#the-dual-era-model). This note covers the server side and
discovery.

## Goals

- One `Server` and one set of handlers for both eras.
- No per-connection state for stateless requests.
- Reject malformed or unsupported requests before a handler runs, with the 2026-07-28 codes.
- Add the members every stateless result needs without handler code.
- An HTTP transport that serves concurrent stateless clients behind one endpoint.

## Design

### `server/discover`

```swift
public enum ServerDiscover: Method {
    public static let name = "server/discover"
    public struct Result: Hashable, Codable, Sendable, CacheableResult {
        public let supportedVersions: [String]
        public let capabilities: Server.Capabilities
        public let instructions: String?
        public var _meta: Metadata?          // serverInfo
        public var ttlMs: Int?
        public var cacheScope: CacheScope?
    }
}
```

`Server.start(transport:)` registers the handler. It answers with
`Server.Configuration.protocolVersions` (both eras, in configured order), the current
`capabilities` and `instructions`. Annotation adds `serverInfo` and cache hints.
`server/discover` and `subscriptions/listen` are stateless-only: a handshake request for them
gets -32601.

Client side (`Client.discoverOrInitialize`):

1. Send `server/discover` with the stateless `_meta` envelope at the preferred version.
2. Success: use the requested version if `supportedVersions` lists it. Otherwise `.automatic`
   uses the first listed version in `Version.stateless`, or falls back to `initialize` when there
   is none; `.stateless(v)` throws -32022.
3. -32022: `.automatic` retries once with the first version in `data.supported` that is in
   `Version.stateless`, even when that version equals the requested one, then falls back to
   `initialize` when `data.supported` is empty or lists a handshake revision. `.stateless(v)`
   throws the error.
4. With `.automatic`, any other JSON-RPC error from the server, an HTTP 400/404/405 refusal
   without a JSON-RPC error for the request (`HTTPClientTransport.isSessionlessRefusal`), or no
   answer within `Configuration.discoveryTimeout`: fall back to `initialize`. The client tells
   transport errors from the server's answer by wrapping send failures (`SendFailure`); other
   transport errors propagate.
5. `adopt` records capabilities, version, `serverInfo` (from `_meta`, `nil` when absent) and
   instructions, and calls `HTTPClientTransport.useStatelessProtocol(_:)`; `connect(transport:)`
   returns that state as a `Client.ConnectionInfo`.

On a stateless connection `ping()` sends `server/discover`, `setLoggingLevel(_:)` changes the
level stamped into `_meta`, and `notifyRootsChanged()` does nothing.

### Classification and dispatch

`Server.handleRequest` runs these steps in order:

| Step | Handshake request | Stateless request |
|---|---|---|
| 1. `classify(_meta, served:)` | no version, or a handshake version | other version: -32602 for invalid `_meta`, -32022 if not served |
| 2. Method gate | `server/discover`, `subscriptions/listen` → -32601 | `initialize`, `ping`, `logging/setLevel`, `resources/subscribe`, `resources/unsubscribe` → -32601 |
| 3. Lifecycle | `strict`: requests other than `initialize`/`ping` need `initialize` (-32600) | none; `strict` does not apply |
| 4. Capability gate | none | `tools/*`, `prompts/*`, `resources/*`, `completion/complete` need the capability → -32601 |
| 5. Handler lookup | -32601 `Unknown method` | same |
| 6. `HandlerContext` | fields from `initialize` | fields from `_meta`; `isStateless = true` |
| 7. Header check | none | `tools/call` over HTTP: `Mcp-Param-*` ([request_headers.md](request_headers.md)) |
| 8. Handler | runs | runs; `tools/list` drops tools with invalid `x-mcp-header` annotations |
| 9. Annotation | none | `StatelessRequests.annotate` on success |

Per-request behavior inside a stateless handler:

- `Server.log` sends a notification only when the request set `logLevel` and the message is at or
  above it. `LogLevel` is `Comparable`.
- Server-to-client requests (`requestSampling`, `requestElicitation`, `listRoots`) throw -32600:
  the profile has `allowsServerRequests == false`. Handlers return input-required results instead
  ([mrtr.md](mrtr.md)).
- `Server.notify` of a list-changed or resource-updated notification publishes to listen streams.
  It writes to the connection only when the server has completed `initialize`
  ([subscriptions.md](subscriptions.md)).
- Progress and other notifications are sent with `relatedRequestID`, so they reach the request's
  response stream.

### `StatelessHTTPServerTransport`

POST handling, in order:

1. Empty body or unclassifiable JSON-RPC: 400 -32700.
2. Validation pipeline. Defaults: `OriginValidator.localhost()`,
   `AcceptHeaderValidator(mode: .jsonOnly)`, `ContentTypeValidator()`, `ProtocolVersionValidator()`
   (accepts `Version.stateless + Version.handshake`; unknown → 400 -32022).
3. `Mcp-Method` and `Mcp-Name` against the body, for requests and notifications at a version
   with `usesStandardHeaders`: 400 -32020. The body is parsed once and re-serialized; the checks
   and the server see that one form ([request_headers.md](request_headers.md)).
4. Notifications and responses: yielded to the server, 202. A `notifications/cancelled` is
   honored only when it names, by id value, exactly one request in flight with the same
   `Authorization` header: it is rewritten to that request's internal id, and the exchange is
   forgotten and ends without a JSON-RPC response (202 when no reply was sent yet, otherwise the
   SSE stream ends). Otherwise it is dropped.
5. Requests: `MCP-Protocol-Version` against `_meta`. Stateless header without `_meta` version:
   -32602. Different versions, or a stateless `_meta` version without a matching header: -32020.
6. The request id is replaced with `mcp-http-<uuid>` and the request is yielded to the server.

Responses:

- The exchange waits for messages for the internal id. The first message that is a response
  produces a JSON body with the client's id restored.
- If a related notification or request arrives first and the client accepts
  `text/event-stream`, the response becomes an SSE stream. It carries those messages and ends
  with the response. Without SSE in `Accept`, those messages are dropped.
- Messages with no in-flight request are dropped: there is no stream outside a request.
- `_meta["io.modelcontextprotocol/subscriptionId"]` equal to the internal id is rewritten to the
  client's id in `params` and `result`.
- JSON errors on stateless requests get HTTP status: 404 for -32601; 400 for -32600, -32602,
  -32020, -32021, -32022; 200 otherwise. On handshake requests only -32022 maps to 400.
- If the SSE consumer goes away (`onTermination(.cancelled)`), the transport yields
  `notifications/cancelled` for the internal id, which cancels the handler task.
- If the transport terminates before a response: 503 with -32000, or the SSE stream ends with an
  error.

Why rewrite ids: without sessions, two clients may send the same id at the same time. The
`Server` keys pending tasks and cancellation by id, so the transport makes them unique. The
`HandlerContext.id` is therefore the internal id, and `HTTPContextProviding` is keyed by it.

### Result annotation

`StatelessRequests.annotate(_:method:serverInfo:cacheHint:)` works on the encoded result `Value`:

- `resultType`: set to `"complete"` when absent. Input-required results already carry
  `"input_required"`.
- `_meta["io.modelcontextprotocol/serverInfo"]`: set from `Server.Info` when absent.
- Cache hints, only for `tools/list`, `prompts/list`, `resources/list`,
  `resources/templates/list`, `resources/read` and `server/discover`, and only when `resultType`
  is `"complete"`: `ttlMs = max(0, hint.ttlMs)` and `cacheScope = hint.scope`, each when absent.
- The hint is `Server.Configuration.cacheHints[method] ?? defaultCacheHint`. The default is
  `CacheHint.uncached` (`ttlMs: 0`, `.private`).

A handler that sets `ttlMs` or `cacheScope` on its result wins. For handshake requests nothing is
added, and `nil` hints are omitted from the encoding.

```swift
let server = Server(
    name: "catalog", version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: true)),
    configuration: .init(cacheHints: ["tools/list": CacheHint(ttlMs: 60_000, scope: .public)]))
```

## Alternatives considered

- **A separate `StatelessServer` type.** Rejected: handlers would be duplicated, and a stdio
  server cannot know the era before the first request.
- **Ignoring the `_meta` version on unknown revisions.** Rejected: an unknown version is served
  only if configured, else -32022 tells the client what to use.
- **Requiring unique ids from clients.** Not possible without sessions. The transport rewrites
  them per exchange.
- **Annotation inside each result type.** It would need the request's era at encode time, which
  `Codable` does not have. The Go SDK has the same constraint. Annotation runs on the encoded
  `Value` after the handler; only the MRTR carriers model `resultType` in the type, because the
  handler chooses it.
- **Serving stateless requests on `StatefulHTTPServerTransport`.** Rejected: session routing and
  the GET stream do not apply. It answers 400 -32022 listing handshake versions, so
  `.automatic` clients fall back.
- **A non-zero default cache hint.** Rejected: the SDK cannot know when a list changes.
  `uncached` is always correct.

## Open questions

- `Client` ignores `ttlMs` and `cacheScope`. It does not cache list results.
- A sessionless handshake request on a shared stateless `Server` can call `initialize`. That sets
  server-wide state (`clientInfo`, `protocolVersion`, initialized flag) seen by other handshake
  requests on the same server. The documented routing sends handshake traffic to the stateful
  transport, which avoids this.
- `ProtocolVersionValidator` on the stateless transport accepts every known revision regardless
  of `Server.Configuration.protocolVersions`; the server returns -32022 later, with the
  configured list.
- The capability gate covers the core features only. Other methods, including extension
  methods, are always allowed.
