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

### Tasks

| Revision | SEP | API | Design |
|---|---|---|---|
| 2026-07-28: the `io.modelcontextprotocol/tasks` extension (server-directed tasks, `tasks/get`, `tasks/update`, `tasks/cancel`, `notifications/tasks` on `subscriptions/listen`, -32021 gating, `Mcp-Name` routing) | SEP-2663 | `Server.withTasks(_:)`, `HandlerContext.runAsTask(ttl:pollInterval:_:)`, `TaskManager`, `Client.Configuration.tasks`, `TaskHandle`, `SubscriptionFilter.taskIds` | [tasks.md](design/tasks.md) |
| 2025-11-25: experimental tasks for `tools/call` (`task` parameter, `Tool.execution`, `tasks/get`, `tasks/result`, `tasks/list`, `tasks/cancel`, `notifications/tasks/status`, progress for the task's lifetime) | SEP-1686 | the same, with `Client.Configuration.Tasks.augmentation` | [tasks.md](design/tasks.md) |

One task store (`TaskStore`, in-memory by default) is behind both wire forms. Earlier revisions
have no tasks: the work runs inline. The server passes the 10 `tasks-*` conformance scenarios;
the harness has none for 2025-11-25, which the interop `tasks` profile checks against the
TypeScript SDK. Tasks hosted by the client (2025-11-25 task-augmented sampling and elicitation)
are not implemented.

### Skills

| Feature | SEP | API | Design |
|---|---|---|---|
| The `io.modelcontextprotocol/skills` extension: `skills/list`, `skills/get`, `resources/directory/read`, skill files through `resources/read` and `resources/list` | SEP-2640 | `Server.withSkills(_:listInResources:)`, `SkillCatalog`, `SkillPackage`, `InMemorySkillCatalog`; `Client.listSkills(cursor:)`, `getSkill(uri:)`, `readResourceDirectory(uri:cursor:)` | [skills.md](design/skills.md) |
| Loading with verification (size, digest, frontmatter) and no prefetching | SEP-2640 | `Client.loadSkill(_:options:)`, `LoadedSkill`, `SkillVerificationError`, `Skill.manifestFingerprint` | [skills.md](design/skills.md) |

Frontmatter is YAML 1.2 (core schema) through Yams, as the conformance harness reads it. The
server passes the 3 `sep-2640-*` server scenarios and the client the 4 client scenarios; no
other SDK implements the extension.

### Server Cards

| Feature | SEP | API | Design |
|---|---|---|---|
| The Server Card document, built from `Server.Info`, with the checks of the format | SEP-2127 | `ServerCard`, `ServerCard.validate()`, `ServerCardError` | [server_cards.md](design/server_cards.md) |
| Serving at `<endpoint>/server-card`, with `ETag`, `If-None-Match`, caching and CORS | SEP-2127 | `ServerCardValidator` | [server_cards.md](design/server_cards.md) |
| Fetching, URL templates, and checks against `server/discover` | SEP-2127 | `ServerCard.fetch(from:ifNoneMatch:session:)`, `cardURL(forEndpoint:)`, `Remote.url(resolving:)`, `mismatches(with:)` | [server_cards.md](design/server_cards.md) |

The format is the one of `modelcontextprotocol/ext-server-card` at `526201bb`; the tests use its
examples. The SDK does not read AI Catalogs: the application passes the card URL.

### MCP Apps

| Feature | SEP | API | Design |
|---|---|---|---|
| Views: `ui://` resources served before the application's handler and merged into `resources/list` | SEP-1865 | `Server.withAppResources(_:listInResources:)`, `UIResource` | [apps.md](design/apps.md) |
| Tool and resource metadata, with the deprecated flat key read | SEP-1865 | `Tool.ui`, `ToolUIMeta`, `Resource.ui`, `Resource.Content.ui`, `UIResourceMeta`, `isVisibleToModel`, `isCallableFromApp` | [apps.md](design/apps.md) |
| The extension settings | SEP-1865 | `Client.Capabilities.ui`, `UIExtensionSettings`, `HandlerContext.clientUISettings` | [apps.md](design/apps.md) |
| Reading a view with its effective metadata, and its Content Security Policy | SEP-1865 | `Client.readAppResource(uri:listing:)`, `AppResourceContents`, `UIResourceMeta.CSP.policy()`, `restrictiveDefault` | [apps.md](design/apps.md) |

The wire is the one of `io.modelcontextprotocol/ui` at `ext-apps` `v2.0.4` (`7af9a75d`).

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

The SEPs marked Planned in [SEP coverage](#sep-coverage), and:

- The MCP Apps View-Host bridge (SEP-1865): `ui/initialize` and the host context,
  `ui/notifications/*`, the view's `tools/call` with visibility enforced, sampling through the
  host, size and display modes, and app-provided tools. It needs a `WKWebView` transport (Apple
  platforms only) and, for web hosts, the sandbox proxy ([design/apps.md](design/apps.md)).

The conformance harness exercises extensions only in the default leg, as scenarios that do not
count toward a tier; their failing checks would be entries in
[conformance/baseline.yml](conformance/baseline.yml).

Other known gaps are listed under "Open questions" in each design note.

## SEP coverage

One row for each SEP in the [official SEP index](https://modelcontextprotocol.io/seps) (44 SEPs,
read on 2026-10-28), and for the SEPs that the specification changelogs cite but the index does
not list (835, 837, 1932, 1933, 2352). Status values:

- Implemented: the SDK does what the SEP asks of an SDK.
- Partial: the SDK does part of it; the column after the status gives the gap.
- Planned: not done yet; the column after the status gives the gap.
- Not applicable: the SEP asks nothing of an SDK.

A change that implements a SEP updates its row.

| SEP | Title | Track | Status | Where, or why |
|---|---|---|---|---|
| 414 | OpenTelemetry trace context in `_meta` | Standards | Not applicable | A naming convention for `_meta` keys (`traceparent`, `tracestate`, `baggage`). The SDK passes `_meta` keys through unchanged. |
| 835 | Incremental scope consent through `WWW-Authenticate` | Not in the index | Implemented | `OAuthAuthorizer`: scope from the challenge, then `scopes_supported`; step-up on `403 insufficient_scope`. [auth.md](design/auth.md) |
| 837 | `application_type` in dynamic client registration | Not in the index | Implemented | `OAuthConfiguration.applicationType` |
| 932 | Governance | Process | Not applicable | Project governance; no protocol surface. |
| 973 | Icons and other metadata for implementations, resources, tools and prompts | Standards | Implemented | `Icon`; `icons` on `Tool`, `Resource`, `Resource.Template`, `Prompt`, `Client.Info` and `Server.Info`; `websiteUrl` on `Client.Info` and `Server.Info` |
| 985 | Protected resource metadata aligned with RFC 9728 | Standards | Implemented | `OAuthDiscovery` (the `WWW-Authenticate` URL, then the well-known URLs); `ProtectedResourceMetadataValidator` |
| 986 | Tool name format | Standards | Implemented | `Tool.isValidName(_:)`. The server logs a warning once for each listed name that does not have the format or that a result has twice; the client logs one for each name without the format. Nothing is refused: the specification says SHOULD. |
| 990 | Enterprise IdP policy controls | Standards | Implemented | `OAuthConfiguration.enterpriseManaged(...)`, `OAuthTokenExchange` |
| 991 | Client ID metadata documents | Standards | Implemented | An https `clientID` URL, used when the authorization server sets `client_id_metadata_document_supported`; otherwise dynamic registration |
| 994 | Shared communication practices | Process | Not applicable | Community process. |
| 1024 | Client security for local server installation | Standards | Not applicable | Applies to host applications that install local servers. The SDK installs nothing. |
| 1034 | Default values for primitive types in elicitation schemas | Standards | Implemented | The requested schema is `Value` (`Elicitation.RequestSchema.properties`); conformance `elicitation-sep1034-*` |
| 1036 | URL mode elicitation | Standards | Implemented | `CreateElicitation.Parameters.url`, `Elicitation.Mode.url`, `ElicitationCompleteNotification` (2025-11-25) |
| 1046 | OAuth client credentials flow | Standards | Implemented | `OAuthConfiguration.GrantType.clientCredentials` |
| 1302 | Working groups and interest groups | Standards | Not applicable | Governance. |
| 1303 | Input validation errors as tool execution errors | Standards | Not applicable | Guidance for tool handlers, given in the server guide ([Errors and isError](docs/server.md#errors-and-iserror)). The SDK does not validate tool arguments. |
| 1319 | Request payloads decoupled from method definitions | Standards | Not applicable | A schema refactor. The SDK already models each method's `Parameters` as its own type (`Method`). |
| 1330 | Elicitation enum schemas | Standards | Implemented | The requested schema is `Value`; conformance `elicitation-sep1330-*` |
| 1577 | Sampling with tools | Standards | Implemented | `Server.requestSampling(...tools:toolChoice:...)` and sampling input requests; `sampling.tools` and `sampling.context` checks at both eras; the rules for tool uses and tool results, checked by server and client. [Sampling with tools](docs/server.md#sampling-with-tools) |
| 1613 | JSON Schema 2020-12 as the default dialect | Standards | Partial | Schemas are `Value`. The SDK does not validate them. |
| 1686 | Tasks (2025-11-25) | Standards | Implemented | [Tasks](#tasks) |
| 1699 | SSE polling through server-side disconnect | Standards | Implemented | `HTTPClientTransport` resumes a closed stream with a GET and its last event ID; `StatefulHTTPServerTransport` sends priming events (`retryInterval`) |
| 1730 | SDK tiering | Standards | Not applicable | Asks something of the SDK project, which the tooling meets: `scripts/run-conformance.sh --requirements <revision>` scores the tier sets, and CI gates on them. |
| 1850 | PR-based SEP workflow | Process | Not applicable | Process. |
| 1865 | MCP Apps | Extensions | Partial | [MCP Apps](#mcp-apps): the wire between server and host; the View-Host bridge is Planned |
| 1932 | DPoP | Not in the index | Implemented | [Authorization](#authorization) |
| 1933 | Workload identity federation | Not in the index | Implemented | [Authorization](#authorization) |
| 2085 | Governance succession and amendment | Process | Not applicable | Governance. |
| 2106 | `inputSchema` and `outputSchema` as JSON Schema 2020-12 | Standards | Partial | Schemas are `Value`, so any keyword is kept, and the client never fetches a network `$ref`. The SDK does not resolve `$ref` or bound composition keywords, because it does not validate. |
| 2127 | Server Cards | Extensions | Implemented | [Server Cards](#server-cards); no AI Catalog discovery |
| 2133 | Extensions | Standards | Implemented | `extensions` on both capability structs |
| 2148 | Contributor ladder | Process | Not applicable | Governance. |
| 2149 | Group charter template | Process | Not applicable | Governance. |
| 2164 | Resource not found error code | Standards | Implemented | `MCPError.resourceNotFound(uri:message:)` |
| 2207 | OIDC refresh token guidance | Standards | Partial | Dynamic registration declares the `refresh_token` grant (a SHOULD). The client does not add `offline_access` (a MAY). |
| 2243 | HTTP header standardization | Standards | Implemented | [2026-07-28 core](#2026-07-28-core) |
| 2260 | Server requests belong to a client request | Standards | Implemented | Met at 2026-07-28, which has no server-to-client requests: a request to the client throws -32600, in a handler and outside one. At 2025-11-25 and earlier, which allow them, a sampling or elicitation request sent while the server handles no client request is sent, with one warning for each method. The client answers such requests. [Requests to the client](docs/server.md#requests-to-the-client) |
| 2322 | Multi round-trip requests | Standards | Implemented | [2026-07-28 core](#2026-07-28-core) |
| 2352 | Client credentials bound to their authorization server | Not in the index | Implemented | [Authorization](#authorization) |
| 2468 | `iss` in authorization responses | Standards | Implemented | [Authorization](#authorization) |
| 2484 | Conformance tests for Final SEPs | Process | Not applicable | Asks something of SEP authors. The SDK runs those tests: every leg runs `--suite all`. |
| 2549 | TTL for list results | Standards | Implemented | [2026-07-28 core](#2026-07-28-core) |
| 2567 | Sessionless MCP | Standards | Implemented | `StatelessHTTPServerTransport` has no session. Lists that do not vary per client are the server's duty. |
| 2575 | Stateless MCP | Standards | Implemented | [2026-07-28 core](#2026-07-28-core) |
| 2577 | Deprecate roots, sampling and logging | Standards | Implemented | The features work on every revision that has them. Their entry points are `@available(*, deprecated)`; types and capabilities carry a note. A notice is logged once when the peer declares a deprecated capability. [Deprecated by the specification](docs/rough_edges.md#deprecated-by-the-specification) |
| 2596 | Feature lifecycle and deprecation policy | Process | Implemented | The policy needs no code; its Tier 1 SDK obligations are met as for SEP-2577. The `includeContext` values `thisServer` and `allServers` are `@available(*, deprecated)`. HTTP+SSE was never implemented. [Deprecated by the specification](docs/rough_edges.md#deprecated-by-the-specification) |
| 2640 | Skills | Extensions | Implemented | [Skills](#skills) |
| 2663 | Tasks extension | Extensions | Implemented | [Tasks](#tasks) |
| 3398 | Release cycle updates (Accepted) | Process | Not applicable | Process. |

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
| default | 0 / 0 |

How the legs work: [conformance/README.md](conformance/README.md).
