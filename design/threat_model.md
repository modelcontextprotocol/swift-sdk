# Threat model

What the SDK defends against, where, and what it leaves to the application. Report
vulnerabilities as described in [SECURITY.md](../SECURITY.md).

## Trust boundaries

| Boundary | Untrusted side | Trusted side |
|---|---|---|
| HTTP server transports | any HTTP client that reaches the endpoint | the application's handlers |
| `Server` | the peer's JSON-RPC messages, `_meta`, `requestState` | the handlers and their configuration |
| `Client` | the server's responses, notifications and server-to-client requests | the application and its sampling, elicitation and roots handlers |
| OAuth client | the MCP server, its metadata, and every URL it names | the configured authorization server, endpoints and credentials |
| stdio, in-memory, `NetworkTransport` | none: the peer owns the connection | |

The SDK assumes that the host's HTTP framework terminates TLS, and that a server's adapter
cancels the request task when its client disconnects (`docs/server.md`).

## Adversaries

- **A hostile client** of an HTTP server: forged headers, malformed or oversized bodies, replayed
  or forged `requestState`, a session or subscription it should not reach, request floods.
- **A hostile or compromised MCP server** facing a client: malformed SSE, endless streams,
  server-to-client request floods, `inputRequests` amplification, error bodies built to hang a
  request, OAuth metadata that points credentials at another host or an internal address.
- **A web page in the user's browser** (DNS rebinding, cross-origin POSTs) against a local server.

Out of scope: a compromised host process, the application's own handlers, the network below TLS,
and side channels other than the `requestState` principal tag (compared in constant time).

## Server side

**Request validation.** `StandardValidationPipeline` runs on every HTTP request before decoding.
`OriginValidator.localhost()`, the default, refuses a `Host` that is not a loopback host (421) and an
`Origin` that is not a loopback origin (403): the defense against DNS rebinding and cross-origin
POSTs. A deployed server replaces it with its own hosts and origins. `AcceptHeaderValidator`, `ContentTypeValidator` and `ProtocolVersionValidator` reject what
the transport would misread. The stateful transport adds `SessionValidator`. Authorization is
opt-in: `BearerTokenValidator` and `ProtectedResourceMetadataValidator`.

**Era confusion.** A request with a 2026-07-28 `_meta` version cannot bypass `initializeHook` or
`strict`. With a hook and no `statelessRequestHook`, stateless requests are refused with -32022, as
they are by the stateful transport. The stateless transport answers a header that differs from
`_meta` with -32020. Methods removed at 2026-07-28 are -32601 there, so a stateless request cannot change
per-connection state ([stateless.md](stateless.md)).

**Cross-client isolation.** `StatelessHTTPServerTransport` replaces each request id with
`mcp-http-<uuid>` and restores it on the way out, so a client cannot address another's response,
cancellation or listen stream. `withSubscriptionAuthorizer` narrows or refuses a listen filter, and
`notify(_:to:)` targets callers ([subscriptions.md](subscriptions.md)).

**`requestState`.** Sealed with AES-GCM under a random nonce; the key id and version prefix are
authenticated. It is bound to the method, the name or URI, a hash of the arguments, the audience
and, when `principal` is set, the caller. It expires after `timeToLive` (600 s), and `consume`
makes it single-use. Any failure is the same -32602 ([mrtr.md](mrtr.md)). Without `principal`,
state sealed for one user verifies for another.

**`Mcp-Param-*` headers.** Header names are restricted to RFC 9110 token characters; values outside
printable ASCII are base64-wrapped and strictly decoded. Validation fails closed when the tool's
schema cannot be resolved. Tool schemas are cached per `tools/list` handler
([request_headers.md](request_headers.md)).

**Resource bounds.**

| What | Bound |
|---|---|
| Messages buffered per stateless exchange | `StatelessHTTPServerTransport.maxBufferedMessages` (1024) |
| Replay store per stateful session | 1000 events and 16 MiB (`eventStoreCapacity`, `eventStoreByteCapacity`) |
| Listen streams per server, URIs per stream | `maxSubscriptionStreams` (1000), `maxResourceSubscriptions` (256), 4096-byte URIs |
| `x-mcp-header` annotations, schema depth | 64, 32 |
| `tools/list` pages read to resolve a schema | 100 |
| Bridged multi round-trip rounds | 10 |

The transports do not bound request bodies, the number of sessions, or idle time: the HTTP
framework does. `Examples/http-server` shows a body limit (4 MiB) and a session cap (100).

## Client side

**Server-to-client requests.** At most `maxConcurrentServerRequests` (4) run at once and 64 more
are queued; the rest, a duplicate in-flight id, and any such request at 2026-07-28 are refused.
`cancelRequest` and `disconnect` cancel them.

**Multi round-trip.** At most `maxRounds` (10) rounds and `maxInputRequests` (16) input requests per
round. Cancelling the call cancels the round in progress.

**HTTP responses.** An SSE line longer than 16 MiB fails the stream. A server's `retry:` is clamped
to 10 ms ... 60 s and reconnects back off to 60 s. A handshake POST stream is resumed at most 10
times. A non-2xx reply is delivered as a JSON-RPC error only when its id matches the request; a
`result` in a non-2xx reply is never delivered. `discoveryTimeout` (10 s) bounds `server/discover`.
Other requests have no default timeout; cancel the awaiting task.

## OAuth client

See [auth.md](auth.md). In short:

- The MCP endpoint, discovery URLs and authorization server endpoints must be HTTPS or loopback
  HTTP. URLs a server names are refused when their host is a private, link-local or reserved IP
  literal, in any spelling (`isPrivateIPHost` parses with `inet_pton`).
- Discovery follows redirects only to URLs that pass the same checks; token, registration and
  exchange requests follow none (`OAuthRedirectGuard`, on every platform).
- Authorization server metadata whose `issuer` differs from the candidate is refused. A refresh
  token is sent only to the server that issued it; a token whose server is unknown is not
  refreshed at one chosen by discovery.
- PKCE with S256 and a checked `state` on the authorization code grant.
- A JWT bearer assertion goes to a token endpoint the application configured. A discovered one
  needs `allowsDiscoveredAuthorizationServer`, and the assertion's `aud` must then name it.
- `handleChallenge` and `prepareAuthorization` run one at a time, and the authorizer's state is
  behind a lock.

Host names are not resolved, so a name that resolves to an internal address is not caught.

## Testing

- Unit and wire tests cover each bound and refusal above.
- `fuzz/` runs libFuzzer with AddressSanitizer on wire decoding, the SSE parser and both HTTP
  server transports. The HTTP targets also check that every server is released after its input
  (CONTRIBUTING.md, "Fuzzing").
- The conformance suite's security scenarios (`auth/*`, DNS rebinding) run in CI.
