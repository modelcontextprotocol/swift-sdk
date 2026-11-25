# Rough edges

This file lists known API decisions and gaps, kept for compatibility or
deferred, with their workarounds. Each item describes the current code. Some
will change in a later major version.

## Server API

- Behind a `StatelessHTTPServerTransport`, handshake clients are served
  without a session: every `initialize` is answered, but the server keeps no
  client info or capabilities, so `Server.currentHandlerContext` has none for
  their requests, and there is no GET stream for messages outside a request.

  **Workaround**: route `initialize` clients to a
  `StatefulHTTPServerTransport`, with one `Server` per session.

- `Configuration.strict` defaults to `false`: in the handshake era a server
  serves requests sent before `initialize`.

## Content and results

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

## Not implemented

| Item | Status |
|---|---|
| The `io.modelcontextprotocol/tasks` extension (`tasks-*` conformance scenarios) | Planned ([ROADMAP.md](../ROADMAP.md#planned)). Not scored for any tier; listed in `conformance/baseline.yml`. |
| The experimental tasks of 2025-11-25 (SEP-1686) | Planned for `tools/call` ([ROADMAP.md](../ROADMAP.md#planned)). Tasks hosted by the client (task-augmented sampling and elicitation) are deferred. |
| The `io.modelcontextprotocol/skills` extension (`sep-2640-*` conformance scenarios) | Planned ([ROADMAP.md](../ROADMAP.md#planned)). Not scored for any tier; the scenarios SKIP. |
| DPoP: algorithms other than ES256 | Not implemented. Proofs are ES256 with a P-256 `DPoPSigningKey`. |
| An OpenID Connect sign-in helper for enterprise-managed authorization | Not planned. `enterpriseManaged` takes the user's ID token from the application. |

The capability structs carry `extensions`, so an application can declare and
read extension settings, but the SDK implements none of these extensions.
