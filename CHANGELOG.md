# Changelog

Release notes, newest first. Each release lists breaking changes, features, fixes, dependency
changes and deprecations ([VERSIONING.md](VERSIONING.md#release-notes)).

## 1.0.0 (unreleased)

The first release with the 1.x stability promise ([VERSIONING.md](VERSIONING.md)). It adds the
2026-07-28 revision of MCP next to the `initialize`-based revisions (2024-11-05 through
2025-11-25), on one `Server` and one `Client`. Changes since 0.12 (`main` at `2a44bfd`), with
before and after code: [docs/migration.md](docs/migration.md).

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
- Swift 6.1 tools are required.

### Features

- 2026-07-28: per-request `_meta`, `server/discover`, `subscriptions/listen`,
  `StatelessHTTPServerTransport`, `resultType`, multi round-trip requests with sealed
  `requestState`, `Mcp-Method`/`Mcp-Name`/`Mcp-Param-*` headers, cache hints, `extensions`, error
  codes -32020 to -32022.
- Authorization: issuer checks (RFC 8414, RFC 9207), `application_type`, authorization server
  migration, the JWT bearer grant, enterprise-managed authorization with token exchange, workload
  identity, DPoP.
- A built-in `logging/setLevel` handler that filters `Server.log`.
- The full list, with the specification references: [ROADMAP.md](ROADMAP.md#implemented-in-100).

### Fixes

- A stopped `Server` is released; every started server leaked before.
- On Linux, `HTTPClientTransport` reads responses as they arrive and handles server-sent events,
  so streamed results, server-to-client requests and notifications arrive as on Apple platforms.
- A non-2xx reply with the request's JSON-RPC error delivers that error.
- A refresh token goes only to the authorization server that issued it, and concurrent OAuth
  challenges run one at a time.
- Server-to-client requests run off the receive loop, at most four at a time, and can be cancelled.
- The other behavior changes: [docs/migration.md](docs/migration.md#behavior-changes).

### Dependencies

- Added swift-crypto (`3.0.0..<5.0.0`): `requestState` sealing, PKCE and `private_key_jwt`, also
  on Linux.
- Removed eventsource: `HTTPClientTransport` parses server-sent events itself.

### Deprecations

- `Version.latest`: use `Version.latestHandshake`.
