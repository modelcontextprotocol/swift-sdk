# Roadmap

Status of the MCP Swift SDK against the MCP specification and what is deferred. Design background: [design/design.md](design/design.md). Versioning rules:
[VERSIONING.md](VERSIONING.md).

## Specification revisions

| Revision | Era | Server | Client | Notes |
|---|---|---|---|---|
| 2026-07-28 | stateless | served by default (`Server.Configuration.protocolVersions`) | default: `ProtocolMode.automatic`, or pinned with `.stateless("2026-07-28")` | `Version.stateless[0]` |
| 2025-11-25 | handshake | yes | yes; the `.automatic` fallback and `.handshake` | `Version.latestHandshake` |
| 2025-06-18 | handshake | yes | yes | |
| 2025-03-26 | handshake | yes | yes | |
| 2024-11-05 | handshake | yes | yes | over stdio and Streamable HTTP; the HTTP+SSE transport of that revision is not implemented |

A server answers both eras on one `Server`. See [docs/protocol.md](docs/protocol.md) for the
lifecycle and [docs/migration.md](docs/migration.md) for upgrading.

## Implemented in 1.0.0

### 2026-07-28 core

| Feature | SEP | API | Design |
|---|---|---|---|
| Per-request `_meta` (protocol version, client capabilities, client info, log level) | SEP-2575 | `MetaKey`, `Metadata` accessors, `Server.HandlerContext` | [stateless.md](design/stateless.md) |
| `server/discover` | SEP-2575 | `ServerDiscover`, `Client.ProtocolMode` | [stateless.md](design/stateless.md) |
| `subscriptions/listen` | SEP-2575 | `Client.listen(_:)`, `Client.Subscription`, `Server.closeSubscriptions()` | [subscriptions.md](design/subscriptions.md) |
| Stateless HTTP serving | SEP-2575 | `StatelessHTTPServerTransport`, `HTTPRequest.statelessProtocolVersion` | [stateless.md](design/stateless.md) |
| `resultType` on results | SEP-2322 | `ResultType`, result annotation | [stateless.md](design/stateless.md) |
| Multi round-trip requests | SEP-2322 | `InputRequest`, `InputResponse`, `.inputRequired(_:requestState:_meta:)`, `RequestStateProtection` | [mrtr.md](design/mrtr.md) |
| Standard and custom request headers | SEP-2243 | `MCPRequestHeaders`, `Tool.headerParameters()` | [request_headers.md](design/request_headers.md) |
| Cache hints | SEP-2549 | `CacheableResult`, `CacheHint`, `Server.Configuration.cacheHints` | [stateless.md](design/stateless.md) |
| Resource not found as -32602 with `data.uri` | SEP-2164 | `MCPError.resourceNotFound(uri:message:)` | [design.md](design/design.md#error-model) |
| `extensions` capability | SEP-2133 | `Client.Capabilities.extensions`, `Server.Capabilities.extensions` | |
| Error codes -32020, -32021, -32022 | | `MCPError.headerMismatch`, `.missingRequiredClientCapabilities`, `.unsupportedProtocolVersion` | [design.md](design/design.md#error-model) |
| Protocol profiles | | `Version.profile(for:)`, `ProtocolProfile` | [design.md](design/design.md#the-dual-era-model) |

### Authorization

| Feature | Reference | API |
|---|---|---|
| AS metadata issuer must match | RFC 8414 §3.3, SEP-2468 | `OAuthAuthorizationError.authorizationServerIssuerMismatch` |
| `iss` in the authorization response | RFC 9207, SEP-2468 | `OAuthAuthorizationCodeFlow.ExpectedIssuer` |
| `application_type` in DCR | SEP-837 | `OAuthConfiguration.applicationType` |
| Authorization server migration | SEP-2352 | `OAuthAuthorizer` 401 handling |
| 2025-03-26 default endpoints | 2025-03-26 spec | fallback in `OAuthAuthorizer` |
| JWT bearer grant | RFC 7523 | `OAuthConfiguration.GrantType.jwtBearer`, `assertionProvider` |
| Enterprise-managed authorization | SEP-990, RFC 8693 | `OAuthConfiguration.enterpriseManaged(...)`, `OAuthTokenExchange` |
| Workload identity | SEP-1933 | `.jwtBearer` with a public client |
| DPoP-bound access tokens | RFC 9449, SEP-1932 | `OAuthConfiguration.dpop`, `HTTPClientAuthorizer.authorizationHeaders(for:method:)` |

Details: [design/auth.md](design/auth.md).

### 2025-11-25 reliability

- Notifications and server-to-client requests from a handler travel on the stream of the request
  that caused them (`Transport.send(_:relatedRequestID:)`).

## Planned

Not implemented yet. The conformance harness exercises these only in the default leg, as
extension scenarios that do not count toward a tier; their failing checks are the entries in
[conformance/baseline.yml](conformance/baseline.yml).

| Item | Reference | Baseline entries |
|---|---|---|
| Tasks extension `io.modelcontextprotocol/tasks` | SEP-2663 | 25 (server, `tasks-*`) |
| Experimental tasks of 2025-11-25 | SEP-1686 | none: the harness has no 2025-11-25 tasks scenarios |
| Skills extension `io.modelcontextprotocol/skills` | SEP-2640 | 0: the 7 `sep-2640-*` scenarios (3 server, 4 client) SKIP while no fixture declares the extension |

Tasks scope: every revision that defines tasks.

- 2026-07-28: SEP-2663 (server-directed; flat `CreateTaskResult` with `resultType: "task"`;
  `tasks/get`, `tasks/update`, `tasks/cancel`; -32021 gating; `Mcp-Name` routing;
  `notifications/tasks` on `subscriptions/listen`). `tasks/result`, `tasks/list` and the `task`
  request parameter stay removed there.
- 2025-11-25: SEP-1686 for `tools/call` (the `task` request parameter, `Tool.execution`,
  `tasks/get`, `tasks/result`, `tasks/list`, `tasks/cancel`, `notifications/tasks/status`).
  Tasks hosted by the client (task-augmented sampling and elicitation) are deferred.
- Earlier revisions define no tasks: the work runs inline.
- Server: one task store (`TaskStore` protocol, in-memory default) behind both wire forms;
  tool handlers that run as a task.
- Client: `callTool` drives a returned task to its result at either revision, and a low-level
  task handle.

Skills scope: wire types, a `SkillCatalog` that serves skills through `skills/list`,
`skills/get`, `resources/read` and `resources/directory/read`, and a client loader that
verifies size, digest and frontmatter. Frontmatter is parsed with Yams.

Other known gaps are listed under "Open questions" in each design note.

## Conformance

Harness: `@modelcontextprotocol/conformance@0.2.0-alpha.12` (pinned by
`scripts/conformance-harness/package-lock.json`). Tier scores use the frozen requirement sets of
that release.

| Revision | Client | Server |
|---|---|---|
| 2025-11-25 | 100% | 100% |
| 2026-07-28 | 100% | 100% |

| Leg | Baseline entries (server / client) |
|---|---|
| `--spec-version 2025-11-25` | 0 / 0 |
| `--spec-version 2026-07-28` | 0 / 0 |
| default | 25 / 0, extension scenarios only (tasks); the skills scenarios SKIP |

How the legs work: [conformance/README.md](conformance/README.md).
