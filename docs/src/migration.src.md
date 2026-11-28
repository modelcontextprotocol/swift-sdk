# Migration guide

This guide lists every public API change between 0.12.1 (`a0ae212`) and
1.0.0: the changes that break source code, the changes in behavior and on the
wire, and the new opt-in features. 1.0.0 also contains the fixes merged to
`main` after 0.12.1, up to `234e412`
([Fixes on `main` after 0.12.1](#fixes-on-main-after-0121)). From 1.0.0 on,
only a major release breaks source compatibility
([VERSIONING.md](../VERSIONING.md)). Most code compiles unchanged. The
[summary](#summary) lists every change with what to do, and
[Breaking changes](#breaking-changes) shows the code before and after for
each change that breaks source code.

## Summary

| Area | Change | Action |
|---|---|---|
| `MCPError` | New cases; `serverError` has a third associated value | Update exhaustive `switch` statements and `serverError` patterns |
| `MCPError` decoding | -32000 and -32001 decode as `serverError`; -32602 with `data.uri` as `resourceNotFound`; without `data.detail`, the standard cases drop their own message text | Match the new cases |
| -32042 error decoding | If the data cannot be represented entirely by `urlElicitationRequired`, decodes as `serverError` and keeps `data` | Match `errorCode == .urlElicitationRequired` to handle both cases |
| `HTTPResponse` | `.data` and `.error` have new associated values | Update patterns |
| `Client.Capabilities.experimental` | `[String: String]?` became `[String: Value]?` | Pass `Value`s |
| `OAuthAuthorizationError` | A struct with a `code`, not an enum; eight new codes | Read details from properties instead of binding associated values |
| `GrantType`, `TokenEndpointAuthentication`, `PrivateKeyJWTSigningAlgorithm` | Structs, not enums; new grant type `.jwtBearer` | Add a `default` to `switch` statements; write `.ES256` instead of `init(rawValue:)` |
| `BearerTokenValidationResult`, `Elicitation.Mode`, `ToolChoice.Mode` | Structs, not enums; `Mode(rawValue:)` is not optional | Add a `default` to `switch` statements; drop the optional binding |
| Roots, sampling and logging | Deprecated by the specification (SEP-2577): the entry points are `@available(*, deprecated)`, and a notice is logged once when the peer declares them | Nothing now; plan the migration in [rough_edges.md](rough_edges.md#deprecated-by-the-specification) |
| `includeContext` | `.thisServer` and `.allServers` are deprecated (SEP-2596) | Omit `includeContext`, or use `.none` |
| `ToolChoice(mode:)` | Takes a `Mode`; the initializer with an optional mode is deprecated | Pass a mode. `.init(mode: .none)` is now the `none` mode, not `nil` (`auto`) |
| Content blocks, `InputRequest`, `InputResponse`, `CreateElicitation.Parameters` | New case `.unknown` for kinds from a later revision | Add it, or a `default`, to `switch` statements |
| `HTTPClientAuthorizer` | `authorizationHeader(for:)` became `authorizationHeaders(for:method:)`; new requirement `handleChallenge(statusCode:headers:endpoint:operationKey:sentAuthorization:session:)`, returning `HTTPChallengeResult`, with a default that calls the Bool method | Update custom authorizers |
| `Client` convenience methods | Return the result type, not a tuple; `startToolCall` replaces the `RequestContext` overload of `callTool`; `initialize()` is removed | Read the result's properties |
| Peer result decoding | An undecodable result, including a server-to-client or task result, throws `ResponseDecodingError` with the expected type, raw result and decoding error. It is separate from `MCPError` | Catch this error to inspect a malformed result; use a `Method` with `Result == Value` for raw access |
| `Client.connect(transport:)` | Returns `Client.ConnectionInfo`, whose `serverInfo` is optional | Unwrap `serverInfo` |
| `Version.latest` | Renamed `Version.latestHandshake`; the old name is deprecated | Rename |
| `Tool.Content` | `annotations` and `_meta` default to `nil`; the deprecated short forms are removed | Use `.text(text:)`, `.image(data:mimeType:)`, `.audio(data:mimeType:)` |
| `HTTPClientTransport` errors | HTTP statuses and OAuth failures are `transportError` with `HTTPStatusError` or `OAuthAuthorizationError`, not `internalError` with a message | Match the typed errors |
| `Server.start(transport:)` | Keeps handlers registered before it; answers `logging/setLevel` and filters `log` when the server declares `logging` | Remove workarounds |
| `OAuthWWWAuthenticateParsing` | New requirement `parseChallenge(scheme:from:)`, with a default | Nothing |
| `Server` | Serves 2026-07-28 requests by default | Nothing, or opt out |
| `Client` | Connects at 2026-07-28 by default, with a fallback to `initialize` | Nothing, or opt out |
| `Version.supported` | Lists 2026-07-28 | Read `Version.handshake` for the `initialize` revisions |
| Handlers | Undecodable parameters fail with -32602, not -32603 | Update tests that check the code |
| Client handlers | Run outside the receive loop; at most 4 server-to-client requests at once; a server `ping` is answered | Remove `Task` wrappers that worked around the old loop, if you like |
| `Client` connection | Pending requests fail with `connectionClosed` when the transport ends its stream; `connect(transport:)` on a connected client disconnects the previous transport | Handle `connectionClosed` where requests waited forever |
| `Client` handshake | `connect(transport:)` throws `internalError` when the server answers `initialize` with a version that is not in `Version.handshake` | Update the server, or handle the error |
| `.stateless(version)` | No retry with another version | Use `.automatic` for negotiation |
| Sampling with tools | The client refuses tools without `sampling.tools`, and tool messages that break the rules, with -32602; `requestSampling` refuses them before it sends | Declare `sampling.tools` when the sampling handler takes tools |
| `.none(clientID:)` | A plain client ID is pre-registered: no dynamic registration | Pass `""` to register |
| `StatelessHTTPServerTransport` with an `initializeHook` | Handshake requests other than `initialize` are refused with -32600 unless a `statelessRequestHook` is set | Set a `statelessRequestHook` |
| Terminated stateful HTTP session | After a session ends and validation passes, requests without a session ID receive 400 instead of 404; requests with any session ID receive 404 | Route a new sessionless `initialize` to a new transport and `Server` |
| `data:` URL strings | Arrive as sent instead of rewritten as base64 `data:` URLs | Nothing |
| HTTP transports | New error bodies, status codes and streaming | See below |
| `HTTPClientTransport` | Default per-host connection limit 64; POST streams resume per stream; SSE on Linux | Raise `httpMaximumConnectionsPerHost` in custom configurations |
| Package | Requires Swift 6.1 tools; depends on swift-crypto and Yams, no longer on eventsource; swift-docc-plugin `from: "1.4.0"` instead of its `main` branch | Use Xcode 16.3 or later; resolve packages again |
| Platforms | Minimums raised to macOS 15, Mac Catalyst 18, iOS 18, tvOS 18, watchOS 11, visionOS 2 | Raise your deployment targets, or stay on 0.12 to keep older ones |

## Breaking changes

### `MCPError` cases

`MCPError` has four new cases, and `serverError` carries the error's `data`:

| Case | Code | `data` |
|---|---|---|
| `serverError(code:message:data:)` | any code | as sent |
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

The cases of `MCPError` are frozen from now on. A code a later revision adds
arrives as `serverError(code:message:data:)`, and gets a constant in
`MCPError.Code`, not a case: compare `error.errorCode` with the constant, or
write `catch MCPError.Code.unsupportedProtocolVersion`.

### `MCPError` decoding

Decoding an error response changed for these codes:

| Code | Previous release | This release |
|---|---|---|
| -32000 | `connectionClosed` | `serverError(code: -32000, message:data:)` |
| -32001 | `transportError(_:)` with an `NSError` | `serverError(code: -32001, message:data:)` |
| -32602 with `data.uri` and no `data.detail` | `invalidParams(_:)` | `resourceNotFound(uri:message:)` |
| -32002 with `data.uri` | `serverError` | `resourceNotFound(uri:message:)` |
| -32020, -32021, -32022 | `serverError` | the new cases |
| -32700, -32600, -32601, -32602 without `data.detail` | the message as the detail: `methodNotFound("Method not found")` | the message less the case's own text: `methodNotFound(nil)`, and `methodNotFound("x")` for "Method not found: x" |
| -32603 without `data.detail` | `internalError(nil)` | `internalError(message)` less the "Internal error: " prefix; a bare "Internal error" stays `internalError(nil)` |

A decoded standard error now equals the error that was sent, and encodes
the same message again; the previous release added the case's text a second
time (`Method not found: Method not found`).

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

`OAuthAuthorizationError` is a struct, modeled on Foundation's `URLError`. Its
`code` says what failed, and properties carry the details: `statusCode`,
`oauthError`, `context`, `url`, `clientID`, `detail`, `expected` and
`actual`. Each former case is a static member with the same name, and the
cases that had associated values are also static functions with the same
labels, so `throw .tokenRequestFailed(statusCode: 400, oauthError: nil)` and
`catch OAuthAuthorizationError.dpopRequired` compile unchanged. A pattern
matches by code alone: `catch OAuthAuthorizationError.tokenRequestFailed`
catches every failed token request. A pattern that binds associated values does
not compile; read the properties instead. A pattern built with values still
compiles, but its values are ignored:
`catch OAuthAuthorizationError.tokenRequestFailed(statusCode: 401, oauthError: nil)`
now catches every failed token request, whatever its status. Compare
`statusCode` or `oauthError` in a `where` clause instead.
`HTTPClientTransport` throws it inside `MCPError.transportError(_:)`
([HTTP client errors](#http-client-errors)), so around `connect` or a request,
match `MCPError.transportError(let error as OAuthAuthorizationError)`.

Before:

```swift
} catch OAuthAuthorizationError.tokenRequestFailed(let status, let error) {
```

After:

%include Examples/Snippets/Guides/Migration.swift migration-oauth-error

Eight codes are new: `authorizationResponseIssuerMismatch`,
`authorizationResponseMissingIssuer`, `assertionProviderMissing`,
`issuedTokenTypeMismatch`, `authorizationServerNotConfigured`,
`assertionAudienceMismatch`, `dpopRequired` and `dpopAlgorithmUnsupported`.
More can appear in a minor release, so a `switch` needs a `default`. See
[Authorization](#authorization).

### Open structs

These enums became structs with one static member per former case, so that a
minor release can add values (`VERSIONING.md`):

| Type | Why it grows |
|---|---|
| `OAuthConfiguration.GrantType` | `.jwtBearer` is new; device code (RFC 8628) is a likely next one |
| `OAuthConfiguration.TokenEndpointAuthentication` | The IANA registry has more methods |
| `OAuthConfiguration.PrivateKeyJWTSigningAlgorithm` | ES256 only today |
| `BearerTokenValidationResult` | Server-side DPoP adds results |
| `Elicitation.Mode` | `url` arrived at 2025-11-25 |
| `CreateSamplingMessage.ToolChoice.Mode` | Follows the vocabularies of model APIs |

`.clientSecretBasic(clientID:clientSecret:)`, `.valid(info)`, `.url` and the
others are written as before, and `==` works as before. A `switch` needs a
`default`. A pattern that binds associated values does not compile:
`TokenEndpointAuthentication` has `clientID` and `methodName`, and
`BearerTokenValidationResult`, which validators return, has `tokenInfo`, the
`BearerTokenInfo` of a `.valid(info)` result. `Elicitation.Mode(rawValue:)` and `ToolChoice.Mode(rawValue:)` are no
longer optional, and the two `Mode` types decode a mode the SDK does not know
instead of failing. `PrivateKeyJWTSigningAlgorithm` has no public initializer:
use `.ES256`.

%include Examples/Snippets/Guides/Migration.swift migration-open-struct

### Unknown kinds

These enums have a new case for a kind the SDK does not know, so that a client
or server talking to a peer on a later revision decodes the message instead of
failing it:

| Enum | New case | Before |
|---|---|---|
| `Tool.Content`, `Prompt.Message.Content`, `Sampling.Message.Content.ContentBlock`, `Sampling.ToolResultContent.ContentBlock` | `.unknown(type:_:)`: the `type` and the whole block as received | the whole result failed to decode |
| `InputRequest` | `.unknown(method:params:)`; the client fulfills it with the handler registered for the method | the input-required result failed to decode |
| `InputResponse` | `.unknown(_:)`: a result of another shape | decoded as a sampling result, and failed |
| `CreateElicitation.Parameters` | `.unknown(mode:_:)` | the request failed to decode |

A block or request is encoded as it was received. An exhaustive `switch` needs
the new case or a `default`; these enums gain no other case in 1.x.

### Client convenience methods

`listTools`, `listPrompts`, `listResources`, `listResourceTemplates`,
`callTool`, `getPrompt` and `readResource` return the request's result
(`ListTools.Result`, `CallTool.Result`, and so on) instead of a tuple or an
array. The results have the tuples' labels as properties (`tools`,
`nextCursor`, `content`, `isError`, `description`, `messages`), so
`try await client.listTools().tools` compiles unchanged; destructuring does
not. The results also carry what the tuples dropped: `structuredContent`,
`_meta`, `ttlMs` and `cacheScope`. `readResource` returns
`ReadResource.Result`; its `contents` is the former array.

Before:

```swift
let (content, isError) = try await client.callTool(name: "echo", arguments: ["text": "hi"])
let (tools, nextCursor) = try await client.listTools()
```

After:

%include Examples/Snippets/Guides/Migration.swift migration-client-results

The synchronous `callTool` overload that returned a
`RequestContext<CallTool.Result>` is now `startToolCall(name:arguments:meta:)`,
so a call no longer needs a type annotation to pick it. The deprecated
`Client.initialize()` is removed: `connect(transport:)` initializes.

### `Client.connect(transport:)`

`connect(transport:)` returns a `Client.ConnectionInfo` instead of an
`Initialize.Result`: `protocolVersion`, `capabilities`, `serverInfo`,
`instructions` and `isStateless`. At 2026-07-28 the previous release built an
`Initialize.Result` from the `server/discover` result, with an empty name and
version when the server sent no `io.modelcontextprotocol/serverInfo`; now
`serverInfo` is `nil` then, on the result and on `Client.serverInfo`.

%include Examples/Snippets/Guides/Migration.swift migration-connection-info

`setLoggingLevel(_:)` on a 2026-07-28 connection sets the new `Client.logLevel`,
which every request carries in `_meta`, instead of changing
`configuration.logLevel`.

### `Tool.Content`

The `text`, `image` and `audio` cases have default values for `annotations`
and `_meta`, so `.text(text: "Hello")` is the case itself. The deprecated
helpers that took `metadata:` or unlabeled values (`.text(_:)`,
`.text(text:metadata:)`, `.image(_:_:metadata:)`,
`.image(data:mimeType:metadata:)`, `.audio(_:_:metadata:)`,
`.audio(data:mimeType:metadata:)`) are removed: write `.text(text: "Hello")`,
and `_meta:` where you passed `metadata:`.

%include Examples/Snippets/Guides/Migration.swift migration-content

### HTTP client errors

`HTTPClientTransport` throws `MCPError.transportError(_:)` with a typed error
where it threw `MCPError.internalError` with a message:

| Failure | Before | After |
|---|---|---|
| HTTP status without a JSON-RPC answer | `internalError("Bad request")`, `("Session expired")`, `("Too many requests")`, ... | `transportError(HTTPStatusError)`: `statusCode`, `headers`, `isSessionExpired` |
| 401 or 403 without an authorizer, or after the retries | `internalError("Authentication required")`, `("Access forbidden")` | `transportError(HTTPStatusError)` with 401 or 403 |
| OAuth | `internalError("Authorization flow failed: …")` | `transportError(OAuthAuthorizationError)`, or the error of a custom `HTTPClientAuthorizer`; a `CancellationError` from the authorizer is thrown as is |

The descriptions changed, so match on the error rather than its text:

- The prefix is `Transport error: ` where it was `Internal error: `.
- An HTTP status reads as before (`Bad request`, `Session expired`, `Too many
  requests`, ...), except a 405 with `streaming: true`, which reads `Method not
  allowed` instead of `Server does not support streaming`, and an unlisted
  status, which reads `Unexpected HTTP response: <status>` without the content
  type in parentheses.
- An authorizer error reads as the error's own description, without
  `Authorization flow failed: `.

The error's `code` is -32001 instead of -32603. A server handler that calls
another server through a `Client` and lets such an error propagate now answers
its own caller with -32001 and `Transport error: …` instead of -32603; catch it
and throw the error the caller should see.
The `debugDescription` of `HTTPStatusError` names the response headers
without their values, so logging the error does not print cookies or
authentication challenges; read the values from `headers`.

%include Examples/Snippets/Guides/Migration.swift migration-http-errors

### `HTTPClientAuthorizer`

`authorizationHeader(for endpoint: URL) -> String?` is replaced by
`authorizationHeaders(for url: URL, method: String) throws -> [String: String]`,
so that an authorizer can sign the request (a DPoP proof covers the method and
the URL). Return `["Authorization": value]` where the old method returned
`value`, and `[:]` for `nil`. The transport now sets these headers after the
`requestModifier`, for the final URL and method; they replace an
`Authorization` header the modifier set. A thrown error fails the request with
`transportError(_:)` carrying that error.

The transport now calls the new requirement
`handleChallenge(statusCode:headers:endpoint:operationKey:sentAuthorization:session:)`
with the `Authorization` header the challenged request carried. It returns an
`HTTPChallengeResult`: `retry`, as the Bool method returns, and
`isDPoPNonceRetry`, whether the retry only answers a DPoP `use_dpop_nonce`
challenge, which the transport allows once per request without counting it
against `maxAuthorizationAttempts`. Its default calls
`handleChallenge(statusCode:headers:endpoint:operationKey:session:)` and reads
the nonce challenge with `DefaultOAuthWWWAuthenticateParser`, so custom
authorizers compile and behave as before. An authorizer that implements it can
tell a challenge for a token another request has already replaced from one for
the current token, and decide which challenge is a nonce retry.

`OAuthAccessToken` has a new stored property, `keyThumbprint`, with a
defaulted initializer parameter; tokens saved by the previous release decode
with `nil`.

### Platforms

The minimum platforms are the releases of the macOS 15 year
([VERSIONING.md](../VERSIONING.md#platforms)):

| Platform | 0.12 | 1.0.0 |
|---|---|---|
| macOS | 13 | 15 |
| Mac Catalyst | 16 | 18 |
| iOS | 16 | 18 |
| tvOS | 16 | 18 |
| watchOS | 9 | 11 |
| visionOS | 1 | 2 |

A package or app that depends on `MCP` raises its own minimums (its
deployment targets) to at least these; SwiftPM and Xcode refuse to build a
target whose minimum is lower than that of a product it uses:

```swift
// Before
platforms: [.macOS(.v13), .iOS(.v16)],
// After
platforms: [.macOS("15.0"), .iOS("18.0")],
```

The string form works with every manifest tools version; the `.v15` and `.v18`
constants need `swift-tools-version: 6.0` or later.

An app that still supports macOS 13 or 14, or the matching iOS, Mac Catalyst,
tvOS, watchOS or visionOS releases, stays on 0.12:
`.upToNextMinor(from: "0.12.1")`. The Linux requirements are unchanged.
Nothing else changes with the minimums: the SDK uses no API that is new in
these releases.

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
`server/discover`, the client sends `initialize` as before. Some calls behave
differently on a stateless connection: `notifyRootsChanged()` does nothing,
`setLoggingLevel(_:)` sets the level of later requests, `ping()` sends
`server/discover`, and notifications arrive only on `subscriptions/listen`
streams. The full lists are in
[client.md](client.md#what-changes-at-2026-07-28) and
[protocol_versions.md](protocol_versions.md#stateless-connections). Code that
relies on the handshake behavior, such as `notifications/roots/list_changed`,
keeps the previous behavior with `.handshake`:

%include Examples/Snippets/Guides/Migration.swift migration-handshake-client

`Version.supported` now contains 2026-07-28. Code that used it as the list of
`initialize` revisions reads `Version.handshake`. `Version.latestHandshake` is still
2025-11-25. `HTTPValidationContext` defaults `supportedProtocolVersions` to
`Version.handshake`, the revisions that sessions serve; a custom stateless
pipeline passes `Version.stateless + Version.handshake`.

Against a server that serves only the handshake, a default client sends one
extra request per connection: `server/discover`, answered with an error, then
`initialize`. A server that does not answer requests sent before
`initialize` delays each connection by up to
`Client.Configuration.discoveryTimeout` (10 seconds by default) before the
client sends `initialize`. Clients that open many short connections to such
servers, or that connect to a server that does not answer, use `.handshake`
or a shorter `discoveryTimeout`.

### `data:` URL strings

The SDK no longer rewrites a `data:` URL string when it passes a message
through `Value`: the client and server message decoders, batches,
type-erased requests and responses, handler results, `_meta` accessors and
error data keep the string as written. A text block, a URI or an icon `src`
such as `data:,hi` arrives as sent; the previous release delivered
`data:text/plain;base64,aGk=`. A `Value` field the application decodes, such
as a tool argument or `structuredContent`, still holds `.data(mimeType:_:)`
for such a string, which encodes as a base64 `data:` URL.

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
- A server whose `protocolVersions` lists no handshake revision answers
  `initialize`, and every request without a stateless `_meta`, with -32022.
  The previous release negotiated a handshake revision anyway.
- A `strict` server ignores notifications before `initialize`. The previous
  release answered them with an error response with a random id. A message
  the server cannot read, and an empty batch, are answered with `"id": null`.
- `Tool` leaves a `nil` description out of the JSON instead of writing
  `"description": null`.

### Client handlers and requests

- Handlers no longer run on the receive loop. Notification handlers run one
  at a time, in order, and may await requests on the same client. A response
  is delivered at once, after the queued progress notifications of its own
  request. Server-to-client requests at 2025-11-25 run concurrently, each in
  its own task, at most `Configuration.maxConcurrentServerRequests` (4) at
  once, and `notifications/cancelled` from the server cancels the task; a
  cancelled handler counts against the limit until it returns. The previous
  release ran every handler on the receive loop, so a handler that awaited a
  request on the same client never returned.
- The client answers a server `ping` at once with an empty result, outside
  that limit. The previous release answered -32601. A `Ping` handler
  registered with `withMethodHandler` still answers it instead.
- When the transport finishes its receive stream (a stdio server exits, for
  example), the client does what `disconnect()` does and fails every pending
  request, and a `connect(transport:)` in progress, with `connectionClosed`,
  or with the stream's error, wrapped in `transportError` unless it is an
  `MCPError`. The previous release kept reading the finished stream, so they
  waited forever.
- `connect(transport:)` on a connected client disconnects the previous
  transport first; its pending requests fail with
  `internalError("Client disconnected")`. The previous release replaced the
  transport and left the old message loop running.
- When the server answers `initialize` with a protocol version that is not in
  `Version.handshake`, `connect(transport:)` disconnects and throws
  `internalError("Server's protocol version is not supported: <version>")`. The
  client does not send `notifications/initialized`. The previous release used
  the server's version.
- Cancelling the task that awaits `RequestContext.value` cancels the request.
- A request is registered before `send(_:)` returns. `cancelRequest(_:reason:)`
  right after `send` always ends the request; a request cancelled before it
  was sent is not sent.
- `withBatch(body:)` requests get the 2026-07-28 `_meta` envelope, header
  parameters and the multi round-trip loop. On a stateless connection they
  are sent one by one. When the closure throws, its requests fail. When the
  connection closes or is replaced while the closure runs, the batch is not
  sent and `withBatch` throws `connectionClosed`.
- `.stateless(version)` no longer retries with another version on -32022:
  it connects at `version` or throws.

### Sampling with tools

The specification's rules for sampling with tools (SEP-1577) are checked:

- The client answers -32602, and the sampling handler does not run, when a
  request has `tools` or `toolChoice` and `capabilities` has no
  `sampling.tools`. The previous release called the handler.
- The client answers -32602 when the messages break the rules for tool uses
  and tool results: tool uses are in assistant messages and tool results in
  user messages, a message with tool results holds only tool results, each
  tool use has a result in the next message, which is a user message, and
  each tool result answers a tool use in the message before it.
  `Server.requestSampling` throws -32602 for such messages before it sends
  the request. The previous release sent them.
- `Server.requestSampling` throws -32601 when the request has `tools` or
  `toolChoice` and the client did not declare `sampling.tools`, also when the
  server is not strict. The previous release sent the request.

### HTTP server transports

`StatefulHTTPServerTransport`:

- An unsupported `MCP-Protocol-Version` header is answered with HTTP 400 and
  -32022, with `data.supported` and `data.requested`. The previous release
  sent -32600 `Bad Request: Unsupported protocol version`.
- A request whose header names a stateless revision is answered with HTTP 400
  and -32022, listing `Version.handshake`, with the request id.
- Error bodies include the error's `data`.
- After its session ends, the transport runs the validation pipeline, then
  answers a request without `Mcp-Session-Id` with 400 and a request with any
  session ID with 404, echoing the ID only when it is the ended session's.
  The previous release answered every request with 404, before validation.
  Route a new sessionless `initialize` to a new transport and `Server`.

`StatelessHTTPServerTransport` was rewritten:

- Notifications that a handler sends for its request are no longer dropped.
  When the client accepts `text/event-stream`, the response is an SSE stream
  that carries them and ends with the response. On handshake requests this
  includes the list-changed and resource-updated notifications the handler
  sends.
- A handshake request other than `initialize` runs the
  `statelessRequestHook`, with no client info or capabilities: without a
  session, nothing ties it to the `initialize` that passed the
  `initializeHook`. A server with an `initializeHook` and no
  `statelessRequestHook` refuses such requests with -32600. The previous
  release ran the hook for `initialize` only and served the requests that
  followed. Set a `statelessRequestHook` that applies the same checks.
- A `notifications/cancelled` that the transport honors ends the cancelled
  request's HTTP response without a JSON-RPC response: 202 Accepted with no
  body, or the end of its SSE stream.
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
- One `Server` behind the transport answers every `initialize`. The previous
  release answered the first and sent -32600 to later clients.
- When the HTTP adapter cancels a request whose JSON response is pending (the
  client went away), the server's handler is cancelled, as for an SSE stream.

`StatefulHTTPServerTransport` keeps at most `eventStoreCapacity` events
(default 1000) and `eventStoreByteCapacity` bytes (default 16 MiB) per session
for `Last-Event-ID` replay. The previous release kept every event until the
session ended.

### Server default handlers

- `start(transport:)` keeps a handler you registered for `initialize`, `ping`,
  `server/discover` or `subscriptions/listen` before it. The previous release
  replaced it with the built-in one. An `initialize` handler of yours replaces
  the handshake: the `initializeHook` and the SDK's version negotiation do not
  run, and the server does not count as initialized.
- A server with the `logging` capability answers `logging/setLevel` itself on
  handshake connections and `log(level:logger:data:)` drops messages below the
  level. The previous release had no such handler (clients got -32601) and sent
  every message. A `SetLoggingLevel` handler of yours still replaces it.
- `Server.HandlerContext` has a public initializer, for tests.
- A stopped server is released. In the previous release the built-in handlers
  kept every started `Server` alive, so a server per session leaked one per
  session.

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
- On Linux the transport reads responses as they arrive and handles SSE, as on
  Apple platforms. The previous release read each response only once the
  server ended it, dropped SSE bodies and opened no GET stream, so streamed
  results, server-to-client requests and notifications did not arrive.
- An SSE line, or the data of one event, longer than 16 MiB fails the request
  with `internalError`. An event that the body ends before its closing blank
  line is discarded.
- A 404 to the GET stream of a session stops the stream, which is not
  reopened; the previous release kept reopening it with the expired session
  ID. The session ID is kept, so the next request carries it, receives the
  server's 404 and reports `isSessionExpired` to its caller.
- A transport dropped without `disconnect()` is released, and then stops its
  GET stream. The previous release never released it and, with
  `streaming: true`, kept reconnecting the GET stream.
- `connect()` after `disconnect()` throws `internalError`: create a new
  transport to reconnect. The previous release raised an exception at the
  next send on Apple platforms. `disconnect()` also ends a notification's
  POST still waiting for its response.

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
- keep the stored tokens and fail the challenge with the error when the
  metadata needed to refresh a rejected token cannot be read (a network
  error, an unexpected status) or the read is cancelled, instead of clearing
  them and starting a new authorization;
- renew a token proactively (`proactiveRefreshWindowSeconds`) at most once
  per token: when the renewal fails, the next 401 recovers. A token issued
  for less than the window is renewed halfway between its issue and 30
  seconds before its expiry. The previous release refreshed before every
  request while the token was within the window, also after a failure;
- handle concurrent challenges one at a time. `InMemoryTokenStorage` is now
  thread-safe; custom `TokenStorage` implementations are called from several
  tasks. A challenge that waited for one that failed and left no usable
  token fails with the same error instead of running the flow again (one
  prompt for a cancelled authorization), and a waiting request can be
  cancelled;
- register again on the next flow when dynamic client registration throws.
  The previous release did not try again until the authorizer was recreated;
- treat a `.none(clientID:)` client ID that is not empty and not a URL as
  pre-registered: no dynamic registration happens. Pass `.none(clientID: "")`
  to register. The previous release registered and replaced the ID;
- check the registration endpoint for private addresses, follow discovery
  redirects only to `https` hosts that are not private addresses, and to a
  loopback host only from a loopback host, and follow
  no redirect for token and registration requests;
- count as private the IPv6 addresses that embed a private IPv4 address as
  IPv4-translated (`::ffff:0:0:0/96`) or 6to4 (`2002::/16`), and the
  local-use NAT64 prefix `64:ff9b:1::/48`. A host with `:` that is not an
  IPv6 address (`fc00::1::2`), an embedded IPv4 address that is not a
  canonical dotted quad (`[::ffff:012.0.0.1]`), brackets around anything but
  an IPv6 address (`[127.0.0.1]`) and a numeric host with a trailing dot
  (`10.0.0.1.`) are refused instead of passing as host names;
- accept `http://[::1]` as a loopback URL, as `http://127.0.0.1`, for the MCP
  endpoint, the redirect URI and redirect targets. The previous release
  refused it;
- no longer block host names that begin with `fc`, `fd` or `fe8` through
  `fe8b`: only IP literals are checked;
- compute PKCE challenges and sign `private_key_jwt` assertions with
  swift-crypto, so they work on Linux. `pkceS256Unavailable` and
  `cryptographyUnavailable` are no longer thrown;
- read a `DPoP` challenge (RFC 9449) for `resource_metadata`, `scope` and
  `error` when the response has no `Bearer` challenge.

### Package

The package requires Swift 6.1 tools (Xcode 16.3 or later):
`Package@swift-6.0.swift` is removed.

The `MCP` target depends on swift-crypto (`3.0.0..<5.0.0`). It seals `requestState` with AES-GCM, computes PKCE challenges and signs
`private_key_jwt` assertions. It depends on Yams (`from: "6.0.0"`), which
parses the YAML frontmatter of skills. It no longer depends on eventsource:
`HTTPClientTransport` parses server-sent events itself. Code that imported
`EventSource` through the SDK declares the dependency itself.

The manifest requires swift-docc-plugin `from: "1.4.0"` instead of its `main`
branch. SwiftPM refuses a version-based requirement on a package whose
manifest has a branch-based dependency, so a package that depends on a
released `MCP` version now resolves.

### Fixes on `main` after 0.12.1

These commits on `main` (`a0ae212..234e412`) are part of 1.0.0:

- `Data.parseDataURL(_:)` takes `;base64` from the header only:
  `data:text/plain,hello;base64,world` is a text URL, where the previous
  release returned `nil` (#309). A payload without `;base64` decodes every
  percent-escaped byte, so `%FF` no longer makes it fail (#310). `Value`
  decodes such strings as `.data(mimeType:_:)`.
- `client_secret_basic` percent-encodes the client ID and secret
  (`application/x-www-form-urlencoded`, RFC 6749 §2.3.1) before the Base64
  step; the previous release sent them verbatim, so a credential with `:`,
  `@`, `%`, `+` or non-ASCII characters could reach the server altered
  (#300).
- Every character of a PKCE code verifier is equally likely; the first
  character of the alphabet was slightly more likely (#303).
- The default `authorizationRedirectURI`, a random loopback port, documents
  that the port is not bound until the callback server starts; prefer a
  fixed port or a custom URL scheme in production (#302).
- `DefaultOAuthWWWAuthenticateParser` unescapes every quoted pair in a
  quoted parameter value (`\X` is `X`, RFC 7230 §3.2.6); the previous
  release unescaped only `\"`, so `\\` stayed two characters (#305).
- `NetworkTransport` with reconnection disabled cancels its `NWConnection`
  when the receive loop ends with an error. The previous release did not,
  so a connection the peer closed kept its socket in `CLOSE_WAIT` until the
  process exited. After five consecutive empty reads on a connection
  that is no longer ready, the receive stream finishes with
  `connectionClosed` and the connection is cancelled, where the receive loop
  ended and `receive()` kept waiting (#283). The transport then also counts
  as disconnected and stops its heartbeats, which the previous release kept
  sending to the closed connection (#326).
- `NetworkTransport` clears the connection's state update handler on the
  actor's executor when a connection attempt ends. The previous release also
  cleared it from the state stream's termination callback, on any thread, a
  data race (#301).
- `StdioTransport.disconnect()` waits for the read loop and the sends in
  progress, then turns `O_NONBLOCK` off again on each descriptor that was
  blocking at `connect()` and still refers to the same file, and then
  finishes the receive stream. The previous release left both descriptors
  non-blocking, which also affects other users of the process's stdin and
  stdout. A send in progress throws `transportError` (ENOTCONN) before its
  next write once `disconnect()` is called, and `connect()` waits for a
  `disconnect()` in progress (#297).

Three commits add API, listed in [New opt-in features](#new-opt-in-features):
`Server.init` takes `description`, `websiteUrl` and `icons` (#258),
`Value.numberValue` (#226), and `Value.init(_:)` takes any `Encodable`
instead of `Codable` (#227).

The other commits change no behavior: notification handlers are appended in
place (#118), the client calls `send(request).value` instead of an internal
helper (#304), the server reuses one encoder and decoder (#299), a
`NetworkTransport` test checks the transport instead of its mock (#311), the
conformance server spaces its progress notifications 50 ms apart instead of
50 µs (#329), `Package.resolved` pins swift-nio 2.100.0, which only the conformance server
and the HTTP server example use (#325), and the README, agent guidance, CI and
CODEOWNERS changed (#155, #294, #306, #308, #318, #320, #331, #333).

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
| Server Cards (SEP-2127) | `ServerCard`, `ServerCardValidator`, `ServerCard.fetch(from:ifNoneMatch:session:)` | [server.md](server.md#server-cards), [client.md](client.md#server-cards) |
| MCP Apps (SEP-1865) | `Server.withAppResources(_:listInResources:)`, `UIResource`, `UIResourceMeta`, `Tool.ui`, `Client.Capabilities.ui`, `Client.readAppResource(uri:listing:)` | [server.md](server.md#mcp-apps), [client.md](client.md#mcp-apps) |
| Sampling with tools (SEP-1577) | `Server.requestSampling(...tools:toolChoice:...)`, `.sampling(_:)` input requests with `tools` | [server.md](server.md#sampling-with-tools), [client.md](client.md#sampling) |
| Skills (SEP-2640) | `Server.withSkills(_:listInResources:)`, `SkillCatalog`, `SkillPackage`, `InMemorySkillCatalog`, `Client.listSkills(cursor:)`, `getSkill(uri:)`, `loadSkill(_:options:)`, `LoadedSkill` | [server.md](server.md#skills), [client.md](client.md#skills) |
| Tasks (SEP-1686, SEP-2663) | `Server.withTasks(_:)`, `TaskManager`, `HandlerContext.runAsTask(ttl:pollInterval:_:)`, `TaskContext`, `Tool.Execution`, `Client.Configuration.tasks`, `TaskHandle`, `TaskSnapshot`, `SubscriptionFilter.taskIds` | [server.md](server.md#tasks), [client.md](client.md#tasks) |
| Error codes | `MCPError.Code`, `MCPError.errorCode` | [`MCPError` cases](#mcperror-cases) |
| Sealed request state | `Server.init(requestStateProtection:)`, `RequestStateProtection`, `AESGCMRequestStateCodec`, `RequestStateCodec` | [server.md](server.md#protecting-requeststate) |
| Cache hints | `CacheableResult`, `ttlMs`, `cacheScope`, `CacheHint`, `Server.Configuration.cacheHints` | [server.md](server.md#cacheable-results) |
| Result type | `ResultType`, `resultType` on the three input-capable results | [server.md](server.md#multi-round-trip-requests) |
| Request headers (SEP-2243) | `MCPRequestHeaders`, `Tool.headerParameters()`, `Transport.send(_:additionalHeaders:)`, with a default, and `HTTPClientTransport.send(_:additionalHeaders:)` | [protocol.md](protocol.md#request-headers-sep-2243), [custom transports](protocol.md#custom-transports) |
| HTTP routing | `HTTPRequest.statelessProtocolVersion` | [protocol.md](protocol.md#routing-both-eras-on-one-endpoint) |
| Per-request transport streams | `Transport.send(_:relatedRequestID:)`, with a default | [protocol.md](protocol.md#custom-transports) |
| Gate requests without `initialize` | `statelessRequestHook` of `Server.start(transport:initializeHook:statelessRequestHook:)`, `Server.StatelessRequestHook` | [server.md](server.md#the-initialize-hook) |
| Abort a request's POST | `HTTPClientTransport.cancelRequest(_:)` | [protocol.md](protocol.md#http-client) |
| Capability extensions | `extensions` on both capability structs | [server.md](server.md#capabilities-and-extensions) |
| Log level order | `LogLevel: Comparable` | [server.md](server.md#logging) |
| OAuth | `OAuthConfiguration.ApplicationType`, `OAuthAuthorizationCodeFlow.ExpectedIssuer` | [protocol.md](protocol.md#authorization) |
| Enterprise-managed authorization, workload identity | `OAuthConfiguration.enterpriseManaged(...)`, `GrantType.jwtBearer`, `assertionProvider`, `OAuthTokenExchange` | [protocol.md](protocol.md#enterprise-managed-authorization) |
| DPoP-bound tokens | `OAuthConfiguration.dpop`, `OAuthConfiguration.DPoP`, `DPoPSigningKey`, `OAuthAccessToken.keyThumbprint`, `HTTPHeaderName.dpop`, `HTTPClientAuthorizer.didReceiveResponse(headers:for:)` | [protocol.md](protocol.md#dpop) |
| Replay store size | `StatefulHTTPServerTransport(eventStoreCapacity:)` | [protocol.md](protocol.md#transports) |
| Server metadata | `Server.init(name:version:title:description:websiteUrl:icons:instructions:capabilities:configuration:requestStateProtection:)`: sent in the `initialize` result and, at 2026-07-28, in `_meta["io.modelcontextprotocol/serverInfo"]` of every result, with `data:` icon URLs as written | [server.md](server.md#creating-a-server) |
| `Value` | `Value.numberValue` (`.int` or `.double` as `Double`); `Value.init(_:)` takes any `Encodable`, not only `Codable` | [server.md](server.md#calling-tools) |

