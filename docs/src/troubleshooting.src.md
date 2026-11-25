# Troubleshooting

This guide shows how to see what the SDK does, and lists common failures with
their causes and fixes. Most failures are JSON-RPC errors: find the code in
[Common failures](#common-failures).

## Logging

### Transport loggers

`Client` and `Server` log through their transport's `logger`. Every built-in
transport defaults to a logger with a no-op handler, so
`LoggingSystem.bootstrap(_:)` alone shows nothing: pass a `Logger` to the
transport.

%include Examples/Snippets/Guides/Troubleshooting.swift logging-logger

The SDK logs at these levels:

| Level | Events |
|---|---|
| `trace` | Every request, notification and response the client and server process, with method and id; stdio messages received, with their size |
| `debug` | Connection and disconnection of `Client`, `Server` and most transports; cancellations; in-memory messages sent and received, with their size; the client's fallback from `server/discover` to `initialize`; notifications dropped by `StatelessHTTPServerTransport` |
| `info` | In-memory transport connection and disconnection; `StatefulHTTPServerTransport` session start and end; `HTTPClientTransport` GET stream connection and reconnection |
| `warning` | Responses for unknown requests; unexpected messages; tools dropped for an invalid `x-mcp-header`; a rejected `requestState`, with the reason |
| `error` | Errors in the message loops; handler errors for notifications |

`StreamLogHandler` filters at `info` unless you set `logLevel`. A stdio server
must not log to standard output, which carries its messages: use
`StreamLogHandler.standardError`, the swift-log default.

### Recording the messages

The loggers do not print message bodies. To see them, wrap the transport:

%include Examples/Snippets/Guides/Troubleshooting.swift logging-wire

Pass `WireLog(transport, logger:)` to `connect(transport:)` or
`start(transport:)` instead of the transport. Each line is the direction and
the JSON message.

### HTTP traffic

The HTTP server transports take `HTTPRequest` values from your HTTP server,
so log the request and the `HTTPResponse` in your adapter: method, path,
`MCP-Protocol-Version`, `Mcp-Session-Id`, `Mcp-Method`, `Mcp-Name` and the
status code. On the client side, a proxy or a `URLProtocol` subclass in the
`URLSessionConfiguration` shows the traffic of `HTTPClientTransport`.

## Reading errors

A failed request throws `MCPError`. `code` is the JSON-RPC code, `data` the
`data` member, and `localizedDescription` combines a fixed prefix with the
detail.

%include Examples/Snippets/Guides/Troubleshooting.swift errors-inspect

Errors that are not `MCPError` come from the transport or from your own
handlers on the client side. A handler error that is not an `MCPError`
reaches the peer as -32603 with the error's description.

## Common failures

| Symptom | Section |
|---|---|
| -32601 Method not found | [-32601](#-32601-method-not-found) |
| -32602 Invalid params, Invalid or expired requestState, resource not found | [-32602](#-32602-invalid-params) |
| -32600 Invalid request | [-32600](#-32600-invalid-request) |
| -32020 Header mismatch | [-32020](#-32020-header-mismatch) |
| -32021 Missing required client capabilities | [-32021](#-32021-missing-required-client-capabilities) |
| -32022 Unsupported protocol version | [-32022](#-32022-unsupported-protocol-version) |
| HTTP 400, 404, 405 and other statuses | [HTTP status codes](#http-status-codes) |
| A feature that works in one era only | [Era mix-ups](#era-mix-ups) |
| `Authorization flow failed` | [OAuth failures](#oauth-failures) |
| A request that never completes | [Timeouts](#timeouts) |

### -32601 Method not found

| Detail | Cause | Fix |
|---|---|---|
| `<method> is not available at protocol version 2026-07-28` | The method was removed at 2026-07-28: `initialize`, `ping`, `logging/setLevel`, `resources/subscribe`, `resources/unsubscribe`. | Use the client methods, which switch per era: `ping()` sends `server/discover`, `setLoggingLevel(_:)` sets the `_meta` level, `subscribeToResource(uri:)` opens a listen stream. |
| `<method>: capability not declared by the server` | A stateless request for a feature whose capability the server does not declare. | Declare the capability in `Server(capabilities:)`. |
| `<method> requires protocol version 2026-07-28 or later` | `server/discover` or `subscriptions/listen` in the handshake era. | Connect with `.automatic`, the default; see [protocol_versions.md](protocol_versions.md#protocol-modes). |
| `Unknown method: <method>` | No handler is registered. `Server` has no built-in handler for `logging/setLevel`, `resources/subscribe` or `resources/unsubscribe`. On the client, a server request without a client handler: for example an elicitation the server sends for an input-required result. | Register the handler with `withMethodHandler(_:handler:)`, or on the client `withElicitationHandler`, `withSamplingHandler`, `withRootsHandler`. |
| `<Feature> is not supported by the server` | A `strict` client checked the server's capabilities before sending. | Check `serverCapabilities` first, or use the default configuration. |
| `<Feature> is not supported by the client` | A `strict` server checked the client's capabilities before a server request. | Declare the capability in `Client(capabilities:)`. |
| `No handler registered for <method>` | The client received an input request it has no handler for. | Register the handler. |

### -32602 Invalid params

| Detail | Cause | Fix |
|---|---|---|
| `Invalid params for <method>: ...` | The parameters do not decode as the method's `Parameters`, including `inputResponses: null`. | Fix the request; omit `inputResponses` instead of sending `null`. |
| `Missing or invalid _meta field "io.modelcontextprotocol/clientCapabilities"` | A stateless request without valid client capabilities. Also `Invalid _meta field` for a bad `protocolVersion` or `clientInfo`. | Send the full `_meta` envelope; `Client` does this. |
| `Missing _meta field "io.modelcontextprotocol/protocolVersion"` | An HTTP request whose `MCP-Protocol-Version` header names a stateless revision, without the version in `_meta`. | Send both. |
| `Invalid or expired requestState` | The `requestState` of an input-required round did not verify. The server logs the reason at `warning` (`requestState rejected`). | See below. |
| A message with `data.uri` | The resource does not exist: the client decodes it as `MCPError.resourceNotFound(uri:message:)`. Servers throw that case. | Match `resourceNotFound`. |

A sealed `requestState` fails to verify when:

- it was changed, or was not issued by this server;
- its round is older than the time to live, 600 seconds by default;
- another process sealed it: the default key, `.ephemeral()`, exists only in
  one process and does not survive a restart;
- it was sealed for another method, tool, prompt, resource, arguments,
  audience or principal.

For several instances, or across restarts, give every instance the same keys
with `RequestStateProtection(keys:)`. After a rejection, the client must start
the request again without `requestState`. See [server.md](server.md#protecting-requeststate).

### -32600 Invalid request

| Detail | Cause | Fix |
|---|---|---|
| `<method> cannot be sent at protocol version 2026-07-28` | A handler of a stateless request called `requestSampling`, `requestElicitation` or `listRoots`. | Return an input-required result; see [Era mix-ups](#era-mix-ups). |
| `Server is already initialized` | A second `initialize` reached the same `Server`. | Use one `Server` per session or connection. |
| `Server is not initialized` | A `strict` server received a request before `initialize`. | Connect with `connect(transport:)`, which initializes. |
| `<method> requires input; enable Configuration.multiRoundTrip or use send(_:)` | `callTool`, `getPrompt` or `readResource` received an input-required result while `multiRoundTrip.isEnabled` is `false`. | Enable it, or call `send(_:)` and run the rounds. |
| `subscriptions/listen requires protocol version 2026-07-28 or later` | `Client.listen(_:)` on a handshake connection. | Register list-changed handlers instead; the server sends the notifications on the connection. |

### -32020 Header mismatch

At 2026-07-28, HTTP requests repeat parts of the body in headers (SEP-2243).
`StatelessHTTPServerTransport` answers HTTP 400 and -32020 when:

- `Mcp-Method` is missing or differs from the JSON-RPC method;
- `Mcp-Name` is missing or differs from `params.name` (`tools/call`,
  `prompts/get`) or `params.uri` (`resources/read`);
- the `MCP-Protocol-Version` header differs from the `_meta` version, or is
  missing while `_meta` names a stateless revision.

`Server` answers -32020 when the `Mcp-Param-*` headers of a `tools/call` do not
match the arguments that the tool's schema marks with `x-mcp-header`, when a
call carries `Mcp-Param-*` headers for a tool it does not list, and for a call
to a tool with an invalid annotation. After a change to the tool list, send
`ToolListChangedNotification`: until then the server checks calls against the
schemas it read before.

`Client` with `HTTPClientTransport` sends these headers itself. A mismatch
usually means a proxy changed or removed headers, or a hand-built request.
A custom or wrapping transport receives the `Mcp-Param-*` headers through
`send(_:additionalHeaders:)`; one that keeps the default implementation drops
them.
Values that are not printable ASCII are sent as `=?base64?<Base64>?=`; build
them with `MCPRequestHeaders.encode(_:)`.

### -32021 Missing required client capabilities

At 2026-07-28, a handler returned input requests for capabilities that the
request's `_meta` does not declare: elicitation (`form` or `url`), sampling
or roots. `data.requiredCapabilities` lists them, and
`MCPError.missingRequiredClientCapabilities` carries them as
`Client.Capabilities`.

- Client: declare the capability in `Client(capabilities:)` and register the
  matching handler.
- Server: check `Server.currentHandlerContext?.clientCapabilities` before
  asking, and return a result that works without the input.

In the handshake era the server sends the request itself; a client without a
handler answers -32601.

### -32022 Unsupported protocol version

| Source | Cause |
|---|---|
| `Server` | A stateless request for a version that is not in `Configuration.protocolVersions`. |
| `ProtocolVersionValidator` | An `MCP-Protocol-Version` header the transport does not serve. |
| `StatefulHTTPServerTransport` | A request whose header names a stateless revision; the data lists `Version.handshake`. |

`data.supported` lists the versions the server serves. A `.automatic` client
retries with one of them, or falls back to `initialize`; a `.stateless(_:)`
client throws. Over HTTP, route requests with a
stateless `MCP-Protocol-Version` to a `StatelessHTTPServerTransport`
(`HTTPRequest.statelessProtocolVersion`). See
[protocol_versions.md](protocol_versions.md).

### HTTP status codes

Server transports:

| Status | Transport | Cause |
|---|---|---|
| 400 | both | Empty body or invalid JSON-RPC; an unsupported `MCP-Protocol-Version` header (-32022). |
| 400 | stateless | At 2026-07-28, JSON-RPC errors -32600, -32602, -32020, -32021 and -32022. |
| 400 | stateful | No session yet (`Session not initialized`), a missing `Mcp-Session-Id`, a second `initialize` on the session, an unknown `Last-Event-ID`, a stateless request (-32022). |
| 403 | both | An `Origin` header that the `OriginValidator` does not allow. |
| 404 | stateless | At 2026-07-28, -32601; any request after the transport stopped. |
| 404 | stateful | An unknown or expired `Mcp-Session-Id`; any request after the session ended. |
| 405 | stateless | Any method other than POST. The `Allow` header is `POST`. |
| 405 | stateful | Any method other than GET, POST and DELETE. |
| 406 | both | An `Accept` header without `application/json` (stateless), or without both `application/json` and `text/event-stream` (stateful POST). |
| 409 | stateful | A second GET stream for the session. |
| 415 | both | A POST whose `Content-Type` is not `application/json`. |
| 421 | both | A `Host` header that the `OriginValidator` does not allow. |
| 503 | stateless | The transport stopped before the server answered. |

The stateless transport's default pipeline is `OriginValidator.localhost()`,
`AcceptHeaderValidator(mode: .jsonOnly)`, `ContentTypeValidator()` and
`ProtocolVersionValidator()`. Behind a proxy or on a public host, pass a
pipeline with `OriginValidator(allowedHosts:allowedOrigins:)` listing the
public host names and the browser origins you allow. A server behind a proxy
is often an internal service that a web page visited by an employee can reach
through DNS rebinding; the Host and Origin checks stop that, and the MCP
specification requires the Origin check. `OriginValidator.disabled` turns off
both: use it only for a server that authenticates every request and that no
browser can reach.

`HTTPClientTransport` delivers the JSON-RPC error of a non-2xx response as
the request's error when the error's ID is the request's ID. Otherwise it throws `MCPError.internalError`
with `Bad request` (400), `Session expired` or `Endpoint not found` (404),
`Server does not support streaming` or `Method not allowed` (405),
`Request timeout` (408), `Too many requests` (429), or `Server error: <status>`
(5xx). A 404 with a session drops the session ID. The client does not
initialize a new session on its own; after `Session expired`, connect a new
client.

A POST response stream that ends before its response, and that the transport
cannot resume, fails its request with -32603: `The server closed the response
stream without a response or an event ID to resume from` (the stream had no
event IDs), or `The response stream could not be resumed` (the server refused
the GET with `Last-Event-ID`, or closed the stream 10 times). The server keeps
no events for replay. At 2026-07-28 there is no resumption, and the message is
`The server closed the response stream without a response`.

### Era mix-ups

Each era has features the other lacks; see
[protocol_versions.md](protocol_versions.md#features-by-version).

| Symptom | Cause | Fix |
|---|---|---|
| `requestSampling`, `requestElicitation` or `listRoots` fails with -32600 | The handler serves a stateless request. | Return an input-required result, which works in both eras (below). |
| A raw `logging/setLevel` fails with -32601 at 2026-07-28 | The method was removed. | Call `Client.setLoggingLevel(_:)`, or set `Configuration.logLevel`. Servers read `currentHandlerContext?.logLevel`. |
| `logging/setLevel` fails with -32601 in the handshake era | `Server` has no built-in handler. | Register a `SetLoggingLevel` handler. |
| No log notifications at 2026-07-28 | The request's `_meta` has no log level, or the message is below it. | Set `Client.Configuration.logLevel`. |
| No list-changed notifications at 2026-07-28 | They are sent only on listen streams. | Register the list-changed handler on the client, declare `listChanged` on the server, and send with `server.notify(_:)`. |
| A `.handshake` client cannot connect to a stateless-only server | The server refuses `initialize`. | Connect with `.automatic`. |

A handler that asks for input in both eras:

%include Examples/Snippets/Guides/Troubleshooting.swift era-neutral-input

At 2026-07-28 the client answers the input request and retries. For
`initialize` clients the server sends `elicitation/create` itself and calls
the handler at most 10 times. The client needs the elicitation capability
(-32021 without it) and an elicitation handler in both eras. Without the
handler, the call fails with -32601 at 2026-07-28 and with -32603 for
`initialize` clients, which answer the server's `elicitation/create` with
-32601.

### OAuth failures

`HTTPClientTransport` reports OAuth failures as
`MCPError.internalError("Authorization flow failed: <description>")`, where
the description is that of an `OAuthAuthorizationError`. Without an
authorizer, a 401 is `Authentication required` and a 403 is
`Access forbidden`.

| Description starts with | Case | Cause |
|---|---|---|
| `Authorization server issuer mismatch` | `authorizationServerIssuerMismatch` | The metadata's `issuer` differs from the issuer its URL was built from (RFC 8414 §3.3), for example by case or a trailing slash on a path. Only a trailing slash on a root issuer is tolerated. To trust such a server, set it in `endpointOverrides.authorizationServerURL`. |
| `Authorization metadata at <url> is unavailable: ...` | — | Discovery got a network error, a timeout or a status other than 404 and 410. Nothing is cached; the next request tries again. |
| `Authorization response issuer mismatch` | `authorizationResponseIssuerMismatch` | The redirect's `iss` differs from the metadata's `issuer`. The comparison is exact. |
| `Authorization response is missing the iss parameter` | `authorizationResponseMissingIssuer` | The server advertises `authorization_response_iss_parameter_supported`, and the redirect has no `iss`. |
| `Authorization server metadata must include code_challenge_methods_supported` | `pkceCodeChallengeMethodsMissing` | The metadata does not advertise PKCE. |
| `Authorization server metadata must support PKCE S256` | `pkceS256NotSupported` | The metadata lists PKCE methods without `S256`. |
| `No authorization server was found` | `missingAuthorizationServer` | The protected resource metadata names no authorization server. |
| `Authorization response state mismatch` | `authorizationResponseStateMismatch` | The redirect does not belong to this authorization request. |

Issuer mismatches are configuration errors on the server side: the issuer in
the metadata must equal the URL that serves it, with no other normalization.
The previous release accepted such metadata; see
[migration.md](migration.md#authorization).

### Timeouts

`Client` has no request timeout: a request waits for its response, for
`cancelRequest(_:reason:)`, or for `disconnect()`. To bound a call, cancel it
after a deadline:

%include Examples/Snippets/Guides/Troubleshooting.swift timeout

`cancelRequest` makes the waiting call throw `CancellationError` and tells the
server: it sends `notifications/cancelled`, or at 2026-07-28 over HTTP closes
the request's response stream. The server cancels the handler's task. For a
request with input-required rounds, it cancels the current round.

Other causes of requests that do not complete:

- A stdio server that writes logs to standard output. The client cannot
  decode those lines and logs `Unexpected message received by client` at
  `warning`.
- `URLSessionConfiguration.timeoutIntervalForRequest` bounds HTTP requests,
  and `HTTPClientTransport(sseInitializationTimeout:)` (10 seconds) bounds the
  wait for a session ID before the GET stream opens.
- A custom `URLSessionConfiguration` with the system's per-host connection
  limit (6 on Apple platforms). At 2025-11-25 over HTTP/1.1, concurrent calls
  that each wait for a sampling, elicitation or roots reply hold every
  connection, and the replies cannot be sent. Start from
  `HTTPClientTransport.defaultConfiguration`, or set
  `httpMaximumConnectionsPerHost` above the number of concurrent requests
  plus one.
- Input-required rounds that carry only `requestState` are retried after
  50 ms, doubling up to 250 ms. After `multiRoundTrip.maxRounds` (10) retries
  the call fails with -32603.
