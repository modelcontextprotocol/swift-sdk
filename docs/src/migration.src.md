# Migration guide

This guide lists every public API change between the previous release
(commit `2a44bfd`) and this major version: the changes that break source
code, the changes in behavior and on the wire, and the new opt-in features.
Most code compiles unchanged; the breaking changes are in `MCPError`,
`HTTPResponse`, `Client.Capabilities.experimental` and
`OAuthAuthorizationError`.

## Summary

| Area | Change | Action |
|---|---|---|
| `MCPError` | New cases; `serverError` has a third associated value | Update exhaustive `switch` statements and `serverError` patterns |
| `MCPError` decoding | -32000 and -32001 decode as `serverError`; -32602 with `data.uri` as `resourceNotFound` | Match the new cases |
| `HTTPResponse` | `.data` and `.error` have new associated values | Update patterns |
| `Client.Capabilities.experimental` | `[String: String]?` became `[String: Value]?` | Pass `Value`s |
| `OAuthAuthorizationError` | Two new cases | Update exhaustive `switch` statements |
| `Server` | Serves 2026-07-28 requests by default | Nothing, or opt out |
| `Client` | Connects at 2026-07-28 by default, with a fallback to `initialize` | Nothing, or opt out |
| `Version.supported` | Lists 2026-07-28 | Read `Version.handshake` for the `initialize` revisions |
| Handlers | Undecodable parameters fail with -32602, not -32603 | Update tests that check the code |
| HTTP transports | New error bodies, status codes and streaming | See below |
| `HTTPClientTransport` | Default per-host connection limit 64; POST streams resume per stream | Raise `httpMaximumConnectionsPerHost` in custom configurations |
| Package | Depends on swift-crypto | Resolve packages again |

## Breaking changes

### `MCPError` cases

`MCPError` has four new cases, and `serverError` carries the error's `data`:

| Case | Code | `data` |
|---|---|---|
| `serverError(code:message:data:)` | any other code | as sent |
| `resourceNotFound(uri:message:)` | -32602 | `{"uri": ...}` |
| `headerMismatch(_:)` | -32020 | `{"detail": ...}` |
| `missingRequiredClientCapabilities(_:message:)` | -32021 | `{"requiredCapabilities": ...}` |
| `unsupportedProtocolVersion(supported:requested:)` | -32022 | `{"supported": [...], "requested": ...}` |

`data` has a default, so `MCPError.serverError(code:message:)` still compiles.
Patterns and exhaustive `switch` statements do not.

Before:

```swift
switch error {
case .serverError(let code, let message):
    return "\(code) \(message)"
case .parseError, .invalidRequest, .methodNotFound, .invalidParams, .internalError,
    .urlElicitationRequired, .connectionClosed, .transportError:
    return error.localizedDescription
}
```

After:

%include Examples/Snippets/Guides/Migration.swift migration-error-switch

`MCPError.data` returns the `data` member for every case. A server can now
send structured data with an implementation-defined code:

%include Examples/Snippets/Guides/Migration.swift migration-error-data

### `MCPError` decoding

Decoding an error response changed for these codes:

| Code | Previous release | This release |
|---|---|---|
| -32000 | `connectionClosed` | `serverError(code: -32000, message:data:)` |
| -32001 | `transportError(_:)` with an `NSError` | `serverError(code: -32001, message:data:)` |
| -32602 with `data.uri` and no `data.detail` | `invalidParams(_:)` | `resourceNotFound(uri:message:)` |
| -32002 with `data.uri` | `serverError` | `resourceNotFound(uri:message:)` |
| -32020, -32021, -32022 | `serverError` | the new cases |

`connectionClosed` and `transportError` are local errors only: transports
throw them, and they are never decoded from the wire.

`serverError` and `urlElicitationRequired` now encode their message as given.
The previous release sent `serverError` messages as
`"Server error: <message>"`, which decoding then prefixed again.

### `HTTPResponse`

`.data` gained a status code, and `.error` gained the JSON-RPC id of the
rejected request. Both new values have defaults, so construction compiles
unchanged.

Before:

```swift
switch response {
case .data(let data, _):
    return data
case .error(let statusCode, let error, _, _):
    return Data("\(statusCode) \(error.code)".utf8)
default:
    return response.bodyData
}
```

After:

%include Examples/Snippets/Guides/Migration.swift migration-http-response

`HTTPResponse.withRequestID(_:)` sets the id of an error response that has
none.

### `Client.Capabilities.experimental`

`experimental` takes JSON values, as `Server.Capabilities.experimental` does.
Both capability structs also gained `extensions` (SEP-2133).

Before:

```swift
let capabilities = Client.Capabilities(experimental: ["com.example/feature": "enabled"])
```

After:

%include Examples/Snippets/Guides/Migration.swift migration-experimental

A string literal is still a valid `Value`, so dictionary literals of strings
compile; variables of type `[String: String]` do not.

### `OAuthAuthorizationError`

Two cases are new: `authorizationResponseIssuerMismatch(expected:actual:)` and
`authorizationResponseMissingIssuer`. Add them, or a `default`, to exhaustive
`switch` statements. See [Authorization](#authorization).

## Behavior changes

### Saved configurations

`Server.Configuration` gained `protocolVersions`, `cacheHints` and
`defaultCacheHint`; `Client.Configuration` gained `protocolMode`, `logLevel`,
`discoveryTimeout` and `multiRoundTrip`. A missing key decodes to the default
of its initializer parameter, so JSON encoded by the previous release,
`{"strict":true}`, still decodes.

### Servers serve 2026-07-28

`Server.Configuration.protocolVersions` defaults to
`Version.stateless + Version.handshake`. A request whose `_meta` carries
`io.modelcontextprotocol/protocolVersion: "2026-07-28"` is served statelessly,
and `server/discover` and `subscriptions/listen` are answered by the server.
Requests without that key are served as before. To keep the previous behavior:

%include Examples/Snippets/Guides/Migration.swift migration-handshake-only

See [protocol_versions.md](protocol_versions.md) for what changes per request.

### Clients connect at 2026-07-28

`Client.Configuration.protocolMode` defaults to `.automatic`. `connect`
sends `server/discover` at 2026-07-28. When the server serves that revision,
the connection is stateless: every request carries `_meta`, there is no
session, and the server cannot send requests to the client; it returns
input-required results, which the client answers with the same handlers. When
the server does not serve it, or answers -32601 like a server that predates
`server/discover`, the client sends `initialize` as before. To keep the
previous behavior:

%include Examples/Snippets/Guides/Migration.swift migration-handshake-client

`Version.supported` now contains 2026-07-28. Code that used it as the list of
`initialize` revisions reads `Version.handshake`. `Version.latest` is still
2025-11-25. `HTTPValidationContext` defaults `supportedProtocolVersions` to
`Version.handshake`, the revisions that sessions serve; a custom stateless
pipeline passes `Version.stateless + Version.handshake`.

Against a server that serves only the handshake, a default client sends one
extra request per connection: `server/discover`, answered with an error, then
`initialize`. Clients that open many short connections to such servers use
`.handshake`.

### Handlers

- A request whose parameters do not decode fails with -32602
  `Invalid params for <method>: ...`. The previous release answered -32603.
- `tools/call`, `prompts/get` and `resources/read` handlers of `initialize`
  clients never see `inputResponses` or `requestState` sent by the client: the
  server removes them. Only the server's own round trips set them.
- `Server.notify(_:)`, `log(level:logger:data:)` and the server-to-client
  requests pass the id of the request being handled to the transport.
  `StatefulHTTPServerTransport` sends such messages on that request's SSE
  stream instead of the standalone GET stream.

### HTTP server transports

`StatefulHTTPServerTransport`:

- An unsupported `MCP-Protocol-Version` header is answered with HTTP 400 and
  -32022, with `data.supported` and `data.requested`. The previous release
  sent -32600 `Bad Request: Unsupported protocol version`.
- A request whose header names a stateless revision is answered with HTTP 400
  and -32022, listing `Version.handshake`, with the request id.
- Error bodies include the error's `data`.

`StatelessHTTPServerTransport` was rewritten:

- Notifications that a handler sends for its request are no longer dropped.
  When the client accepts `text/event-stream`, the response is an SSE stream
  that carries them and ends with the response.
- At 2026-07-28, JSON-RPC errors use HTTP status codes: 404 for -32601; 400
  for -32600, -32602 and -32020 to -32022; 200 for other errors. On
  handshake requests, -32022 is 400 and other errors keep 200.
- The default validation pipeline accepts 2026-07-28 in
  `MCP-Protocol-Version`. After the pipeline, the transport requires
  `Mcp-Method` and `Mcp-Name` on 2026-07-28 requests (-32020).
- Error bodies carry the error's `data`, and the request id when the body
  could be parsed.
- Each request gets an internal JSON-RPC id while it is in flight, so
  concurrent clients may reuse ids.
- When the transport stops before a response, the request gets HTTP 503
  instead of 500.

### HTTP client transport

- A non-2xx response with a JSON-RPC error body for the request (same ID) is
  delivered as the error of that request. The previous release threw
  `internalError("Bad request")` and similar, which hid the server's code and
  message. Any other body still gives the status error.
- The `MCP-Protocol-Version` header comes from the message's `_meta` when it
  has one.
- The default `configuration` is `HTTPClientTransport.defaultConfiguration`:
  `httpMaximumConnectionsPerHost` is 64 instead of the system's 6. The old
  limit deadlocked five or more concurrent calls that each waited for a
  server-to-client request. A configuration you pass is used as is; raise its
  limit the same way.
- A POST response stream that ends before its response is resumed with a GET
  carrying that stream's `Last-Event-ID`. When it cannot be resumed, the
  request fails with -32603. The previous release restarted the GET session
  stream with the last event ID of any stream, and a request whose stream the
  server could not replay waited forever.

### Authorization

`OAuthAuthorizer` and its helpers:

- use authorization server metadata only when its `issuer` matches the
  candidate the metadata URL was built from (RFC 8414 §3.3). The previous
  release fell back to metadata with another issuer; now discovery fails with
  `authorizationServerIssuerMismatch(expected:actual:)`. The comparison is
  case-sensitive, and a root issuer may differ by a trailing slash only. To
  keep using a server whose metadata names its issuer differently, set it in
  `endpointOverrides.authorizationServerURL`, which is trusted;
- check the `iss` parameter of the authorization response against the issuer
  (RFC 9207). `OAuthAuthorizationCodeFlow.perform` and `extractCode` take a
  new, defaulted `ExpectedIssuer` parameter;
- send `application_type` in dynamic client registration (SEP-837):
  `OAuthConfiguration(applicationType:)`, or inferred from the grant type and
  the redirect URI;
- refresh a rejected token at its own server first, read the protected
  resource metadata again when that does not help, and register again when
  the resource names another authorization server (SEP-2352);
- refresh a token only at the server that issued it;
- fall back to `/authorize`, `/token` and `/register` at the server's origin
  only when a 2025-03-26 server answers 404 or 410 for every metadata URL;
  the previous release also did so after network errors and 5xx;
- handle concurrent challenges one at a time. `InMemoryTokenStorage` is now
  thread-safe; custom `TokenStorage` implementations are called from several
  tasks.

### Package

The `MCP` target depends on swift-crypto (`3.0.0..<5.0.0`), in both manifests.
It seals `requestState` with AES-GCM.

## New opt-in features

| Feature | API | Guide |
|---|---|---|
| Choose the protocol era | `Client.Configuration.protocolMode`: `.automatic` (default), `.handshake`, `.stateless(_:)` | [protocol_versions.md](protocol_versions.md#protocol-modes) |
| Connection state | `Client.negotiatedProtocolVersion`, `serverInfo`, `serverCapabilities`, `isStateless` | [client.md](client.md#connection-state) |
| Per-request log level | `Client.Configuration.logLevel` | [client.md](client.md#logging) |
| Version model | `Version.handshake`, `Version.stateless`, `Version.profile(for:)`, `ProtocolProfile` | [protocol_versions.md](protocol_versions.md#version-lists) |
| Request context | `HandlerContext.protocolVersion`, `clientCapabilities`, `clientInfo`, `logLevel`, `isStateless`, `profile` | [server.md](server.md#handler-context) |
| Request and notification `_meta` | `Request._meta`, `Message._meta`, `MetaKey`, `Metadata.protocolVersion` and the other accessors | [protocol.md](protocol.md#per-request-_meta-keys) |
| Discovery | `ServerDiscover` | [protocol.md](protocol.md#discovery-and-protocol-modes) |
| Notification streams | `Client.listen(_:)`, `Client.Subscription`, `unsubscribeFromResource(uri:)`, `subscribedResourceURIs`, `Server.closeSubscriptions()`, `SubscriptionFilter` | [client.md](client.md#notifications-and-subscriptions) |
| Multi round-trip requests | `.inputRequired(_:requestState:_meta:)`, `InputRequest`, `InputResponse`, `Client.Configuration.multiRoundTrip` | [server.md](server.md#multi-round-trip-requests) |
| Sealed request state | `Server.init(requestStateProtection:)`, `RequestStateProtection`, `AESGCMRequestStateCodec`, `RequestStateCodec` | [server.md](server.md#protecting-requeststate) |
| Cache hints | `CacheableResult`, `ttlMs`, `cacheScope`, `CacheHint`, `Server.Configuration.cacheHints` | [server.md](server.md#cacheable-results) |
| Result type | `ResultType`, `resultType` on the three input-capable results | [server.md](server.md#multi-round-trip-requests) |
| Request headers (SEP-2243) | `MCPRequestHeaders`, `Tool.headerParameters()`, `Transport.send(_:additionalHeaders:)`, with a default, and `HTTPClientTransport.send(_:additionalHeaders:)` | [protocol.md](protocol.md#request-headers-sep-2243), [custom transports](protocol.md#custom-transports) |
| HTTP routing | `HTTPRequest.statelessProtocolVersion` | [protocol.md](protocol.md#routing-both-eras-on-one-endpoint) |
| Per-request transport streams | `Transport.send(_:relatedRequestID:)`, with a default | [protocol.md](protocol.md#custom-transports) |
| Capability extensions | `extensions` on both capability structs | [server.md](server.md#capabilities-and-extensions) |
| Log level order | `LogLevel: Comparable` | [server.md](server.md#logging) |
| OAuth | `OAuthConfiguration.ApplicationType`, `OAuthAuthorizationCodeFlow.ExpectedIssuer` | [protocol.md](protocol.md#authorization) |

