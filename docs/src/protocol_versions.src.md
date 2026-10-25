# Protocol versions

The SDK serves two eras of the Model Context Protocol at once. Revisions up to
2025-11-25 open a connection with the `initialize` handshake. Revision
2026-07-28 has no handshake: every request describes its client in `_meta`.
This guide describes how the server classifies requests, how the client
chooses an era, and what differs between the eras.

## The two eras

| | Handshake era | Stateless era |
|---|---|---|
| Revisions | 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05 | 2026-07-28 |
| Connection | `initialize`, then `notifications/initialized` | none; `server/discover` is optional |
| Client capabilities | sent once, in `initialize` | sent in every request's `_meta` |
| Server state per client | yes; over HTTP, a session (`Mcp-Session-Id`) | none |
| Server-to-client requests | yes | no; servers return input requests instead |

A stateless request carries these `_meta` keys (constants in `MetaKey`):

| Key | Required | Meaning |
|---|---|---|
| `io.modelcontextprotocol/protocolVersion` | yes | The revision of this request. |
| `io.modelcontextprotocol/clientCapabilities` | yes | The client's capabilities for this request. |
| `io.modelcontextprotocol/clientInfo` | no | The client implementation. |
| `io.modelcontextprotocol/logLevel` | no | The lowest log level the client wants for this request. |

`Metadata` has typed accessors for them: `protocolVersion`,
`clientCapabilities`, `clientInfo`, `logLevel` and, on results, `serverInfo`.

## Version lists

`Version` (in `Sources/MCP/Base/Versioning.swift`) is the single source of
truth:

%include Examples/Snippets/Guides/ProtocolVersions.swift versions-constants

| Member | Meaning |
|---|---|
| `Version.handshake` | Revisions served through `initialize`, newest first. |
| `Version.stateless` | Revisions served per request, newest first. |
| `Version.supported` | Today `Set(Version.handshake)`. 2026-07-28 is served, but not listed here yet. |
| `Version.latest` | 2025-11-25. The client requests it in `initialize`, and `HTTPClientTransport` sends it in the `MCP-Protocol-Version` header until a version is negotiated. |
| `Version.v2024_11_05` ... `Version.v2026_07_28` | One constant per revision. |

A later release adds 2026-07-28 to `Version.supported` and makes
`.automatic` the client's default mode ([ROADMAP.md](../ROADMAP.md)).
`Version.latest` stays a handshake revision: it is the version that
`initialize` requests. Code that needs every served revision reads
`Version.stateless + Version.handshake`.

## Protocol profiles

`Version.profile(for:)` returns a `ProtocolProfile`: the features that differ
between revisions. Code that behaves differently per revision reads these
flags instead of comparing version strings.

| Flag | 2024-11-05 | 2025-03-26 to 2025-11-25 | 2026-07-28 |
|---|---|---|---|
| `usesInitializeHandshake` | true | true | false |
| `usesRequestMeta` | false | false | true |
| `usesResultType` | false | false | true |
| `usesSessions` | true | true | false |
| `allowsServerRequests` | true | true | false |
| `usesSubscriptionsListen` | false | false | true |
| `usesStandardHeaders` | false | false | true |
| `allowsPrimingEvents` | false | true | false |

Versions are compared as `YYYY-MM-DD` strings, so an unknown later version,
such as `2099-01-01`, gets the 2026-07-28 profile.

In a handler, `Server.currentHandlerContext?.profile` is the profile of the
request being handled:

%include Examples/Snippets/Guides/ProtocolVersions.swift versions-profile

## Server

### Configured versions

`Server.Configuration.protocolVersions` lists the revisions the server serves,
newest first. The default is `Version.stateless + Version.handshake`: both
eras.

%include Examples/Snippets/Guides/ProtocolVersions.swift versions-server-config

- `initialize` returns the requested version when it is a configured handshake
  revision, and otherwise the first configured handshake revision.
- `server/discover` returns `protocolVersions` as `supportedVersions`, with
  the server's capabilities and instructions. The server answers it without a
  handler of yours.
- A stateless request for a version that is not configured fails with -32022.

### Classifying a request

`Server` classifies every request by its `_meta` before it runs a handler
(`StatelessRequests.classify` in `Sources/MCP/Server/StatelessRequests.swift`):

1. No `io.modelcontextprotocol/protocolVersion`: handshake era.
2. A value that is not a non-empty string: -32602.
3. A handshake revision: handshake era.
4. Any other version: `clientCapabilities` must be present and valid, and
   `clientInfo` valid when present; otherwise -32602.
5. A version that is not in `protocolVersions`: -32022, with
   `data.supported` (the configured list) and `data.requested`.
6. Otherwise: stateless era, at that version.

Then the server checks the method:

| Era | Check | Error |
|---|---|---|
| Handshake | `server/discover` and `subscriptions/listen` | -32601 |
| Handshake | With `Configuration.strict`, a request other than `initialize` or `ping` before `initialize` | -32600 |
| Stateless | `initialize`, `ping`, `logging/setLevel`, `resources/subscribe`, `resources/unsubscribe` | -32601 |
| Stateless | A method of a capability the server does not declare: `tools/*` without `tools`, `prompts/*` without `prompts`, `resources/*` without `resources`, `completion/complete` without `completions` | -32601 |
| Both | No handler for the method | -32601 |

A handshake-era request is served whether or not the client sent `initialize`,
unless `strict` is set.

### What a handler sees

`Server.currentHandlerContext` describes the request being handled:

| Member | Handshake era | Stateless era |
|---|---|---|
| `protocolVersion` | The version negotiated by `initialize`, or `nil` before it | From `_meta` |
| `clientCapabilities` | From `initialize` | From `_meta` |
| `clientInfo` | From `initialize` | From `_meta`, if sent |
| `logLevel` | `nil` | From `_meta`, if sent |
| `isStateless` | `false` | `true` |
| `profile` | The profile of `protocolVersion` | The profile of `protocolVersion` |
| `httpContext` | The HTTP request, on HTTP transports | The HTTP request, on HTTP transports |

%include Examples/Snippets/Guides/ProtocolVersions.swift versions-handler-era

### What changes for stateless requests

For a stateless request, the server also:

- adds `resultType: "complete"` to the result when the handler did not set it;
- adds `_meta["io.modelcontextprotocol/serverInfo"]`;
- adds `ttlMs` and `cacheScope` to complete results of `tools/list`,
  `prompts/list`, `resources/list`, `resources/templates/list`,
  `resources/read` and `server/discover`, when the result does not set them.
  The values come from `Configuration.cacheHints[method]`, else
  `Configuration.defaultCacheHint` (`.uncached`: 0 ms, private);
- sends a `log(level:logger:data:)` notification only when the request's
  `_meta` log level is set and the message is at or above it;
- refuses `requestSampling`, `requestElicitation` and `listRoots` with -32600.
  Handlers return an input-required result instead; see
  [server.md](server.md#multi-round-trip-requests);
- delivers list-changed and resource-updated notifications only on
  `subscriptions/listen` streams.

## Client

### Protocol modes

`Client.Configuration.protocolMode` selects how `connect(transport:)` opens the
connection. The default is `.handshake`.

%include Examples/Snippets/Guides/ProtocolVersions.swift versions-client-modes

| Mode | First request | Fallback |
|---|---|---|
| `.handshake` | `initialize` at `Version.latest` | none |
| `.automatic` | `server/discover` at `Version.stateless[0]` (2026-07-28) | `initialize` |
| `.stateless(version)` | `server/discover` at `version` | none; `connect` throws |

### Negotiation and fallback

For `.automatic` and `.stateless(_:)`, the client sends `server/discover` with
the `_meta` envelope of the requested version, then:

1. On success, it uses the requested version when `supportedVersions` lists
   it. Otherwise `.automatic` uses the first listed version that is in
   `Version.stateless`, or sends `initialize` when there is none, and
   `.stateless` throws `MCPError.unsupportedProtocolVersion`.
2. On -32022, `.automatic` retries `server/discover` once, with the first
   version in `data.supported` that is in `Version.stateless`. `.stateless(_:)`
   never retries with another version.
3. When no retry is possible, `.automatic` sends `initialize` if
   `data.supported` is empty or lists a handshake revision; otherwise the
   client throws the -32022 error.
4. On any other JSON-RPC error from the server, for example -32601 from a
   server that predates `server/discover`, `.automatic` sends `initialize` and
   `.stateless` throws.
5. On HTTP 400, 404 or 405 without a JSON-RPC error for the request, the
   refusal of a server that serves only the handshake, `.automatic` sends
   `initialize`.
6. When no answer arrives within `Client.Configuration.discoveryTimeout`
   (10 seconds by default), `.automatic` sends `initialize`. `.stateless`
   waits.
7. Other transport errors are rethrown: authorization failures, 401 and 403
   after the authorization attempts, 408, 429, 5xx, `transportError`, and
   errors that are not `MCPError`, such as a `URLError`.

%include Examples/Snippets/Guides/ProtocolVersions.swift versions-client-connect

After `connect`, `negotiatedProtocolVersion`, `serverInfo`,
`serverCapabilities` and `isStateless` describe the connection. On a stateless
connection, `connect` returns an `Initialize.Result` built from the
`server/discover` result; its `serverInfo` comes from the result's `_meta` and
has an empty name and version when the server sent none.

### Stateless connections

On a stateless connection the client:

- adds the `_meta` envelope to every request; keys already in the request's
  `_meta` win. `logLevel` comes from `Configuration.logLevel`;
- sends no `Mcp-Session-Id` and opens no GET stream over HTTP
  (`HTTPClientTransport.useStatelessProtocol(_:)`), and adds the `Mcp-Method`,
  `Mcp-Name` and `Mcp-Param-*` headers;
- sends `server/discover` for `ping()`;
- stores the level of `setLoggingLevel(_:)` in `Configuration.logLevel`
  instead of sending `logging/setLevel`;
- does nothing in `notifyRootsChanged()`;
- answers input-required results with its sampling, elicitation and roots
  handlers, and retries the request;
- opens `subscriptions/listen` streams for list-changed handlers and for
  `subscribeToResource(uri:)`. See [client.md](client.md#notifications-and-subscriptions).

## Features by version

| Feature | 2025-11-25 and earlier | 2026-07-28 |
|---|---|---|
| `initialize`, `notifications/initialized` | yes | removed: -32601 |
| `server/discover` | -32601 | yes |
| `ping` | yes | removed: -32601; `Client.ping()` sends `server/discover` |
| `logging/setLevel` | yes, when the server registers a handler | removed: -32601; the level is in `_meta` |
| `resources/subscribe`, `resources/unsubscribe` | yes, when the server registers handlers | removed: -32601; use `subscriptions/listen` |
| `subscriptions/listen` | -32601 | yes; the server handles it |
| Unsolicited list-changed and resource-updated notifications | yes | only on listen streams |
| Server requests: sampling, elicitation, roots | yes | no: -32600 |
| Input-required results | the server sends the requests itself and calls the handler at most 10 times | sent to the client; `requestState` is sealed |
| `resultType` in results | no | yes |
| `_meta` server info in results | no | yes |
| `ttlMs`, `cacheScope` | only when the handler sets them | filled for cacheable methods |
| Methods of undeclared capabilities | served when a handler exists | -32601 |
| Log notifications | every `log` call | only at or above the request's `_meta` level |
| HTTP sessions, GET stream, `Last-Event-ID` | yes (`StatefulHTTPServerTransport`) | no |
| `Mcp-Method`, `Mcp-Name`, `Mcp-Param-*` headers | no | required (-32020 when wrong) |
| HTTP status of JSON-RPC errors | 200; 400 for -32022 | 404 for -32601; 400 for -32600, -32602, -32020, -32021, -32022; else 200 |
| Error codes -32020, -32021, -32022 | -32022 only, for an unsupported `MCP-Protocol-Version` header | yes |

## Serving one era

### Handshake only

Configure `protocolVersions: Version.handshake` (the `handshakeOnly`
configuration above). Stateless requests, including `server/discover`, then
fail with -32022, and `.automatic` clients fall back to `initialize`. Over
HTTP, a `StatefulHTTPServerTransport` alone also serves only this era: it
answers requests whose `MCP-Protocol-Version` header names a stateless
revision with HTTP 400 and -32022, listing `Version.handshake`.

### Stateless only

Configure `protocolVersions: Version.stateless`:

%include Examples/Snippets/Guides/ProtocolVersions.swift versions-stateless-only

The server then answers `initialize`, and every other request without a
stateless `io.modelcontextprotocol/protocolVersion`, with -32022 listing
`Version.stateless`. A `.handshake` client fails to connect with -32022, and
an `.automatic` client connects at 2026-07-28.

### Clients

A `.handshake` client never sends `server/discover`. A `.stateless(_:)` client
never sends `initialize`. See [migration.md](migration.md) for opting in, and
[troubleshooting.md](troubleshooting.md#era-mix-ups) for era mix-ups.
