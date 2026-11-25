# Rough edges

This file lists known API decisions and gaps, kept for compatibility or
deferred, with their workarounds. Each item describes the current code. Some
will change in a later major version.

## Versions

- `Version.latest` is 2025-11-25, not the newest revision the SDK
  implements. It is the version `initialize` requests and the initial
  `MCP-Protocol-Version` header of `HTTPClientTransport`. The newest revision
  is `Version.stateless[0]`. See [protocol_versions.md](protocol_versions.md).

## Client API

- The convenience methods return tuples: `listTools()`, `listPrompts()`,
  `listResources()` and `listResourceTemplates()` return the items and the
  next cursor; `callTool` returns content and `isError`; `getPrompt` the
  description and messages. The tuples drop `_meta`, `ttlMs`, `cacheScope`
  and, for `callTool`, `structuredContent`.

  **Workaround**: `send(_:)` returns the whole result.

%include Examples/Snippets/Guides/RoughEdges.swift rough-full-result

- `callTool(name:arguments:meta:)` has two overloads that differ only in the
  return type: an `async` one that returns the tuple, and a synchronous one
  that returns a `RequestContext<CallTool.Result>`. An unannotated call picks
  the tuple.

  **Workaround**: annotate the type to get the `RequestContext`.

%include Examples/Snippets/Guides/RoughEdges.swift rough-call-tool-overloads

- `connect(transport:)` returns an `Initialize.Result` in every mode. On a
  stateless connection it is built from the `server/discover` result. When
  the server sent no `io.modelcontextprotocol/serverInfo`, both the result's
  `serverInfo` and `Client.serverInfo` have an empty name and version,
  rather than `nil`.

- On a stateless connection, `setLoggingLevel(_:)` changes the public
  `configuration.logLevel` instead of sending a request.

- `Client.initialize()` is deprecated and kept: `connect(transport:)`
  initializes.

## Server API

- `start(transport:)` registers the default handlers for `initialize`,
  `ping`, `server/discover` and `subscriptions/listen`, and replaces handlers
  of yours for these methods that were registered before. Register
  replacements after `start`.

- Behind a `StatelessHTTPServerTransport`, handshake clients are served
  without a session: every `initialize` is answered, but the server keeps no
  client info or capabilities, so `Server.currentHandlerContext` has none for
  their requests, and there is no GET stream for messages outside a request.

  **Workaround**: route `initialize` clients to a
  `StatefulHTTPServerTransport`, with one `Server` per session.

- `Server` has no built-in `logging/setLevel` handler, and in the handshake
  era `log(level:logger:data:)` sends every message, whatever level the
  client set. Declaring the `logging` capability does not add a handler.

  **Workaround**: register a `SetLoggingLevel` handler, store the level, and
  filter before calling `log`.

- `Server.HandlerContext` has no public initializer, so a handler that reads
  `Server.currentHandlerContext` can be tested only through a connection. See
  [testing.md](testing.md#testing-handlers-directly).

- `Configuration.strict` defaults to `false`: in the handshake era a server
  serves requests sent before `initialize`.

## Content and results

- The `Tool.Content` cases have no default values for `annotations` and
  `_meta`, and the short forms, such as `.text(_:)` and `.text(text:)`, are
  deprecated helpers.

  **Workaround**: write all three values, or wrap them in a function.

%include Examples/Snippets/Guides/RoughEdges.swift rough-text-content

- `Client.Capabilities.Elicitation()` declares form elicitation, and decoding
  `"elicitation": {}` gives `form` too, for compatibility with clients that
  predate the `form` and `url` sub-capabilities.

## Errors

- `MCPError.connectionClosed` (-32000) and `transportError` (-32001) are local
  errors that use codes from the implementation-defined range. Decoded from
  the wire, -32000 and -32001 are `serverError(code:message:data:)`.

- `serverError(code:message:data:)` is the case for every code without its
  own case, including errors from clients. Its `localizedDescription` starts
  with `Server error:`.

- `resourceNotFound` and `invalidParams` share -32602. Decoding picks
  `resourceNotFound` when `data` has a `uri` and no `detail`.

- `HTTPClientTransport` reports OAuth failures as
  `MCPError.internalError("Authorization flow failed: ...")` with the
  description of the `OAuthAuthorizationError`. The typed error is not
  available to the caller.

- HTTP failures without a JSON-RPC body are `internalError` with a message
  per status code, such as `Session expired`, rather than distinct cases.

## Not implemented

| Item | Status |
|---|---|
| The `io.modelcontextprotocol/tasks` extension (`tasks-*` conformance scenarios) | Deferred. Not scored for any tier; listed in `conformance/baseline.yml`. |
| DPoP-bound tokens (SEP-1932; `auth/dpop`, `auth/dpop-nonce`) | Deferred. |
| Enterprise-managed authorization (`auth/enterprise-managed-authorization`) | Deferred. |
| Workload identity with the JWT bearer grant (`auth/wif-jwt-bearer`) | Deferred. `OAuthConfiguration.GrantType` has `authorizationCode` and `clientCredentials` only. |

The capability structs carry `extensions`, so an application can declare and
read extension settings, but the SDK implements none of these extensions.
