# Changelog

Release notes, newest first. Each release lists breaking changes, features, fixes, dependency
changes and deprecations ([VERSIONING.md](VERSIONING.md#release-notes)).

## 1.0.0 (unreleased)

The first release with the 1.x stability promise ([VERSIONING.md](VERSIONING.md)). It adds the
2026-07-28 revision of MCP next to the `initialize`-based revisions (2024-11-05 through
2025-11-25), on one `Server` and one `Client`. Changes since 0.12.1 (`a0ae212`), including the
fixes merged to `main` after it (up to `234e412`), with before and after code:
[docs/migration.md](docs/migration.md).

### Breaking changes

- `MCPError` has four new cases, and `serverError` carries `data`.
- `HTTPResponse.data` and `.error` have new associated values.
- `Client.Capabilities.experimental` is `[String: Value]?`.
- Open structs instead of enums: `OAuthAuthorizationError`, `GrantType`,
  `TokenEndpointAuthentication`, `PrivateKeyJWTSigningAlgorithm`, `BearerTokenValidationResult`,
  `Elicitation.Mode`, `ToolChoice.Mode`.
- An `.unknown` case for kinds from a later revision on the content blocks, `InputRequest`,
  `InputResponse` and `CreateElicitation.Parameters`.
- The `Client` convenience methods return result types; `startToolCall` replaces the
  `RequestContext` overload of `callTool`; `Client.initialize()` is removed.
- `Client.connect(transport:)` returns `Client.ConnectionInfo`.
- The deprecated `Tool.Content` short forms are removed.
- `HTTPClientTransport` throws `transportError(HTTPStatusError)` and
  `transportError(OAuthAuthorizationError)` instead of `internalError` with a message.
- `HTTPClientAuthorizer.authorizationHeader(for:)` is `authorizationHeaders(for:method:)`.
- Clients connect with `ProtocolMode.automatic`: `server/discover` at 2026-07-28, then
  `initialize` for older servers. Servers serve both eras by default.
- `Version.supported` lists 2026-07-28; `Version.handshake` lists the `initialize` revisions
  ([details](docs/migration.md#clients-connect-at-2026-07-28)).
- Swift 6.1 tools are required.

Behavior that can break working code ([docs/migration.md](docs/migration.md#behavior-changes)):

- `MCPError` decoding: -32000 and -32001 decode as `serverError`, -32602 with `data.uri` as
  `resourceNotFound`, and the standard cases without `data.detail` drop their own message text
  ([details](docs/migration.md#mcperror-decoding)).
- A request whose parameters do not decode fails with -32602 instead of -32603.
- `StatefulHTTPServerTransport` answers an unsupported `MCP-Protocol-Version` with -32022 instead
  of -32600.
- Behind `StatelessHTTPServerTransport`, a server with an `initializeHook` and no
  `statelessRequestHook` refuses handshake requests other than `initialize` with -32600.
- `.none(clientID:)` with a client ID that is not empty and not a URL is pre-registered: no
  dynamic client registration. Pass `""` to register.
- Authorization server metadata whose `issuer` does not match fails discovery
  (`authorizationServerIssuerMismatch`) instead of being used.
- `HTTPClientTransport.connect()` after `disconnect()` throws `internalError`: create a new
  transport to reconnect.

### Features

- 2026-07-28: per-request `_meta`, `server/discover`, `subscriptions/listen`,
  `StatelessHTTPServerTransport`, `resultType`, multi round-trip requests with sealed
  `requestState`, `Mcp-Method`/`Mcp-Name`/`Mcp-Param-*` headers, cache hints, `extensions`, error
  codes -32020 to -32022.
- Tasks for `tools/call` at 2025-11-25 (SEP-1686) and the 2026-07-28 tasks extension
  (SEP-2663): `Server.withTasks(_:)`, `runAsTask`, `TaskManager` and `TaskStore` on the server;
  `Client.Configuration.tasks`, `callTool` that drives a task, and `TaskHandle` on the client.
- The skills extension (SEP-2640): `Server.withSkills(_:listInResources:)`, `SkillCatalog`,
  `SkillPackage` and `InMemorySkillCatalog` on the server; `listSkills`, `getSkill`,
  `readResourceDirectory` and `loadSkill`, which verifies size, digest and frontmatter, on the
  client.
- Authorization: issuer checks (RFC 8414, RFC 9207), `application_type`, authorization server
  migration, the JWT bearer grant, enterprise-managed authorization with token exchange, workload
  identity, DPoP.
- Sampling with tools (SEP-1577): `Server.requestSampling` takes `tools` and `toolChoice`. Server
  and client check the `sampling.tools` and `sampling.context` capabilities and the rules for
  tool uses and tool results.
- Request association (SEP-2260): a sampling or elicitation request sent while the server handles
  no client request logs one warning for each method. At 2025-11-25 it is still sent. At
  2026-07-28 a request to the client throws -32600, also from code that handles no request.
- Tool names (SEP-986): `Tool.isValidName(_:)`; server and client log a warning once for each
  listed name that does not have the format of the specification.
- Server Cards (SEP-2127): `ServerCard`, `ServerCardValidator`, which serves a card at
  `<endpoint>/server-card`, and `ServerCard.fetch`, which reads one.
- MCP Apps (SEP-1865): `Server.withAppResources` serves `ui://` views, `Tool.ui` and
  `Resource.ui` read and write `_meta.ui`, and `Client.readAppResource` reads a view with its
  effective metadata and Content Security Policy. No View-Host bridge.
- A built-in `logging/setLevel` handler that filters `Server.log`.
- `statelessRequestHook` on `Server.start`, `HTTPClientTransport.cancelRequest(_:)`,
  `BearerTokenValidationResult.tokenInfo`, and the `HTTPClientAuthorizer` requirement
  `handleChallenge(statusCode:headers:endpoint:operationKey:sentAuthorization:session:)`, with a
  default, which receives the `Authorization` header of the challenged request and returns an
  `HTTPChallengeResult` that says whether the retry is a DPoP nonce retry.
- The `Transport` requirement `send(_:additionalHeaders:)`, with a default that ignores the
  headers, through which the client hands the `Mcp-Param-*` headers of a `tools/call` to any
  transport. A custom Streamable HTTP transport sends them on the request's POST, and a wrapping
  transport forwards them; `HTTPClientTransport` implements it.
- From `main` after 0.12.1: `Server.init` takes `description`, `websiteUrl` and `icons`, sent in
  `serverInfo` and, at 2026-07-28, in the `_meta` server info of every result, with `data:` icon
  URLs as written (#258); `Value.numberValue` reads `.int` and `.double` as `Double` (#226); `Value.init(_:)`
  takes any `Encodable` instead of `Codable` (#227).
- The full list, with the specification references: [ROADMAP.md](ROADMAP.md#implemented-in-100).

### Fixes

- A stopped `Server` is released; every started server leaked before.
- On Linux, `HTTPClientTransport` reads responses as they arrive and handles server-sent events,
  so streamed results, server-to-client requests and notifications arrive as on Apple platforms.
- A 4xx reply (other than 401, 403, 408 and 429) with the request's JSON-RPC error delivers that error;
  408, 429 and 5xx fail with the status error.
- A refresh token goes only to the authorization server that issued it, and concurrent OAuth
  challenges run one at a time.
- Server-to-client requests run off the receive loop, at most four at a time, and can be cancelled.
  The client answers a server `ping`, at once, instead of -32601.
- When the transport ends its receive stream, pending requests fail with `connectionClosed`
  instead of waiting forever; `connect(transport:)` on a connected client disconnects the previous
  transport.
- `data:` URL strings in messages arrive as sent instead of rewritten as base64 `data:` URLs.
- A decoded standard error equals the error that was sent, without its message text repeated.
- OAuth: a challenge keeps the stored tokens when the authorization server metadata cannot be
  read, proactive renewal tries each token once, a failed client registration is tried again,
  `http://[::1]` counts as loopback, and more private address forms are blocked.
- `HTTPStatusError`'s `debugDescription` names the response headers without their values.
- An `HTTPClientTransport` dropped without `disconnect()` is released and stops its GET stream;
  before, it was never released and, with `streaming: true`, kept reconnecting.
- A `connect(transport:)` that throws disconnects the transport and stops the receive loop;
  before, both kept running and kept the client and the transport alive.
- The package builds for iOS, tvOS, watchOS and visionOS: the interop client and the
  `HelloClient` example no longer use `Process` there. CI builds every target for the iOS device
  SDK and runs the tests on an iOS simulator.
- A `tools/call` cancelled while the server's answer creating a task was already on its way gets
  `tasks/cancel` for that task; before, the task could keep running.
- From `main` after 0.12.1: `Data.parseDataURL(_:)` reads `;base64` from the header only and
  decodes any percent-escaped byte (#309, #310); `client_secret_basic` percent-encodes the client
  credentials (RFC 6749 §2.3.1, #300); PKCE verifier characters are uniformly distributed (#303);
  `WWW-Authenticate` parameter values unescape every quoted pair, not only `\"` (#305);
  `NetworkTransport` without reconnection cancels its connection when the receive loop gives up,
  so the socket no longer stays in `CLOSE_WAIT`, and finishes the receive stream with
  `connectionClosed` after repeated empty reads (#283), and then stops its heartbeats (#326);
  `NetworkTransport` clears the connection's state update handler only on the actor's executor,
  which removes a data race (#301); `StdioTransport.disconnect()` waits for
  sends in progress and restores the blocking mode of the descriptors (#297).
- The other behavior changes: [docs/migration.md](docs/migration.md#behavior-changes).

### Dependencies

- Added swift-crypto (`3.0.0..<5.0.0`): `requestState` sealing, PKCE and `private_key_jwt`, also
  on Linux.
- Added Yams (`from: "6.0.0"`): the YAML frontmatter of skills (SEP-2640).
- Removed eventsource: `HTTPClientTransport` parses server-sent events itself.
- swift-docc-plugin is required `from: "1.4.0"` instead of its `main` branch, so packages can
  depend on a released version of `MCP`.

### Deprecations

- `Version.latest`: use `Version.latestHandshake`.
- Roots, sampling and logging, deprecated by the specification (SEP-2577): `Server.requestSampling`,
  `listRoots`, `log(level:logger:data:)`; `Client.withSamplingHandler`, `withRootsHandler`,
  `notifyRootsChanged`, `setLoggingLevel`. They work on every revision that has them. The server
  logs a notice the first time a client declares `roots` or `sampling`, the client when a server
  declares `logging`.
- `Sampling.ContextInclusion.thisServer` and `.allServers` (SEP-2596): omit `includeContext`, or
  use `.none`.
- The list, with the migrations:
  [docs/rough_edges.md](docs/rough_edges.md#deprecated-by-the-specification).
- `CreateSamplingMessage.ToolChoice.init(mode:)` with an optional mode: pass a `Mode`. With an
  optional parameter, `.none` is `nil`, which is `auto`.
