# MCP Swift SDK design

This document records the design of the `MCP` Swift package and the reasons behind it. It covers
1.x, which adds the 2026-07-28 revision of the
[Model Context Protocol](https://modelcontextprotocol.io) next to the `initialize`-based revisions
(2025-11-25 and earlier). The base of 1.0.0 is `main` at `234e412` (the 0.12 line).

Feature notes go deeper on single topics:

| Note | Topic |
|---|---|
| [stateless.md](stateless.md) | `server/discover`, request classification, `StatelessHTTPServerTransport`, result annotation |
| [request_headers.md](request_headers.md) | SEP-2243 `Mcp-Method`, `Mcp-Name` and `Mcp-Param-*` headers |
| [subscriptions.md](subscriptions.md) | SEP-2575 `subscriptions/listen` |
| [mrtr.md](mrtr.md) | SEP-2322 multi round-trip requests and sealed `requestState` |
| [tasks.md](tasks.md) | Tasks at 2025-11-25 (SEP-1686) and the 2026-07-28 tasks extension (SEP-2663) |
| [skills.md](skills.md) | The skills extension (SEP-2640): frontmatter, catalogs, serving and verified loading |
| [server_cards.md](server_cards.md) | Server Cards (SEP-2127): the document, serving, fetching and checks |
| [apps.md](apps.md) | MCP Apps (SEP-1865): views, tool and resource metadata, the Content Security Policy |
| [auth.md](auth.md) | OAuth client architecture |
| [linux.md](linux.md) | Linux status and what differs there by design |
| [threat_model.md](threat_model.md) | Trust boundaries, defenses and their limits |

User-facing guides: [docs/README.md](../docs/README.md) (index), [docs/protocol.md](../docs/protocol.md),
[docs/server.md](../docs/server.md), [docs/client.md](../docs/client.md),
[docs/migration.md](../docs/migration.md).

Defaults:

- `Client.Configuration.protocolMode` is `.automatic`: `server/discover` at 2026-07-28, with a
  fallback to `initialize`.
- `Version.supported` lists both eras; `Version.latestHandshake`, the version `initialize` requests, is
  `2025-11-25`.
- `Server.Configuration.protocolVersions` defaults to `Version.stateless + Version.handshake`, so a
  server answers both eras.

## Goals

- **Complete.** Implement every client and server feature of each supported revision, measured
  by the conformance harness (see [conformance/README.md](../conformance/README.md)).
- **One code path for both eras.** A handler is written once. The SDK adapts the wire to the
  protocol version of each request.
- **Swift concurrency first.** Clients, servers and transports are actors. Handlers are `async`
  closures. Cancellation uses task cancellation.
- **Spec-shaped types.** Each JSON-RPC method is a Swift type whose parameters and result mirror
  the schema. Wire names stay visible (`_meta`, `ttlMs`, `inputRequests`).
- **Framework-agnostic HTTP.** Server transports take and return plain `HTTPRequest` and
  `HTTPResponse` values. No HTTP server framework is a dependency of the library.
- **Small dependency set.** See [DEPENDENCY_POLICY.md](../DEPENDENCY_POLICY.md).
- **Testable.** `InMemoryTransport` pairs a client and a server in one process. Wire behavior is
  pinned with golden JSON tests (`Tests/MCPTests/Helpers/WireExchange.swift`).

Non-goals:

- A tool registry or macro layer. The library dispatches on method names. Higher-level
  registration is left to applications.
- The 2024-11-05 HTTP+SSE transport. 2024-11-05 is negotiated over stdio and Streamable HTTP only.

## Package structure

### Products and targets

| Target | Kind | Path | Product |
|---|---|---|---|
| `MCP` | library | `Sources/MCP` | `MCP` |
| `MCPTests` | tests | `Tests/MCPTests` | none |
| `MCPConformanceServer` | executable | `conformance/everything-server` | `mcp-everything-server` |
| `MCPConformanceClient` | executable | `conformance/everything-client` | `mcp-everything-client` |
| `QuickStartSnippets`, `ServerSnippets`, `ClientSnippets`, `ProtocolSnippets`, `GuidesSnippets` | library targets | `Examples/Snippets/*` | none |
| `SnippetTests` | tests | `Examples/Tests` | none |
| `HelloServer`, `HelloClient`, `HTTPServerExample` | executables | `Examples/hello-server`, `Examples/hello-client`, `Examples/http-server` | none |

`Package.swift` uses swift-tools-version 6.1, the minimum Swift for 1.x.

The fixtures and examples build with the package, so `swift build` compiles every snippet that
`scripts/weave.swift` copies into `docs/`. None of them is a library product, so consumers of
`MCP` do not link them.

### Source layout

`MCP` is one module. Directories group files; they do not create namespaces.

| Directory | Contents |
|---|---|
| `Base/` | JSON-RPC envelope (`Messages.swift`), `Value`, `ID`, `MCPError`, `Version` and `ProtocolProfile`, `MetaKey`, `ResultType` and cache types, `ServerDiscover`, `SubscriptionsListen`, MRTR wire types, `Initialize` |
| `Base/Transports/` | `Transport` implementations: `StdioTransport`, `HTTPClientTransport`, `InMemoryTransport`, `NetworkTransport` (Network.framework), `MCPRequestHeaders` |
| `Base/Transports/HTTPServer/` | `StatefulHTTPServerTransport`, `StatelessHTTPServerTransport`, `HTTPRequest`/`HTTPResponse`, the validation pipeline (origin, accept, content type, protocol version, session, bearer token, protected resource metadata) |
| `Base/Authorization/` | OAuth 2.1 client: `OAuthAuthorizer` and its components |
| `Base/Utilities/` | Cancellation, progress, ping, `Metadata`, `RequestContext` |
| `Client/` | `Client` actor; client feature types (roots, sampling, elicitation) |
| `Server/` | `Server` actor; server feature method types (tools, resources, prompts, completion, logging); `StatelessRequests`; `RequestState` |

A method type lives with the side that serves it. `CallTool` is in `Server/Tools.swift` and
`CreateSamplingMessage` is in `Client/Sampling.swift`, though both sides use both.

### Fixtures, examples and scripts

- `conformance/everything-{server,client}`: the reference server and client that
  `@modelcontextprotocol/conformance` drives. They use only the public API.
- `conformance/baseline*.yml`: generated expected-failure lists, one per conformance leg.
- `Examples/`: compiled snippet regions (`// snippet: <name>` … `// endsnippet`) and three runnable
  programs. CI runs `HelloClient` against `HelloServer` over stdio.
- `scripts/run-conformance.sh`, `scripts/conformance-baseline.mjs`, `scripts/conformance-score.mjs`:
  the conformance workflow ([CONTRIBUTING.md](../CONTRIBUTING.md)).
- `scripts/weave.swift`: generates `docs/*.md` from `docs/src/*.src.md`.

## Concurrency model

### Actors

`Client`, `Server` and every transport are actors. `Transport` itself requires `Actor`.

- Mutable connection state (pending requests, handlers, negotiated version, listen streams) is
  actor-isolated. The compiler checks every access under strict concurrency.
- Handler closures are `@Sendable` and not actor-isolated. They run concurrently with each other
  and with the actor.
- Actor reentrancy is intended. `Server.handleRequest` awaits the handler task; meanwhile the
  actor processes other messages, including the client's response to a server-to-client request
  that the handler is waiting for.

Message dispatch:

| Side | Requests | Notifications | Responses |
|---|---|---|---|
| `Server` | one unstructured `Task` per request; stored in `pendingRequestTasks` for cancellation | handled in the receive loop, in order | resume the pending continuation |
| `Client` | one unstructured `Task` per request, at most `maxConcurrentServerRequests` at once (64 more wait, then -32603); a duplicate id gets -32600; at 2026-07-28 -32601; cancelled by `notifications/cancelled` | one at a time, in order, on an inbound queue outside the receive loop | at once, except after the queued progress notifications of the same request; never waiting for requests sent from a notification handler |

Client requests are registered (`ResponseSlot`) before `send(_:)` returns and handed to the
transport by a separate task, so a `cancelRequest` always finds them. A request cancelled before
that task runs is never sent, and no `notifications/cancelled` is sent for it. Cancelling the
task that awaits `RequestContext.value` cancels the request the same way.

Responses do not wait for notification handlers, so a handler may await any request. A request
that carries a progress token, while progress handlers are registered, is an exception: its
response is delivered after the progress notifications of that token already queued, so they
are handled before its result. The task-local `isHandlingNotification` marks requests sent from
a notification handler; their responses never wait, so such a handler cannot deadlock on its
own requests (their progress then arrives after the result). Log notifications are not ordered
with responses.

The client's own handling of `notifications/cancelled` and
`notifications/subscriptions/acknowledged` runs in the receive loop: it only updates client
state. Handlers registered for them run on the inbound queue like any other.

`OAuthAuthorizer` is a `final class` marked `@unchecked Sendable`. Concurrent requests reach it
from several tasks: its state is behind a lock, and challenges and proactive refreshes run one at
a time. One authorizer serves one resource.

### Handler context

```swift
@TaskLocal public static var currentHandlerContext: HandlerContext? = nil

public struct HandlerContext: Sendable {
    package let id: ID                         // JSON-RPC id seen by the server
    public let httpContext: HTTPRequest?
    public let protocolVersion: String?
    public let clientCapabilities: Client.Capabilities?
    public let clientInfo: Client.Info?
    public let logLevel: LogLevel?
    public let isStateless: Bool
    public var profile: ProtocolProfile? { get }
}
```

`Server.handleRequest` builds the context and starts the handler task inside
`Server.$currentHandlerContext.withValue(_:)`. For a handshake request the fields come from
`initialize`; for a stateless request they come from the request's `_meta`.

Why a task-local:

- The handler signature stays `(M.Parameters) async throws -> M.Result`. Per-request data was
  added in 1.0.0 without changing `withMethodHandler`.
- The SDK reads the same value: `Server.notify` and server-to-client requests pass
  `currentHandlerContext?.id` as `relatedRequestID`, `Server.log` gates on `logLevel`, the MRTR
  wrapper reads `isStateless` and `clientCapabilities`, and `RequestStateProtection.principal`
  receives the context.
- Child tasks created with `Task { }` inherit it. `Task.detached` does not; capture the value first.

`id` is `package`: the SDK uses it to route messages and to cancel requests. Under
`StatelessHTTPServerTransport` it is an internal id (`mcp-http-<uuid>`), not the client's id.

## Transports

### The `Transport` protocol

```swift
public protocol Transport: Actor {
    var logger: Logger { get }
    func connect() async throws
    func disconnect() async
    func send(_ data: Data) async throws
    func send(_ data: Data, relatedRequestID: ID?) async throws  // default calls send(_:)
    func receive() -> AsyncThrowingStream<Data, Swift.Error>
}
```

- A transport moves whole JSON-RPC messages as `Data`. Framing (newline-delimited stdio, HTTP
  bodies, SSE events) is the transport's job; parsing is the client's or server's job.
- `send(_:relatedRequestID:)` was added in 1.0.0 with a default implementation, so
  existing custom transports compile unchanged. Transports with per-request streams use the id
  to deliver progress, log and server-to-client messages on the stream of the request that
  produced them (SEP-1699 behavior at 2025-11-25).

### HTTP server transports

The server transports are not HTTP servers. An adapter in the application's HTTP framework
converts its request to `HTTPRequest` (method, headers, body, path), calls
`handleRequest(_:) async -> HTTPResponse`, and writes the response. `HTTPResponse.stream` carries
an SSE body as `AsyncThrowingStream<Data, Error>`. `conformance/everything-server/HTTPApp.swift`
and `Examples/http-server` are SwiftNIO adapters.

Both server transports conform to `HTTPContextProviding`:

```swift
public protocol HTTPContextProviding: Sendable {
    func httpRequestContext(for id: ID) async -> HTTPRequest?
}
```

`Server` asks for the `HTTPRequest` of each request id and puts it in
`HandlerContext.httpContext`. Handlers read headers and authentication data there.

| | `StatefulHTTPServerTransport` | `StatelessHTTPServerTransport` |
|---|---|---|
| Revisions | handshake (2025-11-25 and earlier) | 2026-07-28; also handshake requests without a session |
| HTTP methods | POST, GET (standalone SSE stream), DELETE (end session) | POST only; others 405 |
| Session | `Mcp-Session-Id`, one transport and one `Server` per session | none; one shared `Server` |
| Response | SSE stream per POST; priming event; replay with `Last-Event-ID` | one JSON body, or SSE when notifications precede the response and the client accepts `text/event-stream` |
| Request ids | client ids | rewritten to `mcp-http-<uuid>` per exchange, restored on the way out |
| Stateless request | 400, -32022, `data.supported` = handshake revisions | served |
| Error status | 200 (except validation) | 404 for -32601; 400 for -32600, -32602, -32020, -32021, -32022 |

Route requests with `HTTPRequest.statelessProtocolVersion`: a non-`nil` value is a
`MCP-Protocol-Version` header that names a revision outside `Version.handshake`. The -32022 answer
of the stateful transport lets a `.automatic` client fall back to `initialize`.

Request validation is a pipeline of `HTTPRequestValidator` values (`StandardValidationPipeline`).
Defaults: localhost `OriginValidator`, `AcceptHeaderValidator`, `ContentTypeValidator`,
`ProtocolVersionValidator`, and on the stateful transport `SessionValidator`. Applications add
`BearerTokenValidator` and `ProtectedResourceMetadataValidator` for authorization.

### HTTP client transport

`HTTPClientTransport` serves both eras:

- `MCP-Protocol-Version` comes from the outgoing message's
  `_meta["io.modelcontextprotocol/protocolVersion"]` when present, otherwise from the negotiated
  version.
- `useStatelessProtocol(_:)` drops the session id and the GET stream. `Client` calls it after a
  successful `server/discover`.
- When the version's profile has `usesStandardHeaders`, every POST carries `Mcp-Method` and, for
  `tools/call`, `prompts/get` and `resources/read`, `Mcp-Name`.
- `send(_:additionalHeaders:)` carries `Mcp-Param-*` headers.
- Each POST of a message with a JSON-RPC id runs in a task keyed by that id. `cancelRequest(_:)`
  cancels it, which closes the response stream. At 2026-07-28 this is how a request is cancelled.
- A non-2xx reply with a JSON-RPC response body is delivered as a response, so the client sees
  the -32020/-32022 error instead of an HTTP error.

`Client` hands the `Mcp-Param-*` headers to any transport through the `Transport` requirement
`send(_:additionalHeaders:)`, whose default ignores them. It reaches the other features by
downcasting its transport to `HTTPClientTransport`, so a custom HTTP client transport does not
get abort-based cancellation.

## JSON-RPC types

### Methods, requests and responses

```swift
public protocol Method: Sendable {
    associatedtype Parameters: Codable, Hashable, Sendable = Empty
    associatedtype Result: Codable, Hashable, Sendable = Empty
    static var name: String { get }
}

public struct Request<M: Method>: Hashable, Identifiable, Codable, Sendable {
    public let id: ID
    public let method: String
    public let params: M.Parameters
    public var _meta: Metadata?
}

public struct Response<M: Method>: Hashable, Identifiable, Codable, Sendable {
    public let id: ID
    public let result: Swift.Result<M.Result, MCPError>
}
```

- A new MCP method is a new `Method` type. The envelope types do not change.
- `M.request(_:_meta:)` and `M.response(id:result:)` build envelopes. Parameters that conform to
  `NotRequired` decode from a missing `params`.
- Notifications are `Notification` types sent as `Message<N>`, with the same `_meta` support.
- `ID` is a string or an integer. `ID.random` is the default for new requests.

Type erasure: `AnyMethod` has `Value` parameters and result. `AnyRequest`, `AnyResponse` and
`AnyMessage` are the erased envelopes. `TypedRequestHandler<M>` re-encodes an `AnyRequest` and
decodes it as `Request<M>`. A decode failure becomes -32602 `Invalid params for <method>`. The
round trip through JSON costs time; it keeps the handler table a plain `[String: RequestHandlerBox]`.

Batches: the server accepts JSON-RPC batch arrays and answers with one array. The client sends
batches with `withBatch(body:)`.

### `Value`

`Value` is the dynamic JSON type: `null`, `bool`, `int`, `double`, `string`, `data`, `array`,
`object`. It is used for tool arguments, schemas, error data, capability extensions and `_meta`
fields. It has literal conformances, so `["type": "object"]` is a `Value`.

Decoding tries `Bool`, then `Int`, then `Double`, then `String`. A string that is a `data:` URL
decodes as `.data(mimeType:_:)`, which encodes as a base64 `data:` URL: `data:,hi` comes back as
`data:text/plain;base64,aGk=`. The SDK's own hops through `Value` (the client and server message
decoders, batch items, type-erased requests and responses, handler results, `_meta` accessors,
error data) decode with `userInfo[.valuePreservesStrings]` or `Value.preservingStrings`, so a
`data:` string is forwarded as written. The typed decode before a handler runs is a plain
decode: a handler still sees `.data` in a `Value` field, such as a tool argument.

### `_meta`

`Metadata` wraps `fields: [String: Value]`. Typed accessors read the reserved keys:

| `MetaKey` | Wire key | Accessor |
|---|---|---|
| `protocolVersion` | `io.modelcontextprotocol/protocolVersion` | `Metadata.protocolVersion: String?` |
| `clientCapabilities` | `io.modelcontextprotocol/clientCapabilities` | `Metadata.clientCapabilities` |
| `clientInfo` | `io.modelcontextprotocol/clientInfo` | `Metadata.clientInfo` |
| `logLevel` | `io.modelcontextprotocol/logLevel` | `Metadata.logLevel` |
| `serverInfo` | `io.modelcontextprotocol/serverInfo` | `Metadata.serverInfo` |
| `subscriptionID` | `io.modelcontextprotocol/subscriptionId` | `Metadata.subscriptionID: ID?` |

`progressToken` has its own accessor. Invalid or absent values read as `nil`.

Merging rule: `Request._meta` and `Message._meta` are envelope-level. On encode they are merged
into `params._meta`. When the parameters encode their own `_meta` (for example
`CallTool.Parameters(meta:)`), keys from the parameters win. On decode, `_meta` is read back from
`params._meta`. Parameters with `_meta` must encode as a JSON object; otherwise encoding throws.

The envelope field exists so that the client can stamp the stateless envelope on any request
without knowing each parameter type. `Client` builds the envelope with `requestMeta`, and keys the
caller already set win there too.

## The dual-era model

### Versions and profiles

`Sources/MCP/Base/Versioning.swift` is the single source of truth:

| Symbol | Value |
|---|---|
| `Version.handshake` | `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05` (newest first) |
| `Version.stateless` | `2026-07-28` |
| `Version.supported` | `Set(handshake + stateless)` |
| `Version.latestHandshake` | `2025-11-25` |
| `Version.profile(for:)` | the `ProtocolProfile` of a version |

`ProtocolProfile` turns a version string into feature flags:

| Flag | Stateless (≥ 2026-07-28) | Handshake |
|---|---|---|
| `usesInitializeHandshake` | false | true |
| `usesRequestMeta` | true | false |
| `usesResultType` | true | false |
| `usesSessions` | false | true |
| `allowsServerRequests` | false | true |
| `usesSubscriptionsListen` | true | false |
| `usesStandardHeaders` | true | false |
| `allowsPrimingEvents` | false | true from 2025-03-26 |

Versions compare as `YYYY-MM-DD` strings, so an unknown future version gets the profile of the
newest known revision before it. Code that differs per revision reads a flag. It does not compare
version strings.

### Classification

`StatelessRequests.classify(_:served:)` decides the era of every request from its `_meta`, checking
the rows in this order:

| `_meta` | Result |
|---|---|
| no `protocolVersion` | handshake |
| `protocolVersion` not a non-empty string | -32602 |
| `protocolVersion` not in `Server.Configuration.protocolVersions` | -32022 with `data.supported` and `data.requested` |
| `protocolVersion` in `Version.handshake` | handshake |
| other version, `clientCapabilities` missing or invalid | -32602 |
| other version, `clientInfo` present but invalid | -32602 |
| other version | stateless |

The version is checked before the other `_meta` members: a request for a version the server does
not serve gets -32022 even when its capabilities are missing.

What changes for a stateless request is listed in [stateless.md](stateless.md): removed methods,
the capability gate, per-request client fields, log gating, result annotation, the server
request guard and the MRTR boundary.

### Why one `Server` serves both eras

- **Handlers are era-independent.** Tool, prompt and resource logic is the same. The SDK changes
  the envelope (`resultType`, `serverInfo`, cache hints), the delivery of notifications (listen
  streams), and how input is requested (bridge or `inputRequired`).
- **The era is a property of a request.** 2026-07-28 removed the session, so nothing ties a
  request to a connection. One server instance on stdio can receive both kinds of request.
- **Deployment.** Over HTTP, one shared `Server` on a `StatelessHTTPServerTransport` serves all
  stateless traffic, and session clients keep one `Server` per session. The handler registration
  code is shared.

The client chooses its era once per connection with `Client.ProtocolMode`:

| Mode | Behavior |
|---|---|
| `.handshake` | `initialize` |
| `.automatic` (default) | `server/discover` at `Version.stateless[0]`; retry once on -32022 with a stateless version from `data.supported`; fall back to `initialize` on other JSON-RPC errors, an HTTP 400/404/405 refusal, no answer within `discoveryTimeout`, when the discover result lists no stateless revision, or on a -32022 whose `data.supported` is empty or lists a handshake revision; rethrow other transport errors |
| `.stateless(v)` | `server/discover` at `v`; no retry, no fallback |

`connect(transport:)` returns a `Client.ConnectionInfo` in every mode: `protocolVersion`,
`capabilities`, `serverInfo`, `instructions` and `isStateless`. After `server/discover` the client
builds it from the discover result, so callers that read `capabilities` work in both eras;
`serverInfo` is optional, `nil` when the server sends no `io.modelcontextprotocol/serverInfo`.

## Error model

`MCPError` is the only error type on the wire. Handlers may throw any error; the server maps
non-`MCPError` errors to -32603 with the error's `localizedDescription`. `CancellationError` sends
no response.

| Case | Code | `data` |
|---|---|---|
| `parseError(String?)` | -32700 | `{detail}` when set |
| `invalidRequest(String?)` | -32600 | `{detail}` |
| `methodNotFound(String?)` | -32601 | `{detail}` |
| `invalidParams(String?)` | -32602 | `{detail}` |
| `internalError(String?)` | -32603 | `{detail}` |
| `serverError(code:message:data:)` | any | `data` as given |
| `resourceNotFound(uri:message:)` | -32602 | `{uri}` (SEP-2164) |
| `headerMismatch(String?)` | -32020 | `{detail}` |
| `missingRequiredClientCapabilities(_:message:)` | -32021 | `{requiredCapabilities}` |
| `unsupportedProtocolVersion(supported:requested:)` | -32022 | `{supported, requested?}` |
| `urlElicitationRequired(message:elicitations:)` | -32042 | `{elicitations}` |
| `connectionClosed` | -32000 | none |
| `transportError(Error)` | -32001 | `{error}` |

Decoding rules:

- Standard cases read `data.detail`, else the message.
- -32602 with `data.uri` and no `data.detail` decodes as `resourceNotFound`. So does -32002 with
  `data.uri`, the code earlier servers used.
- -32042 without a `data.elicitations` array decodes as `serverError` and keeps its `data`.
- -32000 and -32001 are local transport conditions in this SDK. From the wire they decode as
  `serverError`, because servers use those codes for their own errors.
- Unknown codes decode as `serverError` and keep `data`.

Tool failures that the model should see are results, not errors: `CallTool.Result(isError: true)`.
Protocol errors are for the client program.

Over stateless HTTP the transport maps error codes to HTTP status (table in
[Transports](#http-server-transports)). `HTTPClientTransport` turns such replies back into JSON-RPC
responses.

## Handler registration

```swift
await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: [Tool(name: "greet", description: "Greets", inputSchema: ["type": "object"])])
}
await server.onNotification(RootsListChangedNotification.self) { _ in }
```

- `withMethodHandler(_:handler:)` stores one handler per method name. A second registration
  replaces the first. It returns `Self` for chaining.
- `onNotification(_:handler:)` appends. Every handler for a method runs, in order. Errors are
  logged.
- `start(transport:initializeHook:statelessRequestHook:)` registers the built-in handlers for
  `initialize`, `ping`, `subscriptions/listen` and `server/discover`. They replace handlers
  registered for those methods before `start`.
- For `tools/call`, `prompts/get` and `resources/read`, `withMethodHandler` wraps the handler in
  the MRTR boundary ([mrtr.md](mrtr.md)).
- The client registers handlers for server-to-client requests the same way:
  `withSamplingHandler`, `withElicitationHandler`, `withRootsHandler` are shorthands for
  `withMethodHandler`. The MRTR client loop uses the same handlers.
- A client's list-changed `onNotification` registration can open a listen stream at 2026-07-28
  ([subscriptions.md](subscriptions.md)).

Registration is by method, not by tool. There is no tool registry, so a feature that needs a
tool's schema asks the application's `tools/list` handler. `Mcp-Param-*` validation does this
([request_headers.md](request_headers.md)).

## Breaking changes in 1.0.0

Each change and the reason for it. [docs/migration.md](../docs/migration.md) has before/after code.

| Change | Reason |
|---|---|
| `MCPError` gains `resourceNotFound`, `headerMismatch`, `missingRequiredClientCapabilities`, `unsupportedProtocolVersion`; `serverError` gains `data:` | 2026-07-28 renumbers errors and puts machine-readable details in `data`. Typed cases let the client react to -32022 and -32021 without parsing messages. Adding cases breaks exhaustive `switch` statements. |
| `MCPError.data` | Errors must round-trip their `data`. |
| -32000/-32001 from the wire decode as `serverError` | They were decoded as local `connectionClosed`/`transportError`, which hid server errors. |
| Undecodable params answer -32602, not -32603 | The spec code for bad parameters. |
| `Client.Capabilities.experimental` is `[String: Value]?` (was `[String: String]?`); `Server.Capabilities` gains `experimental`; both gain `extensions` | The schema allows arbitrary objects; SEP-2133 adds `extensions`. |
| `Version.latestHandshake` is explicit; `Version.supported` lists both eras | `supported.max()` would make 2026-07-28 the `initialize` version. |
| `Client.Configuration.protocolMode` defaults to `.automatic` | Clients reach 2026-07-28 servers without configuration and fall back to `initialize` for older ones. |
| `Server.Configuration` gains `protocolVersions`, `cacheHints`, `defaultCacheHint` | Per-server control of the served revisions and SEP-2549 hints. |
| `Server.init` gains `requestStateProtection:`, default `.ephemeral()` | `requestState` is client-held input; sealing is on by default ([mrtr.md](mrtr.md)). |
| `CallTool`, `GetPrompt`, `ReadResource` parameters and results gain MRTR fields; results have custom `Codable` | SEP-2322. An input-required result encodes without content. |
| List and read results conform to `CacheableResult` (`ttlMs`, `cacheScope`) | SEP-2549. |
| `Transport.send(_:relatedRequestID:)` | Per-request streams. Defaulted, so custom transports compile. |
| `Request._meta`, `Message._meta`; `Message.init(method:params:_meta:)` | The stateless envelope on any request. |
| `Client.Configuration` gains `protocolMode`, `logLevel`, `multiRoundTrip` | 2026-07-28 client. All defaulted. |
| List-changed and resource-updated notifications are not sent on a connection without `initialize` | At 2026-07-28 they go only to listen streams. |
| The stateful HTTP transport answers 2026-07-28 requests with 400 -32022 | Lets `.automatic` clients fall back. |
| OAuth: authorization server metadata whose `issuer` differs from the candidate is rejected; new `OAuthAuthorizationError` codes; DCR sends `application_type` | RFC 8414 §3.3, RFC 9207, SEP-2468, SEP-837 ([auth.md](auth.md)). |
| `OAuthAuthorizationError`, `GrantType`, `TokenEndpointAuthentication`, `PrivateKeyJWTSigningAlgorithm`, `BearerTokenValidationResult`, `Elicitation.Mode`, `ToolChoice.Mode` become structs | Their sets grew during 0.x or have registries; as structs, 1.x minors can add values. Static members keep construction and catch patterns compiling. The policy is in `VERSIONING.md` (Enums and open types). |
| Content blocks, `InputRequest`, `InputResponse`, `CreateElicitation.Parameters` gain `.unknown`; `MCPError.Code` | A peer on a later revision sent a block or request the SDK could not decode, and the whole result failed. Users match these with associated values, so they stay enums, frozen apart from the catch-all. |
| `HTTPClientTransport` throws `transportError(HTTPStatusError)` and `transportError(OAuthAuthorizationError)` | Callers matched message strings to tell a session expiry from a rate limit, and could not read the OAuth error at all. |
| `Client` convenience methods return result types; `startToolCall` replaces the `RequestContext` overload of `callTool`; `Client.initialize()` is removed | Tuples dropped `structuredContent`, `_meta` and the cache hints, and two `callTool` overloads differed only in return type. |
| `Client.connect(transport:)` returns `Client.ConnectionInfo`, with an optional `serverInfo` | At 2026-07-28 `serverInfo` is optional; the client used to invent an empty one. |
| `Version.latest` is renamed `Version.latestHandshake` | It is the newest revision `initialize` requests, not the newest supported one. |
| `Tool.Content` cases have defaults for `annotations` and `_meta`; the deprecated short forms are removed | One spelling per block. |
| `Server.start(transport:)` keeps handlers registered before it; built-in `logging/setLevel` | `start` replaced the application's handlers, and a server with `logging` answered -32601. |
| Swift 6.1 tools; `Package@swift-6.0.swift` is removed | No CI job used Swift 6.0, and the 2026-07-28 work no longer compiled with it. |

Layout changes that do not affect the API: fixtures moved from `Sources/MCPConformance` to
`conformance/everything-*`, and baselines from `conformance-baseline*.yml` to
`conformance/baseline*.yml`.

## Alternatives considered

Decided during the 1.0 work, from the change history and the comparison with the Python
and Go SDKs:

- **Version string comparisons at call sites.** Replaced by `ProtocolProfile` flags, so a new
  revision changes one initializer.
- **`Version.latestHandshake = supported.max()`.** The base code did this. It would have switched every
  `initialize` to 2026-07-28 when that revision was added to `supported`. `latest` is now a
  constant, and stateless revisions live in their own list.
- **Extending the task-local instead of the handler signature.** `HandlerContext` already carried
  `httpContext`; the per-request protocol fields were added there, so `withMethodHandler` did not
  change.
- **A union result type for input-required results**, as in the Python SDK. Rejected because
  `Method.Result` is one associated type ([mrtr.md](mrtr.md)).
- **Answering -32603 to handshake clients for input-required results**, as the Python SDK does.
  Rejected in favor of the Go SDK's bridge ([mrtr.md](mrtr.md)).
- **Leaving `requestState` unsealed by default.** Rejected ([mrtr.md](mrtr.md)).
- **Honoring every requested listen kind**, as the Python SDK does. Rejected
  ([subscriptions.md](subscriptions.md)).
- **Accepting AS metadata with another issuer.** The base code did; removed ([auth.md](auth.md)).

Implied by the design, not recorded as separate decisions:

- **Separate server types per era.** Handlers would be registered twice, and a stdio server would
  need to know the era before the first request.
- **Message-typed transports** (`send(_ message:)`), as in the Go SDK. `Transport` moves `Data`,
  so HTTP transports probe messages with small decoders (`JSONRPCMessageKind`,
  `JSONRPCMessageFields`).

## Open questions

- A slow notification handler delays later notifications and the responses queued behind
  them. Running notification handlers concurrently, as the Python SDK does, would lose the
  ordering of progress before results.
- `Client` hands the `Mcp-Param-*` headers to any transport through
  `Transport.send(_:additionalHeaders:)`, but still downcasts to `HTTPClientTransport` to cancel
  a request at 2026-07-28, to pass on the negotiated or discovered protocol version, and to
  extend a request's timeout while a sign-in runs. A transport capability protocol would let
  custom transports opt in.
- The type-erasure round trip through JSON on every request could be replaced by direct
  decoding from the received bytes.
